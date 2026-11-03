import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptWorkspace
import XCTest

/// Lossless-restart Phase 1a (R3): the transcript save maximum wait and buffered assistant-text
/// draining. Time is controlled by a manual save-timer sleep (no wall-clock waits): debounce
/// timers are never fired, so every save observed here comes from the maximum wait, an explicit
/// flush, or a follow-on the maximum wait requested.
@MainActor
final class AgentTranscriptSaveMaxWaitTests: XCTestCase {
    // MARK: - Deadline arming

    func testFirstUnsavedChangeSetsAbsoluteDeadlineThatContinuousChangesAndRequestsNeverMove() async throws {
        let harness = try await makeHarness(windowID: 4440)
        let timer = installManualTimer(on: harness.viewModel)

        harness.session.appendItem(.user("Prompt"))
        let firstUnsavedAt = try XCTUnwrap(harness.session.transcriptSaveFirstUnsavedAt)
        let generation = harness.session.transcriptSaveMaxWaitGeneration
        // Identified by its absolute deadline: first unsaved instant + 10 s.
        let maxWait = try await maxWaitRequest(timer, for: harness.session)

        // A text stream: every buffer flush mutates a source item and replaces the debounce.
        harness.session.appendItem(.assistant("Streaming", isStreaming: true))
        for index in 0 ..< 5 {
            harness.viewModel.enqueueAssistantDelta(" chunk\(index)", session: harness.session)
            harness.viewModel.flushPendingAssistantDelta(harness.session)
            harness.viewModel.scheduleSave(for: harness.tabID)
        }
        XCTAssertEqual(harness.session.transcriptSaveFirstUnsavedAt, firstUnsavedAt)
        XCTAssertEqual(
            harness.session.transcriptSaveMaxWaitGeneration,
            generation,
            "Later changes and requests never re-arm the deadline"
        )
        XCTAssertNil(harness.session.activeAgentSessionID, "Nothing was saved while the debounce kept being replaced")

        let task = harness.session.transcriptSaveMaxWaitTask
        timer.fire(maxWait)
        await task?.value

        let fileText = try await harness.persistedFileText()
        XCTAssertTrue(fileText.contains("Streaming chunk0 chunk1 chunk2 chunk3 chunk4"), fileText)
        XCTAssertFalse(harness.session.isDirty)
        XCTAssertNil(harness.session.transcriptSaveFirstUnsavedAt, "A clean current receipt clears the obligation")
        XCTAssertEqual(timer.requests(.maxWait).count, 1)
        XCTAssertTrue(timer.requests(.retry).isEmpty)
    }

    func testSourceMutationArmsBeforeItsDirtyMarkDirtyOnlyEditArmsAndPlainRequestDoesNot() async throws {
        let harness = try await makeHarness(windowID: 4441)
        let timer = installManualTimer(on: harness.viewModel)

        // A save request without a mutation never starts the clock.
        harness.viewModel.scheduleSave(for: harness.tabID)
        XCTAssertNil(harness.session.transcriptSaveFirstUnsavedAt)
        XCTAssertNil(harness.session.transcriptSaveMaxWaitTask)

        // The source-items callback runs before the mutation's dirty mark: it arms on its own.
        XCTAssertFalse(harness.session.isDirty)
        harness.session.onPersistenceMutation = nil
        let original = harness.session.onSourceItemsChanged
        var observedAtCallback: (dirty: Bool, armed: Bool)?
        harness.session.onSourceItemsChanged = { session, mutation, caller in
            original?(session, mutation, caller)
            observedAtCallback = (session.isDirty, session.transcriptSaveFirstUnsavedAt != nil)
        }
        harness.session.appendItem(.user("Source edit"))
        XCTAssertEqual(observedAtCallback?.dirty, false)
        XCTAssertEqual(observedAtCallback?.armed, true)
        _ = try await maxWaitRequest(timer, for: harness.session)

        // A dirty-only edit (a run-state transition changes no source item) arms too.
        let other = try await makeHarness(windowID: 4442)
        let otherTimer = installManualTimer(on: other.viewModel)
        let revision = other.session.sourceItemsRevision
        other.session.runState = .cancelled
        XCTAssertEqual(other.session.sourceItemsRevision, revision, "The edit is dirty-only")
        XCTAssertTrue(other.session.isDirty)
        _ = try await maxWaitRequest(otherTimer, for: other.session)
    }

    // MARK: - Receipts and in-flight writes

    func testCoveringOlderSnapshotRebasesDeadlineToPreCallAndInFlightWriteGetsImmediateSave() async throws {
        let harness = try await makeHarness(windowID: 4443)
        let timer = installManualTimer(on: harness.viewModel)
        harness.session.appendItem(.user("Initial"))
        let initialSaved = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(initialSaved)
        XCTAssertNil(harness.session.transcriptSaveFirstUnsavedAt)

        // An older snapshot: a change lands during the deadline save's write. The write covers
        // every change before the save call, so the deadline is rebased to that pre-call instant
        // (never to completion time) and no immediate rewrite follows.
        harness.session.appendItem(.user("A1"))
        let firstUnsavedAt = try XCTUnwrap(harness.session.transcriptSaveFirstUnsavedAt)
        var writeCount = 0
        var newerChangeAt: ContinuousClock.Instant?
        harness.viewModel.test_saveSessionBeforeWriteHook = { session in
            writeCount += 1
            if writeCount == 1 {
                newerChangeAt = .now
                session.appendItem(.user("A2 during write"))
            }
        }
        var task = harness.session.transcriptSaveMaxWaitTask
        let expired = try await maxWaitRequest(timer, for: harness.session)
        let firedAt = ContinuousClock.now
        timer.fire(expired)
        await task?.value
        XCTAssertEqual(writeCount, 1, "A covering older snapshot is not rewritten immediately")
        let savedText1 = try await harness.persistedFileText()
        XCTAssertTrue(savedText1.contains("A1"), savedText1)
        XCTAssertFalse(savedText1.contains("A2 during write"), savedText1)
        XCTAssertTrue(harness.session.isDirty, "The newer change stays owed")
        let rebasedAt = try XCTUnwrap(harness.session.transcriptSaveFirstUnsavedAt)
        let changeAt = try XCTUnwrap(newerChangeAt)
        XCTAssertGreaterThan(rebasedAt, firstUnsavedAt)
        XCTAssertGreaterThanOrEqual(rebasedAt, firedAt, "Captured by this wakeup's save call")
        XCTAssertLessThanOrEqual(rebasedAt, changeAt, "Captured before the call, never at completion")
        let rebased = try await maxWaitRequest(timer, for: harness.session)
        XCTAssertEqual(rebased.deadline, rebasedAt + .seconds(10))
        XCTAssertLessThanOrEqual(rebased.deadline, changeAt + .seconds(10), "The newer change is requested within 10 s of itself")
        XCTAssertTrue(timer.requests(.retry).isEmpty)

        // The rebased deadline saves the newer change and clears the obligation.
        task = harness.session.transcriptSaveMaxWaitTask
        timer.fire(rebased)
        await task?.value
        XCTAssertEqual(writeCount, 2)
        let savedText1b = try await harness.persistedFileText()
        XCTAssertTrue(savedText1b.contains("A2 during write"), savedText1b)
        XCTAssertNil(harness.session.transcriptSaveFirstUnsavedAt)
        XCTAssertFalse(harness.session.isDirty)

        // An in-flight write: the deadline fires while an explicit flush is suspended in its write.
        let gate = WriteGate()
        harness.viewModel.test_saveSessionBeforeWriteHook = { _ in await gate.waitOnce() }
        harness.session.appendItem(.user("B1"))
        let flush = Task { await harness.viewModel.flushSaveDetailed(for: harness.tabID) }
        while !gate.isWaiting {
            await Task.yield()
        }
        harness.session.appendItem(.user("B2 after flush snapshot"))
        task = harness.session.transcriptSaveMaxWaitTask
        let inFlightDeadline = try await maxWaitRequest(timer, for: harness.session)
        let requestsBeforeFire = timer.requests(.maxWait).count
        timer.fire(inFlightDeadline)
        while harness.session.transcriptSaveMaxWaitTask != nil {
            await Task.yield()
        }
        gate.release()
        let flushOutcome = await flush.value
        await task?.value
        guard case let .written(flushReceipt) = flushOutcome else {
            return XCTFail("The flush must write its snapshot, got \(flushOutcome)")
        }
        XCTAssertFalse(flushReceipt.projectionClean, "The flush wrote the older snapshot")
        let savedText2 = try await harness.persistedFileText()
        XCTAssertTrue(savedText2.contains("B2 after flush snapshot"), savedText2)
        XCTAssertNil(harness.session.transcriptSaveFirstUnsavedAt)
        XCTAssertFalse(harness.session.isDirty)
        XCTAssertEqual(timer.requests(.maxWait).count, requestsBeforeFire, "No new 10 s window was started")
        XCTAssertTrue(timer.requests(.retry).isEmpty)
    }

    func testFailedSaveKeepsDirtyAndDeadlineAndRetriesOnceAtLeastOneSecondApart() async throws {
        let harness = try await makeHarness(windowID: 4444)
        let timer = installManualTimer(on: harness.viewModel)
        harness.session.appendItem(.user("Initial"))
        let initialSaved = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(initialSaved)

        let folderPath = try await harness.persistedFileURL().deletingLastPathComponent().path
        let originalPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: folderPath)[.posixPermissions] as? NSNumber
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folderPath)
        var permissionsRestored = false
        defer {
            if !permissionsRestored {
                try? FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: folderPath)
            }
        }

        harness.session.appendItem(.user("Unsaved while storage fails"))
        let firstUnsavedAt = try XCTUnwrap(harness.session.transcriptSaveFirstUnsavedAt)
        var task = harness.session.transcriptSaveMaxWaitTask
        let maxWait = try await maxWaitRequest(timer, for: harness.session)
        // Lower bounds are measured from the wakeup: a retry is armed after it.
        var firedAt = ContinuousClock.now
        timer.fire(maxWait)
        await task?.value
        XCTAssertTrue(harness.session.isDirty)
        XCTAssertEqual(harness.session.transcriptSaveFirstUnsavedAt, firstUnsavedAt)
        let firstRetry = try await retryRequest(timer, number: 1)
        XCTAssertEqual(timer.requests(.retry).count, 1, "One coalesced retry, no loop")
        XCTAssertGreaterThanOrEqual(firstRetry.deadline - firedAt, .seconds(1))

        task = harness.session.transcriptSaveMaxWaitTask
        firedAt = ContinuousClock.now
        timer.fire(firstRetry)
        await task?.value
        XCTAssertTrue(harness.session.isDirty)
        let secondRetry = try await retryRequest(timer, number: 2)
        XCTAssertEqual(timer.requests(.retry).count, 2)
        XCTAssertGreaterThanOrEqual(secondRetry.deadline - firedAt, .seconds(2), "Retries back off")

        try FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: folderPath)
        permissionsRestored = true
        task = harness.session.transcriptSaveMaxWaitTask
        timer.fire(secondRetry)
        await task?.value
        XCTAssertFalse(harness.session.isDirty)
        XCTAssertNil(harness.session.transcriptSaveFirstUnsavedAt)
        let savedText3 = try await harness.persistedFileText()
        XCTAssertTrue(savedText3.contains("Unsaved while storage fails"), savedText3)
        XCTAssertEqual(timer.requests(.retry).count, 2)
    }

    // MARK: - Ownership and hydration fences

    func testBindingReplacementAndDisposalMakePreviousOwnerTimerObsolete() async throws {
        // Binding replacement on the same tab retires the previous owner's obligation.
        let harness = try await makeHarness(windowID: 4445)
        let timer = installManualTimer(on: harness.viewModel)
        harness.session.appendItem(.user("Initial"))
        let initialSaved = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(initialSaved)
        let originalFileURL = try await harness.persistedFileURL()
        harness.session.appendItem(.user("Edit of the previous binding"))
        let obsolete = try await maxWaitRequest(timer, for: harness.session)
        let obsoleteTask = harness.session.transcriptSaveMaxWaitTask
        let maxWaitRequests = timer.requests(.maxWait).count

        XCTAssertNotNil(harness.viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: harness.session))
        XCTAssertNil(harness.session.transcriptSaveFirstUnsavedAt)
        XCTAssertNil(harness.session.transcriptSaveMaxWaitTask)
        timer.fire(obsolete)
        await obsoleteTask?.value
        let originalText = try String(contentsOf: originalFileURL, encoding: .utf8)
        XCTAssertFalse(originalText.contains("Edit of the previous binding"), "The obsolete wakeup saved nothing")
        XCTAssertEqual(timer.requests(.maxWait).count, maxWaitRequests, "Nothing re-armed")
        XCTAssertTrue(timer.requests(.retry).isEmpty)

        // A disposed owner (no longer `sessions[tabID]`) is never serviced.
        let disposed = try await makeHarness(windowID: 4446)
        let disposedTimer = installManualTimer(on: disposed.viewModel)
        disposed.session.appendItem(.user("Disposed edit"))
        let disposedTask = disposed.session.transcriptSaveMaxWaitTask
        let disposedDeadline = try await maxWaitRequest(disposedTimer, for: disposed.session)
        disposed.viewModel.test_removeLiveSession(tabID: disposed.tabID)
        disposedTimer.fire(disposedDeadline)
        await disposedTask?.value
        XCTAssertNil(disposed.session.activeAgentSessionID, "Nothing was bound or written")
        XCTAssertTrue(disposedTimer.requests(.retry).isEmpty)
    }

    func testDeadlineNeverSavesBoundOwnerWithoutPairedHydrationAuthority() async throws {
        let owner = try await makeHarness(windowID: 4447)
        owner.session.appendItem(.user("Persisted by owner"))
        let saved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        let fileURL = try await owner.persistedFileURL()
        let persistedBefore = try Data(contentsOf: fileURL)

        // A second tab bound to the same session whose paired load did not adopt anything.
        // `hasLoadedPersistedState` alone is not authority.
        let partial = try await makeHarness(windowID: 4448, workspace: owner.workspace, storageURL: owner.storageURL)
        let timer = installManualTimer(on: partial.viewModel)
        XCTAssertNotNil(partial.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: partial.session))
        partial.session.hasLoadedPersistedState = true
        partial.session.persistedLoadDisposition = .unresolved
        partial.session.appendItem(.user("Partial projection"))
        // `saveSessionDetailed` bumps this once past its early guards, before the persistence
        // ownership check that would also fail closed: unchanged means the save never started.
        let saveRequestGeneration = partial.session.saveRequestGeneration
        let task = partial.session.transcriptSaveMaxWaitTask
        try await timer.fire(maxWaitRequest(timer, for: partial.session))
        await task?.value
        _ = try await retryRequest(timer, number: 1)

        XCTAssertEqual(partial.session.saveRequestGeneration, saveRequestGeneration, "No save was started")
        XCTAssertEqual(try Data(contentsOf: fileURL), persistedBefore, "The persisted file is untouched")
        XCTAssertTrue(partial.session.isDirty)
        XCTAssertNotNil(partial.session.transcriptSaveFirstUnsavedAt, "The obligation waits for authority")
        XCTAssertEqual(timer.requests(.retry).count, 1)
    }

    // MARK: - Buffered assistant text

    func testSaveSnapshotDrainsBufferedTextOfEitherProducerExactlyOnce() async throws {
        // View-model producer (Claude/ACP paths).
        let harness = try await makeHarness(windowID: 4449)
        _ = installManualTimer(on: harness.viewModel)
        harness.session.appendItem(.assistant("VM partial", isStreaming: true))
        harness.viewModel.enqueueAssistantDelta(" tail", session: harness.session)
        let vmFlushTimer = harness.session.assistantDeltaFlushTask
        let saved = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(saved)
        XCTAssertTrue(harness.session.pendingAssistantDelta.isEmpty)
        await vmFlushTimer?.value
        XCTAssertEqual(harness.session.items.last?.text, "VM partial tail", "Applied once; the cancelled flush never replays")
        let savedText4 = try await harness.persistedFileText()
        XCTAssertTrue(savedText4.contains("VM partial tail"), savedText4)
        XCTAssertFalse(harness.session.isDirty)

        // Codex coordinator producer: drained through the coordinator's own scoped flush.
        let codex = try await makeHarness(windowID: 4450)
        _ = installManualTimer(on: codex.viewModel)
        codex.session.appendItem(.assistant("Codex partial", isStreaming: true))
        codex.viewModel.codexCoordinator.test_enqueueAssistantDelta(" tail", session: codex.session)
        let codexFlushTimer = codex.session.assistantDeltaFlushTask
        let codexSaved = await codex.viewModel.flushSave(for: codex.tabID)
        XCTAssertTrue(codexSaved)
        XCTAssertTrue(codex.session.pendingAssistantDelta.isEmpty)
        await codexFlushTimer?.value
        XCTAssertEqual(codex.session.items.last?.text, "Codex partial tail")
        let savedText5 = try await codex.persistedFileText()
        XCTAssertTrue(savedText5.contains("Codex partial tail"), savedText5)
    }

    func testSaveOfCleanSessionWritesItsBufferedAssistantText() async throws {
        let harness = try await makeHarness(windowID: 4452)
        _ = installManualTimer(on: harness.viewModel)
        harness.session.appendItem(.assistant("Clean partial", isStreaming: true))
        let initialSaved = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(initialSaved)
        harness.viewModel.enqueueAssistantDelta(" tail", session: harness.session)
        let flushTimer = harness.session.assistantDeltaFlushTask
        XCTAssertFalse(harness.session.isDirty, "Buffering alone does not dirty the session")
        XCTAssertFalse(harness.session.pendingAssistantDelta.isEmpty)

        let outcome = await harness.viewModel.flushSaveDetailed(for: harness.tabID)
        guard case .written = outcome else {
            return XCTFail("A clean session with buffered text must still be written, got \(outcome)")
        }
        await flushTimer?.value
        XCTAssertTrue(harness.session.pendingAssistantDelta.isEmpty)
        XCTAssertEqual(harness.session.items.map(\.text), ["Clean partial tail"])
        let savedText = try await harness.persistedFileText()
        XCTAssertTrue(savedText.contains("Clean partial tail"), savedText)
    }

    func testSaveDrainsScopedCodexBufferIntoItsOwnRowOnly() async throws {
        let harness = try await makeHarness(windowID: 4453)
        _ = installManualTimer(on: harness.viewModel)
        harness.session.appendItem(.user("Question"))
        let scopedRow = AgentChatItem.assistant("Scoped row", isStreaming: true)
        harness.session.appendItem(scopedRow)
        harness.session.appendItem(.assistant("Trailing row", isStreaming: true))
        let scope = CodexNativeSessionController.ItemScope(turnID: "turn-1", itemID: "item-1")
        harness.session.codexAssistantRowIDByScope[scope] = scopedRow.id
        harness.session.pendingCodexAssistantScope = scope
        harness.viewModel.codexCoordinator.test_enqueueAssistantDelta(" tail", session: harness.session)
        let flushTimer = harness.session.assistantDeltaFlushTask

        let saved = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(saved)
        await flushTimer?.value
        XCTAssertTrue(harness.session.pendingAssistantDelta.isEmpty)
        XCTAssertEqual(
            harness.session.items.map(\.text),
            ["Question", "Scoped row tail", "Trailing row"],
            "Only the scoped row receives the text, once; the cancelled timer never replays it"
        )
        let savedText = try await harness.persistedFileText()
        XCTAssertTrue(savedText.contains("Scoped row tail"), savedText)
        XCTAssertFalse(savedText.contains("Trailing row tail"), savedText)
    }

    // MARK: - Parked obligations and teardown

    func testRemovalReservationParksObligationWithFixedOneSecondRetryUntilAborted() async throws {
        let harness = try await makeHarness(windowID: 4454)
        let timer = installManualTimer(on: harness.viewModel)
        harness.session.appendItem(.user("Initial"))
        let initialSaved = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(initialSaved)
        harness.session.appendItem(.user("Edit during removal"))
        let firstUnsavedAt = try XCTUnwrap(harness.session.transcriptSaveFirstUnsavedAt)
        harness.session.staleResetRemovalAdmission = AgentStaleResetRemovalAdmission(
            id: UUID(),
            operationID: UUID(),
            sessionIdentity: ObjectIdentifier(harness.session),
            binding: harness.session.persistentSessionBindingIdentity,
            transitionGeneration: harness.session.bindingTransitionGeneration,
            consentedEpisodeID: nil,
            isReserved: true
        )
        let requestGeneration = harness.session.saveRequestGeneration

        // While reserved, each wakeup parks the obligation and retries at the fixed 1 s floor.
        var task = harness.session.transcriptSaveMaxWaitTask
        let expired = try await maxWaitRequest(timer, for: harness.session)
        // Taken before the wakeup that arms each retry, so `deadline - armedNoEarlierThan` is
        // at least the retry delay exactly; `requestedAt` (when the timer task starts) bounds it above.
        var armedNoEarlierThan = ContinuousClock.now
        timer.fire(expired)
        await task?.value
        for number in 1 ... 2 {
            XCTAssertEqual(harness.session.transcriptSaveFirstUnsavedAt, firstUnsavedAt, "Parked, not cleared")
            XCTAssertEqual(harness.session.saveRequestGeneration, requestGeneration, "No save was started")
            let retry = try await retryRequest(timer, number: number)
            XCTAssertGreaterThanOrEqual(retry.deadline - armedNoEarlierThan, .seconds(1))
            XCTAssertLessThanOrEqual(
                retry.deadline - retry.requestedAt,
                .seconds(1),
                "Waiting never escalates the spacing"
            )
            armedNoEarlierThan = ContinuousClock.now
            if number == 2 {
                // The removal is aborted: the owner keeps its tab and the next retry saves.
                harness.session.staleResetRemovalAdmission = nil
            }
            task = harness.session.transcriptSaveMaxWaitTask
            timer.fire(retry)
            await task?.value
        }
        let savedText = try await harness.persistedFileText()
        XCTAssertTrue(savedText.contains("Edit during removal"), savedText)
        XCTAssertNil(harness.session.transcriptSaveFirstUnsavedAt)
        XCTAssertFalse(harness.session.isDirty)
        XCTAssertEqual(timer.requests(.retry).count, 2)
    }

    func testWindowCloseKeepsPendingDebounceSaveAndWorkspaceDiscardCancelsBothTimers() async throws {
        // Window close: the maximum wait ends, but the pending debounce still writes the edit made
        // just before close (no lifecycle flush exists before Phase 1b).
        let harness = try await makeHarness(windowID: 4455)
        let timer = installManualTimer(on: harness.viewModel)
        harness.session.appendItem(.user("Initial"))
        let initialSaved = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(initialSaved)
        harness.session.appendItem(.user("Edit before close"))
        XCTAssertNotNil(harness.session.saveDebounceTask)
        XCTAssertNotNil(harness.session.transcriptSaveFirstUnsavedAt)
        let maxWaitTask = harness.session.transcriptSaveMaxWaitTask
        let maxWait = try await maxWaitRequest(timer, for: harness.session)

        await harness.viewModel.prepareForWindowClose()
        // Teardown itself re-dirties the session and reschedules, replacing the pre-close debounce
        // (as at HEAD); whichever debounce is pending after close must survive and save.
        let debounceTask = try XCTUnwrap(harness.session.saveDebounceTask, "A pending debounce survives window close")
        XCTAssertFalse(debounceTask.isCancelled)
        // The live debounce is the only uncancelled one; replaced ones stay suspended but cancelled.
        let pendingDebounce = await timer.awaitPendingRequest { $0.kind == .debounce && !$0.isTaskCancelled }
        let debounce = try XCTUnwrap(pendingDebounce)
        XCTAssertEqual(
            timer.requests(.debounce).filter { !$0.isTaskCancelled }.map(\.id),
            [debounce.id],
            "Exactly one debounce is live after close"
        )
        // A mutation after close never re-arms the maximum wait (the observation hook is still installed).
        XCTAssertNotNil(harness.session.onPersistenceMutation)
        let maxWaitRequestCount = timer.requests(.maxWait).count
        harness.session.isDirty = true
        XCTAssertNil(harness.session.transcriptSaveFirstUnsavedAt, "No deadline is armed after close begins")
        XCTAssertNil(harness.session.transcriptSaveMaxWaitTask)
        XCTAssertNil(harness.session.transcriptSaveMaxWaitTask)
        XCTAssertNil(harness.session.transcriptSaveFirstUnsavedAt)
        // The obsolete maximum-wait wakeup saves nothing.
        let requestGeneration = harness.session.saveRequestGeneration
        timer.fire(maxWait)
        await maxWaitTask?.value
        XCTAssertEqual(harness.session.saveRequestGeneration, requestGeneration)
        let textBeforeDebounce = try await harness.persistedFileText()
        XCTAssertFalse(textBeforeDebounce.contains("Edit before close"), textBeforeDebounce)
        // The kept debounce persists the edit; nothing re-arms the deadline after close.
        timer.fire(debounce)
        await debounceTask.value
        let savedText = try await harness.persistedFileText()
        XCTAssertTrue(savedText.contains("Edit before close"), savedText)
        XCTAssertFalse(harness.session.isDirty)
        XCTAssertNil(harness.session.transcriptSaveFirstUnsavedAt, "No change re-armed the deadline after close")
        XCTAssertNil(harness.session.transcriptSaveMaxWaitTask)
        XCTAssertEqual(timer.requests(.maxWait).count, maxWaitRequestCount, "No maximum-wait timer started after close")

        // Workspace-switch discard.
        let other = try await makeHarness(windowID: 4456)
        _ = installManualTimer(on: other.viewModel)
        other.session.appendItem(.user("Edit before switch"))
        XCTAssertNotNil(other.session.saveDebounceTask)
        XCTAssertNotNil(other.session.transcriptSaveFirstUnsavedAt)
        let owner = other.viewModel.test_receiveWorkspaceSwitchNotification(nil)
        await other.viewModel.test_handleWorkspaceSwitch(nil, owner: owner)
        XCTAssertNil(other.session.saveDebounceTask)
        XCTAssertNil(other.session.transcriptSaveMaxWaitTask)
        XCTAssertNil(other.session.transcriptSaveFirstUnsavedAt)
    }

    func testRebasedDeadlineKeepsAnyFutureDeadlineAndFloorsOnlyAnExpiredOne() {
        let capturedAt = ContinuousClock.now
        let deadline = capturedAt + .seconds(10)
        func rebased(completedAfter elapsed: Duration) -> ContinuousClock.Instant {
            AgentModeViewModel.rebasedTranscriptSaveDeadline(capturedAt: capturedAt, completedAt: capturedAt + elapsed)
        }
        // Healthy writes: the deadline is 10 s after the capture, even when under 1 s remains.
        XCTAssertEqual(rebased(completedAfter: .milliseconds(5)), deadline)
        XCTAssertEqual(rebased(completedAfter: .milliseconds(9500)), deadline)
        XCTAssertEqual(rebased(completedAfter: .milliseconds(9999)), deadline)
        // A write that took 10 s or more (blocked storage): the next save waits the 1 s floor
        // after completion instead of following immediately.
        XCTAssertEqual(rebased(completedAfter: .seconds(10)), capturedAt + .seconds(11))
        XCTAssertEqual(rebased(completedAfter: .seconds(25)), capturedAt + .seconds(26))
    }

    func testWindowCloseCleanupAppliesBufferedTextToRetainedConversation() async throws {
        let harness = try await makeHarness(windowID: 4451)
        _ = installManualTimer(on: harness.viewModel)
        harness.session.appendItem(.assistant("Close partial", isStreaming: true))
        harness.viewModel.enqueueAssistantDelta(" tail", session: harness.session)
        let flushTimer = harness.session.assistantDeltaFlushTask

        await harness.viewModel.prepareForWindowClose()
        await flushTimer?.value
        XCTAssertTrue(harness.session.pendingAssistantDelta.isEmpty)
        let texts = harness.session.items.map(\.text)
        XCTAssertEqual(texts.filter { $0.contains("tail") }, ["Close partial tail"], "\(texts)")
    }

    // MARK: - Harness

    /// The armed maximum-wait timer of `session`, identified by its absolute deadline. The timer
    /// task registers its sleep only once it starts, so this yields until it has.
    private func maxWaitRequest(
        _ timer: ManualSaveTimer,
        for session: AgentTabSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ManualSaveTimer.Request {
        let firstUnsavedAt = try XCTUnwrap(session.transcriptSaveFirstUnsavedAt, file: file, line: line)
        let deadline = firstUnsavedAt + .seconds(10)
        let request = await timer.awaitPendingRequest { $0.kind == .maxWait && $0.deadline == deadline }
        return try XCTUnwrap(request, "No maximum-wait timer armed at the absolute deadline", file: file, line: line)
    }

    /// The `number`-th retry timer (1-based), once its task has started.
    private func retryRequest(
        _ timer: ManualSaveTimer,
        number: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ManualSaveTimer.Request {
        let request = await timer.awaitPendingRequest { request in
            timer.requests(.retry).dropFirst(number - 1).first?.id == request.id
        }
        return try XCTUnwrap(request, "Retry \(number) was never armed", file: file, line: line)
    }

    private struct Harness {
        let viewModel: AgentModeViewModel
        let workspace: WorkspaceModel
        let storageURL: URL
        let tabID: UUID
        let session: AgentTabSession

        struct MissingPersistedFile: Error {}

        @MainActor
        func persistedFileURL() async throws -> URL {
            guard let sessionID = session.activeAgentSessionID,
                  let persisted = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: workspace),
                  let fileURL = persisted.fileURL
            else { throw MissingPersistedFile() }
            return fileURL
        }

        @MainActor
        func persistedFileText() async throws -> String {
            try await String(contentsOf: persistedFileURL(), encoding: .utf8)
        }
    }

    private func installManualTimer(on viewModel: AgentModeViewModel) -> ManualSaveTimer {
        let timer = ManualSaveTimer()
        viewModel.test_saveTimerSleepOverride = { kind, deadline in
            try await timer.sleep(kind, until: deadline)
        }
        addTeardownBlock { @MainActor in
            timer.cancelAll()
        }
        return timer
    }

    private func makeHarness(
        windowID: Int,
        workspace existingWorkspace: WorkspaceModel? = nil,
        storageURL existingStorageURL: URL? = nil
    ) async throws -> Harness {
        let storageURL: URL
        if let existingStorageURL {
            storageURL = existingStorageURL
        } else {
            storageURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentTranscriptSaveMaxWaitTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: storageURL)
            }
        }
        let workspace = existingWorkspace ?? WorkspaceModel(
            name: "Agent Transcript Save Max Wait",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL
        )
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        viewModel.test_establishPersistenceWorkspace(workspace)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        return Harness(viewModel: viewModel, workspace: workspace, storageURL: storageURL, tabID: tabID, session: session)
    }
}

/// Manual save-timer sleep: records each request and suspends it until the test fires it.
/// Cancellation never resumes a sleep, so obsolete wakeups can be delivered on purpose; it is only
/// recorded (`isTaskCancelled`), which identifies the live request among replaced ones.
@MainActor
private final class ManualSaveTimer {
    struct Request {
        let id: Int
        let kind: AgentModeViewModel.SaveTimerKind
        let deadline: ContinuousClock.Instant
        let requestedAt: ContinuousClock.Instant
        fileprivate let cancellation: CancellationRecord

        /// Whether the sleeping timer task has been cancelled (for example, a replaced debounce).
        var isTaskCancelled: Bool {
            cancellation.isCancelled
        }
    }

    /// Set from the task's cancellation handler, which may run on any thread.
    fileprivate final class CancellationRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        func markCancelled() {
            lock.withLock { cancelled = true }
        }
    }

    private var allRequests: [Request] = []
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var nextID = 0
    /// Set by teardown: a timer task that starts afterwards must not suspend forever.
    private var isClosed = false

    func sleep(_ kind: AgentModeViewModel.SaveTimerKind, until deadline: ContinuousClock.Instant) async throws {
        if isClosed {
            throw CancellationError()
        }
        let id = nextID
        nextID += 1
        let cancellation = CancellationRecord()
        allRequests.append(Request(id: id, kind: kind, deadline: deadline, requestedAt: .now, cancellation: cancellation))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
            }
        } onCancel: {
            cancellation.markCancelled()
        }
    }

    func requests(_ kind: AgentModeViewModel.SaveTimerKind) -> [Request] {
        allRequests.filter { $0.kind == kind }
    }

    /// Yields (bounded) until a still-suspended request matches; timer tasks start asynchronously.
    func awaitPendingRequest(_ matches: (Request) -> Bool) async -> Request? {
        for _ in 0 ..< 10000 {
            if let request = allRequests.last(where: { continuations[$0.id] != nil && matches($0) }) {
                return request
            }
            await Task.yield()
        }
        return nil
    }

    func fire(_ request: Request) {
        continuations.removeValue(forKey: request.id)?.resume()
    }

    func cancelAll() {
        isClosed = true
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(throwing: CancellationError())
        }
    }
}

/// Suspends the first write that reaches it until released.
@MainActor
private final class WriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var used = false
    private(set) var isWaiting = false

    func waitOnce() async {
        guard !used else { return }
        used = true
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
