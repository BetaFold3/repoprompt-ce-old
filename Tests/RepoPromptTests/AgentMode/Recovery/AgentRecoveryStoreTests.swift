@testable import RepoPromptAgentCore
import XCTest

/// Recovery store transactions (lossless restart Phase 1b, inactive). Every store uses an injected
/// temporary root; a second store on the same root models an app relaunch.
final class AgentRecoveryStoreTests: XCTestCase {
    private typealias Support = RecoveryTestSupport

    private var root: URL!
    private var sourceDirectory: URL!
    private let instanceA = UUID()
    private let instanceB = UUID()

    override func setUpWithError() throws {
        root = try Support.makeTemporaryRoot("AgentRecoveryStoreTests")
        sourceDirectory = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeStore(
        instance: UUID? = nil,
        fileOperations: AgentRecoveryStore.FileOperations = .live
    ) -> AgentRecoveryStore {
        AgentRecoveryStore(
            rootURL: root.appendingPathComponent("AgentRecovery/v1", isDirectory: true),
            appInstanceID: instance ?? instanceA,
            fileOperations: fileOperations
        )
    }

    private func binding(_ sessionID: UUID, _ incarnationID: UUID, generation: UInt64 = 0) -> AgentRecoveryLifecycleBinding {
        AgentRecoveryLifecycleBinding(sessionID: sessionID, incarnationID: incarnationID, transcriptResetGeneration: generation)
    }

    // MARK: - Schema preservation

    func testSupportedUnknownMembersSurviveRewriteAtEveryObjectBoundary() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        let image = try await store.importManagedImage(
            sessionID: session.sessionID,
            sourceURL: Support.makeImageSource(in: sourceDirectory)
        )
        var workflow = AgentWorkflowDefinition(customID: UUID(), displayName: "Custom", template: "Do $ARGUMENTS carefully")
        workflow.tooltipText = "tip"
        let composerContent = AgentRecoveryInputContent(
            text: "draft",
            images: [image],
            taggedFiles: [AgentRecoveryTaggedFileReference(AgentTaggedFileAttachment(relativePath: "a/b.swift", displayName: "b.swift"))],
            workflow: AgentRecoveryWorkflowSnapshot(workflow),
            interviewFirst: true
        )
        let composer = AgentRecoveryComposerSnapshot(
            revision: .make(),
            capturedAt: AgentRecoveryTimestamp(millisecondsSince1970: 42),
            transcriptResetGeneration: 0,
            content: composerContent
        )
        var revision = try await store.commitComposer(
            binding: session, expectedRevision: nil, expectedComposerRevision: nil, snapshot: composer
        ).recordRevision
        let ownership = Support.ownership(sessionID: session.sessionID)
        revision = try await store.ensureRunAttempt(
            binding: session, expectedRevision: revision, ownership: ownership, processRunID: UUID(), transcriptTurnID: nil,
            providerKindRaw: nil
        ).recordRevision
        let direct = Support.submission(
            "scheduled",
            origin: .scheduled,
            target: Support.liveRunTarget(runAttemptID: ownership.attemptID),
            scheduleReference: AgentRecoveryScheduleReference(scheduleID: UUID(), scheduleAttemptID: UUID())
        )
        let attemptID = UUID()
        revision = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: revision, submission: direct,
            attempt: AgentRecoveryAttemptStart(attemptID: attemptID, runAttemptID: ownership.attemptID), consumption: nil
        ).intent.recordRevision
        revision = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: revision, intentID: direct.intentID,
            attemptID: attemptID, outcome: .deliveryUnknown
        ).intent.recordRevision
        revision = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: revision, intentID: direct.intentID,
            attemptID: attemptID, outcome: .providerAccepted
        ).intent.recordRevision
        revision = try await store.recordRunTerminal(
            binding: session, expectedRevision: revision, commit: Support.terminalCommit(ownership: ownership)
        ).recordRevision
        revision = try await store.recordRunShutdown(
            binding: session, expectedRevision: revision, runAttemptID: ownership.attemptID,
            reason: .appQuit, lastConfirmedActivityAt: Date(timeIntervalSince1970: 5)
        ).recordRevision
        let queued = Support.submission("queued")
        revision = try await store.commitQueuedIntent(
            binding: session, expectedRevision: revision, submission: queued, consumption: nil
        ).intent.recordRevision

        // A newer build adds members at every supported object boundary.
        let fileURL = store.recordFileURL(sessionID: session.sessionID)
        var json = try Support.readJSON(fileURL)
        let boundaries: [[Support.PathComponent]] = [
            [],
            [.key("composer")],
            [.key("composer"), .key("content")],
            [.key("composer"), .key("content"), .key("images"), .index(0)],
            [.key("composer"), .key("content"), .key("taggedFiles"), .index(0)],
            [.key("composer"), .key("content"), .key("workflow")],
            [.key("intents"), .index(0)],
            [.key("intents"), .index(0), .key("payload")],
            [.key("intents"), .index(0), .key("scheduleReference")],
            [.key("intents"), .index(0), .key("target")],
            [.key("intents"), .index(0), .key("target"), .key("run")],
            [.key("intents"), .index(1)],
            [.key("intents"), .index(1), .key("target")],
            [.key("attempts"), .index(0)],
            [.key("attempts"), .index(0), .key("outcome")],
            [.key("attempts"), .index(0), .key("supersededOutcome")],
            [.key("runAttempts"), .index(0)],
            [.key("runAttempts"), .index(0), .key("terminal")],
            [.key("runAttempts"), .index(0), .key("shutdown")]
        ]
        for (index, path) in boundaries.enumerated() {
            Support.setMember(&json, at: path, key: "futureMember\(index)", value: .object(["n": .number(Decimal(index))]))
        }
        try Support.writeJSON(json, to: fileURL)

        let reloaded = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(reloaded.extras["futureMember0"], .object(["n": .number(0)]))
        XCTAssertEqual(reloaded.composer?.content.workflow?.definition.template, "Do $ARGUMENTS carefully")
        XCTAssertEqual(reloaded.composer?.content.workflow?.definition.tooltipText, "tip")
        XCTAssertEqual(reloaded.composer?.content.interviewFirst, true)

        // An unrelated mutation rewrites the record; every extra survives, matched by identity.
        _ = try await store.withdraw(binding: session, expectedRevision: reloaded.revision, intentID: queued.intentID)
        let rewritten = try Support.readJSON(fileURL)
        for (index, path) in boundaries.enumerated() {
            XCTAssertEqual(
                Support.member(rewritten, at: path, key: "futureMember\(index)"),
                .object(["n": .number(Decimal(index))]),
                "extra \(index) lost"
            )
        }
        let final = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(final.intent(id: queued.intentID)?.deliveryState, .withdrawn)
        XCTAssertEqual(final.intent(id: queued.intentID)?.payload.text, "queued", "withdrawal keeps the payload")
        XCTAssertEqual(final.runAttempt(id: ownership.attemptID)?.shutdown?.reason, .appQuit)
    }

    func testFutureMalformedAndUnknownVariantRecordsArePreservedByteForByteAndNonwritable() async throws {
        let store = makeStore()
        let sessionsDirectory = store.sessionsDirectoryURL
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        // A valid record whose fields are then corrupted in specific ways.
        let template = binding(UUID(), UUID())
        _ = try await store.commitQueuedIntent(
            binding: template, expectedRevision: nil, submission: Support.submission("x"), consumption: nil
        )
        let validJSON = try Support.readJSON(store.recordFileURL(sessionID: template.sessionID))

        func variant(_ edit: (inout AgentRecoveryJSONValue) -> Void, sessionID: UUID) throws -> Data {
            var json = validJSON
            Support.setMember(&json, at: [], key: "sessionID", value: .string(sessionID.uuidString))
            edit(&json)
            return try JSONEncoder().encode(json)
        }

        var cases: [(UUID, Data, (AgentRecoveryUnreadableReason) -> Bool)] = []
        let future = UUID()
        try cases.append((future, variant({ Support.setMember(&$0, at: [], key: "schemaVersion", value: .number(2)) }, sessionID: future), {
            $0 == .futureSchema(2)
        }))
        let notJSON = UUID()
        cases.append((notJSON, Data("{not json".utf8), { if case .malformed = $0 { true } else { false } }))
        let unknownState = UUID()
        try cases.append((unknownState, variant({
            Support.setMember(&$0, at: [.key("intents"), .index(0)], key: "deliveryState", value: .string("held"))
        }, sessionID: unknownState), { if case .unknownVariant = $0 { true } else { false } }))
        let unknownTarget = UUID()
        try cases.append((unknownTarget, variant({
            Support.setMember(&$0, at: [.key("intents"), .index(0), .key("target")], key: "kind", value: .string("otherSession"))
        }, sessionID: unknownTarget), { if case .unknownVariant = $0 { true } else { false } }))
        let explicitNull = UUID()
        try cases.append((explicitNull, variant({
            Support.setMember(&$0, at: [], key: "composer", value: .null)
        }, sessionID: explicitNull), { if case .malformed = $0 { true } else { false } }))
        let lowercaseUUID = UUID()
        try cases.append((lowercaseUUID, variant({
            Support.setMember(&$0, at: [], key: "incarnationID", value: .string(UUID().uuidString.lowercased()))
        }, sessionID: lowercaseUUID), { if case .malformed = $0 { true } else { false } }))
        let fractional = UUID()
        try cases.append((fractional, variant({
            Support.setMember(&$0, at: [], key: "updatedAt", value: .number(Decimal(string: "1.5")!))
        }, sessionID: fractional), { if case .malformed = $0 { true } else { false } }))

        for (sessionID, data, matches) in cases {
            let url = store.recordFileURL(sessionID: sessionID)
            try data.write(to: url)
            guard case let .preserved(reason) = await store.read(sessionID: sessionID) else {
                XCTFail("expected preserved record for \(sessionID)")
                continue
            }
            XCTAssertTrue(matches(reason), "unexpected reason \(reason)")
            do {
                _ = try await store.commitComposer(
                    binding: binding(sessionID, UUID()), expectedRevision: nil,
                    expectedComposerRevision: nil, snapshot: Support.snapshot("overwrite?")
                )
                XCTFail("preserved record must not be writable")
            } catch let error as AgentRecoveryStoreError {
                XCTAssertEqual(error.category, .unreadable)
            }
            XCTAssertEqual(try Data(contentsOf: url), data, "bytes must be unchanged")
            let reference = await store.managedImageRecordReference(sessionID: sessionID, fileName: "x.png")
            XCTAssertEqual(reference, .unknown)
        }

        let strayURL = sessionsDirectory.appendingPathComponent("not-a-session.json")
        try Data("{}".utf8).write(to: strayURL)
        let entries = try await store.discoverRecords()
        let preserved = entries.compactMap { entry -> AgentRecoveryPreservedEntry? in
            if case let .preserved(value) = entry { return value }
            return nil
        }
        XCTAssertEqual(Set(preserved.compactMap(\.sessionID)), Set(cases.map(\.0)))
        XCTAssertTrue(preserved.contains { $0.sessionID == nil && $0.fileURL.lastPathComponent == "not-a-session.json" })
        XCTAssertEqual(entries.count, cases.count + 2, "the valid record is discovered too")
    }

    // MARK: - Submissions and receipts

    func testQueuedCommitsWithoutAttemptAndDirectCommitsDispatchingWithAttemptAtomically() async throws {
        let failures = RecoveryStoreWriteFailureSwitch()
        let store = makeStore(fileOperations: failures.fileOperations())
        let session = binding(UUID(), UUID())
        let composer = Support.snapshot("hello")
        let afterComposer = try await store.commitComposer(
            binding: session, expectedRevision: nil, expectedComposerRevision: nil, snapshot: composer
        )

        let queued = Support.submission("queued", origin: .followUp)
        let queuedReceipt = try await store.commitQueuedIntent(
            binding: session, expectedRevision: afterComposer.recordRevision, submission: queued, consumption: nil
        )
        XCTAssertEqual(queuedReceipt.intent.deliveryState, .queued)
        XCTAssertEqual(queuedReceipt.intent.userItemID, queued.userItemID)
        XCTAssertEqual(queuedReceipt.owningAppInstanceID, instanceA)
        XCTAssertEqual(queuedReceipt.intent.composerRevision, composer.revision, "no consumption requested")

        // A failed replacement leaves the previous durable record intact.
        failures.shouldFailWrites = true
        let direct = Support.submission("direct", target: Support.liveRunTarget())
        let start = AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: UUID(), transcriptTurnID: UUID())
        do {
            _ = try await store.commitDispatchingIntent(
                binding: session, expectedRevision: queuedReceipt.intent.recordRevision, submission: direct,
                attempt: start, consumption: AgentRecoveryComposerConsumption(submittedRevision: composer.revision)
            )
            XCTFail("expected storage failure")
        } catch let error as AgentRecoveryStoreError {
            XCTAssertEqual(error.category, .storage)
        }
        let unchanged = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(unchanged.revision, queuedReceipt.intent.recordRevision)
        XCTAssertEqual(unchanged.composer, composer)
        XCTAssertNil(unchanged.intent(id: direct.intentID))

        failures.shouldFailWrites = false
        let directReceipt = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: queuedReceipt.intent.recordRevision, submission: direct,
            attempt: start, consumption: AgentRecoveryComposerConsumption(submittedRevision: composer.revision)
        )
        XCTAssertEqual(directReceipt.intent.deliveryState, .dispatching)
        XCTAssertEqual(directReceipt.attemptID, start.attemptID)
        XCTAssertTrue(directReceipt.intent.composerConsumed)
        XCTAssertNil(directReceipt.intent.composerRevision)

        // A relaunch observes exactly the committed state, including the captured target.
        let relaunched = try await loadRecord(makeStore(instance: instanceB), session.sessionID)
        XCTAssertNil(relaunched.composer)
        XCTAssertEqual(relaunched.intents.map(\.intentID), [queued.intentID, direct.intentID], "submission order")
        XCTAssertEqual(relaunched.intent(id: queued.intentID)?.target, .session)
        XCTAssertEqual(relaunched.intent(id: direct.intentID)?.target, direct.target)
        XCTAssertTrue(relaunched.attempts(forIntent: queued.intentID).isEmpty)
        XCTAssertEqual(relaunched.intent(id: direct.intentID)?.deliveryState, .dispatching)
        let attempt = try XCTUnwrap(relaunched.attempts(forIntent: direct.intentID).first)
        XCTAssertEqual(attempt.attemptID, start.attemptID)
        XCTAssertEqual(attempt.userItemID, direct.userItemID)
        XCTAssertEqual(attempt.runAttemptID, start.runAttemptID)
        XCTAssertEqual(attempt.transcriptTurnID, start.transcriptTurnID)
        XCTAssertEqual(attempt.appInstanceID, instanceA)
        XCTAssertNil(attempt.outcome)
    }

    func testRepeatedSubmissionRevalidatesCurrentStateAndConflictingReuseFails() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        let first = Support.snapshot("first")
        let r1 = try await store.commitComposer(
            binding: session, expectedRevision: nil, expectedComposerRevision: nil, snapshot: first
        ).recordRevision
        let submission = Support.submission("first")
        let consume = AgentRecoveryComposerConsumption(submittedRevision: first.revision)
        let committed = try await store.commitQueuedIntent(
            binding: session, expectedRevision: r1, submission: submission, consumption: consume
        )
        XCTAssertTrue(committed.intent.composerConsumed)

        // New typing becomes durable; a retried identical submission must not consume it, even
        // with a stale expected revision and a consumption set that names it.
        let second = Support.snapshot("second")
        _ = try await store.commitComposer(
            binding: session, expectedRevision: committed.intent.recordRevision, expectedComposerRevision: nil, snapshot: second
        )
        let retry = try await store.commitQueuedIntent(
            binding: session, expectedRevision: r1, submission: submission,
            consumption: AgentRecoveryComposerConsumption(submittedRevision: second.revision)
        )
        XCTAssertEqual(retry.intent.disposition, .unchanged)
        XCTAssertFalse(retry.intent.composerConsumed)
        XCTAssertEqual(retry.intent.composerRevision, second.revision)
        let afterRetry = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(afterRetry.composer, second)
        XCTAssertEqual(afterRetry.intents.count, 1)

        // Conflicting reuse of the intent ID (payload or target), or of its user item ID, fails.
        let changedPayload = Support.submission("different", intentID: submission.intentID, userItemID: submission.userItemID)
        await assertStoreError(.intentConflict(submission.intentID)) {
            try await store.commitQueuedIntent(
                binding: session, expectedRevision: afterRetry.revision, submission: changedPayload, consumption: nil
            )
        }
        let changedTarget = Support.submission(
            "first", intentID: submission.intentID, userItemID: submission.userItemID, target: Support.liveRunTarget()
        )
        await assertStoreError(.intentConflict(submission.intentID)) {
            try await store.commitQueuedIntent(
                binding: session, expectedRevision: afterRetry.revision, submission: changedTarget, consumption: nil
            )
        }
        let reusedItem = Support.submission("other", userItemID: submission.userItemID)
        await assertStoreError(.intentConflict(reusedItem.intentID)) {
            try await store.commitQueuedIntent(
                binding: session, expectedRevision: afterRetry.revision, submission: reusedItem, consumption: nil
            )
        }
        await assertStoreError(.intentConflict(submission.intentID)) {
            try await store.commitDispatchingIntent(
                binding: session, expectedRevision: afterRetry.revision, submission: submission,
                attempt: AgentRecoveryAttemptStart(attemptID: UUID()), consumption: nil
            )
        }

        // A queue receipt is reissued only while the intent is still queued and unheld.
        let attemptID = UUID()
        let dispatching = try await store.beginDispatch(
            binding: session, expectedRevision: afterRetry.revision, intentID: submission.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: attemptID), authorization: .liveQueue
        )
        await assertStoreError(.invalidTransition(intentID: submission.intentID, from: .dispatching, operation: .submit)) {
            try await store.commitQueuedIntent(
                binding: session, expectedRevision: dispatching.intent.recordRevision, submission: submission, consumption: nil
            )
        }

        // A dispatch receipt is reissued only for the same open attempt with the same association.
        let repeatDispatch = try await store.beginDispatch(
            binding: session, expectedRevision: nil, intentID: submission.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: attemptID), authorization: .liveQueue
        )
        XCTAssertEqual(repeatDispatch.intent.disposition, .unchanged)
        await assertStoreError(.attemptConflict(attemptID)) {
            try await store.beginDispatch(
                binding: session, expectedRevision: nil, intentID: submission.intentID,
                attempt: AgentRecoveryAttemptStart(attemptID: attemptID, runAttemptID: UUID()), authorization: .liveQueue
            )
        }
        let accepted = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: dispatching.intent.recordRevision, intentID: submission.intentID,
            attemptID: attemptID, outcome: .providerAccepted
        )
        await assertStoreError(.invalidTransition(intentID: submission.intentID, from: .providerAccepted, operation: .beginDispatch)) {
            try await store.beginDispatch(
                binding: session, expectedRevision: accepted.intent.recordRevision, intentID: submission.intentID,
                attempt: AgentRecoveryAttemptStart(attemptID: attemptID), authorization: .liveQueue
            )
        }
    }

    func testComposerConsumptionHonorsSubmittedAndSupersededRevisionsOnly() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        let older = Support.snapshot("older")
        let submitted = AgentRecoveryComposerRevision.make()
        var revision = try await store.commitComposer(
            binding: session, expectedRevision: nil, expectedComposerRevision: nil, snapshot: older
        ).recordRevision

        // Stored revision superseded by the (unpersisted) submitted snapshot: consumed.
        let a = try await store.commitQueuedIntent(
            binding: session, expectedRevision: revision, submission: Support.submission("a"),
            consumption: AgentRecoveryComposerConsumption(submittedRevision: submitted, supersededRevisions: [older.revision])
        )
        XCTAssertTrue(a.intent.composerConsumed)
        XCTAssertNil(a.intent.composerRevision)

        // A stored composer the submitter does not know (newer typing) is preserved.
        let newer = Support.snapshot("newer")
        revision = try await store.commitComposer(
            binding: session, expectedRevision: a.intent.recordRevision, expectedComposerRevision: nil, snapshot: newer
        ).recordRevision
        let b = try await store.commitQueuedIntent(
            binding: session, expectedRevision: revision, submission: Support.submission("b"),
            consumption: AgentRecoveryComposerConsumption(submittedRevision: .make(), supersededRevisions: [older.revision])
        )
        XCTAssertFalse(b.intent.composerConsumed)
        XCTAssertEqual(b.intent.composerRevision, newer.revision)

        // Composer writes are themselves composer-revision CAS.
        await assertStoreError(.composerRevisionConflict(expected: older.revision, actual: newer.revision)) {
            try await store.commitComposer(
                binding: session, expectedRevision: b.intent.recordRevision, expectedComposerRevision: older.revision,
                snapshot: Support.snapshot("stale")
            )
        }
        // Empty content removes the stored composer.
        let cleared = try await store.commitComposer(
            binding: session, expectedRevision: b.intent.recordRevision, expectedComposerRevision: newer.revision,
            snapshot: Support.snapshot("")
        )
        XCTAssertNil(cleared.composerRevision)
    }

    // MARK: - Delivery transitions

    func testDeliveryOutcomesWithdrawalAndRetryTransitions() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        let direct = Support.submission("direct")
        let attempt1 = UUID()
        var revision = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: nil, submission: direct,
            attempt: AgentRecoveryAttemptStart(attemptID: attempt1), consumption: nil
        ).intent.recordRevision

        await assertStoreError(.invalidTransition(intentID: direct.intentID, from: .dispatching, operation: .withdraw)) {
            try await store.withdraw(binding: session, expectedRevision: revision, intentID: direct.intentID)
        }
        let unknownAttempt = UUID()
        await assertStoreError(.attemptNotFound(unknownAttempt)) {
            try await store.recordDeliveryOutcome(
                binding: session, expectedRevision: revision, intentID: direct.intentID,
                attemptID: unknownAttempt, outcome: .providerAccepted
            )
        }

        let unknown = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: revision, intentID: direct.intentID,
            attemptID: attempt1, outcome: .deliveryUnknown
        )
        XCTAssertEqual(unknown.intent.deliveryState, .deliveryUnknown)
        let repeated = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: revision, intentID: direct.intentID,
            attemptID: attempt1, outcome: .deliveryUnknown
        )
        XCTAssertEqual(repeated.intent.disposition, .unchanged, "identical evidence is idempotent")
        await assertStoreError(.attemptConflict(attempt1)) {
            try await store.recordDeliveryOutcome(
                binding: session, expectedRevision: unknown.intent.recordRevision, intentID: direct.intentID,
                attemptID: attempt1, outcome: .failed(.verifiedRejection, message: nil)
            )
        }
        revision = unknown.intent.recordRevision

        // Delivery-unknown input is not drained by a live queue; an explicit retry reuses the item ID.
        let attempt2 = UUID()
        await assertStoreError(.invalidTransition(intentID: direct.intentID, from: .deliveryUnknown, operation: .beginDispatch)) {
            try await store.beginDispatch(
                binding: session, expectedRevision: revision, intentID: direct.intentID,
                attempt: AgentRecoveryAttemptStart(attemptID: attempt2), authorization: .liveQueue
            )
        }
        let retry = try await store.beginDispatch(
            binding: session, expectedRevision: revision, intentID: direct.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: attempt2), authorization: .explicitUserAction
        )
        XCTAssertEqual(retry.intent.deliveryState, .dispatching)
        let failed = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: retry.intent.recordRevision, intentID: direct.intentID,
            attemptID: attempt2, outcome: .failed(.preHandoff, message: nil)
        )
        XCTAssertEqual(failed.intent.deliveryState, .failed)
        let record = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(Set(record.attempts(forIntent: direct.intentID).map(\.userItemID)), [direct.userItemID])
        XCTAssertEqual(record.attempts(forIntent: direct.intentID).count, 2)

        // Queued intents drain through dispatching; unknown or failed input can be withdrawn explicitly.
        let queued = Support.submission("queued")
        revision = try await store.commitQueuedIntent(
            binding: session, expectedRevision: failed.intent.recordRevision, submission: queued, consumption: nil
        ).intent.recordRevision
        let attempt3 = UUID()
        let draining = try await store.beginDispatch(
            binding: session, expectedRevision: revision, intentID: queued.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: attempt3), authorization: .liveQueue
        )
        let unknown3 = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: draining.intent.recordRevision, intentID: queued.intentID,
            attemptID: attempt3, outcome: .deliveryUnknown
        )
        let withdrawn = try await store.withdraw(binding: session, expectedRevision: unknown3.intent.recordRevision, intentID: queued.intentID)
        XCTAssertEqual(withdrawn.deliveryState, .withdrawn)
        let again = try await store.withdraw(binding: session, expectedRevision: revision, intentID: queued.intentID)
        XCTAssertEqual(again.disposition, .unchanged)
        let withdrawnFailed = try await store.withdraw(
            binding: session, expectedRevision: withdrawn.recordRevision, intentID: direct.intentID
        )
        XCTAssertEqual(withdrawnFailed.deliveryState, .withdrawn)
    }

    func testQualifiedNoHandoffFallbackSettlesSameIntentToQueued() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        let fallback = Support.submission("steer", origin: .steering, target: Support.liveRunTarget())
        let attempt1 = UUID()
        let dispatching = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: nil, submission: fallback,
            attempt: AgentRecoveryAttemptStart(attemptID: attempt1), consumption: nil
        )

        // The handoff provably never began: the same intent returns to queued in one replacement.
        let settled = try await store.settleToQueue(
            binding: session, expectedRevision: dispatching.intent.recordRevision, intentID: fallback.intentID,
            attemptID: attempt1, evidence: .preHandoff, message: nil
        )
        XCTAssertEqual(settled.deliveryState, .queued)
        XCTAssertEqual(settled.intentID, fallback.intentID)
        XCTAssertEqual(settled.userItemID, fallback.userItemID)
        let repeated = try await store.settleToQueue(
            binding: session, expectedRevision: nil, intentID: fallback.intentID,
            attemptID: attempt1, evidence: .preHandoff, message: nil
        )
        XCTAssertEqual(repeated.disposition, .unchanged)
        let queueReceipt = try await store.issueQueueReceipt(binding: session, intentID: fallback.intentID)
        XCTAssertEqual(queueReceipt.intent.recordRevision, settled.recordRevision)
        XCTAssertEqual(queueReceipt.owningAppInstanceID, instanceA)

        var record = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(record.intents.count, 1, "no second intent or bubble")
        let intent = try XCTUnwrap(record.intent(id: fallback.intentID))
        XCTAssertEqual(intent.target, fallback.target)
        XCTAssertEqual(intent.payload, fallback.payload)
        XCTAssertEqual(record.attempts.first?.outcome?.outcome, .failed(.preHandoff, message: nil))

        // The drain reuses the same intent; a verified rejection recorded first can still settle.
        let attempt2 = UUID()
        let redispatch = try await store.beginDispatch(
            binding: session, expectedRevision: settled.recordRevision, intentID: fallback.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: attempt2), authorization: .liveQueue
        )
        let rejected = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: redispatch.intent.recordRevision, intentID: fallback.intentID,
            attemptID: attempt2, outcome: .failed(.verifiedRejection, message: "not steerable")
        )
        // Settlement must name the exact attempt and its exact evidence.
        await assertStoreError(.invalidTransition(intentID: fallback.intentID, from: .failed, operation: .settleToQueue)) {
            try await store.settleToQueue(
                binding: session, expectedRevision: rejected.intent.recordRevision, intentID: fallback.intentID,
                attemptID: attempt1, evidence: .preHandoff, message: nil
            )
        }
        let resettled = try await store.settleToQueue(
            binding: session, expectedRevision: rejected.intent.recordRevision, intentID: fallback.intentID,
            attemptID: attempt2, evidence: .verifiedRejection, message: "not steerable"
        )
        XCTAssertEqual(resettled.deliveryState, .queued)
        record = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(record.attempts(forIntent: fallback.intentID).count, 2)
        XCTAssertEqual(Set(record.attempts.map(\.userItemID)), [fallback.userItemID])
    }

    func testAcceptanceThenReconciliationFailureNeverBecomesQueued() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        let steer = Support.submission("steer", origin: .steering, target: Support.liveRunTarget())
        let attemptID = UUID()
        let dispatching = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: nil, submission: steer,
            attempt: AgentRecoveryAttemptStart(attemptID: attemptID), consumption: nil
        )
        // Acceptance is captured immediately after the successful provider return...
        let accepted = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: dispatching.intent.recordRevision, intentID: steer.intentID,
            attemptID: attemptID, outcome: .providerAccepted
        )
        // ...so a later reconciliation failure cannot rewind or fail it.
        await assertStoreError(.invalidTransition(intentID: steer.intentID, from: .providerAccepted, operation: .settleToQueue)) {
            try await store.settleToQueue(
                binding: session, expectedRevision: accepted.intent.recordRevision, intentID: steer.intentID,
                attemptID: attemptID, evidence: .verifiedRejection, message: "expectedTurnMismatch"
            )
        }
        await assertStoreError(.attemptConflict(attemptID)) {
            try await store.recordDeliveryOutcome(
                binding: session, expectedRevision: accepted.intent.recordRevision, intentID: steer.intentID,
                attemptID: attemptID, outcome: .failed(.verifiedRejection, message: "expectedTurnMismatch")
            )
        }
        await assertStoreError(.attemptConflict(attemptID)) {
            try await store.recordDeliveryOutcome(
                binding: session, expectedRevision: accepted.intent.recordRevision, intentID: steer.intentID,
                attemptID: attemptID, outcome: .deliveryUnknown
            )
        }
        await assertStoreError(.invalidTransition(intentID: steer.intentID, from: .providerAccepted, operation: .submit)) {
            try await store.issueQueueReceipt(binding: session, intentID: steer.intentID)
        }

        // Uncertain delivery is never settled to queued either.
        let other = Support.submission("other")
        let otherAttempt = UUID()
        let otherDispatch = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: accepted.intent.recordRevision, submission: other,
            attempt: AgentRecoveryAttemptStart(attemptID: otherAttempt), consumption: nil
        )
        let unknown = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: otherDispatch.intent.recordRevision, intentID: other.intentID,
            attemptID: otherAttempt, outcome: .deliveryUnknown
        )
        await assertStoreError(.invalidTransition(intentID: other.intentID, from: .deliveryUnknown, operation: .settleToQueue)) {
            try await store.settleToQueue(
                binding: session, expectedRevision: unknown.intent.recordRevision, intentID: other.intentID,
                attemptID: otherAttempt, evidence: .preHandoff, message: nil
            )
        }
        let record = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(record.intent(id: steer.intentID)?.deliveryState, .providerAccepted)
        XCTAssertEqual(record.intent(id: other.intentID)?.deliveryState, .deliveryUnknown)
    }

    func testLateAcceptanceIsBoundToItsExactAttemptAndPreservesHistory() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        let message = Support.submission("message")
        let attempt1 = UUID()
        var revision = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: nil, submission: message,
            attempt: AgentRecoveryAttemptStart(attemptID: attempt1), consumption: nil
        ).intent.recordRevision
        revision = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: revision, intentID: message.intentID,
            attemptID: attempt1, outcome: .deliveryUnknown
        ).intent.recordRevision
        let attempt2 = UUID()
        revision = try await store.beginDispatch(
            binding: session, expectedRevision: revision, intentID: message.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: attempt2), authorization: .explicitUserAction
        ).intent.recordRevision

        // Late acceptance for attempt 1 refines its unknown evidence while attempt 2 is open.
        let late = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: revision, intentID: message.intentID,
            attemptID: attempt1, outcome: .providerAccepted
        )
        XCTAssertEqual(late.intent.deliveryState, .providerAccepted)
        XCTAssertEqual(late.supersededOutcome, .deliveryUnknown)
        // Attempt 2 still closes with its own evidence; the intent stays accepted.
        let second = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: late.intent.recordRevision, intentID: message.intentID,
            attemptID: attempt2, outcome: .deliveryUnknown
        )
        XCTAssertEqual(second.intent.deliveryState, .providerAccepted)
        // Evidence for an attempt belonging to another intent is rejected.
        let other = Support.submission("other")
        let otherRevision = try await store.commitQueuedIntent(
            binding: session, expectedRevision: second.intent.recordRevision, submission: other, consumption: nil
        ).intent.recordRevision
        await assertStoreError(.attemptNotFound(attempt1)) {
            try await store.recordDeliveryOutcome(
                binding: session, expectedRevision: otherRevision, intentID: other.intentID,
                attemptID: attempt1, outcome: .providerAccepted
            )
        }

        let reloaded = try await loadRecord(makeStore(instance: instanceB), session.sessionID)
        let attempts = reloaded.attempts(forIntent: message.intentID)
        XCTAssertEqual(attempts.map(\.attemptID), [attempt1, attempt2])
        XCTAssertEqual(attempts[0].outcome?.outcome, .providerAccepted)
        XCTAssertEqual(attempts[0].supersededOutcome?.outcome, .deliveryUnknown)
        XCTAssertEqual(attempts[1].outcome?.outcome, .deliveryUnknown)

        // Acceptance after a verified rejection and a withdrawal wins and exposes the conflict.
        let withdrawnCase = Support.submission("withdrawn later")
        let attempt3 = UUID()
        revision = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: otherRevision, submission: withdrawnCase,
            attempt: AgentRecoveryAttemptStart(attemptID: attempt3), consumption: nil
        ).intent.recordRevision
        revision = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: revision, intentID: withdrawnCase.intentID,
            attemptID: attempt3, outcome: .failed(.verifiedRejection, message: "rejected")
        ).intent.recordRevision
        revision = try await store.withdraw(binding: session, expectedRevision: revision, intentID: withdrawnCase.intentID).recordRevision
        let conflicting = try await store.recordDeliveryOutcome(
            binding: session, expectedRevision: revision, intentID: withdrawnCase.intentID,
            attemptID: attempt3, outcome: .providerAccepted
        )
        XCTAssertEqual(conflicting.intent.deliveryState, .providerAccepted)
        XCTAssertEqual(conflicting.supersededOutcome, .failed(.verifiedRejection, message: "rejected"))
        let final = try await loadRecord(store, session.sessionID)
        XCTAssertNotNil(final.intent(id: withdrawnCase.intentID)?.withdrawnAt, "withdrawal kept as history")
    }

    func testRunAttemptEvidenceIsKeyedByExistingOwnershipAndSharedByDeliveries() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        let draft = Support.snapshot("draft")
        var revision = try await store.commitComposer(
            binding: session, expectedRevision: nil, expectedComposerRevision: nil, snapshot: draft
        ).recordRevision
        let ownership = Support.ownership(sessionID: session.sessionID)
        let processRunID = UUID()
        revision = try await store.ensureRunAttempt(
            binding: session, expectedRevision: revision, ownership: ownership, processRunID: processRunID, transcriptTurnID: nil,
            providerKindRaw: nil
        ).recordRevision

        // Two deliveries share one run attempt: one associated at dispatch, one attached later.
        let first = Support.submission("first")
        let firstAttempt = UUID()
        revision = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: revision, submission: first,
            attempt: AgentRecoveryAttemptStart(attemptID: firstAttempt, runAttemptID: ownership.attemptID), consumption: nil
        ).intent.recordRevision
        let second = Support.submission("second", origin: .steering)
        let secondAttempt = UUID()
        revision = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: revision, submission: second,
            attempt: AgentRecoveryAttemptStart(attemptID: secondAttempt), consumption: nil
        ).intent.recordRevision
        revision = try await store.attachDeliveryAttempt(
            binding: session, expectedRevision: revision, attemptID: secondAttempt, ownership: ownership
        ).recordRevision
        let unknownRun = Support.ownership(sessionID: session.sessionID)
        await assertStoreError(.runAttemptNotFound(unknownRun.attemptID)) {
            try await store.attachDeliveryAttempt(
                binding: session, expectedRevision: revision, attemptID: firstAttempt, ownership: unknownRun
            )
        }
        revision = try await store.ensureRunAttempt(
            binding: session, expectedRevision: revision, ownership: unknownRun, processRunID: nil, transcriptTurnID: nil,
            providerKindRaw: nil
        ).recordRevision
        await assertStoreError(.attemptConflict(firstAttempt)) {
            try await store.attachDeliveryAttempt(
                binding: session, expectedRevision: revision, attemptID: firstAttempt, ownership: unknownRun
            )
        }

        // The transcript turn can be completed later; a conflicting process run fails.
        let turnID = UUID()
        revision = try await store.ensureRunAttempt(
            binding: session, expectedRevision: revision, ownership: ownership, processRunID: processRunID, transcriptTurnID: turnID,
            providerKindRaw: nil
        ).recordRevision
        let repeatEnsure = try await store.ensureRunAttempt(
            binding: session, expectedRevision: nil, ownership: ownership, processRunID: nil, transcriptTurnID: turnID,
            providerKindRaw: nil
        )
        XCTAssertEqual(repeatEnsure.disposition, .unchanged)
        await assertStoreError(.runAttemptConflict(ownership.attemptID)) {
            try await store.ensureRunAttempt(
                binding: session, expectedRevision: revision, ownership: ownership, processRunID: UUID(), transcriptTurnID: nil,
                providerKindRaw: nil
            )
        }

        // Terminal evidence from a barrier revision without an MCP envelope; identical repeat is unchanged.
        let commit = Support.terminalCommit(ownership: ownership, state: .cancelled, expectedRunID: processRunID)
        XCTAssertNil(commit.mcpPublicationEnvelope)
        let terminal = try await store.recordRunTerminal(binding: session, expectedRevision: revision, commit: commit)
        XCTAssertEqual(terminal.runAttemptID, ownership.attemptID)
        let repeatTerminal = try await store.recordRunTerminal(binding: session, expectedRevision: nil, commit: commit)
        XCTAssertEqual(repeatTerminal.disposition, .unchanged)
        await assertStoreError(.runAttemptConflict(ownership.attemptID)) {
            try await store.recordRunTerminal(
                binding: session, expectedRevision: terminal.recordRevision,
                commit: Support.terminalCommit(ownership: ownership, state: .cancelled, expectedRunID: processRunID)
            )
        }
        let shutdown = try await store.recordRunShutdown(
            binding: session, expectedRevision: terminal.recordRevision, runAttemptID: unknownRun.attemptID,
            reason: .windowClose, lastConfirmedActivityAt: nil
        )
        await assertStoreError(.runAttemptConflict(unknownRun.attemptID)) {
            try await store.recordRunShutdown(
                binding: session, expectedRevision: shutdown.recordRevision, runAttemptID: unknownRun.attemptID,
                reason: .appQuit, lastConfirmedActivityAt: nil
            )
        }

        // Run evidence never touches deliveries or the composer, and provider acceptance is separate.
        let record = try await loadRecord(makeStore(instance: instanceB), session.sessionID)
        XCTAssertEqual(record.composer, draft)
        XCTAssertEqual(record.intent(id: first.intentID)?.deliveryState, .dispatching)
        XCTAssertEqual(record.intent(id: second.intentID)?.deliveryState, .dispatching)
        XCTAssertEqual(record.attempts.map(\.runAttemptID), [ownership.attemptID, ownership.attemptID])
        let run = try XCTUnwrap(record.runAttempt(id: ownership.attemptID))
        XCTAssertEqual(run.processRunID, processRunID)
        XCTAssertEqual(run.transcriptTurnID, turnID)
        XCTAssertEqual(run.terminal?.commitID, commit.commitID)
        XCTAssertEqual(run.terminal?.terminalState, .cancelled)
        XCTAssertEqual(run.terminal?.expectedRunID, processRunID)
        XCTAssertEqual(record.runAttempt(id: unknownRun.attemptID)?.shutdown?.reason, .windowClose)
    }

    func testRunEvidenceRejectsOwnershipFromAnotherSession() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        let foreign = Support.ownership(sessionID: UUID())
        await assertStoreError(.runAttemptConflict(foreign.attemptID)) {
            try await store.ensureRunAttempt(
                binding: session, expectedRevision: nil, ownership: foreign, processRunID: nil, transcriptTurnID: nil,
                providerKindRaw: nil
            )
        }
        let afterForeign = await store.read(sessionID: session.sessionID)
        XCTAssertEqual(afterForeign, .absent)

        let ownership = Support.ownership(sessionID: session.sessionID)
        let run = try await store.ensureRunAttempt(
            binding: session, expectedRevision: nil, ownership: ownership, processRunID: nil, transcriptTurnID: nil,
            providerKindRaw: nil
        )
        let attemptID = UUID()
        let dispatched = try await store.commitDispatchingIntent(
            binding: session, expectedRevision: run.recordRevision, submission: Support.submission("x"),
            attempt: AgentRecoveryAttemptStart(attemptID: attemptID), consumption: nil
        )
        // The same run-attempt ID claimed by a run bound to another session is rejected.
        let spoofed = Support.ownership(sessionID: UUID(), attemptID: ownership.attemptID)
        await assertStoreError(.runAttemptConflict(ownership.attemptID)) {
            try await store.attachDeliveryAttempt(
                binding: session, expectedRevision: dispatched.intent.recordRevision, attemptID: attemptID, ownership: spoofed
            )
        }
        await assertStoreError(.runAttemptConflict(ownership.attemptID)) {
            try await store.recordRunTerminal(
                binding: session, expectedRevision: dispatched.intent.recordRevision,
                commit: Support.terminalCommit(ownership: spoofed)
            )
        }
        let record = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(record.revision, dispatched.intent.recordRevision, "nothing written")
        XCTAssertNil(record.attempts.first?.runAttemptID)
        XCTAssertNil(record.runAttempt(id: ownership.attemptID)?.terminal)
    }

    // MARK: - Targets, revisions, and lifecycle

    func testHeldOlderGenerationComposerIsNeverReplacedRemovedOrConsumed() async throws {
        let store = makeStore()
        let sessionID = UUID()
        let incarnation = UUID()
        let draft = Support.snapshot("typed before reset")
        let written = try await store.commitComposer(
            binding: binding(sessionID, incarnation), expectedRevision: nil, expectedComposerRevision: nil, snapshot: draft
        )
        let gen1 = binding(sessionID, incarnation, generation: 1)
        let heldError = AgentRecoveryStoreError.heldComposerUnresolved(revision: draft.revision, transcriptResetGeneration: 0)
        XCTAssertEqual(heldError.category, .heldInput)

        // Replacement (even with a matching composer CAS) and removal are refused.
        for (expected, snapshot) in [
            (draft.revision, Support.snapshot("new", generation: 1)),
            (nil, Support.snapshot("new", generation: 1)),
            (draft.revision, nil)
        ] as [(AgentRecoveryComposerRevision?, AgentRecoveryComposerSnapshot?)] {
            await assertStoreError(heldError) {
                try await store.commitComposer(
                    binding: gen1, expectedRevision: written.recordRevision,
                    expectedComposerRevision: expected, snapshot: snapshot
                )
            }
        }

        // New intents commit even when told the held revision is consumable; the held draft stays.
        let queued = Support.submission("queued after reset")
        let queuedReceipt = try await store.commitQueuedIntent(
            binding: gen1, expectedRevision: written.recordRevision, submission: queued,
            consumption: AgentRecoveryComposerConsumption(submittedRevision: .make(), supersededRevisions: [draft.revision])
        )
        XCTAssertFalse(queuedReceipt.intent.composerConsumed)
        XCTAssertNil(queuedReceipt.intent.composerRevision)
        XCTAssertEqual(queuedReceipt.intent.heldComposerRevision, draft.revision)
        let direct = Support.submission("direct after reset")
        let directReceipt = try await store.commitDispatchingIntent(
            binding: gen1, expectedRevision: queuedReceipt.intent.recordRevision, submission: direct,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID()),
            consumption: AgentRecoveryComposerConsumption(submittedRevision: draft.revision)
        )
        XCTAssertFalse(directReceipt.intent.composerConsumed)

        let record = try await loadRecord(makeStore(instance: instanceB), sessionID)
        XCTAssertEqual(record.composer, draft)
        XCTAssertEqual(record.intents.map(\.intentID), [queued.intentID, direct.intentID])
    }

    func testPersistedStaleTargetBlocksAutomaticAndExplicitDispatchAcrossReload() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        let steer = Support.submission("steer", origin: .steering, target: Support.liveRunTarget())
        let queued = try await store.commitQueuedIntent(
            binding: session, expectedRevision: nil, submission: steer, consumption: nil
        )
        // The captured run ended during the store await: the producer persists the hold.
        let marked = try await store.markTargetStale(
            binding: session, expectedRevision: queued.intent.recordRevision, intentID: steer.intentID
        )
        XCTAssertEqual(marked.deliveryState, .queued, "no state rewind")
        let repeated = try await store.markTargetStale(binding: session, expectedRevision: nil, intentID: steer.intentID)
        XCTAssertEqual(repeated.disposition, .unchanged)

        // Same instance, same generation, after reload: the hold persists.
        let relaunched = makeStore(instance: instanceA)
        let record = try await loadRecord(relaunched, session.sessionID)
        let intent = try XCTUnwrap(record.intent(id: steer.intentID))
        XCTAssertNotNil(intent.staleTargetMarkedAt)
        XCTAssertEqual(intent.target, steer.target, "the captured target is never recaptured")
        let holds = await relaunched.derivedHolds(for: record)
        XCTAssertEqual(holds[steer.intentID], [.staleTarget])
        await assertStoreError(.heldIntent(intentID: steer.intentID, holds: [.staleTarget])) {
            try await relaunched.issueQueueReceipt(binding: session, intentID: steer.intentID)
        }
        await assertStoreError(.heldIntent(intentID: steer.intentID, holds: [.staleTarget])) {
            try await relaunched.beginDispatch(
                binding: session, expectedRevision: record.revision, intentID: steer.intentID,
                attempt: AgentRecoveryAttemptStart(attemptID: UUID()), authorization: .liveQueue
            )
        }
        await assertStoreError(.heldIntent(intentID: steer.intentID, holds: [.staleTarget])) {
            try await relaunched.beginDispatch(
                binding: session, expectedRevision: record.revision, intentID: steer.intentID,
                attempt: AgentRecoveryAttemptStart(attemptID: UUID()), authorization: .explicitUserAction
            )
        }
        // Explicit withdrawal is still allowed and keeps the payload.
        let withdrawn = try await relaunched.withdraw(binding: session, expectedRevision: record.revision, intentID: steer.intentID)
        XCTAssertEqual(withdrawn.deliveryState, .withdrawn)
        // A withdrawn intent that was never marked cannot be marked afterwards.
        let terminal = Support.submission("terminal")
        let queuedTerminal = try await relaunched.commitQueuedIntent(
            binding: session, expectedRevision: withdrawn.recordRevision, submission: terminal, consumption: nil
        )
        let gone = try await relaunched.withdraw(
            binding: session, expectedRevision: queuedTerminal.intent.recordRevision, intentID: terminal.intentID
        )
        await assertStoreError(.invalidTransition(intentID: terminal.intentID, from: .withdrawn, operation: .markTargetStale)) {
            try await relaunched.markTargetStale(
                binding: session, expectedRevision: gone.recordRevision, intentID: terminal.intentID
            )
        }
    }

    func testRevisionConflictAndLifecycleBindingRejection() async throws {
        let store = makeStore()
        let sessionID = UUID()
        let incarnation = UUID()
        let gen0 = binding(sessionID, incarnation)
        let first = try await store.commitQueuedIntent(
            binding: gen0, expectedRevision: nil, submission: Support.submission("one"), consumption: nil
        )
        await assertStoreError(.revisionConflict(expected: nil, actual: first.intent.recordRevision)) {
            try await store.commitComposer(
                binding: gen0, expectedRevision: nil, expectedComposerRevision: nil, snapshot: Support.snapshot("x")
            )
        }
        let otherIncarnation = UUID()
        await assertStoreError(.staleIncarnation(expected: otherIncarnation, actual: incarnation)) {
            try await store.commitComposer(
                binding: binding(sessionID, otherIncarnation), expectedRevision: first.intent.recordRevision,
                expectedComposerRevision: nil, snapshot: Support.snapshot("x")
            )
        }

        // After a foundation reset, writes carry the new generation; older intents keep theirs.
        let gen1 = binding(sessionID, incarnation, generation: 1)
        await assertStoreError(.staleTranscriptResetGeneration(binding: 1, record: 0)) {
            try await store.commitComposer(
                binding: gen1, expectedRevision: first.intent.recordRevision, expectedComposerRevision: nil,
                snapshot: Support.snapshot("typed before reset", generation: 0)
            )
        }
        let afterReset = try await store.commitComposer(
            binding: gen1, expectedRevision: first.intent.recordRevision, expectedComposerRevision: nil,
            snapshot: Support.snapshot("y", generation: 1)
        )
        await assertStoreError(.staleTranscriptResetGeneration(binding: 0, record: 1)) {
            try await store.commitComposer(
                binding: gen0, expectedRevision: afterReset.recordRevision,
                expectedComposerRevision: afterReset.composerRevision, snapshot: nil
            )
        }
        let record = try await loadRecord(store, sessionID)
        XCTAssertEqual(record.transcriptResetGeneration, 1)
        let held = try XCTUnwrap(record.intents.first)
        XCTAssertEqual(held.transcriptResetGeneration, 0, "reset never retargets an intent")
        let holds = await store.derivedHolds(for: record)
        XCTAssertEqual(holds[held.intentID], [.staleTarget])
        await assertStoreError(.heldIntent(intentID: held.intentID, holds: [.staleTarget])) {
            try await store.beginDispatch(
                binding: gen1, expectedRevision: record.revision, intentID: held.intentID,
                attempt: AgentRecoveryAttemptStart(attemptID: UUID()), authorization: .explicitUserAction
            )
        }
    }

    // MARK: - Discovery

    func testDiscoveryDerivesPreviousInstanceHoldWithoutRewritingOrDispatching() async throws {
        let storeA = makeStore(instance: instanceA)
        let open = binding(UUID(), UUID())
        let closed = binding(UUID(), UUID())
        let queued = Support.submission("queued")
        let direct = Support.submission("direct")
        let r1 = try await storeA.commitQueuedIntent(
            binding: open, expectedRevision: nil, submission: queued, consumption: nil
        ).intent.recordRevision
        _ = try await storeA.commitDispatchingIntent(
            binding: open, expectedRevision: r1, submission: direct,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID()), consumption: nil
        )
        _ = try await storeA.commitComposer(
            binding: closed, expectedRevision: nil, expectedComposerRevision: nil, snapshot: Support.snapshot("closed tab draft")
        )
        let ownEntries = try await storeA.discoverRecords()
        XCTAssertEqual(ownEntries.count, 2)
        XCTAssertTrue(ownEntries.allSatisfy { entry in
            guard case let .supported(discovered) = entry else { return false }
            return discovered.holdsByIntentID.isEmpty
        }, "the owning instance sees no previous-instance hold")

        // Relaunch: a new instance discovers both records, including one with no tab or intents.
        let storeB = makeStore(instance: instanceB)
        let openURL = storeB.recordFileURL(sessionID: open.sessionID)
        let bytesBefore = try Data(contentsOf: openURL)
        let entries = try await storeB.discoverRecords()
        XCTAssertEqual(try Data(contentsOf: openURL), bytesBefore, "discovery never rewrites")
        let discovered = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (UUID, AgentRecoveryDiscoveredRecord)? in
            guard case let .supported(value) = entry else { return nil }
            return (value.record.sessionID, value)
        })
        XCTAssertEqual(Set(discovered.keys), [open.sessionID, closed.sessionID])
        XCTAssertEqual(discovered[closed.sessionID]?.record.composer?.content.text, "closed tab draft")
        let openRecord = try XCTUnwrap(discovered[open.sessionID])
        XCTAssertEqual(openRecord.record.intent(id: queued.intentID)?.deliveryState, .queued)
        XCTAssertEqual(openRecord.record.intent(id: direct.intentID)?.deliveryState, .dispatching, "stored state preserved")
        XCTAssertEqual(openRecord.holdsByIntentID[queued.intentID], [.previousInstance])
        XCTAssertEqual(openRecord.holdsByIntentID[direct.intentID], [.previousInstance])

        // A live queue in the new instance cannot drain it; an explicit user action can.
        await assertStoreError(.heldIntent(intentID: queued.intentID, holds: [.previousInstance])) {
            try await storeB.beginDispatch(
                binding: open, expectedRevision: openRecord.record.revision, intentID: queued.intentID,
                attempt: AgentRecoveryAttemptStart(attemptID: UUID()), authorization: .liveQueue
            )
        }
        let claimed = try await storeB.beginDispatch(
            binding: open, expectedRevision: openRecord.record.revision, intentID: queued.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID()), authorization: .explicitUserAction
        )
        XCTAssertEqual(claimed.intent.deliveryState, .dispatching)
        let after = try await loadRecord(storeB, open.sessionID)
        XCTAssertEqual(after.intent(id: queued.intentID)?.appInstanceID, instanceB)
        let holdsAfterClaim = await storeB.derivedHolds(for: after)
        XCTAssertNil(holdsAfterClaim[queued.intentID])
    }

    // MARK: - Attachments

    func testAttachmentImportFailuresLeaveRecordIntactAndRewritesNeverDeleteFiles() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        let initial = try await store.commitComposer(
            binding: session, expectedRevision: nil, expectedComposerRevision: nil, snapshot: Support.snapshot("keep me")
        )

        // Import failures never reach the record.
        let missingSource = sourceDirectory.appendingPathComponent("missing.png")
        await assertStoreErrorCategory(.attachment) {
            try await store.importManagedImage(sessionID: session.sessionID, sourceURL: missingSource)
        }
        let textSource = sourceDirectory.appendingPathComponent("notes.txt")
        try Data("text".utf8).write(to: textSource)
        await assertStoreErrorCategory(.attachment) {
            try await store.importManagedImage(sessionID: session.sessionID, sourceURL: textSource)
        }
        let phantom = AgentRecoveryImageReference(
            id: UUID(), location: .managedFile(fileName: "phantom.png"), title: nil,
            createdAt: AgentRecoveryTimestamp(millisecondsSince1970: 0)
        )
        await assertStoreError(.attachmentUnavailable(imageID: phantom.id)) {
            try await store.commitComposer(
                binding: session, expectedRevision: initial.recordRevision,
                expectedComposerRevision: initial.composerRevision, snapshot: Support.snapshot("with phantom", images: [phantom])
            )
        }
        let afterRejections = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(afterRejections.revision, initial.recordRevision)

        // Live attachments are copied into durable recovery storage before being referenced.
        let liveSource = try Support.makeImageSource(in: sourceDirectory)
        let liveAttachment = AgentImageAttachment(source: .localFile(path: liveSource.path), title: "shot.png")
        let imageA = try await store.importManagedImage(sessionID: session.sessionID, attachment: liveAttachment)
        XCTAssertEqual(imageA.id, liveAttachment.id)
        let restoredA = try XCTUnwrap(store.attachment(for: imageA, sessionID: session.sessionID))
        guard case let .localFile(pathA) = restoredA.source else { return XCTFail("expected local file") }
        XCTAssertTrue(pathA.hasPrefix(store.managedAttachmentDirectoryURL(sessionID: session.sessionID).path))
        let remote = try await store.importManagedImage(
            sessionID: session.sessionID, attachment: AgentImageAttachment(source: .url("https://example.com/a.png"))
        )
        XCTAssertEqual(remote.location, .remoteURL("https://example.com/a.png"))

        let composerA = Support.snapshot("A", images: [imageA, remote])
        let withA = try await store.commitComposer(
            binding: session, expectedRevision: initial.recordRevision,
            expectedComposerRevision: initial.composerRevision, snapshot: composerA
        )
        let submitted = try await store.commitQueuedIntent(
            binding: session, expectedRevision: withA.recordRevision, submission: Support.submission("A", images: [imageA]),
            consumption: AgentRecoveryComposerConsumption(submittedRevision: composerA.revision)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: pathA))

        // A file the record stops referencing may still be live input or schedule-owned: kept.
        let imageB = try await store.importManagedImage(
            sessionID: session.sessionID, sourceURL: Support.makeImageSource(in: sourceDirectory)
        )
        let withB = try await store.commitComposer(
            binding: session, expectedRevision: submitted.intent.recordRevision, expectedComposerRevision: nil,
            snapshot: Support.snapshot("B", images: [imageB])
        )
        let nameB = try XCTUnwrap(imageB.managedFileName)
        let pathB = try XCTUnwrap(store.managedImageURL(sessionID: session.sessionID, fileName: nameB)).path
        _ = try await store.commitComposer(
            binding: session, expectedRevision: withB.recordRevision, expectedComposerRevision: withB.composerRevision,
            snapshot: Support.snapshot("no images")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: pathB), "record rewrites never delete attachments")
        let nameA = try XCTUnwrap(imageA.managedFileName)
        let referenceA = await store.managedImageRecordReference(sessionID: session.sessionID, fileName: nameA)
        let referenceB = await store.managedImageRecordReference(sessionID: session.sessionID, fileName: nameB)
        let referenceEscape = await store.managedImageRecordReference(sessionID: session.sessionID, fileName: "../escape.png")
        XCTAssertEqual(referenceA, .referencedByRecord)
        XCTAssertEqual(referenceB, .notReferencedByRecord)
        XCTAssertEqual(referenceEscape, .unknown)
    }

    func testAlreadyManagedImageIsReferencedInPlaceWithoutCopying() async throws {
        let store = makeStore()
        let sessionID = UUID()
        let directory = store.managedAttachmentDirectoryURL(sessionID: sessionID)
        let liveSource = try Support.makeImageSource(in: sourceDirectory)
        let live = AgentImageAttachment(source: .localFile(path: liveSource.path), title: "shot.png")
        let first = try await store.importManagedImage(sessionID: sessionID, attachment: live)
        let name = try XCTUnwrap(first.managedFileName)
        XCTAssertEqual(try managedFiles(directory), [name])

        // A restored attachment resolves into managed storage; re-importing it (every keystroke
        // snapshot) references the same file instead of copying it again.
        let restored = try XCTUnwrap(store.attachment(for: first, sessionID: sessionID))
        for _ in 0 ..< 3 {
            let again = try await store.importManagedImage(sessionID: sessionID, attachment: restored)
            XCTAssertEqual(again.id, first.id)
            XCTAssertEqual(again.location, first.location)
            XCTAssertEqual(again.title, first.title)
        }
        let byURL = try await store.importManagedImage(sessionID: sessionID, sourceURL: directory.appendingPathComponent(name))
        XCTAssertEqual(byURL.location, first.location)
        XCTAssertEqual(try managedFiles(directory), [name], "no duplicate copies; the path is stable")

        // Another session's managed file is an external source for this session and is copied.
        let otherSession = UUID()
        let copied = try await store.importManagedImage(sessionID: otherSession, attachment: restored)
        XCTAssertNotNil(copied.managedFileName)
        XCTAssertEqual(try managedFiles(store.managedAttachmentDirectoryURL(sessionID: otherSession)).count, 1)
        XCTAssertEqual(try managedFiles(directory), [name])

        // A missing managed file is reported, never re-created; a missing external source fails import.
        try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        await assertStoreError(.attachmentUnavailable(imageID: restored.id)) {
            try await store.importManagedImage(sessionID: sessionID, attachment: restored)
        }
        await assertStoreErrorCategory(.attachment) {
            try await store.importManagedImage(
                sessionID: sessionID,
                sourceURL: self.sourceDirectory.appendingPathComponent("absent.png")
            )
        }
        XCTAssertEqual(try managedFiles(directory), [])
    }

    // MARK: - Card acknowledgements (Phase 2 §D)

    func testCardAcknowledgementRoundTripsAndSurvivesUnrelatedWrites() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        let queued = Support.submission("queued")
        let other = Support.submission("other")
        var revision = try await store.commitQueuedIntent(
            binding: session, expectedRevision: nil, submission: queued, consumption: nil
        ).intent.recordRevision
        let key = AgentRecoveryCardKey(
            kind: .savedInput,
            incarnationID: session.incarnationID,
            transcriptResetGeneration: 0,
            entityID: queued.intentID.uuidString
        )
        let freshness = AgentRecoveryCardFreshness("queued|held:false|stale:false")
        let committed = try await store.acknowledgeCard(
            binding: session, expectedRevision: revision, key: key, freshness: freshness, isCurrent: { _ in true }
        )
        XCTAssertEqual(committed.disposition, .committed)
        let repeated = try await store.acknowledgeCard(
            binding: session, expectedRevision: nil, key: key, freshness: freshness, isCurrent: { _ in true }
        )
        XCTAssertEqual(repeated.disposition, .unchanged, "An identical Dismiss is idempotent")

        // Unrelated writes keep the acknowledgement; they never unhide the card.
        revision = try await store.commitQueuedIntent(
            binding: session, expectedRevision: committed.recordRevision, submission: other, consumption: nil
        ).intent.recordRevision
        let composerReceipt = try await store.commitComposer(
            binding: session,
            expectedRevision: revision,
            expectedComposerRevision: nil,
            snapshot: Support.snapshot("typing")
        )
        revision = try XCTUnwrap(composerReceipt.recordRevision)
        _ = try await store.withdraw(binding: session, expectedRevision: revision, intentID: other.intentID)

        // A relaunch reads it back; only the exact acknowledged state is dismissed.
        let relaunched = makeStore(instance: instanceB)
        let record = try await loadRecord(relaunched, session.sessionID)
        XCTAssertTrue(record.isCardAcknowledged(key, freshness: freshness))
        XCTAssertFalse(record.isCardAcknowledged(key, freshness: AgentRecoveryCardFreshness("failed|held:false|stale:false")))
        XCTAssertEqual(record.cardAcknowledgements.count, 1)
        XCTAssertEqual(record.intent(id: queued.intentID)?.deliveryState, .queued, "Dismiss withdraws nothing")
    }

    func testCardAcknowledgementKeepsUnknownKindsAndMembersAcrossRewrites() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        let key = AgentRecoveryCardKey(kind: .run, incarnationID: session.incarnationID, transcriptResetGeneration: nil, entityID: "run-1")
        _ = try await store.acknowledgeCard(
            binding: session, expectedRevision: nil, key: key, freshness: AgentRecoveryCardFreshness("interrupted|appCrash"),
            isCurrent: { _ in true }
        )
        let fileURL = store.recordFileURL(sessionID: session.sessionID)
        var json = try Support.readJSON(fileURL)
        XCTAssertNil(Support.member(json, at: [.key("cardAcknowledgements"), .index(0)], key: "transcriptResetGeneration"))
        Support.setMember(&json, at: [.key("cardAcknowledgements"), .index(0)], key: "kind", value: .string("futureKind"))
        Support.setMember(&json, at: [.key("cardAcknowledgements"), .index(0)], key: "futureMember", value: .string("kept"))
        try Support.writeJSON(json, to: fileURL)

        let relaunched = makeStore(instance: instanceB)
        let record = try await loadRecord(relaunched, session.sessionID)
        let future = try XCTUnwrap(record.cardAcknowledgements.first)
        XCTAssertEqual(future.key.kindRaw, "futureKind")
        XCTAssertNil(future.key.kind)
        XCTAssertFalse(record.isCardAcknowledged(key, freshness: AgentRecoveryCardFreshness("interrupted|appCrash")))

        // An unrelated rewrite keeps the newer build's acknowledgement byte-for-byte in meaning.
        _ = try await relaunched.commitQueuedIntent(
            binding: session, expectedRevision: record.revision, submission: Support.submission("later"), consumption: nil
        )
        let rewritten = try Support.readJSON(fileURL)
        XCTAssertEqual(Support.member(rewritten, at: [.key("cardAcknowledgements"), .index(0)], key: "kind"), .string("futureKind"))
        XCTAssertEqual(Support.member(rewritten, at: [.key("cardAcknowledgements"), .index(0)], key: "futureMember"), .string("kept"))
    }

    func testCardAcknowledgementRefusesChangedCardsOtherIncarnationsAndNeverEvictsAnother() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        func key(_ entity: String, incarnation: UUID? = nil) -> AgentRecoveryCardKey {
            AgentRecoveryCardKey(kind: .run, incarnationID: incarnation ?? session.incarnationID, transcriptResetGeneration: nil, entityID: entity)
        }
        let freshness = AgentRecoveryCardFreshness("interrupted|-")
        await assertStoreError(.cardChanged) {
            try await store.acknowledgeCard(binding: session, expectedRevision: nil, key: key("a"), freshness: freshness, isCurrent: { _ in false })
        }
        let afterRefusal = await store.read(sessionID: session.sessionID)
        XCTAssertNil(afterRefusal.record, "A refused Dismiss writes nothing")
        let foreign = UUID()
        await assertStoreError(.staleIncarnation(expected: session.incarnationID, actual: foreign)) {
            try await store.acknowledgeCard(
                binding: session, expectedRevision: nil, key: key("a", incarnation: foreign), freshness: freshness, isCurrent: { _ in true }
            )
        }

        // Review A F07 (deliberate contract change): more than the former 128 bound are all kept.
        let limit = 129
        for index in 0 ... limit {
            _ = try await store.acknowledgeCard(
                binding: session,
                expectedRevision: store.currentRevision(sessionID: session.sessionID),
                key: key("entity-\(index)"),
                freshness: freshness,
                isCurrent: { _ in true }
            )
        }
        // A changed state of the same key replaces it in place of adding another.
        _ = try await store.acknowledgeCard(
            binding: session,
            expectedRevision: store.currentRevision(sessionID: session.sessionID),
            key: key("entity-\(limit)"),
            freshness: AgentRecoveryCardFreshness("failed|-"),
            isCurrent: { _ in true }
        )
        let record = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(record.cardAcknowledgements.count, limit + 1, "No acknowledgement is evicted")
        XCTAssertTrue(
            record.isCardAcknowledged(key("entity-0"), freshness: freshness),
            "An unrelated Dismiss never makes an unchanged dismissed card reappear"
        )
        XCTAssertTrue(record.isCardAcknowledged(key("entity-\(limit)"), freshness: AgentRecoveryCardFreshness("failed|-")))
        XCTAssertFalse(record.isCardAcknowledged(key("entity-\(limit)"), freshness: freshness))
    }

    /// Review B F8: emptying a record's other content (withdrawing its last held intent) never
    /// removes the record or its acknowledgements; a later unrelated write keeps the Dismiss.
    func testWithdrawingTheLastIntentKeepsCardAcknowledgements() async throws {
        let store = makeStore()
        let session = binding(UUID(), UUID())
        let submission = Support.submission("only input")
        _ = try await store.commitQueuedIntent(binding: session, expectedRevision: nil, submission: submission, consumption: nil)
        let key = AgentRecoveryCardKey(kind: .run, incarnationID: session.incarnationID, transcriptResetGeneration: nil, entityID: "turn")
        let freshness = AgentRecoveryCardFreshness("interrupted|appCrash")
        _ = try await store.acknowledgeCard(
            binding: session,
            expectedRevision: store.currentRevision(sessionID: session.sessionID),
            key: key,
            freshness: freshness,
            isCurrent: { _ in true }
        )
        _ = try await store.withdraw(
            binding: session, expectedRevision: store.currentRevision(sessionID: session.sessionID), intentID: submission.intentID
        )
        let afterWithdraw = try await loadRecord(store, session.sessionID)
        XCTAssertTrue(afterWithdraw.isCardAcknowledged(key, freshness: freshness), "The last intent's withdrawal keeps the Dismiss")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.recordFileURL(sessionID: session.sessionID).path))

        // An unrelated later write (a new input) never unhides it.
        _ = try await store.commitQueuedIntent(
            binding: session,
            expectedRevision: store.currentRevision(sessionID: session.sessionID),
            submission: Support.submission("later"),
            consumption: nil
        )
        let afterUnrelated = try await loadRecord(store, session.sessionID)
        XCTAssertTrue(afterUnrelated.isCardAcknowledged(key, freshness: freshness))
    }

    // MARK: - Crash-hold settlement (9-live O43/O46)

    /// One earlier-launch session for the settlement tests: an open run `open`, a finished run
    /// `finished`, and intents in every relevant state.
    private struct SettlementFixture {
        let session: AgentRecoveryLifecycleBinding
        let open: UUID
        let dispatching: UUID
        let dispatchingAttempt: UUID
        let unknown: UUID
        let unknownAttempt: UUID
        let onFinishedRun: UUID
        let queued: UUID
        let accepted: UUID
    }

    private func settlementFixture(_ earlier: AgentRecoveryStore) async throws -> SettlementFixture {
        let session = binding(UUID(), UUID())
        let open = Support.ownership(sessionID: session.sessionID)
        let finished = Support.ownership(sessionID: session.sessionID)
        func revision() async throws -> AgentRecoveryRecordRevision? {
            try await earlier.currentRevision(sessionID: session.sessionID)
        }
        for ownership in [open, finished] {
            _ = try await earlier.ensureRunAttempt(
                binding: session, expectedRevision: revision(), ownership: ownership, processRunID: nil, transcriptTurnID: nil,
                providerKindRaw: nil
            )
        }
        func dispatch(_ text: String, on runAttemptID: UUID) async throws -> (intentID: UUID, attemptID: UUID) {
            let submission = Support.submission(text)
            _ = try await earlier.commitQueuedIntent(binding: session, expectedRevision: revision(), submission: submission, consumption: nil)
            let attempt = AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: runAttemptID)
            _ = try await earlier.beginDispatch(
                binding: session, expectedRevision: revision(), intentID: submission.intentID, attempt: attempt, authorization: .liveQueue
            )
            return (submission.intentID, attempt.attemptID)
        }
        let dispatching = try await dispatch("dispatching", on: open.attemptID)
        let unknown = try await dispatch("unknown", on: open.attemptID)
        _ = try await earlier.recordDeliveryOutcome(
            binding: session, expectedRevision: revision(), intentID: unknown.intentID, attemptID: unknown.attemptID, outcome: .deliveryUnknown
        )
        let accepted = try await dispatch("accepted", on: open.attemptID)
        _ = try await earlier.recordDeliveryOutcome(
            binding: session, expectedRevision: revision(), intentID: accepted.intentID, attemptID: accepted.attemptID, outcome: .providerAccepted
        )
        // A T4-style retry: its attempt is on a run whose terminal commit is recorded.
        let onFinishedRun = try await dispatch("retry", on: finished.attemptID)
        _ = try await earlier.recordRunTerminal(
            binding: session, expectedRevision: revision(), commit: Support.terminalCommit(ownership: finished, state: .failed)
        )
        let queued = Support.submission("queued")
        _ = try await earlier.commitQueuedIntent(binding: session, expectedRevision: revision(), submission: queued, consumption: nil)
        return SettlementFixture(
            session: session,
            open: open.attemptID,
            dispatching: dispatching.intentID,
            dispatchingAttempt: dispatching.attemptID,
            unknown: unknown.intentID,
            unknownAttempt: unknown.attemptID,
            onFinishedRun: onFinishedRun.intentID,
            queued: queued.intentID,
            accepted: accepted.intentID
        )
    }

    /// Check's write settles the earlier launch's uncertain intents of the exited run (and the
    /// retry on a finished run) to `deliveryUnknown` in the acknowledgement's own write: open
    /// attempts get the outcome with its message, payloads stay, `queued` and `providerAccepted`
    /// are untouched, and the acknowledgement lists the settled intents.
    func testCrashHoldAcknowledgementSettlesUncertainIntentsOfTheExitedRun() async throws {
        let fixture = try await settlementFixture(makeStore(instance: instanceA))
        let store = makeStore(instance: instanceB)
        let session = fixture.session
        let before = try await loadRecord(store, session.sessionID)
        let unknownOutcomeBefore = before.attempts.first { $0.attemptID == fixture.unknownAttempt }?.outcome
        let intentIDs: Set = [fixture.dispatching, fixture.unknown, fixture.onFinishedRun]

        let receipt = try await store.recordCrashHoldAcknowledgement(
            binding: session,
            expectedRevision: store.currentRevision(sessionID: session.sessionID),
            incarnationID: session.incarnationID,
            transcriptResetGeneration: 0,
            runAttemptIDs: [fixture.open],
            intentIDs: intentIDs,
            transcriptTurnIDs: [],
            settlement: .everyIntent
        )

        XCTAssertEqual(receipt.disposition, .committed)
        let record = try await loadRecord(store, session.sessionID)
        for intentID in intentIDs {
            XCTAssertEqual(record.intent(id: intentID)?.deliveryState, .deliveryUnknown)
            XCTAssertEqual(record.intent(id: intentID)?.payload, before.intent(id: intentID)?.payload, "the message text is kept")
            XCTAssertTrue(record.isSettledByCrashHoldExitProof(intentID: intentID))
        }
        let settledAttempt = try XCTUnwrap(record.attempts.first { $0.attemptID == fixture.dispatchingAttempt }?.outcome)
        XCTAssertEqual(settledAttempt.outcome, .deliveryUnknown)
        XCTAssertEqual(
            settledAttempt.extras[AgentRecoveryAttemptOutcome.deliveryUnknownMessageExtrasKey],
            .string(AgentRecoveryCrashHoldIntentSettlement.provenExitMessage)
        )
        XCTAssertEqual(
            record.attempts.first { $0.attemptID == fixture.unknownAttempt }?.outcome,
            unknownOutcomeBefore,
            "an attempt already closed keeps its outcome"
        )
        XCTAssertEqual(record.intent(id: fixture.queued)?.deliveryState, .queued)
        XCTAssertEqual(record.intent(id: fixture.accepted)?.deliveryState, .providerAccepted)
        XCTAssertFalse(record.isSettledByCrashHoldExitProof(intentID: fixture.queued))
        XCTAssertEqual(record.crashHoldAcknowledgement?.intentIDs, intentIDs)
        XCTAssertEqual(record.crashHoldAcknowledgement?.runAttemptIDs, [fixture.open])
        XCTAssertNil(record.runAttempt(id: fixture.open)?.terminal, "no run is closed")

        // The reread round-trips the outcome's message (a forward-compatible extras member).
        let reread = try await loadRecord(makeStore(instance: instanceB), session.sessionID)
        XCTAssertEqual(reread.attempts, record.attempts)

        // Repeating the identical write has nothing left to settle.
        let repeated = try await store.recordCrashHoldAcknowledgement(
            binding: session,
            expectedRevision: store.currentRevision(sessionID: session.sessionID),
            incarnationID: session.incarnationID,
            transcriptResetGeneration: 0,
            runAttemptIDs: [fixture.open],
            intentIDs: intentIDs,
            transcriptTurnIDs: [],
            settlement: .everyIntent
        )
        XCTAssertEqual(repeated.disposition, .unchanged)
    }

    /// Check's write refuses the whole hold (nothing written) when an uncertain intent's attempt is on
    /// a run the proof doesn't cover, or has no run-attempt reference; "It stopped" settles the
    /// qualifying ones and only acknowledges the rest.
    func testCrashHoldSettlementRefusesUncoveredAttemptsForCheckAndSkipsThemForItStopped() async throws {
        let earlier = makeStore(instance: instanceA)
        let fixture = try await settlementFixture(earlier)
        let session = fixture.session
        let untied = Support.submission("untied")
        _ = try await earlier.commitQueuedIntent(
            binding: session, expectedRevision: earlier.currentRevision(sessionID: session.sessionID), submission: untied, consumption: nil
        )
        _ = try await earlier.beginDispatch(
            binding: session,
            expectedRevision: earlier.currentRevision(sessionID: session.sessionID),
            intentID: untied.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID()),
            authorization: .liveQueue
        )
        let store = makeStore(instance: instanceB)
        let before = try await loadRecord(store, session.sessionID)

        // The open run isn't among the exited ones.
        await assertStoreError(.intentConflict(fixture.dispatching)) {
            try await store.recordCrashHoldAcknowledgement(
                binding: session,
                expectedRevision: store.currentRevision(sessionID: session.sessionID),
                incarnationID: session.incarnationID,
                transcriptResetGeneration: 0,
                runAttemptIDs: [],
                intentIDs: [fixture.dispatching],
                transcriptTurnIDs: [],
                settlement: .everyIntent
            )
        }
        // An attempt without a run-attempt reference.
        await assertStoreError(.intentConflict(untied.intentID)) {
            try await store.recordCrashHoldAcknowledgement(
                binding: session,
                expectedRevision: store.currentRevision(sessionID: session.sessionID),
                incarnationID: session.incarnationID,
                transcriptResetGeneration: 0,
                runAttemptIDs: [fixture.open],
                intentIDs: [fixture.dispatching, untied.intentID],
                transcriptTurnIDs: [],
                settlement: .everyIntent
            )
        }
        let afterRefusals = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(afterRefusals.revision, before.revision, "a refused settlement writes nothing")

        // "It stopped": the qualifying intent is settled, the untied one is acknowledged only.
        _ = try await store.recordCrashHoldAcknowledgement(
            binding: session,
            expectedRevision: store.currentRevision(sessionID: session.sessionID),
            incarnationID: session.incarnationID,
            transcriptResetGeneration: 0,
            runAttemptIDs: [fixture.open],
            intentIDs: [fixture.dispatching, untied.intentID],
            transcriptTurnIDs: [],
            settlement: .qualifyingIntents
        )
        let record = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(record.intent(id: fixture.dispatching)?.deliveryState, .deliveryUnknown)
        XCTAssertEqual(
            record.attempts.first { $0.attemptID == fixture.dispatchingAttempt }?.outcome?
                .extras[AgentRecoveryAttemptOutcome.deliveryUnknownMessageExtrasKey],
            .string(AgentRecoveryCrashHoldIntentSettlement.userConfirmedStopMessage)
        )
        XCTAssertEqual(record.intent(id: untied.intentID)?.deliveryState, .dispatching, "an untied attempt is never settled")
        XCTAssertFalse(record.isSettledByCrashHoldExitProof(intentID: untied.intentID))
        XCTAssertEqual(record.crashHoldAcknowledgement?.intentIDs, [fixture.dispatching, untied.intentID])
    }

    /// The settlement is never evaluated against this launch's own input, and a stale revision is
    /// refused before anything is written.
    func testCrashHoldSettlementRefusesCurrentLaunchInputAndRevisionConflicts() async throws {
        let fixture = try await settlementFixture(makeStore(instance: instanceA))
        let session = fixture.session
        // The same launch that dispatched it: not an earlier launch's input.
        let sameLaunch = makeStore(instance: instanceA)
        await assertStoreError(.intentConflict(fixture.dispatching)) {
            try await sameLaunch.recordCrashHoldAcknowledgement(
                binding: session,
                expectedRevision: sameLaunch.currentRevision(sessionID: session.sessionID),
                incarnationID: session.incarnationID,
                transcriptResetGeneration: 0,
                runAttemptIDs: [fixture.open],
                intentIDs: [fixture.dispatching],
                transcriptTurnIDs: [],
                settlement: .everyIntent
            )
        }
        let store = makeStore(instance: instanceB)
        let before = try await loadRecord(store, session.sessionID)
        await assertStoreErrorCategory(.revisionConflict) {
            try await store.recordCrashHoldAcknowledgement(
                binding: session,
                expectedRevision: .make(),
                incarnationID: session.incarnationID,
                transcriptResetGeneration: 0,
                runAttemptIDs: [fixture.open],
                intentIDs: [fixture.dispatching],
                transcriptTurnIDs: [],
                settlement: .everyIntent
            )
        }
        let after = try await loadRecord(store, session.sessionID)
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.intent(id: fixture.dispatching)?.deliveryState, .dispatching)
    }

    // MARK: - Helpers

    private func managedFiles(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

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
