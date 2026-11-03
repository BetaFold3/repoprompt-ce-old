@testable import RepoPromptAgentCore
import XCTest

/// Durable pending-handoff association (lossless restart, inactive): the session payload's durable
/// ID and the exact handoff snapshot captured on a recovery intent before any handoff.
final class AgentRecoveryPendingHandoffTests: XCTestCase {
    private typealias Support = RecoveryTestSupport

    private var root: URL!
    private let instanceA = UUID()

    override func setUpWithError() throws {
        root = try Support.makeTemporaryRoot("AgentRecoveryPendingHandoffTests")
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A fresh actor on the same root models a relaunch of the same launch instance (fresh reload).
    private func makeStore() -> AgentRecoveryStore {
        AgentRecoveryStore(
            rootURL: root.appendingPathComponent("AgentRecovery/v1", isDirectory: true),
            appInstanceID: instanceA
        )
    }

    private func makeBinding() -> AgentRecoveryLifecycleBinding {
        AgentRecoveryLifecycleBinding(sessionID: UUID(), incarnationID: UUID(), transcriptResetGeneration: 0)
    }

    private func handoff(
        payloadID: UUID = UUID(),
        payload: String = "## Handoff\nPrior context",
        prependedText: String? = nil
    ) -> AgentRecoveryPendingHandoffSnapshot {
        AgentRecoveryPendingHandoffSnapshot(
            payloadID: payloadID,
            payload: payload,
            createdAt: AgentRecoveryTimestamp(millisecondsSince1970: 1234),
            sourceItemID: UUID(),
            prependedText: prependedText ?? "\(payload)\n\n---\n\n"
        )
    }

    private func submission(
        _ text: String,
        intentID: UUID = UUID(),
        userItemID: UUID = UUID(),
        pendingHandoff: AgentRecoveryPendingHandoffSnapshot?
    ) -> AgentRecoveryIntentSubmission {
        AgentRecoveryIntentSubmission(
            intentID: intentID,
            userItemID: userItemID,
            origin: .composer,
            target: .session,
            payload: Support.content(text),
            pendingHandoff: pendingHandoff
        )
    }

    // MARK: - Session payload identity (v7)

    func testPendingHandoffPayloadIDRoundTripsInVersionSevenAndLegacyPayloadDecodesWithoutOne() throws {
        let payloadID = UUID()
        let session = AgentSession(
            id: UUID(),
            name: "Handoff",
            pendingHandoffPayload: "payload",
            pendingHandoffCreatedAt: Date(timeIntervalSince1970: 10),
            pendingHandoffSourceItemID: UUID(),
            pendingHandoffPayloadID: payloadID
        )
        let encoded = try AgentSessionDataCodec.encodeSession(session)
        let decoded = try AgentSessionDataCodec.decodeSession(from: encoded)
        XCTAssertEqual(decoded.serializationVersion, 7)
        XCTAssertEqual(decoded.pendingHandoffPayloadID, payloadID)
        XCTAssertEqual(decoded.pendingHandoffPayload, "payload")

        let withoutID = try AgentSessionDataCodec.encodeSession(AgentSession(id: UUID(), name: "None"))
        XCTAssertFalse(String(decoding: withoutID, as: UTF8.self).contains("pendingHandoffPayloadID"))

        let legacy = Data(
            """
            {
              "id": "\(UUID().uuidString)",
              "serializationVersion": 7,
              "name": "Legacy",
              "savedAt": 0,
              "autoEditEnabled": true,
              "pendingHandoffPayload": "legacy payload"
            }
            """.utf8
        )
        let legacySession = try AgentSessionDataCodec.decodeSession(from: legacy)
        XCTAssertEqual(legacySession.pendingHandoffPayload, "legacy payload")
        XCTAssertNil(legacySession.pendingHandoffPayloadID)

        // A legacy payload is assigned an ID once; an existing ID is never changed; clearing drops it.
        var state = AgentPendingHandoffState(payload: legacySession.pendingHandoffPayload)
        XCTAssertNil(AgentRecoveryPendingHandoffSnapshot(state, prependedText: "x"), "No snapshot without a durable ID")
        let assigned = try XCTUnwrap(state.ensurePayloadID())
        XCTAssertEqual(state.ensurePayloadID(), assigned)
        let snapshot = try XCTUnwrap(AgentRecoveryPendingHandoffSnapshot(state, prependedText: "legacy payload\n\n"))
        XCTAssertEqual(snapshot.payloadID, assigned)
        XCTAssertEqual(snapshot.payload, "legacy payload")
        XCTAssertEqual(snapshot.prependedText, "legacy payload\n\n")
        state.clearAfterSend()
        XCTAssertNil(state.payloadID)
        XCTAssertNil(state.ensurePayloadID(), "No payload, no ID")
    }

    func testHeaderStubCarriesPendingHandoffPayloadIDFromRealSessionFile() async throws {
        let directory = root.appendingPathComponent("sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payloadID = UUID()
        let sourceItemID = UUID()

        func writeSession(payloadIDLine: String) throws -> URL {
            let id = UUID().uuidString
            let payload = """
            {
              "id": "\(id)",
              "serializationVersion": 7,
              "name": "Header Session",
              "savedAt": 0,
              "itemCount": 0,
              "autoEditEnabled": true,
              "pendingHandoffPayload": "handoff payload",
              "pendingHandoffSourceItemID": "\(sourceItemID.uuidString)"\(payloadIDLine)
            }
            """
            let fileURL = directory.appendingPathComponent("AgentSession-\(id).json")
            try Data(payload.utf8).write(to: fileURL)
            return fileURL
        }

        let withID = try writeSession(payloadIDLine: #", "pendingHandoffPayloadID": "\#(payloadID.uuidString)""#)
        let stub = try await AgentSessionDataService.shared.loadAgentSessionStub(from: withID)
        XCTAssertTrue(stub.isListStub)
        XCTAssertEqual(stub.pendingHandoffPayload, "handoff payload")
        XCTAssertEqual(stub.pendingHandoffSourceItemID, sourceItemID)
        XCTAssertEqual(stub.pendingHandoffPayloadID, payloadID)

        let legacy = try writeSession(payloadIDLine: "")
        let legacyStub = try await AgentSessionDataService.shared.loadAgentSessionStub(from: legacy)
        XCTAssertEqual(legacyStub.pendingHandoffPayload, "handoff payload")
        XCTAssertNil(legacyStub.pendingHandoffPayloadID)
    }

    // MARK: - Codec

    func testPendingHandoffNestedUnknownMembersSurviveRewriteAndCorruptSnapshotIsPreserved() async throws {
        let store = makeStore()
        let session = makeBinding()
        let snapshot = handoff()
        let first = submission("user text", pendingHandoff: snapshot)
        _ = try await store.commitQueuedIntent(binding: session, expectedRevision: nil, submission: first, consumption: nil)

        let fileURL = store.recordFileURL(sessionID: session.sessionID)
        var json = try Support.readJSON(fileURL)
        let handoffPath: [Support.PathComponent] = [.key("intents"), .index(0), .key("pendingHandoff")]
        XCTAssertEqual(
            Support.member(json, at: [.key("intents"), .index(0), .key("payload")], key: "text"),
            .string("user text"),
            "The user payload stays the original input"
        )
        XCTAssertEqual(Support.member(json, at: handoffPath, key: "prependedText"), .string(snapshot.prependedText))
        Support.setMember(&json, at: handoffPath, key: "futureMember", value: .object(["n": .number(7)]))
        try Support.writeJSON(json, to: fileURL)

        let reloaded = try await loadRecord(makeStore(), session.sessionID)
        let stored = try XCTUnwrap(reloaded.intent(id: first.intentID)?.pendingHandoff)
        XCTAssertTrue(stored.hasSameContent(as: snapshot))
        XCTAssertEqual(stored.extras["futureMember"], .object(["n": .number(7)]))

        // An unrelated rewrite keeps the nested member.
        _ = try await makeStore().commitQueuedIntent(
            binding: session,
            expectedRevision: reloaded.revision,
            submission: Support.submission("second"),
            consumption: nil
        )
        XCTAssertEqual(
            try Support.member(Support.readJSON(fileURL), at: handoffPath, key: "futureMember"),
            .object(["n": .number(7)])
        )

        // A corrupt snapshot makes the record unreadable: bytes are preserved and never written.
        var corrupt = try Support.readJSON(fileURL)
        Support.setMember(&corrupt, at: handoffPath, key: "payloadID", value: .string("not-a-uuid"))
        try Support.writeJSON(corrupt, to: fileURL)
        let corruptBytes = try Data(contentsOf: fileURL)
        let state = await makeStore().read(sessionID: session.sessionID)
        guard case .preserved(.malformed(_)) = state else {
            return XCTFail("expected preserved malformed record, got \(state)")
        }
        await assertStoreErrorCategory(.unreadable) {
            try await self.makeStore().attachPendingHandoff(
                binding: session,
                expectedRevision: nil,
                intentID: first.intentID,
                snapshot: snapshot
            )
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes)
    }

    // MARK: - Attachment

    func testAttachToQueuedIntentThenBeginDispatchCarriesSnapshotAcrossFreshReload() async throws {
        let session = makeBinding()
        let queued = submission("user text", pendingHandoff: nil)
        let committed = try await makeStore().commitQueuedIntent(
            binding: session, expectedRevision: nil, submission: queued, consumption: nil
        )
        XCTAssertNil(committed.intent.pendingHandoff)

        let snapshot = handoff()
        let attached = try await makeStore().attachPendingHandoff(
            binding: session,
            expectedRevision: committed.intent.recordRevision,
            intentID: queued.intentID,
            snapshot: snapshot
        )
        XCTAssertEqual(attached.disposition, .committed)
        XCTAssertEqual(attached.deliveryState, .queued)
        XCTAssertEqual(attached.pendingHandoff, snapshot)

        let afterAttach = try await loadRecord(makeStore(), session.sessionID)
        XCTAssertEqual(afterAttach.revision, attached.recordRevision)
        XCTAssertEqual(afterAttach.intent(id: queued.intentID)?.pendingHandoff, snapshot)

        let attemptID = UUID()
        let dispatch = try await makeStore().beginDispatch(
            binding: session,
            expectedRevision: afterAttach.revision,
            intentID: queued.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: attemptID),
            authorization: .liveQueue
        )
        XCTAssertEqual(dispatch.intent.deliveryState, .dispatching)
        XCTAssertEqual(dispatch.intent.pendingHandoff, snapshot, "The dispatch receipt names the exact prefix")

        let afterDispatch = try await loadRecord(makeStore(), session.sessionID)
        let intent = try XCTUnwrap(afterDispatch.intent(id: queued.intentID))
        XCTAssertEqual(intent.deliveryState, .dispatching)
        XCTAssertEqual(intent.pendingHandoff, snapshot)
        XCTAssertEqual(intent.payload.text, "user text")
        XCTAssertEqual(afterDispatch.intents(carryingPendingHandoff: snapshot.payloadID).map(\.intentID), [queued.intentID])
        XCTAssertEqual(afterDispatch.attempts(forIntent: queued.intentID).map(\.attemptID), [attemptID])
    }

    func testAttachRefusesConflictingReplacementAndAttachmentWhileAHandoffMayHaveBegun() async throws {
        let store = makeStore()
        let session = makeBinding()
        let original = handoff()
        let queued = submission("queued", pendingHandoff: nil)
        var revision = try await store.commitQueuedIntent(
            binding: session, expectedRevision: nil, submission: queued, consumption: nil
        ).intent.recordRevision
        revision = try await store.attachPendingHandoff(
            binding: session, expectedRevision: revision, intentID: queued.intentID, snapshot: original
        ).recordRevision

        let conflicting = AgentRecoveryPendingHandoffSnapshot(
            payloadID: original.payloadID,
            payload: original.payload,
            createdAt: original.createdAt,
            sourceItemID: original.sourceItemID,
            prependedText: original.payload + "\n"
        )
        await assertStoreError(.intentConflict(queued.intentID)) {
            try await store.attachPendingHandoff(
                binding: session, expectedRevision: revision, intentID: queued.intentID, snapshot: conflicting
            )
        }
        await assertStoreError(.intentConflict(queued.intentID)) {
            try await store.attachPendingHandoff(
                binding: session, expectedRevision: revision, intentID: queued.intentID, snapshot: self.handoff()
            )
        }
        var record = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(record.revision, revision)
        XCTAssertEqual(record.intent(id: queued.intentID)?.pendingHandoff, original)

        // Dispatching: a handoff may have begun.
        let dispatching = submission("dispatching", pendingHandoff: nil)
        revision = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: revision, submission: dispatching,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID()), consumption: nil
        ).intent.recordRevision
        await assertStoreError(.invalidTransition(intentID: dispatching.intentID, from: .dispatching, operation: .attachPendingHandoff)) {
            try await store.attachPendingHandoff(
                binding: session, expectedRevision: revision, intentID: dispatching.intentID, snapshot: self.handoff()
            )
        }

        record = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(record.revision, revision)
        XCTAssertNil(record.intent(id: dispatching.intentID)?.pendingHandoff)
    }

    /// Main decision (R03 follow-up): a queued intent whose every earlier attempt is conclusively
    /// not delivered (pre-handoff, or verified rejection) may receive its first prefix before its
    /// redispatch. Attempts are kept unchanged, and the next dispatch carries the attached prefix.
    func testFirstAttachAfterOnlyAffirmativeNonDeliveryIsAllowedAndKeepsHistory() async throws {
        let store = makeStore()
        let session = makeBinding()
        let settled = submission("settled", pendingHandoff: nil)
        let first = UUID()
        var revision = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: nil, submission: settled,
            attempt: AgentRecoveryAttemptStart(attemptID: first), consumption: nil
        ).intent.recordRevision
        revision = try await store.settleToQueue(
            binding: session, expectedRevision: revision, intentID: settled.intentID,
            attemptID: first, evidence: .preHandoff, message: nil
        ).recordRevision
        let second = UUID()
        revision = try await store.beginDispatch(
            binding: session, expectedRevision: revision, intentID: settled.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: second), authorization: .liveQueue
        ).intent.recordRevision
        revision = try await store.settleToQueue(
            binding: session, expectedRevision: revision, intentID: settled.intentID,
            attemptID: second, evidence: .verifiedRejection, message: "rejected"
        ).recordRevision
        let attemptsBefore = try await loadRecord(store, session.sessionID).attempts(forIntent: settled.intentID)

        let snapshot = handoff()
        let attached = try await store.attachPendingHandoff(
            binding: session, expectedRevision: revision, intentID: settled.intentID, snapshot: snapshot
        )
        XCTAssertEqual(attached.disposition, .committed)
        XCTAssertEqual(attached.deliveryState, .queued)
        var record = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(record.intent(id: settled.intentID)?.pendingHandoff, snapshot)
        XCTAssertEqual(record.attempts(forIntent: settled.intentID), attemptsBefore, "No attempt is rewritten")

        // Identical repeat stays idempotent; a different prefix never replaces it.
        let repeated = try await store.attachPendingHandoff(
            binding: session, expectedRevision: nil, intentID: settled.intentID, snapshot: snapshot
        )
        XCTAssertEqual(repeated.disposition, .unchanged)
        await assertStoreError(.intentConflict(settled.intentID)) {
            try await store.attachPendingHandoff(
                binding: session, expectedRevision: nil, intentID: settled.intentID, snapshot: self.handoff()
            )
        }

        let third = UUID()
        let redispatch = try await store.beginDispatch(
            binding: session, expectedRevision: attached.recordRevision, intentID: settled.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: third), authorization: .liveQueue
        )
        XCTAssertEqual(redispatch.intent.pendingHandoff, snapshot, "The redispatch carries the attached prefix")
        record = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(record.attempts(forIntent: settled.intentID).map(\.attemptID), [first, second, third])
    }

    /// A queued intent whose recorded history does not prove non-delivery (here an attempt with
    /// `deliveryUnknown` evidence) keeps refusing a first attachment, and nothing is written.
    func testFirstAttachRefusedWhenAnyAttemptHasUncertainEvidence() async throws {
        let store = makeStore()
        let session = makeBinding()
        let queued = submission("uncertain", pendingHandoff: nil)
        let attemptID = UUID()
        var revision = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: nil, submission: queued,
            attempt: AgentRecoveryAttemptStart(attemptID: attemptID), consumption: nil
        ).intent.recordRevision
        revision = try await store.settleToQueue(
            binding: session, expectedRevision: revision, intentID: queued.intentID,
            attemptID: attemptID, evidence: .preHandoff, message: nil
        ).recordRevision
        // A history no store transition produces for a queued intent: its attempt's evidence is
        // uncertain. The predicate must still refuse it.
        let fileURL = store.recordFileURL(sessionID: session.sessionID)
        var json = try Support.readJSON(fileURL)
        Support.setMember(
            &json,
            at: [.key("attempts"), .index(0), .key("outcome")],
            key: "kind",
            value: .string("deliveryUnknown")
        )
        try Support.writeJSON(json, to: fileURL)
        let edited = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(edited.attempts(forIntent: queued.intentID).first?.outcome?.outcome, .deliveryUnknown)
        XCTAssertEqual(edited.intent(id: queued.intentID)?.deliveryState, .queued)
        let bytes = try Data(contentsOf: fileURL)

        await assertStoreError(.invalidTransition(intentID: queued.intentID, from: .queued, operation: .attachPendingHandoff)) {
            try await store.attachPendingHandoff(
                binding: session, expectedRevision: edited.revision, intentID: queued.intentID, snapshot: self.handoff()
            )
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes, "A refused attachment writes nothing")
    }

    /// The eligibility predicate over every attempt: zero attempts and closed pre-handoff/verified
    /// rejection evidence qualify; an open attempt, `deliveryUnknown`, `providerAccepted`, or any
    /// superseded evidence (current or earlier) disqualifies the whole history.
    func testAffirmativeNonDeliveryPredicateIsConservativeOverTheWholeHistory() {
        let intentID = UUID()
        func attempt(
            _ outcome: AgentRecoveryDeliveryOutcome?,
            superseded: AgentRecoveryDeliveryOutcome? = nil
        ) -> AgentRecoveryAttempt {
            AgentRecoveryAttempt(
                attemptID: UUID(),
                intentID: intentID,
                userItemID: UUID(),
                runAttemptID: nil,
                transcriptTurnID: nil,
                appInstanceID: UUID(),
                dispatchedAt: AgentRecoveryTimestamp(Date()),
                outcome: outcome.map { AgentRecoveryAttemptOutcome(outcome: $0, recordedAt: AgentRecoveryTimestamp(Date())) },
                supersededOutcome: superseded.map { AgentRecoveryAttemptOutcome(outcome: $0, recordedAt: AgentRecoveryTimestamp(Date())) }
            )
        }
        let preHandoff = AgentRecoveryDeliveryOutcome.failed(.preHandoff, message: nil)
        let rejected = AgentRecoveryDeliveryOutcome.failed(.verifiedRejection, message: "no")
        let qualifies = AgentRecoveryStore.hasOnlyAffirmativeNonDelivery

        XCTAssertTrue(qualifies([]))
        XCTAssertTrue(qualifies([attempt(preHandoff)]))
        XCTAssertTrue(qualifies([attempt(preHandoff), attempt(rejected)]))
        XCTAssertFalse(qualifies([attempt(nil)]), "An open attempt may have been handed off")
        XCTAssertFalse(qualifies([attempt(.deliveryUnknown)]))
        XCTAssertFalse(qualifies([attempt(.providerAccepted)]))
        XCTAssertFalse(qualifies([attempt(preHandoff), attempt(.deliveryUnknown)]), "One uncertain attempt disqualifies the history")
        XCTAssertFalse(qualifies([attempt(.providerAccepted, superseded: rejected)]), "Superseded acceptance conflict")
        XCTAssertFalse(qualifies([attempt(rejected, superseded: .deliveryUnknown)]), "A superseded uncertainty is never erased")
    }

    /// CAS race: acceptance evidence for an earlier attempt that lands after the attachment but
    /// before the redispatch advances the record; the queued redispatch is then refused, the
    /// acceptance stays intact, and the attached prefix is kept as history.
    func testLateAcceptanceBetweenAttachAndRedispatchRefusesTheRedispatch() async throws {
        let store = makeStore()
        let session = makeBinding()
        let queued = submission("raced", pendingHandoff: nil)
        let first = UUID()
        var revision = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: nil, submission: queued,
            attempt: AgentRecoveryAttemptStart(attemptID: first), consumption: nil
        ).intent.recordRevision
        revision = try await store.settleToQueue(
            binding: session, expectedRevision: revision, intentID: queued.intentID,
            attemptID: first, evidence: .preHandoff, message: nil
        ).recordRevision
        let snapshot = handoff()
        let attachedRevision = try await store.attachPendingHandoff(
            binding: session, expectedRevision: revision, intentID: queued.intentID, snapshot: snapshot
        ).recordRevision

        let accepted = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: attachedRevision, intentID: queued.intentID,
            attemptID: first, outcome: .providerAccepted
        )
        XCTAssertEqual(accepted.intent.deliveryState, .providerAccepted)

        await assertStoreErrorCategory(.revisionConflict) {
            try await store.beginDispatch(
                binding: session, expectedRevision: attachedRevision, intentID: queued.intentID,
                attempt: AgentRecoveryAttemptStart(attemptID: UUID()), authorization: .liveQueue
            )
        }
        await assertStoreError(.invalidTransition(intentID: queued.intentID, from: .providerAccepted, operation: .beginDispatch)) {
            try await store.beginDispatch(
                binding: session, expectedRevision: accepted.intent.recordRevision, intentID: queued.intentID,
                attempt: AgentRecoveryAttemptStart(attemptID: UUID()), authorization: .liveQueue
            )
        }
        let record = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(record.intent(id: queued.intentID)?.deliveryState, .providerAccepted)
        XCTAssertEqual(record.intent(id: queued.intentID)?.pendingHandoff, snapshot)
        XCTAssertEqual(record.attempts(forIntent: queued.intentID).map(\.attemptID), [first], "No redispatch attempt was written")
    }

    func testIdenticalAttachAndSubmissionAreDedupedByExactIDAndContent() async throws {
        let store = makeStore()
        let session = makeBinding()
        let snapshot = handoff()
        let queued = submission("queued", pendingHandoff: nil)
        var revision = try await store.commitQueuedIntent(
            binding: session, expectedRevision: nil, submission: queued, consumption: nil
        ).intent.recordRevision
        revision = try await store.attachPendingHandoff(
            binding: session, expectedRevision: revision, intentID: queued.intentID, snapshot: snapshot
        ).recordRevision

        // Identical repeat: unchanged without a write, even with a stale expected revision and even
        // when a newer build stored unknown members on the snapshot.
        let fileURL = store.recordFileURL(sessionID: session.sessionID)
        var json = try Support.readJSON(fileURL)
        Support.setMember(&json, at: [.key("intents"), .index(0), .key("pendingHandoff")], key: "futureMember", value: .bool(true))
        try Support.writeJSON(json, to: fileURL)
        let bytes = try Data(contentsOf: fileURL)
        let repeated = try await store.attachPendingHandoff(
            binding: session, expectedRevision: nil, intentID: queued.intentID, snapshot: snapshot
        )
        XCTAssertEqual(repeated.disposition, .unchanged)
        XCTAssertEqual(repeated.recordRevision, revision)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)

        // Identical submission repeats compare the handoff by exact ID and content.
        let withHandoff = submission("direct", pendingHandoff: handoff())
        let attemptID = UUID()
        revision = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: revision, submission: withHandoff,
            attempt: AgentRecoveryAttemptStart(attemptID: attemptID), consumption: nil
        ).intent.recordRevision
        let repeatedDispatch = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: nil, submission: withHandoff,
            attempt: AgentRecoveryAttemptStart(attemptID: attemptID), consumption: nil
        )
        XCTAssertEqual(repeatedDispatch.intent.disposition, .unchanged)
        XCTAssertEqual(repeatedDispatch.intent.pendingHandoff, withHandoff.pendingHandoff)

        let samePayload = try XCTUnwrap(withHandoff.pendingHandoff).payload
        let otherID = submission(
            "direct",
            intentID: withHandoff.intentID,
            userItemID: withHandoff.userItemID,
            pendingHandoff: handoff(payload: samePayload)
        )
        await assertStoreError(.intentConflict(withHandoff.intentID)) {
            try await store.commitDispatchingIntent(
                binding: session, expectedRevision: nil, submission: otherID,
                attempt: AgentRecoveryAttemptStart(attemptID: attemptID), consumption: nil
            )
        }
        let withoutHandoff = submission(
            "direct",
            intentID: withHandoff.intentID,
            userItemID: withHandoff.userItemID,
            pendingHandoff: nil
        )
        await assertStoreError(.intentConflict(withHandoff.intentID)) {
            try await store.commitDispatchingIntent(
                binding: session, expectedRevision: nil, submission: withoutHandoff,
                attempt: AgentRecoveryAttemptStart(attemptID: attemptID), consumption: nil
            )
        }
        let record = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(record.revision, revision)
        XCTAssertEqual(record.intents.count, 2)
    }

    // MARK: - Helpers

    private func loadRecord(
        _ store: AgentRecoveryStore,
        _ sessionID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> AgentRecoveryRecord {
        let state = await store.read(sessionID: sessionID)
        return try XCTUnwrap(state.record, "expected supported record, got \(state)", file: file, line: line)
    }

    private func assertStoreError(
        _ expected: AgentRecoveryStoreError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> some Any
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as AgentRecoveryStoreError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func assertStoreErrorCategory(
        _ expected: AgentRecoveryStoreError.Category,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> some Any
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected) failure", file: file, line: line)
        } catch let error as AgentRecoveryStoreError {
            XCTAssertEqual(error.category, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
