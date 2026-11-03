import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptWorkspace
import XCTest

/// Lossless-restart Phase 1b: the VM transcript-reset boundary with recovery composed. A reset
/// preserves the old composer, joins (never queues behind) an in-flight normal save, keeps
/// admission frozen until the reset receipt actually commits, and clears live/provider state only
/// after that commit. A failed commit clears nothing, keeps the old generation, and reopens
/// admission. Real temporary store, real DataService gate, real VM save path.
@MainActor
final class AgentRecoveryResetBoundaryTests: XCTestCase {
    func testResetJoinsHeldInFlightSaveRefusesInputAndClearsOnlyAfterCommit() async throws {
        let harness = try await makeHarness(windowID: 4601)
        let oldLane = try await persistAndClaimLane(harness)
        harness.session.providerSessionID = "provider-before-reset"
        harness.session.draftText = "draft before reset"

        // A normal save suspended in its write.
        let gate = ResetBoundaryWriteGate()
        harness.viewModel.test_saveSessionBeforeWriteHook = { _ in await gate.waitOnce() }
        harness.session.appendItem(.user("Saved by the held write"))
        let heldSave = Task { await harness.viewModel.flushSaveDetailed(for: harness.tabID) }
        let saveHeld = await RecoveryTestSupport.eventually { gate.isWaiting }
        XCTAssertTrue(saveHeld)

        var commitHookCalls = 0
        var admissionDuringCommit: Result<AgentRecoveryAdmitted<AgentRecoveryQueueReceipt>, AgentRecoveryAdmissionFailure>?
        harness.viewModel.test_recoveryResetBeforeCommitHook = { session in
            commitHookCalls += 1
            XCTAssertEqual(session.items.count, 2, "Nothing is cleared before the reset commit")
            admissionDuringCommit = await Self.admitQueued("typed during the commit", on: oldLane)
        }
        let reset = Task { await harness.viewModel.clearChatPreservingRecovery(tabID: harness.tabID) }
        let frozen = await RecoveryTestSupport.eventually { oldLane.isResetPreparationActive }
        XCTAssertTrue(frozen)
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        // The reset waits for the writer; the old state is intact and admission stays frozen.
        XCTAssertEqual(commitHookCalls, 0, "The reset never commits around an in-flight write")
        XCTAssertEqual(harness.session.items.map(\.text), ["Before reset", "Saved by the held write"])
        XCTAssertEqual(harness.session.providerSessionID, "provider-before-reset")
        guard case .failure(.refused(.resetPreparationInProgress)) = await Self.admitQueued("typed while joined", on: oldLane) else {
            return XCTFail("Admission is frozen while the reset joins the writer")
        }

        gate.release()
        let heldOutcome = await heldSave.value
        guard case .written = heldOutcome else {
            return XCTFail("The held save writes its old-generation snapshot, got \(heldOutcome)")
        }
        let outcome = await reset.value
        harness.viewModel.test_saveSessionBeforeWriteHook = nil
        harness.viewModel.test_recoveryResetBeforeCommitHook = nil

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(commitHookCalls, 1)
        guard case .failure(.refused(.resetPreparationInProgress))? = admissionDuringCommit else {
            return XCTFail("Admission is frozen through the commit, got \(String(describing: admissionDuringCommit))")
        }
        XCTAssertTrue(oldLane.isRetired, "The successor claim retired the frozen lane")
        let newLane = try XCTUnwrap(harness.session.recoveryLane)
        XCTAssertFalse(newLane === oldLane)
        XCTAssertEqual(newLane.binding.transcriptResetGeneration, 1, "The generation advanced exactly once")
        XCTAssertEqual(harness.session.persistenceState?.transcriptResetGeneration, 1)
        XCTAssertNil(harness.session.pendingTranscriptResetReceipt, "No reset is left for a later normal save")
        XCTAssertTrue(harness.session.items.isEmpty)
        XCTAssertNil(harness.session.providerSessionID)

        let fileText = try await harness.persistedFileText()
        XCTAssertFalse(fileText.contains("Before reset"), fileText)
        XCTAssertFalse(fileText.contains("Saved by the held write"), fileText)

        // The preserved old-generation composer is held for explicit resolution, never adopted.
        let held = await RecoveryTestSupport.eventually {
            if case .held = newLane.composerState { return true }
            return false
        }
        XCTAssertTrue(held)
        guard case let .held(snapshot) = newLane.composerState else {
            return XCTFail("Expected a held composer, got \(newLane.composerState)")
        }
        XCTAssertEqual(snapshot.content.text, "draft before reset")
        XCTAssertEqual(snapshot.transcriptResetGeneration, 0)
    }

    func testResetCommitFailureClearsNothingKeepsGenerationAndReopensAdmission() async throws {
        let harness = try await makeHarness(windowID: 4602)
        let oldLane = try await persistAndClaimLane(harness)
        harness.session.providerSessionID = "provider-before-reset"
        harness.session.draftText = "draft kept on failure"
        let stateBefore = try XCTUnwrap(harness.session.persistenceState)

        // A normal save held in its write while the reset starts.
        let gate = ResetBoundaryWriteGate()
        harness.viewModel.test_saveSessionBeforeWriteHook = { _ in await gate.waitOnce() }
        harness.session.appendItem(.user("Saved by the held write"))
        let heldSave = Task { await harness.viewModel.flushSaveDetailed(for: harness.tabID) }
        let saveHeld = await RecoveryTestSupport.eventually { gate.isWaiting }
        XCTAssertTrue(saveHeld)

        // The session file cannot be replaced when the reset commits.
        let folderPath = try await harness.persistedFileURL().deletingLastPathComponent().path
        let originalPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: folderPath)[.posixPermissions] as? NSNumber
        )
        var permissionsRestored = false
        defer {
            if !permissionsRestored {
                try? FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: folderPath)
            }
        }
        var admissionDuringCommit: Result<AgentRecoveryAdmitted<AgentRecoveryQueueReceipt>, AgentRecoveryAdmissionFailure>?
        harness.viewModel.test_recoveryResetBeforeCommitHook = { _ in
            admissionDuringCommit = await Self.admitQueued("typed during the failing commit", on: oldLane)
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folderPath)
        }
        let reset = Task { await harness.viewModel.clearChatPreservingRecovery(tabID: harness.tabID) }
        let frozen = await RecoveryTestSupport.eventually { oldLane.isResetPreparationActive }
        XCTAssertTrue(frozen)
        guard case .failure(.refused(.resetPreparationInProgress)) = await Self.admitQueued("typed while joined", on: oldLane) else {
            return XCTFail("Admission is frozen while the reset joins the writer")
        }
        gate.release()
        _ = await heldSave.value
        let outcome = await reset.value
        try FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: folderPath)
        permissionsRestored = true
        harness.viewModel.test_saveSessionBeforeWriteHook = nil
        harness.viewModel.test_recoveryResetBeforeCommitHook = nil

        guard case let .vetoed(reason) = outcome else {
            return XCTFail("A failed reset commit is a veto, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("reset commit failed"), reason)
        guard case .failure(.refused(.resetPreparationInProgress))? = admissionDuringCommit else {
            return XCTFail("Admission is frozen through the commit attempt, got \(String(describing: admissionDuringCommit))")
        }

        // Nothing was cleared; the old generation and its lane stay usable.
        XCTAssertEqual(harness.session.items.map(\.text), ["Before reset", "Saved by the held write"])
        XCTAssertEqual(harness.session.providerSessionID, "provider-before-reset")
        XCTAssertEqual(harness.session.draftText, "draft kept on failure")
        XCTAssertNil(harness.session.pendingTranscriptResetReceipt, "No reset is left for a later normal save")
        XCTAssertEqual(harness.session.persistenceState, stateBefore, "The generation did not advance")
        XCTAssertTrue(harness.session.recoveryLane === oldLane)
        XCTAssertFalse(oldLane.isRetired)
        XCTAssertFalse(oldLane.isResetPreparationActive, "The veto released the freeze")
        let fileText = try await harness.persistedFileText()
        XCTAssertTrue(fileText.contains("Saved by the held write"), fileText)

        // Admission reopened under the old generation.
        let admitted = await Self.admitQueued("typed after the veto", on: oldLane)
        guard case let .success(committed) = admitted else {
            return XCTFail("Admission reopens after a vetoed reset, got \(admitted)")
        }
        XCTAssertEqual(committed.admission.binding.transcriptResetGeneration, 0)
    }

    /// The draft held by Clear Chat is listed without a restart. Restore is offered only into an
    /// empty message box (typing keeps both); Discard asks first; resolving it removes the row.
    func testHeldDraftIsListedLiveAndRestoreIsOfferedOnlyIntoAnEmptyMessageBox() async throws {
        let harness = try await makeHarness(windowID: 4603)
        _ = try await persistAndClaimLane(harness)
        harness.session.draftText = "draft before reset"
        let outcome = await harness.viewModel.clearChatPreservingRecovery(tabID: harness.tabID)
        XCTAssertEqual(outcome, .committed)
        let newLane = try XCTUnwrap(harness.session.recoveryLane)
        let isHeld = await RecoveryTestSupport.eventually {
            if case .held = newLane.composerState { return true }
            return false
        }
        XCTAssertTrue(isHeld)

        let viewModel = harness.viewModel
        let session = harness.session
        let tabID = harness.tabID
        func heldRow() -> AgentRecoveryListRowProps? {
            viewModel.recoveryListProps(forActiveSession: session)?.rows.first { $0.id.hasPrefix("draft-held-") }
        }
        viewModel.storeDraftText(for: tabID, "typed after clearing")
        let typedRow = try XCTUnwrap(heldRow(), "The held draft is listed in this launch")
        XCTAssertEqual(typedRow.text, "draft before reset")
        XCTAssertEqual(typedRow.actions, [.discardDraft, .dismiss], "Restore never replaces current typing")
        XCTAssertNotNil(typedRow.confirmation, "Discard asks first")

        viewModel.storeDraftText(for: tabID, "")
        let emptyRow = try XCTUnwrap(heldRow())
        XCTAssertEqual(emptyRow.id, typedRow.id, "The row identifies the same displayed draft")
        XCTAssertEqual(emptyRow.actions, [.restoreDraft, .discardDraft, .dismiss])

        await viewModel.performRecoveryListAction(rowID: emptyRow.id, action: .restoreDraft)
        XCTAssertNil(heldRow(), "The resolved draft leaves the list")
        XCTAssertEqual(newLane.composerState, .ready)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "draft before reset")
        let stored = await newLane.store.read(sessionID: newLane.sessionID).record?.composer
        XCTAssertEqual(stored?.content.text, "draft before reset")
        XCTAssertEqual(stored?.transcriptResetGeneration, 1)
    }

    // MARK: - Shutdown Stage A (R4)

    /// Stage A joins an in-flight save and flushes again, so the latest projection (changed while
    /// that save was suspended) is durable; a partially hydrated session is skipped, never written.
    func testShutdownPreparationFlushesAgainAfterAnInFlightSaveAndSkipsPartialHydration() async throws {
        let harness = try await makeHarness(windowID: 4604)
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        let gate = ResetBoundaryWriteGate()
        viewModel.test_saveSessionBeforeWriteHook = { _ in await gate.waitOnce() }
        harness.session.appendItem(.user("Saved by the held write"))
        let heldSave = Task { await viewModel.flushSaveDetailed(for: harness.tabID) }
        let saveHeld = await RecoveryTestSupport.eventually { gate.isWaiting }
        XCTAssertTrue(saveHeld)
        harness.session.appendItem(.user("Appended while the save was held"))

        let requestID = UUID()
        viewModel.beginShutdownFreeze(requestID: requestID, ownsRecoveryFreeze: true)
        XCTAssertTrue(lane.isShutdownFrozen, "a window close freezes its own lanes synchronously")
        guard case .failure(.refused(.shutdownInProgress)) = await Self.admitQueued("typed while closing", on: lane) else {
            return XCTFail("admission is refused while frozen")
        }
        let preparation = Task { await viewModel.prepareSessionsForShutdown(reason: .windowClose) }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        gate.release()
        _ = await heldSave.value
        let report = await preparation.value
        viewModel.test_saveSessionBeforeWriteHook = nil
        XCTAssertEqual(report.blockers, [])
        XCTAssertFalse(harness.session.isDirty, "the second flush made the latest projection durable")
        let fileText = try await harness.persistedFileText()
        XCTAssertTrue(fileText.contains("Saved by the held write"), fileText)
        XCTAssertTrue(fileText.contains("Appended while the save was held"), fileText)

        // Partial hydration: skipped, never written, never reported as saved.
        harness.session.hasLoadedPersistedState = false
        harness.session.appendItem(.user("Not hydrated yet"))
        let skipped = await viewModel.flushTranscriptForShutdown(harness.session, final: false)
        XCTAssertEqual(skipped, .skipped)
        let unchanged = try await harness.persistedFileText()
        XCTAssertFalse(unchanged.contains("Not hydrated yet"), unchanged)
        harness.session.hasLoadedPersistedState = true

        // Cancel reopens the window's lanes.
        viewModel.endShutdownFreeze(requestID: requestID)
        XCTAssertFalse(lane.isShutdownFrozen)
        XCTAssertFalse(viewModel.isShutdownFrozen)
        guard case .success = await Self.admitQueued("typed after cancel", on: lane) else {
            return XCTFail("Cancel reopens admission")
        }
    }

    /// A non-empty secret answer vetoes Stage A before anything is written; otherwise the pending
    /// question is preserved with its partial non-secret answer and never the secret one.
    func testShutdownPreparationVetoesASecretAnswerAndNeverPersistsIt() async throws {
        let harness = try await makeHarness(windowID: 4605)
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        let request = AgentRequestUserInputRequest(
            requestID: .string("shutdown-request"),
            method: "request_user_input",
            threadID: "thread",
            turnID: "turn",
            itemID: "item",
            questions: [
                AgentRequestUserInputQuestion(
                    id: "target",
                    header: "Target",
                    question: "Which environment?",
                    isOther: false,
                    isSecret: false,
                    options: []
                ),
                AgentRequestUserInputQuestion(
                    id: "token",
                    header: "Token",
                    question: "Paste the deploy token",
                    isOther: false,
                    isSecret: true,
                    options: []
                )
            ]
        )
        harness.session.pendingUserInputRequest = request
        viewModel.updateUserInputDraft(
            tabID: harness.tabID,
            requestID: request.id,
            questionID: "target",
            draft: AgentRequestUserInputQuestionDraft(note: "staging")
        )
        viewModel.updateUserInputDraft(
            tabID: harness.tabID,
            requestID: request.id,
            questionID: "token",
            draft: AgentRequestUserInputQuestionDraft(note: "hunter2")
        )

        let first = UUID()
        viewModel.beginShutdownFreeze(requestID: first, ownsRecoveryFreeze: true)
        viewModel.updateUserInputDraft(
            tabID: harness.tabID,
            requestID: request.id,
            questionID: "token",
            draft: AgentRequestUserInputQuestionDraft(note: "changed while frozen")
        )
        XCTAssertEqual(
            viewModel.userInputDrafts(tabID: harness.tabID, requestID: request.id)["token"]?.note,
            "hunter2",
            "answers are frozen during Stage A"
        )
        let vetoed = await viewModel.prepareSessionsForShutdown(reason: .windowClose)
        XCTAssertEqual(vetoed.blockers.count, 1)
        XCTAssertTrue(vetoed.blockers.first?.contains("secret answer") == true, "\(vetoed.blockers)")
        let afterVeto = await lane.store.read(sessionID: lane.sessionID).record?.questions ?? []
        XCTAssertTrue(afterVeto.isEmpty, "nothing is written before the veto")
        viewModel.endShutdownFreeze(requestID: first)

        viewModel.updateUserInputDraft(
            tabID: harness.tabID,
            requestID: request.id,
            questionID: "token",
            draft: AgentRequestUserInputQuestionDraft()
        )
        let second = UUID()
        viewModel.beginShutdownFreeze(requestID: second, ownsRecoveryFreeze: true)
        let report = await viewModel.prepareSessionsForShutdown(reason: .windowClose)
        XCTAssertEqual(report.blockers, [])
        let questions = await lane.store.read(sessionID: lane.sessionID).record?.questions ?? []
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions.first?.interactionID, request.id)
        XCTAssertEqual(questions.first?.kind, .userInput)
        XCTAssertEqual(questions.first?.items.map(\.isSecret), [false, true])
        XCTAssertEqual(questions.first?.items.first?.answer, "staging")
        XCTAssertNil(questions.first?.items.last?.answer)
        let recordData = try Data(contentsOf: lane.store.recordFileURL(sessionID: lane.sessionID))
        XCTAssertFalse(String(decoding: recordData, as: UTF8.self).contains("hunter2"))
        viewModel.endShutdownFreeze(requestID: second)
    }

    // MARK: - Shutdown Stage B and the answer freeze (R4 review fixes)

    /// R4-04 (VM): a terminal-evidence write that failed is retried (storage only) by the final
    /// flush after the real teardown; while storage still fails, the report blocks the clean mark.
    func testFinalFlushRetriesFailedTerminalEvidenceStorageOnly() async throws {
        let failures = RecoveryStoreWriteFailureSwitch()
        let harness = try await makeHarness(windowID: 4606, fileOperations: failures.fileOperations())
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        let ownership = RecoveryTestSupport.ownership(sessionID: lane.sessionID)
        let commit = RecoveryTestSupport.terminalCommit(ownership: ownership, state: .cancelled)
        failures.shouldFailWrites = true
        await lane.recordTerminalEvidence(commit, transcriptTurnID: nil).value
        XCTAssertNotNil(lane.terminalEvidenceFailures[ownership.attemptID])

        viewModel.beginShutdownFreeze(requestID: UUID(), ownsRecoveryFreeze: true)
        await viewModel.prepareForWindowClose(reason: .appQuit)
        let blocked = await viewModel.finalizeTranscriptsAfterShutdown()
        XCTAssertTrue(
            blocked.blockers.contains { $0.contains("how its last run ended could not be saved") },
            "\(blocked.blockers)"
        )

        failures.shouldFailWrites = false
        let report = await viewModel.finalizeTranscriptsAfterShutdown()
        XCTAssertEqual(report.blockers, [])
        XCTAssertTrue(lane.terminalEvidenceFailures.isEmpty)
        let run = await lane.store.read(sessionID: lane.sessionID).record?.runAttempt(id: ownership.attemptID)
        XCTAssertEqual(run?.terminal?.commitID, commit.commitID)
        XCTAssertEqual(run?.terminal?.terminalState, .cancelled)
    }

    /// O49 (app quit, Stage B): a written Claude message whose turn the CLI had begun settles
    /// accepted through the window teardown, before any result arrives and although the controller
    /// is shut down; the attempt never recorded delivery-unknown first.
    func testAppQuitTeardownSettlesAStartedClaudeTurnAcceptedWithoutAResult() async throws {
        let harness = try await makeHarness(windowID: 4620)
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        let session = harness.session
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(recorder: recorder)
        session.selectedAgent = .claudeCode
        session.runState = .running
        session.runID = UUID()
        let ownership = session.beginRunAttempt(source: "test.quit")
        session.claudeController = controller
        let admitted = try await lane.admitQueued(AgentRecoveryAdmission(
            binding: lane.binding,
            userItemID: UUID(),
            origin: .mcp,
            target: .session,
            original: RecoveryTestSupport.content("quit me")
        )).get()
        let intentID = admitted.receipt.intent.intentID
        let handoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [AgentQueuedInputIdentity(receipt: admitted.receipt)],
            ownership: ownership,
            processRunID: session.runID
        ).get()
        // The provider write itself (this harness cannot prepare a Claude session to send).
        XCTAssertTrue(handoff.enterProviderBoundary(in: session))
        let turnID = UUID()
        viewModel.claudeCoordinator.test_recordWrittenDispatchHandoff(
            turnID: turnID,
            session: session,
            handoff: handoff,
            controller: controller
        )
        await controller.setStartedTurnID(turnID)

        await viewModel.prepareForWindowClose(reason: .appQuit)
        _ = await handoff.evidence.settled()
        XCTAssertEqual(handoff.observation, .accepted)
        XCTAssertTrue(recorder.contains("claude:shutdown"), "The controller was shut down without a result")
        let accepted = await RecoveryTestSupport.eventually {
            await lane.store.read(sessionID: lane.sessionID).record?.intent(id: intentID)?.deliveryState == .providerAccepted
        }
        XCTAssertTrue(accepted)
        let attempts = await lane.store.read(sessionID: lane.sessionID).record?.attempts(forIntent: intentID) ?? []
        XCTAssertEqual(attempts.count, 1)
        XCTAssertNil(attempts.first?.supersededOutcome, "Never recorded as delivery-unknown first")
    }

    /// R4-B07: after the real teardown, the final flush writes content that arrived during it (the
    /// terminal commit's transcript) with an empty report; a queued intent stays queued; and a
    /// later preparation of the torn-down window is a no-op that keeps its preserved question.
    func testTeardownKeepsQueuedIntentAndQuestionAndTheFinalFlushWritesLateContent() async throws {
        let harness = try await makeHarness(windowID: 4607)
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        guard case let .success(admitted) = await Self.admitQueued("queued before quit", on: lane) else {
            return XCTFail("admitted before the freeze")
        }
        let intentID = admitted.receipt.intent.intentID
        let (interaction, asked) = await pendingAskUser(harness)
        viewModel.updateAskUserDraft(
            tabID: harness.tabID,
            interactionID: interaction.id,
            questionID: "target",
            draft: AgentAskUserDraft(customResponse: "staging")
        )

        viewModel.beginShutdownFreeze(requestID: UUID(), ownsRecoveryFreeze: true)
        let prepared = await viewModel.prepareSessionsForShutdown(reason: .appQuit)
        XCTAssertEqual(prepared.blockers, [])
        let preserved = await lane.store.read(sessionID: lane.sessionID).record?.questions ?? []
        XCTAssertEqual(preserved.map(\.interactionID), [interaction.id])
        XCTAssertEqual(preserved.first?.kind, .askUser)
        XCTAssertEqual(preserved.first?.items.first?.answer, "staging", "the ask_user partial answer is preserved")

        await viewModel.prepareForWindowClose(reason: .appQuit)
        do {
            _ = try await asked.value
            XCTFail("teardown cancels the live question")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected \(error)")
        }
        // The terminal commit's transcript content lands after the teardown.
        harness.session.appendItem(.user("Arrived during teardown"))
        let report = await viewModel.finalizeTranscriptsAfterShutdown()
        XCTAssertEqual(report.blockers, [])
        XCTAssertFalse(harness.session.isDirty)
        let fileText = try await harness.persistedFileText()
        XCTAssertTrue(fileText.contains("Arrived during teardown"), fileText)

        let record = await lane.store.read(sessionID: lane.sessionID).record
        XCTAssertEqual(record?.intent(id: intentID)?.deliveryState, .queued, "teardown never withdraws a queued intent")
        XCTAssertEqual(record?.questions.map(\.interactionID), [interaction.id], "teardown never erases the snapshot")
        let again = await viewModel.prepareSessionsForShutdown(reason: .appQuit)
        XCTAssertEqual(again.blockers, [])
        let kept = await lane.store.read(sessionID: lane.sessionID).record?.questions ?? []
        XCTAssertEqual(kept.map(\.interactionID), [interaction.id], "a torn-down window is never prepared again")
    }

    /// R4-03: an answer submitted while frozen is refused at the shared boundary before any
    /// mutation (drafts, pending question, continuation kept), MCP elicitation included; after
    /// Cancel the same answer is accepted.
    func testFrozenAnswersAreRefusedBeforeAnyMutationAndAcceptedAfterCancel() async throws {
        let harness = try await makeHarness(windowID: 4608)
        _ = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        let (interaction, asked) = await pendingAskUser(harness)
        viewModel.updateAskUserDraft(
            tabID: harness.tabID,
            interactionID: interaction.id,
            questionID: "target",
            draft: AgentAskUserDraft(customResponse: "staging")
        )

        let requestID = UUID()
        viewModel.beginShutdownFreeze(requestID: requestID, ownsRecoveryFreeze: true)
        XCTAssertThrowsError(try viewModel.submitAskUserResponse(
            tabID: harness.tabID,
            interactionID: interaction.id,
            draftsByQuestionID: ["target": AgentAskUserDraft(customResponse: "production")]
        )) { error in
            XCTAssertTrue(error is AgentModeShutdownAnswerRefused, "\(error)")
        }
        viewModel.submitAskUserResponse(tabID: harness.tabID, interactionID: interaction.id)
        viewModel.skipAskUser(tabID: harness.tabID, interactionID: interaction.id)
        XCTAssertEqual(
            harness.session.pendingAskUser?.draftsByQuestionID["target"],
            AgentAskUserDraft(customResponse: "staging"),
            "the preserved draft was not replaced"
        )
        XCTAssertNotNil(harness.session.askUserContinuation, "the question is still pending")

        viewModel.endShutdownFreeze(requestID: requestID)
        try viewModel.submitAskUserResponse(
            tabID: harness.tabID,
            interactionID: interaction.id,
            draftsByQuestionID: ["target": AgentAskUserDraft(customResponse: "production")]
        )
        let response = try await asked.value
        XCTAssertEqual(response.answersByQuestionID["target"]?.customResponse, "production")
        XCTAssertNil(harness.session.pendingAskUser)

        // MCP elicitation: the same boundary.
        let elicitation = AgentMCPElicitationRequest(
            requestID: .string("shutdown-elicitation"),
            method: "mcpServer/elicitation/request",
            threadID: "thread",
            turnID: "turn",
            itemID: "item",
            prompt: "Provide a value",
            rawParamsJSON: "{}"
        )
        harness.session.pendingMCPElicitationRequest = elicitation
        let second = UUID()
        viewModel.beginShutdownFreeze(requestID: second, ownsRecoveryFreeze: true)
        viewModel.submitMCPElicitationResponse(
            tabID: harness.tabID,
            requestID: elicitation.id,
            response: AgentMCPElicitationResponse(action: .accept)
        )
        XCTAssertEqual(harness.session.pendingMCPElicitationRequest?.id, elicitation.id, "the elicitation stays pending")
        viewModel.endShutdownFreeze(requestID: second)
        harness.session.pendingMCPElicitationRequest = nil
    }

    /// R4-01: Cancel removes the snapshots this window introduced; a later Stage A joins that
    /// removal before writing its own, so the removal never erases them. (A question the live lane
    /// never created; a lane-created one is durable already, see
    /// `testLaneCreatedQuestionStaysStoredThroughCancelAndIsRemovedOnlyByItsResolution`.)
    func testCancelClearsThisLaunchQuestionSnapshotsBeforeALaterStageAWritesAgain() async throws {
        let harness = try await makeHarness(windowID: 4609)
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        let interaction = installUntrackedUserInput(harness, "cancel")

        let first = UUID()
        viewModel.beginShutdownFreeze(requestID: first, ownsRecoveryFreeze: true)
        _ = await viewModel.prepareSessionsForShutdown(reason: .windowClose)
        let written = await lane.store.read(sessionID: lane.sessionID).record?.questions ?? []
        XCTAssertEqual(written.map(\.interactionID), [interaction.id])
        XCTAssertEqual(
            viewModel.shutdownQuestionSnapshots[harness.tabID],
            AgentModeShutdownQuestionSnapshots(lane: ObjectIdentifier(lane), live: [interaction.id], introduced: [interaction.id])
        )

        viewModel.endShutdownFreeze(requestID: first)
        XCTAssertTrue(viewModel.shutdownQuestionSnapshots.isEmpty)
        let second = UUID()
        viewModel.beginShutdownFreeze(requestID: second, ownsRecoveryFreeze: true)
        _ = await viewModel.prepareSessionsForShutdown(reason: .windowClose)
        let rewritten = await lane.store.read(sessionID: lane.sessionID).record?.questions ?? []
        XCTAssertEqual(rewritten.map(\.interactionID), [interaction.id], "the earlier clear landed first")

        viewModel.endShutdownFreeze(requestID: second)
        await viewModel.shutdownQuestionSnapshotWriteTask?.value
        let cleared = await lane.store.read(sessionID: lane.sessionID).record?.questions ?? []
        XCTAssertTrue(cleared.isEmpty, "a reopened question is no longer preserved")
        harness.session.pendingUserInputRequest = nil
    }

    /// Plan §E: a question created through the live lane is durable before it is shown, so Stage A
    /// finds it already stored (never "introduced") and Cancel keeps it; only its own resolution
    /// removes it, after the reply.
    func testLaneCreatedQuestionStaysStoredThroughCancelAndIsRemovedOnlyByItsResolution() async throws {
        let harness = try await makeHarness(windowID: 4617)
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        func storedIDs() async -> [UUID] {
            await (lane.store.read(sessionID: lane.sessionID).record?.questions ?? []).map(\.interactionID)
        }
        let (interaction, asked) = await pendingAskUser(harness)
        var ids = await storedIDs()
        XCTAssertEqual(ids, [interaction.id], "committed before the question was shown")

        let requestID = UUID()
        viewModel.beginShutdownFreeze(requestID: requestID, ownsRecoveryFreeze: true)
        let prepared = await viewModel.prepareSessionsForShutdown(reason: .windowClose)
        XCTAssertEqual(prepared.blockers, [])
        XCTAssertEqual(
            viewModel.shutdownQuestionSnapshots[harness.tabID],
            AgentModeShutdownQuestionSnapshots(lane: ObjectIdentifier(lane), live: [interaction.id], introduced: []),
            "already stored by the live lane, so Stage A introduces nothing"
        )
        viewModel.endShutdownFreeze(requestID: requestID)
        await viewModel.shutdownQuestionSnapshotWriteTask?.value
        ids = await storedIDs()
        XCTAssertEqual(ids, [interaction.id], "Cancel keeps a live question durable")

        try viewModel.submitAskUserResponse(
            tabID: harness.tabID,
            interactionID: interaction.id,
            draftsByQuestionID: ["target": AgentAskUserDraft(customResponse: "done")]
        )
        let response = try await asked.value
        XCTAssertEqual(response.answersByQuestionID["target"]?.customResponse, "done")
        let removed = await RecoveryTestSupport.eventually { await storedIDs().isEmpty }
        XCTAssertTrue(removed, "the resolution removes exactly its snapshot")
    }

    /// R4-01 (same-launch close/reopen): a window closed earlier in this launch preserved a question
    /// (its snapshot carries this launch's instance ID; this window never tracked it). This window's
    /// Stage A without that question live, Cancel, and an untracked live resolution all keep it. A
    /// question this window introduces is removed by Cancel; one already preserved by the closed
    /// owner that is live here again (adopted, rewritten in place) is kept.
    func testReopenedWindowKeepsASameLaunchClosedOwnersQuestionsThroughStageAAndCancel() async throws {
        let harness = try await makeHarness(windowID: 4611)
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        let store = lane.store
        func storedIDs() async -> [UUID] {
            await (store.read(sessionID: lane.sessionID).record?.questions ?? []).map(\.interactionID)
        }
        let adoptedRequest = Self.userInputRequest("adopted", questionIDs: ["target"])
        let closed = Self.questionSnapshot(interactionID: UUID(), appInstanceID: store.appInstanceID)
        let closedAdopted = Self.questionSnapshot(interactionID: adoptedRequest.id, appInstanceID: store.appInstanceID)
        guard case .success = await lane.updateQuestionSnapshots(.init(upserting: [closed, closedAdopted])) else {
            return XCTFail("the closed window's preserved questions are stored")
        }

        // Quit with no live question, then Cancel: nothing preserved is erased.
        let first = UUID()
        viewModel.beginShutdownFreeze(requestID: first, ownsRecoveryFreeze: true)
        let emptyPreparation = await viewModel.prepareSessionsForShutdown(reason: .appQuit)
        XCTAssertEqual(emptyPreparation.blockers, [])
        XCTAssertNil(viewModel.shutdownQuestionSnapshots[harness.tabID])
        var ids = await storedIDs()
        XCTAssertEqual(ids, [closed.interactionID, adoptedRequest.id], "an empty capture erases nothing")
        viewModel.endShutdownFreeze(requestID: first)
        await viewModel.shutdownQuestionSnapshotWriteTask?.value
        ids = await storedIDs()
        XCTAssertEqual(ids, [closed.interactionID, adoptedRequest.id], "Cancel erases nothing this window did not add")

        // A live question of this window (introduced; one the live lane never created) and the
        // adopted one live again.
        harness.session.pendingUserInputRequest = adoptedRequest
        let interaction = installUntrackedUserInput(harness, "introduced", queued: true)
        let second = UUID()
        viewModel.beginShutdownFreeze(requestID: second, ownsRecoveryFreeze: true)
        let livePreparation = await viewModel.prepareSessionsForShutdown(reason: .appQuit)
        XCTAssertEqual(livePreparation.blockers, [])
        let written = await store.read(sessionID: lane.sessionID).record?.questions ?? []
        XCTAssertEqual(written.map(\.interactionID), [closed.interactionID, adoptedRequest.id, interaction.id])
        XCTAssertEqual(written[1].kind, .userInput, "the adopted question is rewritten in place from the live request")
        XCTAssertEqual(
            viewModel.shutdownQuestionSnapshots[harness.tabID],
            AgentModeShutdownQuestionSnapshots(
                lane: ObjectIdentifier(lane),
                live: [adoptedRequest.id, interaction.id],
                introduced: [interaction.id]
            )
        )
        viewModel.endShutdownFreeze(requestID: second)
        await viewModel.shutdownQuestionSnapshotWriteTask?.value
        ids = await storedIDs()
        XCTAssertEqual(ids, [closed.interactionID, adoptedRequest.id], "Cancel removes only what this window introduced")

        // An untracked live resolution (after Cancel) writes nothing.
        harness.session.pendingUserInputRequest = nil
        harness.session.queuedUserInputRequests = []
        viewModel.recordMCPInteractionResolution(for: harness.session, interactionID: interaction.id)
        await viewModel.shutdownQuestionSnapshotWriteTask?.value
        ids = await storedIDs()
        XCTAssertEqual(ids, [closed.interactionID, adoptedRequest.id])
    }

    /// R4-01: a live resolution during a frozen Stage A's lifetime removes exactly that
    /// interaction's snapshot; the other live question and the closed owner's question stay.
    func testLiveResolutionRemovesExactlyItsSnapshot() async throws {
        let harness = try await makeHarness(windowID: 4612)
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        let store = lane.store
        let closed = Self.questionSnapshot(interactionID: UUID(), appInstanceID: store.appInstanceID)
        guard case .success = await lane.updateQuestionSnapshots(.init(upserting: [closed])) else {
            return XCTFail("the closed window's preserved question is stored")
        }
        let (interaction, asked) = await pendingAskUser(harness)
        let request = Self.userInputRequest("still-live", questionIDs: ["region"])
        harness.session.pendingUserInputRequest = request

        let requestID = UUID()
        viewModel.beginShutdownFreeze(requestID: requestID, ownsRecoveryFreeze: true)
        _ = await viewModel.prepareSessionsForShutdown(reason: .windowClose)
        // The resolution funnel (a timeout reaches it while answers are frozen).
        viewModel.recordMCPInteractionResolution(for: harness.session, interactionID: interaction.id)
        await viewModel.shutdownQuestionSnapshotWriteTask?.value
        let ids = await (store.read(sessionID: lane.sessionID).record?.questions ?? []).map(\.interactionID)
        XCTAssertEqual(ids, [closed.interactionID, request.id])
        XCTAssertEqual(viewModel.shutdownQuestionSnapshots[harness.tabID]?.live, [request.id])

        viewModel.endShutdownFreeze(requestID: requestID)
        await viewModel.shutdownQuestionSnapshotWriteTask?.value
        let afterCancel = await (store.read(sessionID: lane.sessionID).record?.questions ?? []).map(\.interactionID)
        XCTAssertEqual(afterCancel, [closed.interactionID])
        harness.session.pendingUserInputRequest = nil
        try viewModel.submitAskUserResponse(
            tabID: harness.tabID,
            interactionID: interaction.id,
            draftsByQuestionID: ["target": AgentAskUserDraft(customResponse: "done")]
        )
        _ = try await asked.value
    }

    /// R4-01-R1 (Cancel → new quit): a cancelled request's preparation, held after its question
    /// upsert (during run evidence), finishes after a new request started. Its late cleanup lands
    /// before the successor captures, so the successor's snapshot survives and is owned by it.
    func testCancelledPreparationsLateCleanupNeverErasesTheSuccessorsSnapshot() async throws {
        try await assertSupersededPreparationNeverErasesTheSuccessorsSnapshot(.cancelThenNewQuit, windowID: 4613)
    }

    /// R4-01-R1 (window close → app quit): the same, when an app quit supersedes this window's close.
    func testSupersededWindowClosePreparationsLateCleanupNeverErasesTheSuccessorsSnapshot() async throws {
        try await assertSupersededPreparationNeverErasesTheSuccessorsSnapshot(.windowCloseThenAppQuit, windowID: 4614)
    }

    /// R4-01-R2: a question-snapshot removal whose write failed keeps its IDs and lane, is retried
    /// before the next Stage A writes (a failure there is a blocker, with nothing upserted over it),
    /// and is dropped only after a successful retry.
    func testFailedQuestionSnapshotRemovalIsKeptAndRetriedBeforeTheNextStageA() async throws {
        let failures = RecoveryStoreWriteFailureSwitch()
        let harness = try await makeHarness(windowID: 4615, fileOperations: failures.fileOperations())
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        let laneKey = ObjectIdentifier(lane)
        let interaction = installUntrackedUserInput(harness, "failed-removal")
        func storedIDs() async -> [UUID] {
            await (lane.store.read(sessionID: lane.sessionID).record?.questions ?? []).map(\.interactionID)
        }

        let first = UUID()
        viewModel.beginShutdownFreeze(requestID: first, ownsRecoveryFreeze: true)
        let prepared = await viewModel.prepareSessionsForShutdown(reason: .windowClose)
        XCTAssertEqual(prepared.blockers, [])
        failures.shouldFailWrites = true
        viewModel.endShutdownFreeze(requestID: first)
        await viewModel.shutdownQuestionSnapshotWriteTask?.value
        XCTAssertEqual(viewModel.shutdownFailedQuestionSnapshotRemovals[laneKey]?.interactionIDs, [interaction.id])
        XCTAssertEqual(viewModel.shutdownFailedQuestionSnapshotRemovals[laneKey]?.tabID, harness.tabID)
        var ids = await storedIDs()
        XCTAssertEqual(ids, [interaction.id], "the failed removal left the snapshot stored")

        let second = UUID()
        viewModel.beginShutdownFreeze(requestID: second, ownsRecoveryFreeze: true)
        let blocked = await viewModel.prepareSessionsForShutdown(reason: .windowClose)
        XCTAssertTrue(
            blocked.blockers.contains { $0.contains("could not be removed from its saved recovery state") },
            "\(blocked.blockers)"
        )
        XCTAssertNil(viewModel.shutdownQuestionSnapshots[harness.tabID], "nothing was upserted over the failed removal")
        XCTAssertEqual(viewModel.shutdownFailedQuestionSnapshotRemovals[laneKey]?.interactionIDs, [interaction.id], "kept until a receipt")
        viewModel.endShutdownFreeze(requestID: second)

        failures.shouldFailWrites = false
        let third = UUID()
        viewModel.beginShutdownFreeze(requestID: third, ownsRecoveryFreeze: true)
        let ready = await viewModel.prepareSessionsForShutdown(reason: .windowClose)
        XCTAssertEqual(ready.blockers, [])
        XCTAssertNil(viewModel.shutdownFailedQuestionSnapshotRemovals[laneKey], "dropped after the successful retry")
        XCTAssertEqual(
            viewModel.shutdownQuestionSnapshots[harness.tabID],
            AgentModeShutdownQuestionSnapshots(lane: laneKey, live: [interaction.id], introduced: [interaction.id]),
            "removed by the retry, then preserved (and owned) again by this Stage A"
        )
        ids = await storedIDs()
        XCTAssertEqual(ids, [interaction.id])

        viewModel.endShutdownFreeze(requestID: third)
        await viewModel.shutdownQuestionSnapshotWriteTask?.value
        ids = await storedIDs()
        XCTAssertTrue(ids.isEmpty)
        harness.session.pendingUserInputRequest = nil
    }

    /// R4 B-N4: the composer and answer cards observe narrow stores, not the view model; the freeze
    /// reaches them through those stores' snapshots on begin and on end.
    func testShutdownFreezeIsPublishedThroughTheObservedComposerAndAnswerStores() async throws {
        let harness = try await makeHarness(windowID: 4616)
        let viewModel = harness.viewModel
        viewModel.syncComposerUIState()
        viewModel.syncRunInteractionUIState()
        XCTAssertFalse(viewModel.ui.composer.props.isShutdownFrozen)
        XCTAssertFalse(viewModel.ui.runInteraction.snapshot.isShutdownFrozen)

        let requestID = UUID()
        viewModel.beginShutdownFreeze(requestID: requestID, ownsRecoveryFreeze: true)
        XCTAssertTrue(viewModel.ui.composer.props.isShutdownFrozen)
        XCTAssertTrue(viewModel.ui.runInteraction.snapshot.isShutdownFrozen)

        viewModel.endShutdownFreeze(requestID: requestID)
        XCTAssertFalse(viewModel.ui.composer.props.isShutdownFrozen)
        XCTAssertFalse(viewModel.ui.runInteraction.snapshot.isShutdownFrozen)
    }

    private enum ShutdownSupersession {
        case cancelThenNewQuit
        case windowCloseThenAppQuit
    }

    private func assertSupersededPreparationNeverErasesTheSuccessorsSnapshot(
        _ pattern: ShutdownSupersession,
        windowID: Int
    ) async throws {
        let hold = RecoveryStoreRunShutdownWriteHold()
        defer { hold.release() }
        let harness = try await makeHarness(windowID: windowID, fileOperations: hold.fileOperations())
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        // A question the live lane never created: only Stage A writes it.
        let interaction = installUntrackedUserInput(harness, "supersession")
        viewModel.updateUserInputDraft(
            tabID: harness.tabID,
            requestID: interaction.id,
            questionID: "target",
            draft: AgentRequestUserInputQuestionDraft(note: "staging")
        )
        // An active run: its shutdown reason is the lane write after the question upsert.
        _ = harness.session.beginRunAttempt(source: "shutdownSupersessionTest")

        let first = UUID()
        viewModel.beginShutdownFreeze(requestID: first, ownsRecoveryFreeze: true)
        let predecessor = Task { @MainActor in
            await viewModel.prepareSessionsForShutdown(reason: pattern == .cancelThenNewQuit ? .appQuit : .windowClose)
        }
        let held = await RecoveryTestSupport.eventually { hold.isHolding }
        XCTAssertTrue(held, "the predecessor is held after its question upsert, in its run evidence write")

        let second = UUID()
        switch pattern {
        case .cancelThenNewQuit:
            viewModel.endShutdownFreeze(requestID: first)
            viewModel.beginShutdownFreeze(requestID: second, ownsRecoveryFreeze: false)
        case .windowCloseThenAppQuit:
            viewModel.beginShutdownFreeze(requestID: second, ownsRecoveryFreeze: false)
            viewModel.endShutdownFreeze(requestID: first) // superseded: ignored
        }
        let successor = Task { @MainActor in
            await viewModel.prepareSessionsForShutdown(reason: .appQuit)
        }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        hold.release()
        _ = await predecessor.value
        let report = await successor.value
        XCTAssertEqual(report.blockers, [])
        await viewModel.shutdownQuestionSnapshotWriteTask?.value

        let stored = await lane.store.read(sessionID: lane.sessionID).record?.questions ?? []
        XCTAssertEqual(stored.map(\.interactionID), [interaction.id], "the predecessor's late cleanup never erases the successor's snapshot")
        XCTAssertEqual(stored.first?.items.first?.answer, "staging")
        XCTAssertEqual(
            viewModel.shutdownQuestionSnapshots[harness.tabID],
            AgentModeShutdownQuestionSnapshots(lane: ObjectIdentifier(lane), live: [interaction.id], introduced: [interaction.id]),
            "the successor owns the snapshot it wrote"
        )
        let raw = try String(decoding: Data(contentsOf: lane.store.recordFileURL(sessionID: lane.sessionID)), as: UTF8.self)
        XCTAssertTrue(raw.lowercased().contains(interaction.id.uuidString.lowercased()), "the raw record keeps the question")
        XCTAssertTrue(raw.contains("staging"))

        viewModel.endShutdownFreeze(requestID: second)
        await viewModel.shutdownQuestionSnapshotWriteTask?.value
        harness.session.pendingUserInputRequest = nil
    }

    /// R4-06: the native user-input card seeds each request from its session-owned partial answers,
    /// so switching requests (a reused card) never reports empty defaults over a retained answer.
    func testNativeUserInputCardReseedsRetainedPartialAnswersPerRequest() async throws {
        let harness = try await makeHarness(windowID: 4610)
        let viewModel = harness.viewModel
        let first = Self.userInputRequest("first", questionIDs: ["target", "region"])
        let second = Self.userInputRequest("second", questionIDs: ["reason"])
        harness.session.pendingUserInputRequest = first
        viewModel.updateUserInputDraft(
            tabID: harness.tabID,
            requestID: first.id,
            questionID: "target",
            draft: AgentRequestUserInputQuestionDraft(note: "staging")
        )
        viewModel.updateUserInputDraft(
            tabID: harness.tabID,
            requestID: first.id,
            questionID: "region",
            draft: AgentRequestUserInputQuestionDraft(note: "eu")
        )
        let retained = viewModel.userInputDrafts(tabID: harness.tabID, requestID: first.id)
        XCTAssertEqual(retained["target"]?.note, "staging", "a later draft keeps the other answers")
        XCTAssertEqual(retained["region"]?.note, "eu")

        let seededFirst = AgentRequestUserInputCard.seededDrafts(for: first, initialDrafts: retained)
        XCTAssertEqual(seededFirst["target"]?.note, "staging")
        XCTAssertEqual(seededFirst["region"]?.note, "eu")
        let seededSecond = AgentRequestUserInputCard.seededDrafts(
            for: second,
            initialDrafts: viewModel.userInputDrafts(tabID: harness.tabID, requestID: second.id)
        )
        XCTAssertEqual(Set(seededSecond.keys), ["reason"], "another request never shows the first one's answers")
        XCTAssertEqual(seededSecond["reason"], AgentRequestUserInputQuestionDraft())
        let seededBack = AgentRequestUserInputCard.seededDrafts(
            for: first,
            initialDrafts: viewModel.userInputDrafts(tabID: harness.tabID, requestID: first.id)
        )
        XCTAssertEqual(seededBack, seededFirst, "switching back reseeds the retained answers")
    }

    // MARK: - Live question persistence (plan §E)

    /// Answer ordering: the answer's snapshot is written before the reply, edits are refused
    /// meanwhile, and the snapshot is removed by its ID after the reply.
    func testAnswerIsSavedBeforeItsReplyAndRemovedAfterIt() async throws {
        let hold = RecoveryStoreMarkerWriteHold(marker: "held-answer")
        defer { hold.release() }
        let harness = try await makeHarness(windowID: 4618, fileOperations: hold.fileOperations())
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        let (interaction, asked) = await pendingAskUser(harness)

        try viewModel.submitAskUserResponse(
            tabID: harness.tabID,
            interactionID: interaction.id,
            draftsByQuestionID: ["target": AgentAskUserDraft(customResponse: "held-answer")]
        )
        let held = await RecoveryTestSupport.eventually { hold.isHolding }
        XCTAssertTrue(held, "the answer's snapshot write is in flight")
        XCTAssertNotNil(harness.session.askUserContinuation, "no reply before the answer is saved")
        XCTAssertTrue(harness.session.recoveryQuestionResolutionReservations.contains(interaction.id))
        viewModel.updateAskUserDraft(
            tabID: harness.tabID,
            interactionID: interaction.id,
            questionID: "target",
            draft: AgentAskUserDraft(customResponse: "edited meanwhile")
        )
        XCTAssertEqual(
            harness.session.pendingAskUser?.draftsByQuestionID["target"],
            AgentAskUserDraft(customResponse: "held-answer"),
            "the submitted answer stays the latest while it is saved"
        )

        hold.release()
        let response = try await asked.value
        XCTAssertEqual(response.answersByQuestionID["target"]?.customResponse, "held-answer")
        XCTAssertTrue(harness.session.recoveryQuestionResolutionReservations.isEmpty)
        let removed = await RecoveryTestSupport.eventually {
            await (lane.store.read(sessionID: lane.sessionID).record?.questions ?? []).isEmpty
        }
        XCTAssertTrue(removed, "removed by its ID after the reply")
    }

    /// Review A F01. This replaces R4's `testStorageCannotHoldAnAnswersReplyPastTheBound`, which
    /// asserted the wrong contract (the reply was sent while its snapshot write was still stuck).
    /// An answer is replied only after its snapshot is preserved: storage that does not answer
    /// within the bound sends nothing; the answer, its request and its live continuation stay, the
    /// reservation is released, and a retryable save error is listed. Once storage recovers,
    /// submitting again replies exactly once and the snapshot is removed after the reply.
    func testDelayedPreservationSendsNoReplyAndKeepsTheAnswerForRetry() async throws {
        let hold = RecoveryStoreMarkerWriteHold(marker: "stuck-answer")
        defer { hold.release() }
        let harness = try await makeHarness(windowID: 4619, fileOperations: hold.fileOperations())
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        let (interaction, asked) = await pendingAskUser(harness)
        let answer = ["target": AgentAskUserDraft(customResponse: "stuck-answer")]

        try viewModel.submitAskUserResponse(tabID: harness.tabID, interactionID: interaction.id, draftsByQuestionID: answer)
        let held = await RecoveryTestSupport.eventually { hold.isHolding }
        XCTAssertTrue(held, "the answer's snapshot write is in flight")
        let session = harness.session
        let gaveUp = await RecoveryTestSupport.eventually(timeoutSeconds: 10) {
            lane.questionPersistence.unsentAnswerIDs.contains(interaction.id)
                && !session.recoveryQuestionResolutionReservations.contains(interaction.id)
        }
        XCTAssertTrue(gaveUp, "the bounded wait ended without preserving the answer")
        XCTAssertTrue(hold.isHolding, "storage still has not answered")
        XCTAssertNotNil(harness.session.askUserContinuation, "no reply was sent after the bounded wait")
        XCTAssertEqual(harness.session.pendingAskUser?.interaction.id, interaction.id, "the request stays pending")
        XCTAssertEqual(harness.session.pendingAskUser?.draftsByQuestionID["target"], answer["target"], "the answer is kept")
        XCTAssertFalse(harness.session.recoveryQuestionResolutionReservations.contains(interaction.id), "the reservation is released")
        let saveFailureID = AgentRecoveryCatalogProjection.questionSaveFailureItemID(sessionID: lane.sessionID)
        let listed = await RecoveryTestSupport.eventually {
            guard case .questionSaveFailed(_, unsentAnswer: true)? = viewModel.recoveryCoordinator?.catalog.item(id: saveFailureID)?.payload else { return false }
            return true
        }
        XCTAssertTrue(listed, "A retryable save error is listed for the unsent answer")

        hold.release()
        let preserved = await RecoveryTestSupport.eventually { !lane.questionPersistence.needsPreservation(interaction.id) }
        XCTAssertTrue(preserved)
        try viewModel.submitAskUserResponse(tabID: harness.tabID, interactionID: interaction.id, draftsByQuestionID: answer)
        let response = try await asked.value
        XCTAssertEqual(response.answersByQuestionID["target"]?.customResponse, "stuck-answer")
        XCTAssertFalse(response.timedOut)
        XCTAssertTrue(lane.questionPersistence.unsentAnswerIDs.isEmpty)
        let removed = await RecoveryTestSupport.eventually {
            await (lane.store.read(sessionID: lane.sessionID).record?.questions ?? []).isEmpty
        }
        XCTAssertTrue(removed, "removed by its ID after the reply")
        let cleared = await RecoveryTestSupport.eventually { viewModel.recoveryCoordinator?.catalog.item(id: saveFailureID) == nil }
        XCTAssertTrue(cleared, "the save error clears once the answer is sent")
    }

    /// Review A F01: a failed preservation sends no reply. The answer and its continuation stay, the
    /// reservation is released, the save error is listed, and the timeout that yielded to the answer
    /// is armed again; the question then ends by its actual timeout (separate cleanup), never by
    /// the unsaved answer.
    func testFailedPreservationSendsNoReplyKeepsTheAnswerAndRearmsTheTimeout() async throws {
        let failures = RecoveryStoreWriteFailureSwitch()
        let harness = try await makeHarness(windowID: 4631, fileOperations: failures.fileOperations())
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        let interaction = AgentAskUserInteraction(
            timeoutSeconds: 2,
            questions: [AgentAskUserQuestion(id: "target", question: "Which environment?")]
        )
        let tabID = harness.tabID
        let asked = Task { @MainActor in
            try await viewModel.askUser(tabID: tabID, interaction: interaction)
        }
        let session = harness.session
        let pending = await RecoveryTestSupport.eventually { session.askUserContinuation != nil }
        XCTAssertTrue(pending)

        failures.shouldFailWrites = true
        try viewModel.submitAskUserResponse(
            tabID: tabID,
            interactionID: interaction.id,
            draftsByQuestionID: ["target": AgentAskUserDraft(customResponse: "unsaved-answer")]
        )
        let notSent = await RecoveryTestSupport.eventually {
            lane.questionPersistence.unsentAnswerIDs.contains(interaction.id)
                && !session.recoveryQuestionResolutionReservations.contains(interaction.id)
        }
        XCTAssertTrue(notSent)
        XCTAssertNotNil(session.askUserContinuation, "no reply after a failed preservation")
        XCTAssertEqual(session.pendingAskUser?.draftsByQuestionID["target"], AgentAskUserDraft(customResponse: "unsaved-answer"))
        XCTAssertFalse(session.recoveryQuestionResolutionReservations.contains(interaction.id))
        XCTAssertNotNil(lane.questionPersistence.lastWriteFailure)
        let saveFailureID = AgentRecoveryCatalogProjection.questionSaveFailureItemID(sessionID: lane.sessionID)
        let listed = await RecoveryTestSupport.eventually {
            guard case .questionSaveFailed(_?, unsentAnswer: true)? = viewModel.recoveryCoordinator?.catalog.item(id: saveFailureID)?.payload else { return false }
            return true
        }
        XCTAssertTrue(listed, "The save error is listed with the unsent answer")

        let response = try await asked.value
        XCTAssertTrue(response.timedOut, "the re-armed timeout ends the question; the unsaved answer is never sent")
        XCTAssertTrue(lane.questionPersistence.unsentAnswerIDs.isEmpty, "the timeout ended the interaction")
        failures.shouldFailWrites = false
    }

    /// A timeout replies without waiting for storage; a failed removal keeps the snapshot, is owed
    /// (never re-replied), and is retried by the next Stage A before it writes.
    func testTimeoutRemovesItsSnapshotAndAFailedRemovalIsRetriedWithoutAnotherReply() async throws {
        let failures = RecoveryStoreWriteFailureSwitch()
        let harness = try await makeHarness(windowID: 4620, fileOperations: failures.fileOperations())
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        func storedIDs() async -> [UUID] {
            await (lane.store.read(sessionID: lane.sessionID).record?.questions ?? []).map(\.interactionID)
        }
        let interaction = AgentAskUserInteraction(
            timeoutSeconds: 0.3,
            questions: [AgentAskUserQuestion(id: "target", question: "Which environment?")]
        )
        let tabID = harness.tabID
        let asked = Task { @MainActor in
            try await viewModel.askUser(tabID: tabID, interaction: interaction)
        }
        let session = harness.session
        let pending = await RecoveryTestSupport.eventually { session.askUserContinuation != nil }
        XCTAssertTrue(pending)
        var ids = await storedIDs()
        XCTAssertEqual(ids, [interaction.id])

        failures.shouldFailWrites = true
        let response = try await asked.value
        XCTAssertTrue(response.timedOut)
        let owed = await RecoveryTestSupport.eventually {
            lane.questionPersistence.owedRemovals == [interaction.id] && lane.questionPersistence.lastWriteFailure != nil
        }
        XCTAssertTrue(owed, "the failed removal is owed")
        ids = await storedIDs()
        XCTAssertEqual(ids, [interaction.id], "the failed removal kept the snapshot")

        failures.shouldFailWrites = false
        let requestID = UUID()
        viewModel.beginShutdownFreeze(requestID: requestID, ownsRecoveryFreeze: true)
        let report = await viewModel.prepareSessionsForShutdown(reason: .windowClose)
        XCTAssertEqual(report.blockers, [])
        ids = await storedIDs()
        XCTAssertTrue(ids.isEmpty, "retried by Stage A's drain")
        XCTAssertTrue(lane.questionPersistence.owedRemovals.isEmpty)
        viewModel.endShutdownFreeze(requestID: requestID)
    }

    /// A failed creation write refuses the question (never shown as durably available); the next
    /// one is accepted once storage works.
    func testAskUserIsRefusedWhenItsCreationCannotBeSaved() async throws {
        let failures = RecoveryStoreWriteFailureSwitch()
        let harness = try await makeHarness(windowID: 4621, fileOperations: failures.fileOperations())
        let lane = try await persistAndClaimLane(harness)
        let viewModel = harness.viewModel
        failures.shouldFailWrites = true
        let refused = AgentAskUserInteraction(questions: [AgentAskUserQuestion(id: "target", question: "Which environment?")])
        do {
            _ = try await viewModel.askUser(tabID: harness.tabID, interaction: refused)
            XCTFail("an unsaved question is refused")
        } catch {
            XCTAssertTrue(String(describing: error).contains("could not be saved"), "\(error)")
        }
        XCTAssertNil(harness.session.pendingAskUser)
        XCTAssertNil(harness.session.recoveryQuestionCreationReservation)
        XCTAssertFalse(lane.questionPersistence.hasPendingWork, "the refused question is not retried")

        failures.shouldFailWrites = false
        let (interaction, asked) = await pendingAskUser(harness)
        let stored = await (lane.store.read(sessionID: lane.sessionID).record?.questions ?? []).map(\.interactionID)
        XCTAssertEqual(stored, [interaction.id])
        viewModel.skipAskUser(tabID: harness.tabID, interactionID: interaction.id)
        _ = try await asked.value
    }

    // MARK: - Harness

    /// Starts a real pending ask_user question (its continuation is the run's wait).
    private func pendingAskUser(_ harness: Harness) async -> (AgentAskUserInteraction, Task<AgentAskUserResponse, Error>) {
        let interaction = AgentAskUserInteraction(
            id: UUID(),
            questions: [AgentAskUserQuestion(id: "target", question: "Which environment?")]
        )
        let viewModel = harness.viewModel
        let tabID = harness.tabID
        let asked = Task { @MainActor in
            try await viewModel.askUser(tabID: tabID, interaction: interaction)
        }
        let session = harness.session
        let pending = await RecoveryTestSupport.eventually { session.askUserContinuation != nil }
        XCTAssertTrue(pending, "the ask_user question is pending")
        return (interaction, asked)
    }

    /// Installs a native user-input request directly, as a producer without a live lane would: the
    /// live question lane never created it, so only shutdown preparation writes it (R4 tracking).
    private func installUntrackedUserInput(
        _ harness: Harness,
        _ name: String,
        queued: Bool = false
    ) -> AgentRequestUserInputRequest {
        let request = Self.userInputRequest(name, questionIDs: ["target"])
        if queued {
            harness.session.queuedUserInputRequests.append(request)
        } else {
            harness.session.pendingUserInputRequest = request
        }
        return request
    }

    /// A question another owner preserved (as a closed window's Stage A would have written it).
    private static func questionSnapshot(interactionID: UUID, appInstanceID: UUID) -> AgentRecoveryQuestionSnapshot {
        AgentRecoveryQuestionSnapshot(
            interactionID: interactionID,
            kind: .askUser,
            runAttemptID: nil,
            transcriptResetGeneration: 0,
            appInstanceID: appInstanceID,
            askedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000),
            title: "Preserved by a closed window",
            message: nil,
            items: [
                AgentRecoveryQuestionItem(
                    questionID: "target",
                    header: "Target",
                    text: "Which environment?",
                    options: [],
                    isSecret: false,
                    answer: nil
                )
            ]
        )
    }

    private static func userInputRequest(_ name: String, questionIDs: [String]) -> AgentRequestUserInputRequest {
        AgentRequestUserInputRequest(
            requestID: .string("request-\(name)"),
            method: "request_user_input",
            threadID: "thread",
            turnID: "turn-\(name)",
            itemID: "item-\(name)",
            questions: questionIDs.map {
                AgentRequestUserInputQuestion(
                    id: $0,
                    header: $0,
                    question: "Value for \($0)?",
                    isOther: false,
                    isSecret: false,
                    options: []
                )
            }
        )
    }

    // MARK: - F5: unbounded composer-preparation join under the single deadline

    /// Stage A joins a session's pending composer preparation without a bound of its own. One that
    /// never finishes presents the window close's Stage A prompt (Retry / Cancel) at the request's
    /// single 8-second deadline, carrying that request's identity; the prompt then waits for the
    /// user, and the preparation's late completion never completes the expired request.
    func testPermanentlySuspendedComposerPreparationPresentsTheStageAPromptAtTheSingleDeadline() async throws {
        let windowID = 4632
        let harness = try await makeHarness(windowID: windowID)
        let viewModel = harness.viewModel
        let session = harness.session
        let recovery = try XCTUnwrap(viewModel.recoveryCoordinator)
        let preparationGate = ResetBoundaryWriteGate()
        defer { preparationGate.release() }
        recovery.recordComposerMutationAwaitingPreparation(owner: session, content: nil)
        XCTAssertTrue(recovery.startComposerPreparation(owner: session) { _ in
            await preparationGate.waitOnce()
            return nil
        })
        let preparationTask = try XCTUnwrap(recovery.composerPreparation(for: session)?.preparationTask)

        let sleeper = ShutdownDeadlineSleeper()
        let prompts = ShutdownPromptRecorder()
        let origin = ContinuousClock.now
        let shutdown = AgentLifecycleShutdownCoordinator(environment: AgentLifecycleShutdownEnvironment(
            participants: { [weak viewModel] scope in
                guard scope == .window(windowID), let viewModel else { return [] }
                return [viewModel]
            },
            beginApplicationRecoveryFreeze: { {} },
            preserveLayout: { true },
            settleReleasedRecoveryInput: { [] },
            recordLaunchState: { _ in Task { true } },
            authorizeCleanExit: { UUID() },
            recordCleanExit: { _ in Task { true } },
            beginIrreversible: { prompts.irreversible.append($0) },
            tearDownScope: { _ in },
            presentFailure: { await prompts.present($0) },
            dismissFailure: { _ in },
            now: { origin },
            sleepUntil: { try await sleeper.sleep(until: $0) }
        ))
        var finishes: [Bool] = []
        XCTAssertTrue(shutdown.requestWindowClose(windowID: windowID, forwardedVeto: { true }, finish: { finishes.append($0) }))
        let requestID = try XCTUnwrap(shutdown.request(for: .window(windowID))?.id)

        let parked = await RecoveryTestSupport.eventually { preparationGate.isWaiting && sleeper.requested.count == 1 }
        XCTAssertTrue(parked)
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        XCTAssertEqual(shutdown.request(for: .window(windowID))?.phase, .preparing, "Stage A is parked in the join")
        XCTAssertFalse(prompts.isPresenting, "no prompt before the deadline")
        XCTAssertEqual(sleeper.requested, [origin + .seconds(8)], "the single deadline, captured at the request")

        sleeper.fire()
        let presented = await RecoveryTestSupport.eventually { prompts.isPresenting }
        XCTAssertTrue(presented)
        let failure = try XCTUnwrap(prompts.presented.last)
        XCTAssertEqual(failure.requestID, requestID)
        XCTAssertEqual(failure.scope, .window(windowID))
        XCTAssertEqual(failure.stage, .preparation)
        XCTAssertEqual(failure.timedOut, true)
        XCTAssertEqual(failure.messages, [AgentLifecycleShutdownCoordinator.timeoutMessage])
        XCTAssertEqual(failure.offeredChoices, [.retry, .cancel])
        XCTAssertEqual(AgentLifecycleShutdownDiagnostics.dialogStage(failure), "preparation.deadline_expired")
        XCTAssertTrue(viewModel.isShutdownFrozen, "the prompt waits for the user; nothing reopens on its own")

        // The preparation finishes late: the expired request is not completed, re-prompted, or closed.
        preparationGate.release()
        await preparationTask.value
        // Stage A itself (the participant's preparation) now runs to its end.
        _ = await viewModel.shutdownPreparationTask?.value
        for _ in 0 ..< 200 {
            await Task.yield()
        }
        XCTAssertEqual(shutdown.request(for: .window(windowID))?.phase, .preparationFailed, "the late completion is fenced")
        XCTAssertEqual(prompts.presented.count, 1)
        XCTAssertTrue(prompts.irreversible.isEmpty, "never crosses the point of no return")
        XCTAssertTrue(finishes.isEmpty)

        prompts.choose(.cancel)
        let cancelled = await RecoveryTestSupport.eventually { finishes == [false] }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(viewModel.isShutdownFrozen, "Cancel reopens the window")
    }

    private struct Harness {
        let viewModel: AgentModeViewModel
        let workspace: WorkspaceModel
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

    private static func admitQueued(
        _ text: String,
        on lane: AgentRecoverySessionLane
    ) async -> Result<AgentRecoveryAdmitted<AgentRecoveryQueueReceipt>, AgentRecoveryAdmissionFailure> {
        await lane.admitQueued(AgentRecoveryAdmission(
            binding: lane.binding,
            userItemID: UUID(),
            origin: .mcp,
            target: .session,
            original: RecoveryTestSupport.content(text)
        ))
    }

    /// Persists the first transcript through the VM save path (which claims the lane) and waits for
    /// the lane's eager composer restore.
    private func persistAndClaimLane(_ harness: Harness) async throws -> AgentRecoverySessionLane {
        harness.session.appendItem(.user("Before reset"))
        let saved = await harness.viewModel.flushSave(for: harness.tabID)
        XCTAssertTrue(saved)
        let lane = try XCTUnwrap(harness.session.recoveryLane, "The first save claims the session's lane")
        let restored = await RecoveryTestSupport.eventually {
            if case .ready = lane.composerState { return true }
            return false
        }
        XCTAssertTrue(restored)
        return lane
    }

    private func makeHarness(
        windowID: Int,
        fileOperations: AgentRecoveryStore.FileOperations = .live
    ) async throws -> Harness {
        let storageURL = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryResetBoundaryWorkspace")
        let recoveryRoot = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryResetBoundaryStore")
            .appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: storageURL)
            try? FileManager.default.removeItem(at: recoveryRoot.deletingLastPathComponent().deletingLastPathComponent())
        }
        let store = AgentRecoveryStore(rootURL: recoveryRoot, fileOperations: fileOperations)
        let service = AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
        let coordinator = try AgentRecoveryCoordinator(
            store: store,
            dataService: service,
            reconcile: { _ in .empty },
            makeComposerController: { store, gate in
                // Debounced composer writes never fire on their own: only explicit flushes write.
                AgentRecoveryComposerPersistenceController(
                    store: store,
                    gate: gate,
                    sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
                )
            }
        )
        coordinator.startIfNeeded()
        let startup = await coordinator.awaitStartup()
        guard startup == .ready else { throw RecoveryLaneFixtureError.startupNotReady }

        let workspace = WorkspaceModel(
            name: "Agent Recovery Reset Boundary",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL
        )
        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        viewModel.installRecoveryCoordinator(coordinator)
        XCTAssertTrue(viewModel.test_dataService === service, "The VM writes through the coordinator's gated DataService")
        viewModel.test_establishPersistenceWorkspace(workspace)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        XCTAssertNotNil(session.recoveryComposerObserver, "First-draft observation is installed at session creation")
        return Harness(viewModel: viewModel, workspace: workspace, tabID: tabID, session: session)
    }
}

/// Store file operations that hold the first record write containing `marker` until released.
private final class RecoveryStoreMarkerWriteHold: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let marker: Data
    private var armed = true
    private var holding = false
    private var released = false

    init(marker: String) {
        self.marker = Data(marker.utf8)
    }

    var isHolding: Bool {
        lock.withLock { holding }
    }

    func fileOperations() -> AgentRecoveryStore.FileOperations {
        AgentRecoveryStore.FileOperations(
            writeAtomically: { [self] data, url in
                let shouldHold = lock.withLock { () -> Bool in
                    guard armed, !released, data.range(of: marker) != nil else { return false }
                    armed = false
                    holding = true
                    return true
                }
                if shouldHold {
                    gate.wait()
                }
                try data.write(to: url, options: .atomic)
            },
            removeItem: { url in try FileManager.default.removeItem(at: url) }
        )
    }

    /// Idempotent.
    func release() {
        let wasHolding = lock.withLock { () -> Bool in
            released = true
            defer { holding = false }
            return holding
        }
        if wasHolding {
            gate.signal()
        }
    }
}

/// Store file operations that hold the first record write carrying a run's shutdown reason (the
/// lane's Stage A write after its question upsert) until released.
private final class RecoveryStoreRunShutdownWriteHold: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var armed = true
    private var holding = false
    private var released = false

    var isHolding: Bool {
        lock.withLock { holding }
    }

    func fileOperations() -> AgentRecoveryStore.FileOperations {
        AgentRecoveryStore.FileOperations(
            writeAtomically: { [self] data, url in
                let marker = Data("\"shutdown\"".utf8)
                let shouldHold = lock.withLock { () -> Bool in
                    guard armed, !released, data.range(of: marker) != nil else { return false }
                    armed = false
                    holding = true
                    return true
                }
                if shouldHold {
                    gate.wait()
                }
                try data.write(to: url, options: .atomic)
            },
            removeItem: { url in try FileManager.default.removeItem(at: url) }
        )
    }

    /// Idempotent.
    func release() {
        let wasHolding = lock.withLock { () -> Bool in
            released = true
            defer { holding = false }
            return holding
        }
        if wasHolding {
            gate.signal()
        }
    }
}

/// The shutdown coordinator's deadline sleep, fired by the test (time never moves on its own).
/// Cancellation throws, so a cancelled deadline task never stays suspended.
private final class ShutdownDeadlineSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var requestedInstants: [ContinuousClock.Instant] = []

    var requested: [ContinuousClock.Instant] {
        lock.withLock { requestedInstants }
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                requestedInstants.append(deadline)
                waiters.append((id, continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let index = waiters.firstIndex { $0.0 == id }
            let continuation = index.map { waiters.remove(at: $0).1 }
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Expires every pending sleep.
    func fire() {
        let pending = lock.withLock {
            let values = waiters
            waiters = []
            return values
        }
        pending.forEach { $0.1.resume() }
    }
}

/// Records the shutdown coordinator's prompts and answers them on the test's command.
@MainActor
private final class ShutdownPromptRecorder {
    var presented: [AgentLifecycleShutdownFailure] = []
    var irreversible: [AgentLifecycleShutdownScope] = []
    private var pendingChoice: CheckedContinuation<AgentLifecycleShutdownChoice, Never>?

    var isPresenting: Bool {
        pendingChoice != nil
    }

    func present(_ failure: AgentLifecycleShutdownFailure) async -> AgentLifecycleShutdownChoice {
        presented.append(failure)
        return await withCheckedContinuation { pendingChoice = $0 }
    }

    func choose(_ choice: AgentLifecycleShutdownChoice) {
        let continuation = pendingChoice
        pendingChoice = nil
        continuation?.resume(returning: choice)
    }
}

/// Suspends the first write that reaches it until released.
@MainActor
private final class ResetBoundaryWriteGate {
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
