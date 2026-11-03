import Foundation
@testable import RepoPromptAgentCore
import XCTest

/// R9 schedule receipt kinds and the pure receipt-transfer repair decision, against a real
/// temporary recovery store (receipts and dispatch evidence come only from the lane).
@MainActor
final class AgentScheduledSendReceiptTransferTests: XCTestCase {
    // MARK: - Receipt kinds (codec)

    func testLegacyReceiptWithoutKindDecodesAsLegacyUnknownAndReencodesUnchanged() throws {
        let scheduleID = UUID()
        let attemptID = UUID()
        let legacy = """
        {"scheduleID":"\(scheduleID.uuidString)","attemptID":"\(attemptID.uuidString)","scheduledFor":10,"sentAt":20}
        """
        let decoded = try JSONDecoder().decode(AgentScheduledSendProvenance.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.kind, .legacyUnknown)
        XCTAssertFalse(decoded.isProviderAccepted, "Old data never becomes acceptance")
        XCTAssertNil(decoded.queueLink)
        XCTAssertEqual(decoded.scheduleID, scheduleID)
        XCTAssertEqual(decoded.attemptID, attemptID)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["scheduleID", "attemptID", "scheduledFor", "sentAt"])
        XCTAssertEqual(
            AgentScheduledSendProvenance(scheduleID: scheduleID, attemptID: attemptID, scheduledFor: decoded.scheduledFor, sentAt: decoded.sentAt),
            decoded,
            "The kindless initializer is legacyUnknown, never acceptance"
        )
    }

    func testProviderAcceptedAndSavedInQueueReceiptsRoundTrip() throws {
        let link = AgentScheduledSendQueueLink(intentID: UUID(), userItemID: UUID())
        let receipts = [
            AgentScheduledSendProvenance(scheduleID: UUID(), attemptID: UUID(), scheduledFor: Date(timeIntervalSince1970: 1), sentAt: Date(timeIntervalSince1970: 2), kind: .providerAccepted),
            AgentScheduledSendProvenance(scheduleID: UUID(), attemptID: UUID(), scheduledFor: Date(timeIntervalSince1970: 3), sentAt: Date(timeIntervalSince1970: 4), kind: .savedInQueue(link))
        ]
        for receipt in receipts {
            let decoded = try JSONDecoder().decode(AgentScheduledSendProvenance.self, from: JSONEncoder().encode(receipt))
            XCTAssertEqual(decoded, receipt)
        }
        XCTAssertTrue(receipts[0].isProviderAccepted)
        XCTAssertEqual(receipts[1].queueLink, link)
        XCTAssertFalse(receipts[1].isProviderAccepted, "Saved input is not delivery evidence")
    }

    func testUnknownOrIncompleteKindProjectsLegacyUnknownAndRetainsItsRawFieldsOnResave() throws {
        let base = "\"scheduleID\":\"\(UUID().uuidString)\",\"attemptID\":\"\(UUID().uuidString)\",\"scheduledFor\":1,\"sentAt\":2"
        let futureIntentID = UUID().uuidString
        let cases: [(name: String, json: String, retained: [String: Any])] = [
            (
                "unknown future kind",
                "{\(base),\"receiptKind\":\"deliveredTwice\",\"intentID\":\"\(futureIntentID)\",\"evidence\":{\"n\":3}}",
                ["receiptKind": "deliveredTwice", "intentID": futureIntentID, "evidence": ["n": 3]]
            ),
            (
                "incomplete savedInQueue",
                "{\(base),\"receiptKind\":\"savedInQueue\",\"intentID\":\"\(futureIntentID)\"}",
                ["receiptKind": "savedInQueue", "intentID": futureIntentID]
            ),
            (
                "malformed link",
                "{\(base),\"receiptKind\":\"savedInQueue\",\"intentID\":\"not-a-uuid\",\"userItemID\":7}",
                ["receiptKind": "savedInQueue", "intentID": "not-a-uuid", "userItemID": 7]
            )
        ]
        for testCase in cases {
            let decoded = try JSONDecoder().decode(AgentScheduledSendProvenance.self, from: Data(testCase.json.utf8))
            XCTAssertEqual(decoded.kind, .legacyUnknown, testCase.name)
            XCTAssertFalse(decoded.isProviderAccepted, testCase.name)
            XCTAssertNil(decoded.queueLink, testCase.name)

            let resaved = try JSONEncoder().encode(decoded)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: resaved) as? NSDictionary, testCase.name)
            for (key, value) in testCase.retained {
                XCTAssertEqual(object[key] as? NSObject, value as? NSObject, "\(testCase.name): \(key) is written back verbatim")
            }
            let redecoded = try JSONDecoder().decode(AgentScheduledSendProvenance.self, from: resaved)
            XCTAssertEqual(redecoded, decoded, "\(testCase.name): a re-save is lossless and stays legacyUnknown")
        }
    }

    func testRecognizedKindRetainsUninterpretedExtraFields() throws {
        let json = """
        {"scheduleID":"\(UUID().uuidString)","attemptID":"\(UUID().uuidString)","scheduledFor":1,"sentAt":2,\
        "receiptKind":"providerAccepted","acceptedBy":"future"}
        """
        let decoded = try JSONDecoder().decode(AgentScheduledSendProvenance.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .providerAccepted)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertEqual(object["acceptedBy"] as? String, "future")
        XCTAssertEqual(object["receiptKind"] as? String, "providerAccepted")
    }

    // MARK: - Transfer repair decision (real store)

    func testNoLinkedIntentAppliesLegacyNormalization() async throws {
        let fixture = try await RecoveryLaneFixture.make("schedule-transfer-none")
        defer { fixture.tearDown() }
        let record = makeDispatchingRecord()
        let initialRecord = try await fixture.lane.readRecord().get()
        XCTAssertEqual(
            AgentScheduledSendTransfer.resolve(record: record, recoveryRecord: initialRecord, sentAt: Date()),
            .noLinkedIntent
        )
        // An unrelated intent does not link.
        _ = try await fixture.queuedIdentity("unrelated")
        let withUnrelated = try await fixture.lane.readRecord().get()
        XCTAssertEqual(
            AgentScheduledSendTransfer.resolve(record: record, recoveryRecord: withUnrelated, sentAt: Date()),
            .noLinkedIntent
        )
    }

    func testQueuedLinkedIntentRepairsAsSavedInQueueNeverAcceptance() async throws {
        let fixture = try await RecoveryLaneFixture.make("schedule-transfer-queued")
        defer { fixture.tearDown() }
        let record = makeDispatchingRecord()
        let attempt = try XCTUnwrap(record.attempt)
        let identity = try await admitScheduled(record: record, attempt: attempt, in: fixture)
        let intentID = try XCTUnwrap(identity.intentID)
        let sentAt = Date(timeIntervalSince1970: 500)

        let state = try await fixture.lane.readRecord().get()
        XCTAssertTrue(AgentScheduledSendTransfer.intentNeverDispatched(intentID: intentID, in: state))
        let resolution = AgentScheduledSendTransfer.resolve(record: record, recoveryRecord: state, sentAt: sentAt)
        XCTAssertEqual(
            resolution,
            .completeTransfer(AgentScheduledSendProvenance(
                scheduleID: record.id,
                attemptID: attempt.attemptID,
                scheduledFor: record.notBefore,
                sentAt: sentAt,
                kind: .savedInQueue(AgentScheduledSendQueueLink(intentID: intentID, userItemID: attempt.itemID))
            ))
        )
    }

    func testUncertainDeliveryIsHeldWithPayloadUnchangedNeverSavedOrAccepted() async throws {
        let fixture = try await RecoveryLaneFixture.make("schedule-transfer-uncertain")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()

        // `dispatching` with no outcome yet (a crash mid-handoff) and recorded `deliveryUnknown`.
        for notesUnknown in [false, true] {
            let record = makeDispatchingRecord()
            let identity = try await admitScheduled(record: record, attempt: XCTUnwrap(record.attempt), in: fixture)
            let admittedIntent = await fixture.intent(identity)
            let admitted = try XCTUnwrap(admittedIntent)
            let evidence = try await AgentRecoveryDispatchEvidence.begin(
                session: session,
                constituents: [identity],
                runAttemptID: nil
            ).get()
            if notesUnknown {
                evidence.noteDeliveryUnknown()
            }
            let failures = await evidence.settled()
            XCTAssertTrue(failures.isEmpty)

            let state = try await fixture.lane.readRecord().get()
            let intentID = try XCTUnwrap(identity.intentID)
            XCTAssertFalse(AgentScheduledSendTransfer.intentNeverDispatched(intentID: intentID, in: state))
            guard case .hold = AgentScheduledSendTransfer.resolve(record: record, recoveryRecord: state, sentAt: Date()) else {
                return XCTFail("Uncertain delivery (deliveryUnknown: \(notesUnknown)) is held, never a receipt")
            }
            let currentIntent = await fixture.intent(identity)
            let current = try XCTUnwrap(currentIntent)
            XCTAssertEqual(current.deliveryState, notesUnknown ? .deliveryUnknown : .dispatching)
            XCTAssertEqual(current.payload, admitted.payload, "The held input's payload is unchanged")
            XCTAssertEqual(current.userItemID, record.attempt?.itemID)
        }
    }

    func testProvenNonHandoffBackInQueueRepairsAsSavedInQueueAndLaterWithdrawalIsHeld() async throws {
        let fixture = try await RecoveryLaneFixture.make("schedule-transfer-requeued")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()
        let record = makeDispatchingRecord()
        let attempt = try XCTUnwrap(record.attempt)
        let identity = try await admitScheduled(record: record, attempt: attempt, in: fixture)
        let intentID = try XCTUnwrap(identity.intentID)
        let evidence = try await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [identity],
            runAttemptID: nil
        ).get()
        evidence.noteNoHandoff()
        let failures = await evidence.settled()
        XCTAssertTrue(failures.isEmpty)

        let requeued = try await fixture.lane.readRecord().get()
        XCTAssertEqual(requeued.record?.intent(id: intentID)?.deliveryState, .queued)
        XCTAssertFalse(AgentScheduledSendTransfer.intentNeverDispatched(intentID: intentID, in: requeued), "A delivery attempt exists")
        guard case let .completeTransfer(receipt) = AgentScheduledSendTransfer.resolve(
            record: record,
            recoveryRecord: requeued,
            sentAt: Date()
        ) else {
            return XCTFail("A durably queued intent owns the input")
        }
        XCTAssertEqual(receipt.queueLink, AgentScheduledSendQueueLink(intentID: intentID, userItemID: attempt.itemID))

        _ = try await fixture.lane.withdraw(intentID: intentID).get()
        let withdrawn = try await fixture.lane.readRecord().get()
        guard case .hold = AgentScheduledSendTransfer.resolve(record: record, recoveryRecord: withdrawn, sentAt: Date()) else {
            return XCTFail("A withdrawal after a delivery attempt is held, not a rollback")
        }
    }

    func testOnlyAffirmativeAcceptanceRepairsAsProviderAccepted() async throws {
        let fixture = try await RecoveryLaneFixture.make("schedule-transfer-accepted")
        defer { fixture.tearDown() }
        let session = fixture.boundTabSession()

        let acceptedRecord = makeDispatchingRecord()
        let acceptedIdentity = try await admitScheduled(record: acceptedRecord, attempt: XCTUnwrap(acceptedRecord.attempt), in: fixture)
        let acceptedEvidence = try await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: [acceptedIdentity],
            runAttemptID: nil
        ).get()
        acceptedEvidence.noteAccepted()
        let acceptedFailures = await acceptedEvidence.settled()
        XCTAssertTrue(acceptedFailures.isEmpty)
        let acceptedRecoveryRecord = try await fixture.lane.readRecord().get()
        guard case let .completeTransfer(acceptedReceipt) = AgentScheduledSendTransfer.resolve(
            record: acceptedRecord,
            recoveryRecord: acceptedRecoveryRecord,
            sentAt: Date()
        ) else {
            return XCTFail("Recorded acceptance completes the transfer")
        }
        XCTAssertEqual(acceptedReceipt.kind, .providerAccepted)
    }

    func testConflictingOrMismatchedLinksAreHeldNotConfirmed() async throws {
        let fixture = try await RecoveryLaneFixture.make("schedule-transfer-conflict")
        defer { fixture.tearDown() }
        let record = makeDispatchingRecord()
        let attempt = try XCTUnwrap(record.attempt)

        // One intent from another attempt of the same schedule (not rolled back): mismatch.
        let otherAttempt = AgentScheduledSendPersist.Attempt(attemptID: UUID(), itemID: UUID(), startedAt: Date())
        _ = try await admitScheduled(record: record, attempt: otherAttempt, in: fixture)
        let mismatchedRecord = try await fixture.lane.readRecord().get()
        guard case .hold = AgentScheduledSendTransfer.resolve(
            record: record,
            recoveryRecord: mismatchedRecord,
            sentAt: Date()
        ) else {
            return XCTFail("A link to another attempt is conflicting evidence")
        }

        // A matching intent alongside it: several owners claim the schedule.
        _ = try await admitScheduled(record: record, attempt: attempt, in: fixture)
        let severalOwnersRecord = try await fixture.lane.readRecord().get()
        guard case .hold = AgentScheduledSendTransfer.resolve(
            record: record,
            recoveryRecord: severalOwnersRecord,
            sentAt: Date()
        ) else {
            return XCTFail("Several linked intents are held")
        }
    }

    func testRolledBackAdmissionsAreHistoryNotOwners() async throws {
        let fixture = try await RecoveryLaneFixture.make("schedule-transfer-rollback")
        defer { fixture.tearDown() }
        let record = makeDispatchingRecord()
        let attempt = try XCTUnwrap(record.attempt)

        // An earlier attempt's never-dispatched admission, withdrawn on rollback, is ignored.
        let earlier = AgentScheduledSendPersist.Attempt(attemptID: UUID(), itemID: UUID(), startedAt: Date())
        let earlierIdentity = try await admitScheduled(record: record, attempt: earlier, in: fixture)
        _ = try await fixture.lane.withdraw(intentID: XCTUnwrap(earlierIdentity.intentID)).get()
        let afterEarlierRollback = try await fixture.lane.readRecord().get()
        XCTAssertEqual(
            AgentScheduledSendTransfer.resolve(record: record, recoveryRecord: afterEarlierRollback, sentAt: Date()),
            .noLinkedIntent
        )

        // This attempt's own rolled-back admission leaves the schedule as the owner.
        let current = try await admitScheduled(record: record, attempt: attempt, in: fixture)
        _ = try await fixture.lane.withdraw(intentID: XCTUnwrap(current.intentID)).get()
        let afterCurrentRollback = try await fixture.lane.readRecord().get()
        XCTAssertEqual(
            AgentScheduledSendTransfer.resolve(record: record, recoveryRecord: afterCurrentRollback, sentAt: Date()),
            .rolledBack
        )
    }

    // MARK: - Helpers

    private func makeDispatchingRecord() -> AgentScheduledSendPersist {
        let start = Date(timeIntervalSince1970: 100)
        return AgentScheduledSendPersist(
            id: UUID(),
            createdAt: start,
            updatedAt: start,
            notBefore: start.addingTimeInterval(60),
            state: .dispatching,
            rawText: "scheduled",
            attachments: [],
            taggedFileAttachments: [],
            interviewFirst: false,
            isNewSessionStart: false,
            runAlongsideOtherSessions: false,
            attempt: AgentScheduledSendPersist.Attempt(attemptID: UUID(), itemID: UUID(), startedAt: start)
        )
    }

    private func admitScheduled(
        record: AgentScheduledSendPersist,
        attempt: AgentScheduledSendPersist.Attempt,
        in fixture: RecoveryLaneFixture
    ) async throws -> AgentQueuedInputIdentity {
        let admitted = try await fixture.lane.admitQueued(AgentRecoveryAdmission(
            binding: fixture.lane.binding,
            userItemID: attempt.itemID,
            origin: .scheduled,
            target: .session,
            original: RecoveryTestSupport.content(record.rawText),
            scheduleReference: AgentScheduledSendTransfer.recoveryScheduleReference(scheduleID: record.id, attempt: attempt)
        )).get()
        return AgentQueuedInputIdentity(receipt: admitted.receipt)
    }
}
