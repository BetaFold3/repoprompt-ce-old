@testable import RepoPromptAgentCore
import XCTest

/// Composer persistence controller (lossless restart Phase 1b, inactive). Deadlines use a manual
/// sleep seam; lifecycle authority is a fixture gate, not `AgentSessionDataService`.
@MainActor
final class AgentRecoveryComposerPersistenceControllerTests: XCTestCase {
    private typealias Support = RecoveryTestSupport
    private typealias Controller = AgentRecoveryComposerPersistenceController

    private var root: URL!
    private var failures: RecoveryStoreWriteFailureSwitch!
    private var store: AgentRecoveryStore!
    private var sleeper: RecoveryManualSleeper!
    private var clock: RecoveryTestClock!
    private var lifecycle: RecoveryFixtureLifecycle!
    private var gate: RecoveryFixtureGate!

    override func setUp() async throws {
        root = try Support.makeTemporaryRoot("AgentRecoveryComposerControllerTests")
        failures = RecoveryStoreWriteFailureSwitch()
        store = AgentRecoveryStore(
            rootURL: root.appendingPathComponent("AgentRecovery/v1", isDirectory: true),
            appInstanceID: UUID(),
            fileOperations: failures.fileOperations()
        )
        sleeper = RecoveryManualSleeper()
        clock = RecoveryTestClock()
        let incarnation = UUID()
        lifecycle = RecoveryFixtureLifecycle(incarnationID: incarnation)
        gate = RecoveryFixtureGate(
            binding: AgentRecoveryLifecycleBinding(sessionID: UUID(), incarnationID: incarnation, transcriptResetGeneration: 0),
            lifecycle: lifecycle
        )
    }

    override func tearDown() async throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeController(
        durable: AgentRecoveryComposerRevision? = nil,
        gate: RecoveryFixtureGate? = nil
    ) -> Controller {
        let sleeper = sleeper!
        let clock = clock!
        return Controller(
            store: store,
            gate: gate ?? self.gate!,
            durableComposerRevision: durable,
            sleep: { try await sleeper.sleep(until: $0) },
            clockNow: { clock.now }
        )
    }

    private func storedComposer() async -> AgentRecoveryComposerSnapshot? {
        await store.read(sessionID: gate.binding.sessionID).record?.composer
    }

    private func assertEventually(
        _ message: String = "condition not reached",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let reached = await Support.eventually(condition)
        XCTAssertTrue(reached, message, file: file, line: line)
    }

    private func assertPendingDeadlines(
        _ expected: [ContinuousClock.Instant],
        _ message: String = "pending deadlines",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await assertEventually(message, file: file, line: line) { await self.sleeper.pendingDeadlines == expected }
    }

    // MARK: - Deadlines

    func testDeadlinesAreAbsoluteFromFirstUnsavedMutationDespiteLateTimerStartAndOngoingEdits() async {
        let controller = makeController()
        let debounce = Controller.debounce
        let maximum = Controller.maximumDelay
        let t0 = clock.now

        controller.composerDidChange(Support.content("h"))
        // Time passes before the timer tasks first run; their deadlines must not move.
        clock.advance(by: .milliseconds(1500))
        await assertPendingDeadlines([t0 + debounce, t0 + maximum], "deadlines are captured at the mutation")
        XCTAssertEqual(controller.maximumDelayDeadline, t0 + maximum)

        // Ongoing edits restart only the debounce; the maximum stays anchored to the first edit.
        controller.composerDidChange(Support.content("he"))
        await assertPendingDeadlines([t0 + .milliseconds(1800), t0 + maximum])
        clock.advance(by: .milliseconds(250))
        let r3 = controller.composerDidChange(Support.content("hel"))
        await assertPendingDeadlines([t0 + maximum, t0 + .milliseconds(2050)])
        let maximumRequests = await sleeper.requestedDeadlines.count { $0 == t0 + maximum }
        XCTAssertEqual(maximumRequests, 1, "the maximum-delay timer is armed once")
        let beforeDeadline = await storedComposer()
        XCTAssertNil(beforeDeadline, "nothing written before a deadline")

        // The 2-second bound fires although typing kept postponing the debounce.
        await sleeper.fire(through: t0 + maximum)
        await assertEventually { await self.storedComposer()?.revision == r3 }
        XCTAssertEqual(controller.durableComposerRevision, r3)
        XCTAssertFalse(controller.hasPendingChanges)
        XCTAssertNil(controller.maximumDelayDeadline)
        await assertPendingDeadlines([], "the spent debounce is cancelled")

        // After a pause, the 300 ms debounce writes on its own.
        clock.advance(by: .seconds(10))
        let t1 = clock.now
        let r4 = controller.composerDidChange(Support.content("hello"))
        await assertPendingDeadlines([t1 + debounce, t1 + maximum])
        await sleeper.fire(through: t1 + debounce)
        await assertEventually { await self.storedComposer()?.revision == r4 }
        let written = await storedComposer()
        XCTAssertEqual(written?.content.text, "hello")
    }

    func testEditsDuringHeldWriteOwnTheirBoundAndCompletionDoesNotResetIt() async {
        let controller = makeController()
        let t0 = clock.now
        let r1 = controller.composerDidChange(Support.content("first"))
        await assertPendingDeadlines([t0 + Controller.debounce, t0 + Controller.maximumDelay])

        // The debounce write captures r1 (spending both timers) and is held inside the lifecycle gate.
        await lifecycle.armPause()
        clock.advance(by: .milliseconds(300))
        await sleeper.fire(through: t0 + Controller.debounce)
        await lifecycle.waitUntilPaused()
        await assertPendingDeadlines([], "the captured snapshot's timers are spent")

        // An edit during the held write is owed within 2 s of its own first mutation.
        clock.advance(by: .milliseconds(500))
        let t2 = clock.now
        let r2 = controller.composerDidChange(Support.content("second"))
        await assertPendingDeadlines([t2 + Controller.debounce, t2 + Controller.maximumDelay])

        // The held write completes later; the newer edit's deadline is not rebased to completion.
        clock.advance(by: .seconds(1))
        await lifecycle.releasePause()
        await assertEventually { await self.storedComposer()?.revision == r1 }
        XCTAssertTrue(controller.hasPendingChanges)
        XCTAssertEqual(controller.maximumDelayDeadline, t2 + Controller.maximumDelay)
        await assertPendingDeadlines([t2 + Controller.debounce, t2 + Controller.maximumDelay])

        await sleeper.fire(through: t2 + Controller.maximumDelay)
        await assertEventually { await self.storedComposer()?.revision == r2 }
    }

    func testFlushWritesImmediatelyAndWriteFailurePersistsUntilNextSuccess() async {
        let controller = makeController()
        let r1 = controller.composerDidChange(Support.content("draft", interviewFirst: true))
        failures.shouldFailWrites = true
        let failed = await controller.flush()
        guard case let .failed(failure) = failed, case let .store(error) = failure else {
            return XCTFail("expected store failure, got \(failed)")
        }
        XCTAssertEqual(error.category, .storage)
        XCTAssertEqual(controller.lastWriteFailure, failure)
        XCTAssertTrue(controller.hasPendingChanges, "the snapshot is retained after a failed write")
        XCTAssertNil(controller.durableComposerRevision)

        failures.shouldFailWrites = false
        guard case let .committed(receipt) = await controller.flush() else {
            return XCTFail("expected commit")
        }
        XCTAssertEqual(receipt.composerRevision, r1)
        XCTAssertNil(controller.lastWriteFailure)
        let written = await storedComposer()
        XCTAssertEqual(written?.content.interviewFirst, true)
        let again = await controller.flush()
        XCTAssertEqual(again, .nothingPending)
    }

    // MARK: - Submission

    func testSubmissionConsumesSubmittedOrSupersededComposerButNeverNewerTyping() async throws {
        let controller = makeController()

        // Durable r1, pending r2, submit r2: r1 is superseded, so it is consumed with the intent.
        controller.composerDidChange(Support.content("hel"))
        _ = await controller.flush()
        let r2 = controller.composerDidChange(Support.content("hello"))
        let attempt = AgentRecoveryAttemptStart(attemptID: UUID())
        let first = try await controller.submitDirect(Support.submission("hello"), attempt: attempt, submittedRevision: r2).get()
        XCTAssertTrue(first.receipt.intent.composerConsumed)
        XCTAssertEqual(first.receipt.intent.deliveryState, .dispatching)
        XCTAssertEqual(first.receipt.attemptID, attempt.attemptID)
        XCTAssertTrue(first.permitsClearingLiveComposer(currentLiveRevision: controller.liveRevision))
        XCTAssertFalse(controller.hasPendingChanges, "pre-submission draft work is invalidated")
        XCTAssertNil(controller.durableComposerRevision)
        // A spent timer firing later must not resurrect the submitted draft.
        await sleeper.fire(through: clock.now + .seconds(60))
        let flushAfterSubmit = await controller.flush()
        XCTAssertEqual(flushAfterSubmit, .nothingPending)
        let afterFirst = await storedComposer()
        XCTAssertNil(afterFirst)

        // r3 submitted, but r4 was typed and persisted before the submission committed: preserved.
        let r3 = controller.composerDidChange(Support.content("next"))
        let r4 = controller.composerDidChange(Support.content("next and more"))
        _ = await controller.flush()
        let second = try await controller.submitQueued(Support.submission("next"), submittedRevision: r3).get()
        XCTAssertFalse(second.receipt.intent.composerConsumed)
        XCTAssertEqual(second.receipt.intent.composerRevision, r4)
        XCTAssertEqual(second.receipt.intent.deliveryState, .queued)
        XCTAssertFalse(second.permitsClearingLiveComposer(currentLiveRevision: controller.liveRevision))
        let preserved = await storedComposer()
        XCTAssertEqual(preserved?.revision, r4)
    }

    func testEditsDuringSubmissionStayPendingAndAreWrittenAfterIt() async throws {
        let controller = makeController()
        let r1 = controller.composerDidChange(Support.content("send me"))
        await lifecycle.armPause()
        let submission = Support.submission("send me")
        let submitTask = Task { await controller.submitQueued(submission, submittedRevision: r1) }
        await lifecycle.waitUntilPaused()
        let r2 = controller.composerDidChange(Support.content("typed during submit"))
        await lifecycle.releasePause()
        let result = try await submitTask.value.get()
        XCTAssertEqual(result.receipt.intent.deliveryState, .queued)
        XCTAssertFalse(result.permitsClearingLiveComposer(currentLiveRevision: controller.liveRevision))
        XCTAssertTrue(controller.hasPendingChanges, "newer typing is not invalidated by the submission")

        guard case let .committed(receipt) = await controller.flush() else {
            return XCTFail("expected the newer draft to be written")
        }
        XCTAssertEqual(receipt.composerRevision, r2)
        let state = await store.read(sessionID: gate.binding.sessionID)
        let record = try XCTUnwrap(state.record)
        XCTAssertEqual(record.composer?.content.text, "typed during submit")
        XCTAssertEqual(record.intents.map(\.intentID), [submission.intentID])
    }

    func testFailedSubmissionChangesNothingAndKeepsDraftPending() async throws {
        let controller = makeController()
        controller.composerDidChange(Support.content("old"))
        _ = await controller.flush()
        let durable = controller.durableComposerRevision
        let r2 = controller.composerDidChange(Support.content("new"))
        failures.shouldFailWrites = true
        let result = await controller.submitQueued(Support.submission("new"), submittedRevision: r2)
        guard case let .failure(.store(error)) = result else {
            return XCTFail("expected failure, got \(result)")
        }
        XCTAssertEqual(error.category, .storage)
        XCTAssertTrue(controller.hasPendingChanges)
        XCTAssertEqual(controller.durableComposerRevision, durable)
        let state = await store.read(sessionID: gate.binding.sessionID)
        let record = try XCTUnwrap(state.record)
        XCTAssertTrue(record.intents.isEmpty)
        XCTAssertEqual(record.composer?.revision, durable)
    }

    // MARK: - Lifecycle and restoration

    func testLifecycleRejectionBlocksComposerWritesAndSubmissionsWithFixtureAuthority() async {
        let controller = makeController()
        let r1 = controller.composerDidChange(Support.content("draft"))
        await lifecycle.advanceReset()
        guard case .failed(.lifecycleRejected) = await controller.flush() else {
            return XCTFail("stale reset generation must be rejected")
        }
        await lifecycle.markDeleted()
        let submitted = await controller.submitQueued(Support.submission("draft"), submittedRevision: r1)
        guard case .failure(.lifecycleRejected) = submitted else {
            return XCTFail("deleted session must be rejected")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recordFileURL(sessionID: gate.binding.sessionID).path))
        XCTAssertTrue(controller.hasPendingChanges)
    }

    func testRestorationReturnsDurableComposerUnlessNewerTypingArrived() async throws {
        let writer = makeController()
        let stored = writer.composerDidChange(Support.content("from before restart"))
        _ = await writer.flush()

        let restoring = makeController()
        guard case let .restored(snapshot) = await restoring.loadRestorableComposer() else {
            return XCTFail("expected restore")
        }
        XCTAssertEqual(snapshot?.revision, stored)
        XCTAssertEqual(restoring.durableComposerRevision, stored)

        // A restored composer that the user then edits and submits is consumed as superseded.
        let edited = restoring.composerDidChange(Support.content("from before restart, edited"))
        let result = try await restoring.submitQueued(Support.submission("edited"), submittedRevision: edited).get()
        XCTAssertTrue(result.receipt.intent.composerConsumed)

        // Typing while a restore read is in flight wins over the restore.
        let fresh = makeController()
        await lifecycle.armPause()
        let loadTask = Task { await fresh.loadRestorableComposer() }
        await lifecycle.waitUntilPaused()
        fresh.composerDidChange(Support.content("typed first"))
        await lifecycle.releasePause()
        let outcome = await loadTask.value
        XCTAssertEqual(outcome, .superseded)
    }

    func testTypingDuringRestoreOfStoredComposerLearnsBaselineAndLaterFlushSucceeds() async {
        let writer = makeController()
        let r0 = writer.composerDidChange(Support.content("stored before restart"))
        _ = await writer.flush()

        // A fresh controller (no baseline) restores while the user types during the read.
        let fresh = makeController()
        await lifecycle.armPause()
        let loadTask = Task { await fresh.loadRestorableComposer() }
        await lifecycle.waitUntilPaused()
        let r1 = fresh.composerDidChange(Support.content("typed during restore"))
        await lifecycle.releasePause()
        let outcome = await loadTask.value
        XCTAssertEqual(outcome, .superseded, "newer typing is not overwritten")
        XCTAssertEqual(fresh.durableComposerRevision, r0, "the validated read still sets the CAS baseline")
        XCTAssertEqual(fresh.liveRevision, r1)
        XCTAssertTrue(fresh.hasPendingChanges)

        guard case let .committed(receipt) = await fresh.flush() else {
            return XCTFail("the newer typing must replace the stored composer")
        }
        XCTAssertEqual(receipt.composerRevision, r1)
        XCTAssertNil(fresh.lastWriteFailure)
        let reloaded = await relaunchedComposer()
        XCTAssertEqual(reloaded?.revision, r1)
        XCTAssertEqual(reloaded?.content.text, "typed during restore")
    }

    func testQueuedSubmissionEnqueuedDuringRestoreConsumesRestoredBaselineButNotNewerTyping() async throws {
        try await assertSubmissionEnqueuedDuringRestore(direct: false)
    }

    func testDirectSubmissionEnqueuedDuringRestoreConsumesRestoredBaselineButNotNewerTyping() async throws {
        try await assertSubmissionEnqueuedDuringRestore(direct: true)
    }

    func testRestoredBaselineNeverConsumesANewerSelfWrittenRevision() async throws {
        let writer = makeController()
        let r0 = writer.composerDidChange(Support.content("stored before restart"))
        _ = await writer.flush()

        let restoring = makeController()
        guard case let .restored(restored?) = await restoring.loadRestorableComposer() else {
            return XCTFail("expected restore")
        }
        XCTAssertEqual(restored.revision, r0)
        let r1 = restoring.composerDidChange(Support.content("submitted"))
        let r2 = restoring.composerDidChange(Support.content("submitted, then kept typing"))
        guard case .committed = await restoring.flush() else {
            return XCTFail("expected the newer draft to be stored")
        }
        let result = try await restoring.submitQueued(Support.submission("submitted"), submittedRevision: r1).get()
        XCTAssertFalse(result.receipt.intent.composerConsumed, "a revision written after the submitted edit is kept")
        XCTAssertEqual(result.receipt.intent.composerRevision, r2)
        let reloaded = await relaunchedComposer()
        XCTAssertEqual(reloaded?.revision, r2)
        XCTAssertEqual(reloaded?.content.text, "submitted, then kept typing")
    }

    func testHeldDraftSurvivesNewGenerationTypingAndFlushAcrossReload() async throws {
        let (held, resetGate, writer) = try await seedHeldDraft()

        // A controller bound to the new generation does not adopt the old draft or use it as a baseline.
        let restoring = makeController(gate: resetGate)
        let outcome = await restoring.loadRestorableComposer()
        XCTAssertEqual(outcome, .heldForOtherGeneration(held))
        XCTAssertNil(restoring.durableComposerRevision, "a held draft is never a write baseline")
        XCTAssertEqual(restoring.heldComposerRevision, held.revision)
        XCTAssertNil(restoring.liveRevision)

        // The old-generation controller can no longer write.
        writer.composerDidChange(Support.content("late old typing"))
        guard case .failed(.lifecycleRejected) = await writer.flush() else {
            return XCTFail("stale generation must be rejected")
        }

        // New typing is refused with a typed error and stays pending; it never replaces the held draft.
        let heldError = AgentRecoveryStoreError.heldComposerUnresolved(revision: held.revision, transcriptResetGeneration: 0)
        restoring.composerDidChange(Support.content("after reset"))
        let flushed = await restoring.flush()
        XCTAssertEqual(flushed, .failed(.store(heldError)))
        XCTAssertEqual(restoring.lastWriteFailure, .store(heldError))
        XCTAssertTrue(restoring.hasPendingChanges)
        restoring.composerDidChange(Support.content(""))
        let removal = await restoring.flush()
        XCTAssertEqual(removal, .failed(.store(heldError)), "clearing the new composer never removes the held draft")

        // A controller that never restored is refused too, and learns the held revision from the error.
        let unaware = makeController(gate: resetGate)
        unaware.composerDidChange(Support.content("unaware typing"))
        let unawareFlush = await unaware.flush()
        XCTAssertEqual(unawareFlush, .failed(.store(heldError)))
        XCTAssertEqual(unaware.heldComposerRevision, held.revision)
        XCTAssertNil(unaware.durableComposerRevision)

        let reloaded = await relaunchedComposer()
        XCTAssertEqual(reloaded, held, "text, workflow, tagged files, and image references survive")
        assertManagedImagesExist(held)

        // Once the held draft is gone (stand-in for a future explicit resolution), the next
        // successful write clears the stale held revision.
        let fileURL = store.recordFileURL(sessionID: gate.binding.sessionID)
        guard case var .object(object) = try Support.readJSON(fileURL) else {
            return XCTFail("expected a record object")
        }
        object.removeValue(forKey: "composer")
        try Support.writeJSON(.object(object), to: fileURL)
        unaware.composerDidChange(Support.content("after resolution"))
        guard case .committed = await unaware.flush() else {
            return XCTFail("expected commit once no held composer is stored")
        }
        XCTAssertNil(unaware.heldComposerRevision)
        XCTAssertNil(unaware.lastWriteFailure)
    }

    func testHeldDraftSurvivesNewGenerationSubmissionAcrossReload() async throws {
        let (held, resetGate, _) = try await seedHeldDraft()
        let restoring = makeController(gate: resetGate)
        let outcome = await restoring.loadRestorableComposer()
        XCTAssertEqual(outcome, .heldForOtherGeneration(held))

        // Submitting unflushed new input commits the intent and leaves the held draft in place.
        let typed = restoring.composerDidChange(Support.content("new message"))
        let queued = Support.submission("new message")
        let queuedResult = try await restoring.submitQueued(queued, submittedRevision: typed).get()
        XCTAssertFalse(queuedResult.receipt.intent.composerConsumed)
        XCTAssertNil(queuedResult.receipt.intent.composerRevision)
        XCTAssertEqual(queuedResult.receipt.intent.heldComposerRevision, held.revision)
        XCTAssertTrue(queuedResult.permitsClearingLiveComposer(currentLiveRevision: restoring.liveRevision))
        XCTAssertFalse(restoring.hasPendingChanges)
        XCTAssertNil(restoring.durableComposerRevision, "the held draft never becomes the baseline")
        XCTAssertEqual(restoring.heldComposerRevision, held.revision)

        let next = restoring.composerDidChange(Support.content("direct message"))
        let direct = Support.submission("direct message")
        let directResult = try await restoring.submitDirect(
            direct, attempt: AgentRecoveryAttemptStart(attemptID: UUID()), submittedRevision: next
        ).get()
        XCTAssertFalse(directResult.receipt.intent.composerConsumed)
        XCTAssertEqual(directResult.receipt.intent.heldComposerRevision, held.revision)

        let relaunched = AgentRecoveryStore(rootURL: recoveryRootURL, appInstanceID: UUID())
        let state = await relaunched.read(sessionID: gate.binding.sessionID)
        let record = try XCTUnwrap(state.record)
        XCTAssertEqual(record.composer, held, "text, workflow, tagged files, and image references survive")
        XCTAssertEqual(record.intents.map(\.intentID), [queued.intentID, direct.intentID])
        XCTAssertEqual(record.intents.map(\.transcriptResetGeneration), [1, 1])
        assertManagedImagesExist(held)
    }

    func testDiscardingHeldDraftStoresPendingTypingInOneReplacementAndRefusesAStaleRevision() async throws {
        let (held, resetGate, _) = try await seedHeldDraft()
        let restoring = makeController(gate: resetGate)
        let outcome = await restoring.loadRestorableComposer()
        XCTAssertEqual(outcome, .heldForOtherGeneration(held))
        let typed = restoring.composerDidChange(Support.content("typed after reset"))

        let commits = RecoveryCommitLog()
        store.commitPublisher.setHandler { commits.append($0) }
        defer { store.commitPublisher.setHandler(nil) }

        // Only exactly the displayed held revision can be resolved.
        let stale = await restoring.resolveHeldComposer(.discard, expectedHeldRevision: .make())
        XCTAssertEqual(stale, .failure(.heldInputChanged))
        XCTAssertEqual(restoring.heldComposerRevision, held.revision)
        XCTAssertTrue(commits.all.isEmpty, "a refused resolution writes nothing")

        let result = await restoring.resolveHeldComposer(.discard, expectedHeldRevision: held.revision)
        XCTAssertEqual(result, .success(nil))
        XCTAssertNil(restoring.heldComposerRevision)
        XCTAssertFalse(restoring.hasPendingChanges, "the live typing was stored with the discard")
        XCTAssertEqual(restoring.durableComposerRevision, typed)
        XCTAssertNil(restoring.lastWriteFailure)
        XCTAssertEqual(commits.all.count, 1, "discard and the live typing are one record replacement")
        guard case let .supported(record)? = commits.all.first?.state else {
            return XCTFail("expected a supported-record commit")
        }
        XCTAssertEqual(record.composer?.revision, typed)

        let reloaded = await relaunchedComposer()
        XCTAssertEqual(reloaded?.revision, typed)
        XCTAssertEqual(reloaded?.content.text, "typed after reset")
        XCTAssertEqual(reloaded?.transcriptResetGeneration, 1)
    }

    func testTypingDuringHeldRestoreBeforeItsWriteKeepsTheHeldDraftStoredAndTheTypingPending() async throws {
        let (held, resetGate, _) = try await seedHeldDraft()
        let restoring = makeController(gate: resetGate)
        let outcome = await restoring.loadRestorableComposer()
        XCTAssertEqual(outcome, .heldForOtherGeneration(held))
        let commits = RecoveryCommitLog()
        store.commitPublisher.setHandler { commits.append($0) }
        defer { store.commitPublisher.setHandler(nil) }

        // The resolution passed its unsaved-content check and holds the gate, before its write.
        await lifecycle.armPause()
        let resolution = Task { await restoring.resolveHeldComposer(.restoreToComposer, expectedHeldRevision: held.revision) }
        await lifecycle.waitUntilPaused()
        XCTAssertNotNil(restoring.activeResolutionFence, "the restore freeze is armed while it is in flight")
        let typed = restoring.composerDidChange(Support.content("typed during restore"))
        await lifecycle.releasePause()
        let result = await resolution.value

        XCTAssertEqual(result, .failure(.composerChangedDuringRestore))
        XCTAssertTrue(commits.all.isEmpty, "the raced restore wrote nothing")
        XCTAssertNil(restoring.activeResolutionFence)
        XCTAssertNil(restoring.restoreRevertFailure)
        XCTAssertEqual(restoring.heldComposerRevision, held.revision, "the held draft stays stored and presented")
        XCTAssertEqual(restoring.liveRevision, typed)
        XCTAssertTrue(restoring.hasPendingChanges, "the typing stays in the message box")
        let stored = await relaunchedComposer()
        XCTAssertEqual(stored, held, "the held draft is durable, unchanged")

        // The user then resolves explicitly: discarding the old draft stores the typing.
        let discarded = await restoring.resolveHeldComposer(.discard, expectedHeldRevision: held.revision)
        XCTAssertEqual(discarded, .success(nil))
        let reloaded = await relaunchedComposer()
        XCTAssertEqual(reloaded?.revision, typed)
        XCTAssertEqual(reloaded?.content.text, "typed during restore")
    }

    func testChangeAfterTheRestoreWriteRevertsToTheHeldDraftDurably() async throws {
        let (held, resetGate, _) = try await seedHeldDraft()
        let restoring = makeController(gate: resetGate)
        let outcome = await restoring.loadRestorableComposer()
        XCTAssertEqual(outcome, .heldForOtherGeneration(held))

        // A change reported right after the store committed the restore (before the owner
        // resumed): the commit publisher runs synchronously after the write.
        await lifecycle.armPause()
        let resolution = Task { await restoring.resolveHeldComposer(.restoreToComposer, expectedHeldRevision: held.revision) }
        await lifecycle.waitUntilPaused()
        let fence = try XCTUnwrap(restoring.activeResolutionFence)
        let commits = RecoveryCommitLog()
        store.commitPublisher.setHandler { commit in
            commits.append(commit)
            fence.noteComposerMutation()
        }
        defer { store.commitPublisher.setHandler(nil) }
        await lifecycle.releasePause()
        let result = await resolution.value

        XCTAssertEqual(result, .failure(.composerChangedDuringRestore))
        XCTAssertEqual(fence.state, .trippedAfterCommit)
        XCTAssertEqual(commits.all.count, 2, "the restore commit and its revert")
        XCTAssertNil(restoring.restoreRevertFailure)
        XCTAssertEqual(restoring.heldComposerRevision, held.revision)
        XCTAssertNil(restoring.durableComposerRevision, "a held draft is never a write baseline")
        let stored = await relaunchedComposer()
        XCTAssertEqual(stored, held, "the held draft is stored again, unchanged")
        assertManagedImagesExist(held)

        // Typing now is refused by the held draft (both kept) until an explicit resolution.
        restoring.composerDidChange(Support.content("typed after the race"))
        let flushed = await restoring.flush()
        guard case .failed(.store(.heldComposerUnresolved)) = flushed else {
            return XCTFail("ordinary writes never replace the held draft, got \(flushed)")
        }
        let restoredAgain = await restoring.resolveHeldComposer(.restoreToComposer, expectedHeldRevision: held.revision)
        XCTAssertEqual(restoredAgain, .failure(.liveComposerHasUnsavedContent))
    }

    /// R02: a raced restore whose rollback fails keeps the restored draft protected in the stored
    /// composer slot. Newer typing never replaces it; once storage recovers, the next write
    /// retries the rollback, the held draft is stored again (never memory-only), and a relaunched
    /// store and controller recover the original draft. The newer typing stays pending.
    func testFailedRollbackKeepsTheRestoredDraftProtectedUntilARetriedRollbackSucceeds() async throws {
        let race = try await raceRestoreWithFailingRollback()
        let (held, resetGate, restoring, restored) = (race.held, race.resetGate, race.restoring, race.restored)
        let commits = race.commits
        defer { store.commitPublisher.setHandler(nil) }
        var rolledBack: [AgentRecoveryComposerSnapshot] = []
        restoring.restoreRollbackDidSucceed = { rolledBack.append($0) }
        var stored: AgentRecoveryComposerSnapshot?

        // Newer typing while storage still fails: the rollback retry fails, nothing is replaced.
        restoring.composerDidChange(Support.content("typed after the race"))
        let stillFailing = await restoring.flush()
        guard case let .failed(.store(storageError)) = stillFailing else {
            return XCTFail("expected the retried rollback to fail on storage, got \(stillFailing)")
        }
        XCTAssertEqual(storageError.category, .storage)
        XCTAssertEqual(restoring.lastWriteFailure, .store(storageError), "the failure stays visible for Retry")
        XCTAssertTrue(restoring.isRestoredDraftAwaitingRollback)
        XCTAssertTrue(restoring.hasPendingChanges, "the newer typing stays in the message box")
        stored = await relaunchedComposer()
        XCTAssertEqual(stored?.content.text, "typed before reset", "typing never replaces the protected draft")

        // Storage recovers: the next write retries the rollback first, and it succeeds.
        failures.shouldFailWrites = false
        let recovered = await restoring.flush()
        let heldError = AgentRecoveryStoreError.heldComposerUnresolved(revision: held.revision, transcriptResetGeneration: 0)
        XCTAssertEqual(recovered, .failed(.store(heldError)), "the held draft owns the slot again and refuses the typing")
        XCTAssertFalse(restoring.isRestoredDraftAwaitingRollback)
        XCTAssertNil(restoring.restoreRevertFailure)
        XCTAssertEqual(restoring.heldComposerRevision, held.revision)
        XCTAssertNil(restoring.durableComposerRevision, "a held draft is never a write baseline")
        XCTAssertEqual(restoring.lastWriteFailure, .store(heldError))
        XCTAssertEqual(rolledBack, [held], "the owner is told the held draft is back")
        XCTAssertTrue(restoring.hasPendingChanges, "the newer typing is still pending and visible")
        XCTAssertEqual(commits.all.count, 2, "the restore and the retried rollback")
        stored = await relaunchedComposer()
        XCTAssertEqual(stored, held, "the held draft is stored again, unchanged")
        assertManagedImagesExist(held)

        // Relaunch: a new store and controller recover the original draft.
        let relaunchedStore = AgentRecoveryStore(rootURL: recoveryRootURL, appInstanceID: UUID())
        let sleeper = try XCTUnwrap(sleeper)
        let clock = try XCTUnwrap(clock)
        let relaunchedController = Controller(
            store: relaunchedStore,
            gate: resetGate,
            durableComposerRevision: nil,
            sleep: { try await sleeper.sleep(until: $0) },
            clockNow: { clock.now }
        )
        let reloaded = await relaunchedController.loadRestorableComposer()
        XCTAssertEqual(reloaded, .heldForOtherGeneration(held))
    }

    /// R02: while the rollback is outstanding, a submission of newer typing commits its intent but
    /// never consumes the protected restored draft; the later rollback restores the held draft.
    func testSubmissionDuringAnOutstandingRollbackNeverConsumesTheProtectedDraft() async throws {
        let race = try await raceRestoreWithFailingRollback()
        defer { store.commitPublisher.setHandler(nil) }
        failures.shouldFailWrites = false

        let typed = race.restoring.composerDidChange(Support.content("sent after the race"))
        let submission = Support.submission("sent after the race")
        let queued = try await race.restoring.submitQueued(submission, submittedRevision: typed).get()
        XCTAssertFalse(queued.receipt.intent.composerConsumed, "the protected restored draft is not consumed")
        XCTAssertTrue(race.restoring.isRestoredDraftAwaitingRollback)
        var stored = await relaunchedComposer()
        XCTAssertEqual(stored?.revision, race.restored.revision)
        XCTAssertEqual(stored?.content.text, "typed before reset")

        let flushed = await race.restoring.flush()
        XCTAssertEqual(flushed, .nothingPending, "the rollback succeeded and nothing else was owed")
        XCTAssertNil(race.restoring.lastWriteFailure)
        XCTAssertEqual(race.restoring.heldComposerRevision, race.held.revision)
        stored = await relaunchedComposer()
        XCTAssertEqual(stored, race.held, "the held draft is stored again")
        let relaunched = AgentRecoveryStore(rootURL: recoveryRootURL, appInstanceID: UUID())
        let state = await relaunched.read(sessionID: race.resetGate.binding.sessionID)
        let record = try XCTUnwrap(state.record)
        XCTAssertEqual(record.intents.map(\.intentID), [submission.intentID])
    }

    private struct FailedRollbackRace {
        let held: AgentRecoveryComposerSnapshot
        let resetGate: RecoveryFixtureGate
        let restoring: Controller
        let restored: AgentRecoveryComposerSnapshot
        let commits: RecoveryCommitLog
    }

    /// A held restore commits, a change trips its fence right after, and the revert write fails
    /// (storage failing from then on). The commit-publisher handler stays installed.
    private func raceRestoreWithFailingRollback() async throws -> FailedRollbackRace {
        let (held, resetGate, _) = try await seedHeldDraft()
        let restoring = makeController(gate: resetGate)
        let outcome = await restoring.loadRestorableComposer()
        XCTAssertEqual(outcome, .heldForOtherGeneration(held))

        await lifecycle.armPause()
        let resolution = Task { await restoring.resolveHeldComposer(.restoreToComposer, expectedHeldRevision: held.revision) }
        await lifecycle.waitUntilPaused()
        let fence = try XCTUnwrap(restoring.activeResolutionFence)
        let failures = failures!
        let commits = RecoveryCommitLog()
        store.commitPublisher.setHandler { commit in
            commits.append(commit)
            // Only the restore commit: the change lands after it and storage then starts failing.
            guard commits.all.count == 1 else { return }
            fence.noteComposerMutation()
            failures.shouldFailWrites = true
        }
        await lifecycle.releasePause()
        let result = await resolution.value

        guard case let .success(restored?) = result else {
            XCTFail("a failed revert returns the restored draft unadopted, got \(result)")
            throw CancellationError()
        }
        XCTAssertEqual(fence.state, .trippedAfterCommit)
        XCTAssertEqual(commits.all.count, 1, "only the restore committed; its revert failed")
        XCTAssertEqual(restored.content.text, "typed before reset")
        XCTAssertNotNil(restoring.restoreRevertFailure)
        XCTAssertTrue(restoring.isRestoredDraftAwaitingRollback)
        XCTAssertNil(restoring.heldComposerRevision)
        let stored = await relaunchedComposer()
        XCTAssertEqual(stored?.revision, restored.revision, "the original draft is durable as the restored composer")
        XCTAssertEqual(stored?.content.text, "typed before reset")
        return FailedRollbackRace(held: held, resetGate: resetGate, restoring: restoring, restored: restored, commits: commits)
    }

    func testStoreCommitPublisherReportsWritesAndDeletedSessionRemovalInOrder() async throws {
        let commits = RecoveryCommitLog()
        store.commitPublisher.setHandler { commits.append($0) }
        defer { store.commitPublisher.setHandler(nil) }

        let controller = makeController()
        let r1 = controller.composerDidChange(Support.content("first"))
        _ = await controller.flush()
        let r2 = controller.composerDidChange(Support.content("second"))
        _ = await controller.flush()
        _ = try await store.removeDataForDeletedSession(sessionID: gate.binding.sessionID)
        // Removing an absent record publishes nothing.
        _ = try await store.removeDataForDeletedSession(sessionID: gate.binding.sessionID)

        let all = commits.all
        XCTAssertEqual(all.map(\.sessionID), Array(repeating: gate.binding.sessionID, count: 3))
        XCTAssertEqual(all.map(\.sequence), all.map(\.sequence).sorted())
        XCTAssertEqual(Set(all.map(\.sequence)).count, 3, "sequences are strictly increasing")
        let composerRevisions = all.map { commit -> AgentRecoveryComposerRevision?? in
            if case let .supported(record) = commit.state { return .some(record.composer?.revision) }
            return nil
        }
        XCTAssertEqual(composerRevisions, [.some(r1), .some(r2), nil])
    }

    func testRestoredComposerTextEditKeepsUnknownMembersOfRetainedEntities() async throws {
        let writer = makeController()
        let original = try await richContent("original")
        writer.composerDidChange(original)
        _ = await writer.flush()

        // A newer build stored unknown members on the composer and its retained entities.
        let fileURL = store.recordFileURL(sessionID: gate.binding.sessionID)
        var json = try Support.readJSON(fileURL)
        let composerPath: [Support.PathComponent] = [.key("composer")]
        let contentPath = composerPath + [.key("content")]
        let retained: [[Support.PathComponent]] = [
            composerPath,
            contentPath,
            contentPath + [.key("images"), .index(0)],
            contentPath + [.key("taggedFiles"), .index(0)],
            contentPath + [.key("workflow")]
        ]
        for (index, path) in retained.enumerated() {
            Support.setMember(&json, at: path, key: "futureMember\(index)", value: .object(["n": .number(Decimal(index))]))
        }
        Support.setMember(&json, at: contentPath + [.key("taggedFiles"), .index(1)], key: "futureRemoved", value: .string("x"))
        try Support.writeJSON(json, to: fileURL)

        let restoring = makeController()
        guard case let .restored(restored?) = await restoring.loadRestorableComposer() else {
            return XCTFail("expected restore")
        }
        XCTAssertEqual(restored.extras["futureMember0"], .object(["n": .number(0)]))

        // The producer rebuilds content from live state, which carries no unknown members. The text
        // changes and the second tagged file is explicitly removed.
        let sessionID = gate.binding.sessionID
        let liveImage = try XCTUnwrap(store.attachment(for: restored.content.images[0], sessionID: sessionID))
        let image = try await store.importManagedImage(sessionID: sessionID, attachment: liveImage)
        XCTAssertEqual(image.location, restored.content.images[0].location, "an already-managed image is not copied")
        XCTAssertTrue(image.extras.isEmpty)
        let workflow = try XCTUnwrap(restored.content.workflow?.definition)
        let edited = AgentRecoveryInputContent(
            text: "original, edited",
            images: [image],
            taggedFiles: [AgentRecoveryTaggedFileReference(restored.content.taggedFiles[0].attachment)],
            workflow: AgentRecoveryWorkflowSnapshot(workflow)
        )
        let revision = restoring.composerDidChange(edited)
        guard case let .committed(receipt) = await restoring.flush() else {
            return XCTFail("expected commit")
        }
        XCTAssertEqual(receipt.composerRevision, revision)

        let rewritten = try Support.readJSON(fileURL)
        for (index, path) in retained.enumerated() {
            XCTAssertEqual(
                Support.member(rewritten, at: path, key: "futureMember\(index)"),
                .object(["n": .number(Decimal(index))]),
                "extra \(index) lost on a same-generation edit"
            )
        }
        let relaunched = await relaunchedComposer()
        let reloaded = try XCTUnwrap(relaunched)
        XCTAssertEqual(reloaded.revision, revision)
        XCTAssertEqual(reloaded.content.text, "original, edited")
        XCTAssertEqual(reloaded.content.taggedFiles.map(\.id), [restored.content.taggedFiles[0].id], "explicit removal wins")
        XCTAssertFalse(
            reloaded.content.taggedFiles.contains { $0.extras["futureRemoved"] != nil },
            "a removed entity's members are not carried onto another entity"
        )
        XCTAssertEqual(reloaded.content.images.map(\.id), [restored.content.images[0].id])
    }

    // MARK: - Helpers

    /// R0 is stored; a fresh controller's restore pauses in the gate; the user types R1 and submits it,
    /// and the submission is enqueued before the restore is released; then R2 is typed. The
    /// submission must consume R0 (learned by the preceding restore) but never the newer R2.
    private func assertSubmissionEnqueuedDuringRestore(
        direct: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let writer = makeController()
        writer.composerDidChange(Support.content("stored before restart"))
        _ = await writer.flush()

        let fresh = makeController()
        await lifecycle.armPause()
        let loadTask = Task { await fresh.loadRestorableComposer() }
        await lifecycle.waitUntilPaused()
        let r1 = fresh.composerDidChange(Support.content("sent during restore"))
        let submission = Support.submission("sent during restore")
        let enqueuedBefore = fresh.enqueuedOperationCount
        let submitTask = Task { () -> Result<AgentRecoveryIntentReceipt, AgentRecoveryControllerFailure> in
            if direct {
                let attempt = AgentRecoveryAttemptStart(attemptID: UUID())
                return await fresh.submitDirect(submission, attempt: attempt, submittedRevision: r1).map(\.receipt.intent)
            }
            return await fresh.submitQueued(submission, submittedRevision: r1).map(\.receipt.intent)
        }
        await assertEventually("submission enqueued before the restore is released", file: file, line: line) {
            fresh.enqueuedOperationCount == enqueuedBefore + 1
        }
        let r2 = fresh.composerDidChange(Support.content("typed after sending"))
        await lifecycle.releasePause()

        let outcome = await loadTask.value
        XCTAssertEqual(outcome, .superseded, file: file, line: line)
        let receipt = try await submitTask.value.get()
        XCTAssertTrue(receipt.composerConsumed, "the restored R0 predates R1 and is consumed", file: file, line: line)
        XCTAssertNil(receipt.composerRevision, file: file, line: line)
        XCTAssertEqual(fresh.liveRevision, r2, file: file, line: line)
        XCTAssertTrue(fresh.hasPendingChanges, "newer typing is never consumed", file: file, line: line)
        XCTAssertNil(fresh.durableComposerRevision, file: file, line: line)

        let relaunched = AgentRecoveryStore(rootURL: recoveryRootURL, appInstanceID: UUID())
        let state = await relaunched.read(sessionID: gate.binding.sessionID)
        let record = try XCTUnwrap(state.record, file: file, line: line)
        XCTAssertNil(record.composer, "R0 is no longer the stored composer", file: file, line: line)
        XCTAssertEqual(record.intents.map(\.payload.text), ["sent during restore"], file: file, line: line)
        XCTAssertEqual(record.intents.first?.deliveryState, direct ? .dispatching : .queued, file: file, line: line)

        guard case let .committed(written) = await fresh.flush() else {
            return XCTFail("expected the newer draft to be written", file: file, line: line)
        }
        XCTAssertEqual(written.composerRevision, r2, file: file, line: line)
        let reloaded = await relaunchedComposer()
        XCTAssertEqual(reloaded?.content.text, "typed after sending", file: file, line: line)
    }

    private var recoveryRootURL: URL {
        root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
    }

    /// Composer read through a second store on the same root (an app relaunch).
    private func relaunchedComposer() async -> AgentRecoveryComposerSnapshot? {
        let relaunched = AgentRecoveryStore(rootURL: recoveryRootURL, appInstanceID: UUID())
        return await relaunched.read(sessionID: gate.binding.sessionID).record?.composer
    }

    /// Text, a managed image, two tagged files, and a custom workflow with a template body.
    private func richContent(_ text: String) async throws -> AgentRecoveryInputContent {
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let image = try await store.importManagedImage(
            sessionID: gate.binding.sessionID,
            sourceURL: Support.makeImageSource(in: sources)
        )
        let workflow = AgentWorkflowDefinition(customID: UUID(), displayName: "Custom", template: "Do $ARGUMENTS carefully")
        return AgentRecoveryInputContent(
            text: text,
            images: [image],
            taggedFiles: [
                AgentRecoveryTaggedFileReference(AgentTaggedFileAttachment(relativePath: "a/b.swift", displayName: "b.swift")),
                AgentRecoveryTaggedFileReference(AgentTaggedFileAttachment(relativePath: "c/d.swift", displayName: "d.swift"))
            ],
            workflow: AgentRecoveryWorkflowSnapshot(workflow)
        )
    }

    /// Persists a rich draft under generation 0, then commits a foundation reset (generation 1).
    private func seedHeldDraft() async throws -> (AgentRecoveryComposerSnapshot, RecoveryFixtureGate, Controller) {
        let writer = makeController()
        let draft = try await richContent("typed before reset")
        writer.composerDidChange(draft)
        let flushed = await writer.flush()
        guard case .committed = flushed else {
            XCTFail("expected the draft to persist, got \(flushed)")
            throw CancellationError()
        }
        let storedDraft = await storedComposer()
        let held = try XCTUnwrap(storedDraft)
        XCTAssertEqual(held.transcriptResetGeneration, 0)
        XCTAssertNotNil(held.content.workflow?.template)
        XCTAssertEqual(held.content.taggedFiles.count, 2)
        XCTAssertEqual(held.content.images.count, 1)
        await lifecycle.advanceReset()
        let resetGate = RecoveryFixtureGate(
            binding: AgentRecoveryLifecycleBinding(
                sessionID: gate.binding.sessionID,
                incarnationID: gate.binding.incarnationID,
                transcriptResetGeneration: 1
            ),
            lifecycle: lifecycle
        )
        return (held, resetGate, writer)
    }

    private func assertManagedImagesExist(
        _ snapshot: AgentRecoveryComposerSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for image in snapshot.content.images {
            let url = image.managedFileName.flatMap { store.managedImageURL(sessionID: gate.binding.sessionID, fileName: $0) }
            XCTAssertTrue(url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false, file: file, line: line)
        }
    }
}

/// Commits observed through a store's publisher, in delivery order.
private final class RecoveryCommitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var commits: [AgentRecoveryRecordCommit] = []

    func append(_ commit: AgentRecoveryRecordCommit) {
        lock.withLock { commits.append(commit) }
    }

    var all: [AgentRecoveryRecordCommit] {
        lock.withLock { commits }
    }
}
