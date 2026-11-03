import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Stop-and-retain contract after a committed peer transcript reset (R6 P1-4): the exact owner
/// whose save was rejected retains its complete working view without save authority, stops
/// ingestion through the ordinary cancellation/terminal lifecycle, refuses new work at the
/// backend admission points, protects the view from unconfirmed disposal, and replaces it only
/// through an explicitly confirmed paired reload whose permit is re-validated at apply time.
@MainActor
final class AgentStaleResetOwnershipTests: XCTestCase {
    // MARK: - Entry, stop, retain, admission

    func testPeerResetDuringActiveStreamRetainsWorkStopsRunAndBlocksNewWork() async throws {
        let owner = try await makeHarness(windowID: 4380)
        owner.session.appendItem(.user("Pre-reset prompt"))
        let initialSave = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(initialSave)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        XCTAssertNotNil(owner.session.persistenceState(for: sessionID))

        // The owner streams: an active run with a streaming assistant item and buffered output
        // that has not been committed to the transcript yet.
        owner.session.runID = UUID()
        owner.viewModel.setAgentRunActive(owner.tabID, isActive: true)
        owner.session.runState = .running
        owner.session.appendItem(.assistant("Streaming partial", isStreaming: true))
        owner.viewModel.enqueueAssistantDelta(" tail", session: owner.session)
        XCTAssertEqual(owner.session.pendingAssistantDelta, " tail")

        // A peer window resets the conversation and commits it.
        let peer = try await makeHarness(windowID: 4381, workspace: owner.workspace, storageURL: owner.storageURL)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        peer.viewModel.clearChat(tabID: peer.tabID)
        let resetSaved = await peer.viewModel.flushSave(for: peer.tabID)
        XCTAssertTrue(resetSaved)

        // The owner's next save is rejected by the committed reset: stop-and-retain begins for
        // exactly this owner, synchronously, before any suspension.
        owner.session.appendItem(.user("Sent after the peer reset"))
        let rejected = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        XCTAssertEqual(rejected, .notWritten)
        let recovery = try XCTUnwrap(owner.session.staleResetRecovery)
        XCTAssertNil(owner.session.persistenceState, "Authority is dropped; no fresh stamp for rejected history")
        XCTAssertFalse(owner.session.hasLoadedPersistedState)
        XCTAssertTrue(owner.session.isPresentableForOwner, "The retained view stays presentable")
        XCTAssertTrue(owner.session.isDirty, "Retained work stays dirty")
        XCTAssertEqual(owner.session.persistedIncarnationSessionID, sessionID, "The incarnation is never forgotten")

        try await waitUntil("stop settled into retained") {
            if case .retained(problem: nil) = owner.session.staleResetRecovery?.phase { return true }
            return false
        }
        XCTAssertEqual(owner.session.staleResetRecovery?.id, recovery.id, "One episode; the stop never replaces it")
        XCTAssertFalse(owner.session.runState.isActive, "The old run was stopped through the terminal lifecycle")
        XCTAssertFalse(owner.viewModel.isTabRunning(owner.tabID))
        XCTAssertNil(owner.session.activeRunOwnership)
        XCTAssertTrue(owner.session.pendingAssistantDelta.isEmpty)
        let retainedTexts = owner.session.items.map(\.text)
        XCTAssertTrue(retainedTexts.contains("Pre-reset prompt"), "\(retainedTexts)")
        XCTAssertTrue(retainedTexts.contains("Sent after the peer reset"), "\(retainedTexts)")
        XCTAssertTrue(
            retainedTexts.contains("Streaming partial tail"),
            "Buffered assistant output is committed to the retained view, never discarded: \(retainedTexts)"
        )
        XCTAssertFalse(owner.session.items.contains { $0.isStreaming }, "Streaming items are finalized by the stop")
        XCTAssertNil(owner.session.persistenceState, "Stopping never re-acquires authority")
        XCTAssertTrue(owner.session.isDirty)

        // Backend admission is closed and the view is retained; nothing is written.
        let submit = owner.viewModel.submitUserTurn(text: "blocked", tabID: owner.tabID, codexAttemptID: nil, admitted: nil)
        XCTAssertEqual(submit, .blocked(message: AgentModeViewModel.staleResetRecoveryBlockedMessage))
        let start = await owner.viewModel.startAgentRun(tabID: owner.tabID, initialMessage: "blocked", inputConstituents: nil)
        guard case let .failed(startMessage)? = start else {
            return XCTFail("Run start must be refused, got \(String(describing: start))")
        }
        XCTAssertEqual(startMessage, AgentModeViewModel.staleResetRecoveryBlockedMessage)
        owner.viewModel.clearChat(tabID: owner.tabID)
        XCTAssertEqual(owner.session.items.map(\.text), retainedTexts, "Reset is refused while recovery owns the view")
        XCTAssertTrue(owner.viewModel.scheduledSendBusyState(tabID: owner.tabID).isBusy, "Scheduled dispatch treats the tab as reserved")
        XCTAssertFalse(owner.viewModel.canScheduleSend(tabID: owner.tabID, session: owner.session))
        XCTAssertNil(
            owner.viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: owner.session),
            "Rebinding is blocked while the retained view is unsaved"
        )
        XCTAssertEqual(owner.session.activeAgentSessionID, sessionID)
        XCTAssertFalse(owner.viewModel.isComposeTabEligibleForAutomaticStash(owner.tabID))
        let laterSave = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        XCTAssertEqual(laterSave, .notWritten, "The retained snapshot is never written")
        let disk = try await owner.persistedSession()
        XCTAssertTrue(disk.toLiveItems().isEmpty, "The peer's committed reset is never overwritten from the retained view")
        XCTAssertEqual(owner.session.staleResetRecovery?.id, recovery.id)
    }

    // MARK: - Explicit reload permit

    func testReloadPermitRejectsMutationDuringHeldReadAndConfirmedRetrySucceeds() async throws {
        let fixture = try await makeRetainedFixture(ownerWindowID: 4382, peerWindowID: 4383)
        let owner = fixture.owner
        let recoveryID = try XCTUnwrap(owner.session.staleResetRecovery?.id)
        owner.viewModel.storeDraftText(for: owner.tabID, "unsent draft")
        let attachmentURL = try makeManagedAttachmentFile(in: owner.storageURL, name: "kept.png")
        let attachment = AgentImageAttachment(source: .localFile(path: attachmentURL.path))
        owner.session.pendingImageAttachments = [attachment]
        let retainedTexts = owner.session.items.map(\.text)

        // A real source mutation lands while the confirmed read is held after preparation.
        owner.viewModel.test_persistedLoadPrepareHook = { held in
            held.appendItem(.user("Late mutation during reload"))
        }
        let rejected = await owner.viewModel.reloadLatestForStaleResetRecovery(tabID: owner.tabID, recoveryID: recoveryID)
        owner.viewModel.test_persistedLoadPrepareHook = nil
        XCTAssertEqual(rejected, AgentModeViewModel.staleResetRecoveryChangedMessage)
        XCTAssertEqual(owner.session.staleResetRecovery?.id, recoveryID)
        XCTAssertEqual(
            owner.session.staleResetRecovery?.phase,
            .retained(problem: AgentModeViewModel.staleResetRecoveryChangedMessage),
            "The rejected attempt returns to retained with its problem; nothing retries automatically"
        )
        XCTAssertNil(owner.session.persistenceState, "A rejected payload never installs authority")
        XCTAssertFalse(owner.session.hasLoadedPersistedState)
        XCTAssertEqual(
            owner.session.items.map(\.text),
            retainedTexts + ["Late mutation during reload"],
            "The retained view (including the late mutation) is untouched"
        )
        XCTAssertNil(owner.session.staleResetRecoveryTask)

        // A new confirmed attempt after quiescence replaces the view with the persisted snapshot.
        let succeeded = await owner.viewModel.reloadLatestForStaleResetRecovery(tabID: owner.tabID, recoveryID: recoveryID)
        XCTAssertNil(succeeded)
        XCTAssertNil(owner.session.staleResetRecovery)
        XCTAssertTrue(owner.session.hasLoadedPersistedState)
        XCTAssertEqual(owner.session.persistedIncarnationSessionID, fixture.sessionID)
        let adoptedState = owner.session.persistenceState(for: fixture.sessionID)
        XCTAssertNotNil(adoptedState, "Authority is adopted together with the persisted snapshot")
        XCTAssertTrue(owner.session.items.isEmpty, "Cleared history and the discarded working copy are absent")
        XCTAssertEqual(owner.viewModel.retrieveDraftText(for: owner.tabID), "unsent draft", "Unsent composer text survives the reload")
        XCTAssertEqual(owner.session.pendingImageAttachments, [attachment], "Pending attachments survive the reload")
        XCTAssertNil(owner.session.pendingTranscriptResetReceipt)
        XCTAssertTrue(owner.session.pendingFinalizedScheduledSendItemRemovals.isEmpty)

        // Renewed save capability: an ordinary edit saves under the adopted paired state.
        owner.session.appendItem(.user("After reload"))
        let savedAfterReload = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(savedAfterReload)
        let disk = try await owner.persistedSession()
        XCTAssertEqual(disk.toLiveItems().map(\.text), ["After reload"], "No discarded history is reapplied")
    }

    func testMissingAndUnreadableFilesRetainLocalWorkAndNeverEnterCreation() async throws {
        let fixture = try await makeRetainedFixture(ownerWindowID: 4384, peerWindowID: 4385)
        let owner = fixture.owner
        let recoveryID = try XCTUnwrap(owner.session.staleResetRecovery?.id)
        let retainedTexts = owner.session.items.map(\.text)
        let files = try await owner.viewModel.test_dataService.listAgentSessions(for: owner.workspace)
        let fileURL = try XCTUnwrap(files.first { $0.lastPathComponent.localizedCaseInsensitiveContains(fixture.sessionID.uuidString) })
        let aside = fileURL.deletingLastPathComponent().appendingPathComponent("aside-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: fileURL, to: aside)

        // Missing file: the read reports it; local work and ownership history are retained and
        // no create-only preparation is ever attempted.
        let missing = await owner.viewModel.reloadLatestForStaleResetRecovery(tabID: owner.tabID, recoveryID: recoveryID)
        XCTAssertEqual(missing, AgentModeViewModel.staleResetRecoveryMissingFileMessage)
        XCTAssertEqual(owner.session.staleResetRecovery?.phase, .retained(problem: AgentModeViewModel.staleResetRecoveryMissingFileMessage))
        XCTAssertNil(owner.session.persistenceState)
        XCTAssertFalse(owner.session.hasLoadedPersistedState)
        XCTAssertEqual(owner.session.persistedIncarnationSessionID, fixture.sessionID)
        XCTAssertEqual(owner.session.items.map(\.text), retainedTexts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Missing-file recovery never enters initial creation")

        // Unreadable file: the read fails; the retained view is untouched and retry stays available.
        try Data("not a session".utf8).write(to: fileURL)
        let unreadable = await owner.viewModel.reloadLatestForStaleResetRecovery(tabID: owner.tabID, recoveryID: recoveryID)
        XCTAssertEqual(unreadable, AgentModeViewModel.staleResetRecoveryReadFailedMessage)
        XCTAssertEqual(owner.session.staleResetRecovery?.phase, .retained(problem: AgentModeViewModel.staleResetRecoveryReadFailedMessage))
        XCTAssertNil(owner.session.persistenceState)
        XCTAssertEqual(owner.session.items.map(\.text), retainedTexts)

        // Storage recovers: the next confirmed attempt succeeds under the same lifetime.
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: aside, to: fileURL)
        let restored = await owner.viewModel.reloadLatestForStaleResetRecovery(tabID: owner.tabID, recoveryID: recoveryID)
        XCTAssertNil(restored)
        XCTAssertNil(owner.session.staleResetRecovery)
        XCTAssertNotNil(owner.session.persistenceState(for: fixture.sessionID))
        XCTAssertTrue(owner.session.hasLoadedPersistedState)
    }

    // MARK: - Ownership fences and disposal

    func testStaleFailureForPreviousBindingIsIgnoredAndDuplicatesCoalesce() async throws {
        let owner = try await makeHarness(windowID: 4386)
        owner.session.appendItem(.user("history"))
        let saved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        let staleToken = try XCTUnwrap(owner.viewModel.test_saveCommitToken(for: owner.session, workspaceID: owner.workspace.id))
        let submittedState = try XCTUnwrap(owner.session.persistenceState(for: sessionID))

        // A→B: the failure belongs to the previous binding.
        let replacement = UUID()
        XCTAssertNotNil(owner.viewModel.test_installPersistentSessionBinding(sessionID: replacement, on: owner.session))
        owner.viewModel.handleStaleTranscriptResetForOwner(
            owner.session,
            saveToken: staleToken,
            submittedState: submittedState,
            reportedResetGeneration: 1
        )
        XCTAssertNil(owner.session.staleResetRecovery, "A failure for a previous binding never enters recovery")

        // A→B→A: the durable ID matches again but the transition generation does not.
        XCTAssertNotNil(owner.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: owner.session))
        owner.viewModel.handleStaleTranscriptResetForOwner(
            owner.session,
            saveToken: staleToken,
            submittedState: submittedState,
            reportedResetGeneration: 1
        )
        XCTAssertNil(owner.session.staleResetRecovery, "A→B→A invalidates the old failure even though the ID matches")

        // The current owner enters exactly once; a duplicate failure neither restarts the stop
        // nor replaces the episode identity.
        let currentToken = try XCTUnwrap(owner.viewModel.test_saveCommitToken(for: owner.session, workspaceID: owner.workspace.id))
        owner.viewModel.handleStaleTranscriptResetForOwner(
            owner.session,
            saveToken: currentToken,
            submittedState: submittedState,
            reportedResetGeneration: 1
        )
        let entered = try XCTUnwrap(owner.session.staleResetRecovery)
        XCTAssertNil(owner.session.persistenceState)
        XCTAssertFalse(owner.session.hasLoadedPersistedState)
        XCTAssertTrue(owner.session.isDirty)
        try await waitUntil("stop settled") {
            if case .retained = owner.session.staleResetRecovery?.phase { return true }
            return false
        }
        owner.viewModel.handleStaleTranscriptResetForOwner(
            owner.session,
            saveToken: currentToken,
            submittedState: submittedState,
            reportedResetGeneration: 1
        )
        XCTAssertEqual(owner.session.staleResetRecovery?.id, entered.id)
        XCTAssertEqual(owner.session.staleResetRecovery?.phase, .retained(problem: nil), "A duplicate failure does not restart shutdown")
        XCTAssertNil(owner.session.staleResetRecoveryTask)
    }

    func testDisposalConsentCollectionNeverPublishesOrRelinquishesOwnership() async throws {
        let fixture = try await makeRetainedFixture(ownerWindowID: 4387, peerWindowID: 4388)
        let owner = fixture.owner
        let recoveryID = try XCTUnwrap(owner.session.staleResetRecovery?.id)
        let retainedTexts = owner.session.items.map(\.text)

        // No presenter: removal is refused rather than discarding silently.
        owner.viewModel.staleResetRecoveryDiscardConfirmation = nil
        let refused = await owner.viewModel.confirmStaleResetRecoveryDiscard(tabIDs: [owner.tabID], operation: "Closing the tab")
        XCTAssertFalse(refused)
        XCTAssertEqual(owner.session.staleResetRecovery?.id, recoveryID)

        // The user cancels the confirmation: the recovery and its view remain.
        let requests = DiscardRequestRecorder()
        owner.viewModel.staleResetRecoveryDiscardConfirmation = { [requests] request in
            requests.requests.append(request)
            return false
        }
        let cancelled = await owner.viewModel.confirmStaleResetRecoveryDiscard(tabIDs: [owner.tabID], operation: "Stashing the tab")
        XCTAssertFalse(cancelled)
        XCTAssertEqual(requests.requests.count, 1)
        XCTAssertEqual(requests.requests.first?.tabCount, 1)
        XCTAssertEqual(requests.requests.first?.operation, "Stashing the tab")
        XCTAssertEqual(owner.session.staleResetRecovery?.id, recoveryID)
        XCTAssertEqual(owner.session.items.map(\.text), retainedTexts)

        // Unrelated tabs pass through without any confirmation.
        let other = try await owner.viewModel.ensureSessionReady(tabID: UUID())
        let unrelated = await owner.viewModel.confirmStaleResetRecoveryDiscard(tabIDs: [other.tabID], operation: "Closing the tab")
        XCTAssertTrue(unrelated)
        XCTAssertEqual(requests.requests.count, 1)

        // Confirmation alone is UI-only. It does not publish admission, reserve the tab,
        // or relinquish the retained episode; only a complete removal operation may do that.
        owner.viewModel.staleResetRecoveryDiscardConfirmation = { [requests] request in
            requests.requests.append(request)
            return true
        }
        let confirmed = await owner.viewModel.confirmStaleResetRecoveryDiscard(
            tabIDs: [owner.tabID],
            operation: "Closing the tab"
        )
        XCTAssertTrue(confirmed)
        XCTAssertEqual(requests.requests.count, 2)
        XCTAssertEqual(owner.session.staleResetRecovery?.id, recoveryID)
        XCTAssertNil(owner.session.staleResetRemovalAdmission)
        XCTAssertNil(owner.viewModel.reservedComposeTabIDs[owner.tabID])
        XCTAssertEqual(owner.session.items.map(\.text), retainedTexts)

        // A final commit for an episode the admission never covered is refused and preserves it.
        let uncovered = try await makeRetainedFixture(ownerWindowID: 4401, peerWindowID: 4402)
        let uncoveredID = try XCTUnwrap(uncovered.owner.session.staleResetRecovery?.id)
        XCTAssertNil(uncovered.owner.session.staleResetRemovalAdmission)
        XCTAssertEqual(
            uncovered.owner.session.staleResetRecovery?.id,
            uncoveredID,
            "Consent collection never publishes an admission or relinquishes an uncovered episode"
        )
    }

    func testCompetingAdmissionCannotOverwriteAtomicReservation() async throws {
        let fixture = try await makeRetainedFixture(ownerWindowID: 4403, peerWindowID: 4404)
        let owner = fixture.owner
        let firstConfirmationGate = StaleResetGate()
        let confirmations = DiscardRequestRecorder()
        owner.viewModel.staleResetRecoveryDiscardConfirmation = { [confirmations, firstConfirmationGate] request in
            confirmations.requests.append(request)
            if confirmations.requests.count == 1 {
                await firstConfirmationGate.waitForRelease()
            }
            return true
        }

        let firstAdmission = Task { @MainActor in
            await owner.viewModel.admitComposeTabRemoval(
                tabIDs: [owner.tabID],
                reason: .close
            )
        }
        try await waitUntil("first admission confirmation held") {
            firstConfirmationGate.isWaiting
        }

        let secondAdmission = await owner.viewModel.admitComposeTabRemoval(
            tabIDs: [owner.tabID],
            reason: .close
        )
        let secondOperationID = try XCTUnwrap(secondAdmission)
        let secondAdmissionID = try XCTUnwrap(
            owner.session.staleResetRemovalAdmission?.id
        )
        XCTAssertEqual(owner.viewModel.reservedComposeTabIDs[owner.tabID], secondOperationID)

        firstConfirmationGate.release()
        let firstOperationID = await firstAdmission.value
        XCTAssertNil(firstOperationID)
        XCTAssertEqual(owner.session.staleResetRemovalAdmission?.id, secondAdmissionID)
        XCTAssertEqual(
            owner.session.staleResetRemovalAdmission?.operationID,
            secondOperationID
        )
        XCTAssertEqual(owner.viewModel.reservedComposeTabIDs[owner.tabID], secondOperationID)

        owner.viewModel.finalizeComposeTabRemoval(operationID: secondOperationID)
        XCTAssertNil(owner.session.staleResetRemovalAdmission)
        XCTAssertNil(owner.viewModel.reservedComposeTabIDs[owner.tabID])
    }

    // MARK: - Disposal through the real PromptViewModel removal path

    func testStashPathFinalSaveDiscoveringResetIsVetoableAndRetainsTheTab() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4389)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.appendItem(.user("Pre-reset prompt"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)

        // A peer commits a reset; the local tab keeps dirty work it has not saved since, so no
        // recovery marker exists yet when the user stashes the tab.
        let peer = try await makeHarness(windowID: 4390, workspace: fixture.workspace, storageURL: fixture.storageURL)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        peer.viewModel.clearChat(tabID: peer.tabID)
        let resetSaved = await peer.viewModel.flushSave(for: peer.tabID)
        XCTAssertTrue(resetSaved)
        session.appendItem(.user("Unsaved local work"))
        XCTAssertNil(session.staleResetRecovery)
        XCTAssertTrue(session.isDirty)

        // No presenter: the final save runs before the vetoable commit, discovers the reset, enters
        // stop-and-retain, and the removal is refused.
        viewModel.staleResetRecoveryDiscardConfirmation = nil
        await fixture.promptManager.stashTab(tabID)
        XCTAssertTrue(
            fixture.composeTabIDs().contains(tabID),
            "The stash is refused once the final save discovered the committed peer reset"
        )
        XCTAssertTrue(viewModel.sessions[tabID] === session)
        let recovery = try XCTUnwrap(session.staleResetRecovery, "The final save entered recovery before the commit")
        XCTAssertEqual(session.items.map(\.text), ["Pre-reset prompt", "Unsaved local work"])
        XCTAssertNil(session.persistenceState)

        // Declined confirmation: the tab, its retained transcript, and the recovery stay available.
        let prompts = DiscardRequestRecorder()
        viewModel.staleResetRecoveryDiscardConfirmation = { [prompts] request in
            prompts.requests.append(request)
            return false
        }
        await fixture.promptManager.stashTab(tabID)
        XCTAssertEqual(prompts.requests.count, 1)
        XCTAssertEqual(prompts.requests.first?.operation, "Stashing the tab")
        XCTAssertTrue(fixture.composeTabIDs().contains(tabID))
        XCTAssertTrue(viewModel.sessions[tabID] === session)
        XCTAssertEqual(session.staleResetRecovery?.id, recovery.id)
        XCTAssertEqual(session.items.map(\.text), ["Pre-reset prompt", "Unsaved local work"])
        let diskWhileRetained = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: fixture.workspace)
        XCTAssertEqual(diskWhileRetained?.toLiveItems().isEmpty, true, "The retained view is never written over the peer's reset")

        // Confirmed discard: the stash proceeds and the tab is removed.
        viewModel.staleResetRecoveryDiscardConfirmation = { [prompts] request in
            prompts.requests.append(request)
            return true
        }
        await fixture.promptManager.stashTab(tabID)
        XCTAssertEqual(prompts.requests.count, 2)
        XCTAssertFalse(fixture.composeTabIDs().contains(tabID))
        XCTAssertNil(viewModel.sessions[tabID])
        let diskAfterStash = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: fixture.workspace)
        XCTAssertEqual(diskAfterStash?.toLiveItems().isEmpty, true, "Teardown never resurrects the discarded local work")
    }

    func testStashHeldBetweenPreflightAndFinalSaveVetoesRemovalWhenThePeerResetLandsInBetween() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4403)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.appendItem(.user("Pre-reset prompt"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        XCTAssertFalse(session.isDirty, "The preflight will find a clean, saveable tab")
        let peer = try await makeHarness(windowID: 4404, workspace: fixture.workspace, storageURL: fixture.storageURL)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)

        // Between the preflight (clean tab, no prompt) and the listener's final save: the peer
        // commits a reset and the local tab receives a mutation.
        viewModel.staleResetRecoveryDiscardConfirmation = nil
        let holds = DiscardRequestRecorder()
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [peer, holds] held in
            holds.requests.append(AgentModeViewModel.AgentStaleResetDiscardRequest(tabCount: 0, operation: "held"))
            peer.viewModel.clearChat(tabID: peer.tabID)
            _ = await peer.viewModel.flushSave(for: peer.tabID)
            held.appendItem(.user("Mutation after preflight"))
        }
        await fixture.promptManager.stashTab(tabID)
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil
        XCTAssertEqual(holds.requests.count, 1, "The listener reached its final save exactly once")
        XCTAssertTrue(
            fixture.composeTabIDs().contains(tabID),
            "The final save discovered the reset after the preflight; removal is vetoed at the final boundary"
        )
        XCTAssertTrue(viewModel.sessions[tabID] === session, "The retained owner is preserved even though its runtime cleanup already settled")
        let recovery = try XCTUnwrap(session.staleResetRecovery)
        XCTAssertNil(session.staleResetRemovalAdmission, "An admission that never covered this episode is dropped")
        XCTAssertNil(session.persistenceState)
        XCTAssertEqual(session.items.map(\.text), ["Pre-reset prompt", "Mutation after preflight"])
        try await waitUntil("stop settled into retained") {
            if case .retained(problem: nil) = session.staleResetRecovery?.phase { return true }
            return false
        }
        let diskAfterVeto = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: fixture.workspace)
        XCTAssertEqual(diskAfterVeto?.toLiveItems().isEmpty, true, "The peer's reset is never overwritten by the vetoed removal")

        // Next attempt: the preflight shows exactly this episode; consent covers it; removal proceeds.
        let prompts = DiscardRequestRecorder()
        viewModel.staleResetRecoveryDiscardConfirmation = { [prompts] request in
            prompts.requests.append(request)
            return true
        }
        await fixture.promptManager.stashTab(tabID)
        XCTAssertEqual(prompts.requests.count, 1)
        XCTAssertEqual(prompts.requests.first?.tabCount, 1)
        XCTAssertFalse(fixture.composeTabIDs().contains(tabID))
        XCTAssertNil(viewModel.sessions[tabID])
        _ = recovery
    }

    func testMCPRegistrationSettlesBeforeFinalSaveResetVetoAndConfirmedReload() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4421)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.appendItem(.user("Pre-reset prompt"))
        let initialSave = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(initialSave)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        let peer = try await makeHarness(
            windowID: 4422,
            workspace: fixture.workspace,
            storageURL: fixture.storageURL
        )
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        try await waitUntil("approval subscription installed before MCP activation") {
            session.applyEditsApprovalScopeGeneration != nil
        }
        _ = try await viewModel.mcpActivateControlContext(
            forTabID: tabID,
            sessionID: sessionID,
            originatingConnectionID: nil
        )
        let activeRegistration = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertNotNil(activeRegistration)

        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [peer] held in
            guard held.tabID == tabID else { return }
            peer.viewModel.clearChat(tabID: peer.tabID)
            _ = await peer.viewModel.flushSave(for: peer.tabID)
            held.appendItem(.user("Mutation after preflight"))
        }
        await fixture.promptManager.stashTab(tabID)
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil

        XCTAssertTrue(fixture.composeTabIDs().contains(tabID), "Unconsented reset vetoes the stash")
        XCTAssertTrue(viewModel.sessions[tabID] === session)
        XCTAssertNil(session.mcpControlContext)
        let registrationAfterAbort = await AgentRunSessionStore.currentRegistration(for: sessionID)
        XCTAssertNil(registrationAfterAbort, "Preparation owns registration settlement even when commit aborts")
        try await waitUntil("MCP-controlled reset retained after veto") {
            if case .retained(problem: nil) = session.staleResetRecovery?.phase { return true }
            return false
        }
        let recoveryID = try XCTUnwrap(session.staleResetRecovery?.id)
        let reloadProblem = await viewModel.reloadLatestForStaleResetRecovery(
            tabID: tabID,
            recoveryID: recoveryID
        )
        XCTAssertNil(reloadProblem)
        XCTAssertNil(session.staleResetRecovery)
        XCTAssertTrue(session.hasLoadedPersistedState)
    }

    func testBatchVetoRestoresCapturedMCPApprovalAfterOtherSubscriptionCancellation() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4423)
        let viewModel = fixture.viewModel
        let orderedTabIDs = ([fixture.primaryTabID] + fixture.extraTabIDs)
            .sorted { $0.uuidString < $1.uuidString }
        let firstTabID = orderedTabIDs[0]
        let secondTabID = orderedTabIDs[1]
        let vetoTabID = orderedTabIDs[2]
        let first = try await viewModel.ensureSessionReady(tabID: firstTabID)
        let second = try await viewModel.ensureSessionReady(tabID: secondTabID)
        let veto = try await viewModel.ensureSessionReady(tabID: vetoTabID)
        let approvalStore = viewModel.applyEditsApprovalStore

        for session in [first, second, veto] {
            session.appendItem(.user("Pre-reset history"))
            let saved = await viewModel.flushSave(for: session.tabID)
            XCTAssertTrue(saved)
        }
        let firstSessionID = try XCTUnwrap(first.activeAgentSessionID)
        let secondSessionID = try XCTUnwrap(second.activeAgentSessionID)
        let vetoSessionID = try XCTUnwrap(veto.activeAgentSessionID)
        let peer = try await makeHarness(
            windowID: 4424,
            workspace: fixture.workspace,
            storageURL: fixture.storageURL
        )
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: vetoSessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)

        try await waitUntil("both approval subscriptions installed") {
            first.applyEditsApprovalScopeGeneration != nil
                && second.applyEditsApprovalScopeGeneration != nil
        }
        for session in [first, second] {
            let generation = try XCTUnwrap(session.applyEditsApprovalScopeGeneration)
            let accepted = await approvalStore.setAutoEditEnabled(
                false,
                for: viewModel.applyEditsScope(for: session.tabID),
                ifOwnedBy: generation,
                updateGlobalDefault: false
            )
            XCTAssertTrue(accepted)
        }
        try await waitUntil("both local preferences are off") {
            !first.autoEditEnabled && !second.autoEditEnabled
        }
        _ = try await viewModel.mcpActivateControlContext(
            forTabID: firstTabID,
            sessionID: firstSessionID,
            originatingConnectionID: nil
        )
        _ = try await viewModel.mcpActivateControlContext(
            forTabID: secondTabID,
            sessionID: secondSessionID,
            originatingConnectionID: nil
        )
        XCTAssertTrue(first.autoEditEnabled)
        XCTAssertTrue(second.autoEditEnabled)
        let secondScope = viewModel.applyEditsScope(for: secondTabID)
        let forcedServiceSetting = await approvalStore.autoEditEnabled(for: secondScope)
        XCTAssertTrue(forcedServiceSetting)
        let secondSubscriptionTask = try XCTUnwrap(second.applyEditsApprovalSubscriptionTask)

        let firstGate = StaleResetGate()
        viewModel.test_composeTabRemovalEarlyTeardownHook = { held in
            guard held === first else { return }
            await firstGate.waitForRelease()
        }
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [peer] held in
            guard held === veto else { return }
            peer.viewModel.clearChat(tabID: peer.tabID)
            _ = await peer.viewModel.flushSave(for: peer.tabID)
            held.appendItem(.user("Mutation after preflight"))
        }
        defer {
            firstGate.release()
            viewModel.test_composeTabRemovalEarlyTeardownHook = nil
            viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil
        }
        let closeTask = Task { @MainActor in
            await fixture.promptManager.closeAllComposeTabs()
        }
        try await waitUntil("first target held during preparation") {
            firstGate.isWaiting
        }
        try await waitUntil("second cancelled subscription finished before deactivation") {
            second.applyEditsApprovalSubscriptionTask == nil
                && second.applyEditsApprovalScopeGeneration == nil
        }
        await secondSubscriptionTask.value
        XCTAssertNotNil(second.mcpControlContext)
        XCTAssertTrue(second.autoEditEnabled)

        firstGate.release()
        await closeTask.value

        XCTAssertTrue(fixture.composeTabIDs().contains(secondTabID), "The later reset vetoed the batch")
        XCTAssertTrue(viewModel.sessions[secondTabID] === second)
        XCTAssertNil(second.staleResetRecovery, "The second target remains a healthy owner")
        XCTAssertNil(second.mcpControlContext)
        XCTAssertFalse(second.autoEditEnabled, "The captured owner's local preference is restored")
        let restoredServiceSetting = await approvalStore.autoEditEnabled(for: secondScope)
        XCTAssertFalse(restoredServiceSetting, "The captured generation restores the service override")
        let secondRegistration = await AgentRunSessionStore.currentRegistration(for: secondSessionID)
        XCTAssertNil(secondRegistration)
        XCTAssertNotNil(veto.staleResetRecovery, "A later final save supplies the batch veto")
    }

    func testBatchRemovalVetoRetainsConsentedAndNewlyDiscoveredEpisodesTogether() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4405)
        let viewModel = fixture.viewModel
        let firstTabID = fixture.extraTabIDs[0]
        let secondTabID = fixture.extraTabIDs[1]
        let peer = try await makeHarness(windowID: 4406, workspace: fixture.workspace, storageURL: fixture.storageURL)

        // First target: a consented recovery already retained before removal.
        let first = try await viewModel.ensureSessionReady(tabID: firstTabID)
        first.appendItem(.user("First history"))
        let firstSaved = await viewModel.flushSave(for: firstTabID)
        XCTAssertTrue(firstSaved)
        let firstSessionID = try XCTUnwrap(first.activeAgentSessionID)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: firstSessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        peer.viewModel.clearChat(tabID: peer.tabID)
        let firstResetSaved = await peer.viewModel.flushSave(for: peer.tabID)
        XCTAssertTrue(firstResetSaved)
        first.appendItem(.user("First unsaved work"))
        let firstRejected = await viewModel.flushSaveDetailed(for: firstTabID)
        XCTAssertEqual(firstRejected, .notWritten)
        try await waitUntil("first target retained") {
            if case .retained(problem: nil) = first.staleResetRecovery?.phase { return true }
            return false
        }
        let consentedEpisodeID = try XCTUnwrap(first.staleResetRecovery?.id)

        // Second target: clean and saveable when the preflight runs; its reset lands only inside
        // the listener's final save.
        let second = try await viewModel.ensureSessionReady(tabID: secondTabID)
        second.appendItem(.user("Second history"))
        let secondSaved = await viewModel.flushSave(for: secondTabID)
        XCTAssertTrue(secondSaved)
        let secondSessionID = try XCTUnwrap(second.activeAgentSessionID)
        let secondPeerTabID = UUID()
        let secondPeer = try await peer.viewModel.ensureSessionReady(tabID: secondPeerTabID)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: secondSessionID, on: secondPeer))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: secondPeerTabID)
        XCTAssertFalse(second.isDirty)

        let prompts = DiscardRequestRecorder()
        viewModel.staleResetRecoveryDiscardConfirmation = { [prompts] request in
            prompts.requests.append(request)
            return true
        }
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [peer] held in
            guard held.tabID == secondTabID else { return }
            peer.viewModel.clearChat(tabID: secondPeerTabID)
            _ = await peer.viewModel.flushSave(for: secondPeerTabID)
            held.appendItem(.user("Second mutation during final save"))
        }
        // Real two-target `.close` batch through PromptViewModel.
        await fixture.promptManager.closeTabsToRight(of: fixture.primaryTabID)
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil

        XCTAssertEqual(prompts.requests.count, 1)
        XCTAssertEqual(prompts.requests.first?.tabCount, 1, "Consent covered only the first target's episode")
        let remainingTabIDs = fixture.composeTabIDs()
        XCTAssertTrue(remainingTabIDs.contains(firstTabID), "The batch is vetoed: the consented target stays")
        XCTAssertTrue(remainingTabIDs.contains(secondTabID), "The batch is vetoed: the newly discovered target stays")
        XCTAssertTrue(viewModel.sessions[firstTabID] === first)
        XCTAssertTrue(viewModel.sessions[secondTabID] === second)
        XCTAssertEqual(first.staleResetRecovery?.id, consentedEpisodeID, "The consented episode is not relinquished when another target vetoes")
        XCTAssertEqual(first.items.map(\.text), ["First history", "First unsaved work"])
        XCTAssertNotNil(second.staleResetRecovery, "The episode discovered by the final save is retained")
        XCTAssertEqual(second.items.map(\.text), ["Second history", "Second mutation during final save"])
        XCTAssertNil(first.staleResetRemovalAdmission)
        XCTAssertNil(second.staleResetRemovalAdmission)
        XCTAssertNil(first.persistenceState)
        XCTAssertNil(second.persistenceState)
        try await waitUntil("second target retained") {
            if case .retained(problem: nil) = second.staleResetRecovery?.phase { return true }
            return false
        }
        let firstDisk = try await viewModel.test_dataService.loadAgentSession(id: firstSessionID, for: fixture.workspace)
        let secondDisk = try await viewModel.test_dataService.loadAgentSession(id: secondSessionID, for: fixture.workspace)
        XCTAssertEqual(firstDisk?.toLiveItems().isEmpty, true, "A vetoed close deletes nothing and writes nothing")
        XCTAssertEqual(secondDisk?.toLiveItems().isEmpty, true)

        // Next attempt shows both episodes; consent covers both; the batch is removed.
        await fixture.promptManager.closeTabsToRight(of: fixture.primaryTabID)
        XCTAssertEqual(prompts.requests.count, 2)
        XCTAssertEqual(prompts.requests.last?.tabCount, 2)
        let afterRemoval = fixture.composeTabIDs()
        XCTAssertFalse(afterRemoval.contains(firstTabID))
        XCTAssertFalse(afterRemoval.contains(secondTabID))
        XCTAssertNil(viewModel.sessions[firstTabID])
        XCTAssertNil(viewModel.sessions[secondTabID])
        // The backing files were last written by the peer window (their stub `composeTabID` is
        // the peer's tab), so this window's close does not resolve them for deletion; what the
        // consented close must guarantee is that the discarded retained work never reaches them.
        let firstAfterClose = try await viewModel.test_dataService.loadAgentSession(id: firstSessionID, for: fixture.workspace)
        let secondAfterClose = try await viewModel.test_dataService.loadAgentSession(id: secondSessionID, for: fixture.workspace)
        XCTAssertEqual(firstAfterClose?.toLiveItems().isEmpty, true, "A consented close never resurrects the discarded work")
        XCTAssertEqual(secondAfterClose?.toLiveItems().isEmpty, true)
    }

    func testChangeAfterFinalSaveWhileAnotherTargetIsHeldIsReconsideredAndVetoesOnDiscoveredReset() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4407)
        let viewModel = fixture.viewModel
        let firstTabID = fixture.extraTabIDs[0]
        let secondTabID = fixture.extraTabIDs[1]
        let peer = try await makeHarness(windowID: 4408, workspace: fixture.workspace, storageURL: fixture.storageURL)

        let first = try await viewModel.ensureSessionReady(tabID: firstTabID)
        first.appendItem(.user("First history"))
        let firstSaved = await viewModel.flushSave(for: firstTabID)
        XCTAssertTrue(firstSaved)
        let firstSessionID = try XCTUnwrap(first.activeAgentSessionID)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: firstSessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        let second = try await viewModel.ensureSessionReady(tabID: secondTabID)
        second.appendItem(.user("Second history"))
        let secondSaved = await viewModel.flushSave(for: secondTabID)
        XCTAssertTrue(secondSaved)

        // The first target's final save completes; while the second target's teardown is held,
        // the first target receives output and a peer commits a reset of its conversation.
        let holds = DiscardRequestRecorder()
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [peer, first, holds] held in
            guard held.tabID == secondTabID else { return }
            holds.requests.append(AgentModeViewModel.AgentStaleResetDiscardRequest(tabCount: 0, operation: "held"))
            XCTAssertEqual(first.staleResetRemovalAdmission?.isFinalSaveCompleted, true, "The first target's final save completed before the second was held")
            first.appendItem(.user("Output after the final save"))
            XCTAssertNil(first.saveDebounceTask, "A reserved owner never schedules a debounced save")
            peer.viewModel.clearChat(tabID: peer.tabID)
            _ = await peer.viewModel.flushSave(for: peer.tabID)
        }
        viewModel.staleResetRecoveryDiscardConfirmation = { _ in true }
        await fixture.promptManager.closeTabsToRight(of: fixture.primaryTabID)
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil

        XCTAssertEqual(holds.requests.count, 1)
        let remaining = fixture.composeTabIDs()
        XCTAssertTrue(remaining.contains(firstTabID), "The changed target was re-saved, discovered the reset, and vetoed the batch")
        XCTAssertTrue(remaining.contains(secondTabID))
        XCTAssertTrue(viewModel.sessions[firstTabID] === first)
        XCTAssertTrue(viewModel.sessions[secondTabID] === second)
        XCTAssertNotNil(first.staleResetRecovery, "The reset discovered by the reconsideration save is retained, never removed")
        XCTAssertEqual(first.items.map(\.text), ["First history", "Output after the final save"], "The complete retained transcript survives")
        XCTAssertNil(first.persistenceState)
        XCTAssertNil(first.staleResetRemovalAdmission, "The vetoed operation releases its reservation")
        XCTAssertNil(second.staleResetRemovalAdmission)
        XCTAssertNil(second.staleResetRecovery)
        try await waitUntil("first target retained") {
            if case .retained(problem: nil) = first.staleResetRecovery?.phase { return true }
            return false
        }
        let firstDisk = try await viewModel.test_dataService.loadAgentSession(id: firstSessionID, for: fixture.workspace)
        XCTAssertEqual(firstDisk?.toLiveItems().isEmpty, true, "The peer's reset is never overwritten by the vetoed removal")
        // The released owners accept work again.
        second.appendItem(.user("Second tab continues"))
        let secondResaved = await viewModel.flushSave(for: secondTabID)
        XCTAssertTrue(secondResaved, "A released, healthy target saves normally after the veto")
    }

    func testOwnerReplacedDuringTeardownVetoesRemovalAndPreservesBothOwners() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4409)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let original = try await viewModel.ensureSessionReady(tabID: tabID)
        original.appendItem(.user("Original history"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        let originalSessionID = try XCTUnwrap(original.activeAgentSessionID)

        // While the operation's teardown is held, the tab's owner object is replaced.
        let replacement = AgentTabSession(tabID: tabID)
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [viewModel, replacement] held in
            guard held.tabID == tabID else { return }
            viewModel.test_installLiveSession(replacement)
        }
        viewModel.staleResetRecoveryDiscardConfirmation = { _ in true }
        await fixture.promptManager.stashTab(tabID)
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil

        XCTAssertTrue(fixture.composeTabIDs().contains(tabID), "A replaced owner is not covered by the admission: the removal is vetoed")
        XCTAssertTrue(viewModel.sessions[tabID] === replacement, "The replacement owner is untouched")
        XCTAssertNil(replacement.staleResetRemovalAdmission)
        XCTAssertEqual(original.items.map(\.text), ["Original history"], "The captured owner is not destroyed")
        XCTAssertEqual(original.activeAgentSessionID, originalSessionID)
        let disk = try await viewModel.test_dataService.loadAgentSession(id: originalSessionID, for: fixture.workspace)
        XCTAssertNotNil(disk, "A vetoed removal deletes nothing")
    }

    func testCommittedRemovalBlocksRematerializationUntilCapturedCleanupFinishes() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4410)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let original = try await viewModel.ensureSessionReady(tabID: tabID)
        original.appendItem(.user("Original history"))
        let initialSave = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(initialSave)

        let observations = DiscardRequestRecorder()
        viewModel.test_composeTabRemovalPhaseTwoHook = { [viewModel, observations] held in
            guard held.tabID == tabID else { return }
            let optionalOwner = viewModel.session(for: tabID, createIfNeeded: true)
            let readinessWasRejected: Bool
            do {
                _ = try await viewModel.ensureSessionReady(tabID: tabID)
                readinessWasRejected = false
            } catch {
                readinessWasRejected = true
            }
            let rebound = viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: held)
            observations.requests.append(AgentModeViewModel.AgentStaleResetDiscardRequest(
                tabCount: optionalOwner == nil && readinessWasRejected && rebound == nil ? 0 : 1,
                operation: "postcommit exclusion"
            ))
        }

        await fixture.promptManager.closeComposeTab(tabID)
        viewModel.test_composeTabRemovalPhaseTwoHook = nil

        XCTAssertEqual(observations.requests.count, 1)
        XCTAssertEqual(
            observations.requests.first?.tabCount,
            0,
            "Optional materialization, throwing readiness, and rebinding all refuse a committed target"
        )
        XCTAssertFalse(fixture.composeTabIDs().contains(tabID))
        XCTAssertNil(viewModel.sessions[tabID])
        XCTAssertNil(viewModel.session(for: tabID, createIfNeeded: true))
        XCTAssertTrue(viewModel.reservedComposeTabIDs.isEmpty)
    }

    func testHeldInitialApprovalSetupCannotClaimReplacementScopeAfterRemoval() async throws {
        let windowID = 4420
        let fixture = try await makePromptManagedFixture(windowID: windowID)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let approvalStore = viewModel.applyEditsApprovalStore
        let setupGate = StaleResetGate()
        await approvalStore.test_setInitialSetupHook { _ in
            let shouldHold = await MainActor.run { !setupGate.isWaiting }
            if shouldHold {
                await setupGate.waitForRelease()
            }
        }
        defer {
            setupGate.release()
            Task { await approvalStore.test_setInitialSetupHook(nil) }
        }

        let original = try await viewModel.ensureSessionReady(tabID: tabID)
        let originalSetup = try XCTUnwrap(original.applyEditsApprovalSubscriptionTask)
        try await waitUntil("original setup held before service authority") {
            setupGate.isWaiting
        }

        await fixture.promptManager.closeComposeTab(tabID)
        XCTAssertNil(viewModel.sessions[tabID])
        let replacement = AgentTabSession(tabID: tabID)
        replacement.autoEditEnabled = false
        viewModel.test_installLiveSession(replacement)
        XCTAssertTrue(viewModel.session(for: tabID, createIfNeeded: false) === replacement)
        try await waitUntil("replacement approval owner installed") {
            replacement.applyEditsApprovalSubscriptionID != nil
                && replacement.applyEditsApprovalScopeGeneration != nil
        }
        let replacementGeneration = try XCTUnwrap(replacement.applyEditsApprovalScopeGeneration)
        let scope = ApplyEditsApprovalScope(windowID: windowID, tabID: tabID)

        setupGate.release()
        await originalSetup.value
        let replacementStillOwnsScope = await approvalStore.setAutoEditEnabled(
            false,
            for: scope,
            ifOwnedBy: replacementGeneration,
            updateGlobalDefault: false
        )
        XCTAssertTrue(replacementStillOwnsScope)
        let enabled = await approvalStore.autoEditEnabled(for: scope)
        XCTAssertFalse(enabled, "A cancelled old setup never overwrites replacement configuration")
        XCTAssertEqual(replacement.applyEditsApprovalScopeGeneration, replacementGeneration)
        _ = await approvalStore.cleanupScope(scope, ifOwnedBy: replacementGeneration)
        await approvalStore.test_setInitialSetupHook(nil)
    }

    func testConditionalApprovalAndMCPPostcleanupPreserveNewerServiceOwners() async throws {
        let windowID = 4417
        let fixture = try await makePromptManagedFixture(windowID: windowID)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.appendItem(.user("Cleanup ownership"))
        let initialSave = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(initialSave)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        try await waitUntil("approval subscription installed") {
            session.applyEditsApprovalSubscriptionID != nil
                && session.applyEditsApprovalScopeGeneration != nil
        }
        _ = try await viewModel.mcpActivateControlContext(
            forTabID: tabID,
            sessionID: sessionID,
            originatingConnectionID: nil
        )

        let approvalGate = StaleResetGate()
        let mcpGate = StaleResetGate()
        let approvalStore = viewModel.applyEditsApprovalStore
        await approvalStore.test_setConditionalCleanupHook { _, _ in
            await approvalGate.waitForRelease()
        }
        defer {
            Task {
                await approvalStore.test_setConditionalCleanupHook(nil)
                await AgentRunSessionStore.shared.test_setCleanupHook(nil)
            }
        }

        let closeTask = Task { @MainActor in
            await fixture.promptManager.closeComposeTab(tabID)
        }
        try await waitUntil("approval cleanup held at owner check") {
            approvalGate.isWaiting
        }

        let scope = ApplyEditsApprovalScope(windowID: windowID, tabID: tabID)
        let replacementApproval = await approvalStore.subscribe(scope: scope)
        await AgentRunSessionStore.shared.test_setCleanupHook { _ in
            await mcpGate.waitForRelease()
        }
        XCTAssertNil(viewModel.session(for: tabID, createIfNeeded: true))
        let reservedControlActivation = try? await viewModel.mcpActivateControlContext(
            forTabID: tabID,
            sessionID: sessionID,
            originatingConnectionID: nil
        )
        XCTAssertNil(reservedControlActivation)
        approvalGate.release()

        try await waitUntil("MCP cleanup held at owner check") {
            mcpGate.isWaiting
        }
        let replacementRegistration = await AgentRunSessionStore.shared.register(
            sessionID: sessionID
        )
        mcpGate.release()
        await closeTask.value

        let newerApprovalStillOwnsScope = await approvalStore.setAutoEditEnabled(
            false,
            for: scope,
            ifOwnedBy: replacementApproval.generation,
            updateGlobalDefault: false
        )
        XCTAssertTrue(newerApprovalStillOwnsScope)
        let currentRegistration = await AgentRunSessionStore.currentRegistration(
            for: sessionID
        )
        XCTAssertEqual(currentRegistration, replacementRegistration)

        _ = await approvalStore.cleanupScope(
            scope,
            ifOwnedBy: replacementApproval.generation
        )
        await AgentRunSessionStore.cleanup(registration: replacementRegistration)
        await approvalStore.test_setConditionalCleanupHook(nil)
        await AgentRunSessionStore.shared.test_setCleanupHook(nil)
    }

    func testConditionalDeletionFailureKeepsCapturedFileAndIndexEvidence() async throws {
        struct ForcedDeletionFailure: Error {}

        let fixture = try await makePromptManagedFixture(windowID: 4418)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.appendItem(.user("Keep durable evidence"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        XCTAssertNotNil(viewModel.ownerValidatedSessionIndex[sessionID])

        await viewModel.test_dataService.test_setConditionalDeletionHook { _ in
            throw ForcedDeletionFailure()
        }
        await fixture.promptManager.closeComposeTab(tabID)
        await viewModel.test_dataService.test_setConditionalDeletionHook(nil)

        XCTAssertFalse(fixture.composeTabIDs().contains(tabID))
        XCTAssertNil(viewModel.sessions[tabID])
        let retainedFile = try await viewModel.test_dataService.loadAgentSession(
            id: sessionID,
            for: fixture.workspace
        )
        XCTAssertNotNil(retainedFile)
        XCTAssertNotNil(
            viewModel.ownerValidatedSessionIndex[sessionID],
            "Failed deletion retains matching index evidence"
        )
    }

    func testFinalSaveHeldDuringMutationRecordsTheWrittenSnapshotAndReconsiders() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4411)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.appendItem(.user("History"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)

        // The tab becomes dirty only after admission (inside the operation's early teardown), so
        // the operation's own final save is the save that snapshots it. That save suspends before
        // the write and a mutation lands while the write is awaited.
        viewModel.test_composeTabRemovalEarlyTeardownHook = { held in
            guard held.tabID == tabID else { return }
            held.appendItem(.user("Dirty before removal"))
        }
        let holds = DiscardRequestRecorder()
        viewModel.test_saveSessionBeforeWriteHook = { [holds] held in
            guard held.tabID == tabID, held.staleResetRemovalAdmission?.isReserved == true else { return }
            guard holds.requests.isEmpty else { return }
            holds.requests.append(AgentModeViewModel.AgentStaleResetDiscardRequest(tabCount: 0, operation: "held"))
            held.appendItem(.user("Mutation during the final save"))
        }
        viewModel.staleResetRecoveryDiscardConfirmation = { _ in true }
        await fixture.promptManager.stashTab(tabID)
        viewModel.test_saveSessionBeforeWriteHook = nil
        viewModel.test_composeTabRemovalEarlyTeardownHook = nil

        XCTAssertEqual(holds.requests.count, 1, "The mutation was delivered during the awaited final save exactly once")
        XCTAssertFalse(fixture.composeTabIDs().contains(tabID), "The reconsideration saved the newer content; removal completed")
        XCTAssertNil(viewModel.sessions[tabID])
        let disk = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: fixture.workspace)
        XCTAssertEqual(
            disk?.toLiveItems().map(\.text),
            ["History", "Dirty before removal", "Mutation during the final save"],
            "Content that landed during the awaited final save is durably saved before removal"
        )
    }

    func testTargetReplacedDuringPreflightIsNotAdmittedAndKeepsItsTab() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4412)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let original = try await viewModel.ensureSessionReady(tabID: tabID)
        original.appendItem(.user("Original history"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)
        original.appendItem(.user("Original unsaved work"))

        // The preflight's discovery save for the dirty target is suspended; the tab's owner is
        // replaced meanwhile (no reservation exists yet).
        let replacement = AgentTabSession(tabID: tabID)
        let holds = DiscardRequestRecorder()
        viewModel.test_saveSessionBeforeWriteHook = { [viewModel, replacement, holds] held in
            guard held === original, holds.requests.isEmpty else { return }
            holds.requests.append(AgentModeViewModel.AgentStaleResetDiscardRequest(tabCount: 0, operation: "held"))
            viewModel.test_installLiveSession(replacement)
        }
        viewModel.staleResetRecoveryDiscardConfirmation = { _ in true }
        await fixture.promptManager.stashTab(tabID)
        viewModel.test_saveSessionBeforeWriteHook = nil

        XCTAssertEqual(holds.requests.count, 1)
        XCTAssertTrue(fixture.composeTabIDs().contains(tabID), "A target replaced during admission is never admitted: the tab stays")
        XCTAssertTrue(viewModel.sessions[tabID] === replacement, "The replacement is untouched")
        XCTAssertNil(replacement.staleResetRemovalAdmission)
        XCTAssertNil(original.staleResetRemovalAdmission, "No admission survives a refused operation")
        XCTAssertEqual(original.items.map(\.text), ["Original history", "Original unsaved work"], "The captured owner's content is retained")
        XCTAssertTrue(viewModel.composeTabRemovalOperations.isEmpty)
        XCTAssertTrue(viewModel.reservedComposeTabIDs.isEmpty)
    }

    func testAbsentTargetMaterializedDuringPreflightRefusesAdmission() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4413)
        let viewModel = fixture.viewModel
        let dirtyTabID = fixture.extraTabIDs[0]
        let absentTabID = fixture.extraTabIDs[1]
        let dirty = try await viewModel.ensureSessionReady(tabID: dirtyTabID)
        dirty.appendItem(.user("Dirty history"))
        let saved = await viewModel.flushSave(for: dirtyTabID)
        XCTAssertTrue(saved)
        dirty.appendItem(.user("Dirty unsaved work"))
        XCTAssertNil(viewModel.sessions[absentTabID], "The second target has no live session at entry")

        // While the preflight's discovery save is suspended, the absent target materializes.
        let holds = DiscardRequestRecorder()
        var materializationError: Error?
        viewModel.test_saveSessionBeforeWriteHook = { [viewModel, holds] held in
            guard held === dirty, holds.requests.isEmpty else { return }
            holds.requests.append(AgentModeViewModel.AgentStaleResetDiscardRequest(tabCount: 0, operation: "held"))
            do {
                _ = try await viewModel.ensureSessionReady(tabID: absentTabID)
            } catch {
                materializationError = error
            }
        }
        viewModel.staleResetRecoveryDiscardConfirmation = { _ in true }
        await fixture.promptManager.closeTabsToRight(of: fixture.primaryTabID)
        viewModel.test_saveSessionBeforeWriteHook = nil

        XCTAssertNil(
            materializationError,
            "The preflight fixture must materialize the absent target: \(String(describing: materializationError))"
        )
        XCTAssertEqual(holds.requests.count, 1)
        let remaining = fixture.composeTabIDs()
        XCTAssertTrue(remaining.contains(dirtyTabID), "Admission is refused for the whole batch")
        XCTAssertTrue(remaining.contains(absentTabID))
        XCTAssertTrue(viewModel.sessions[dirtyTabID] === dirty)
        XCTAssertNotNil(viewModel.sessions[absentTabID], "The materialized owner is untouched")
        XCTAssertNil(dirty.staleResetRemovalAdmission)
        XCTAssertTrue(viewModel.composeTabRemovalOperations.isEmpty)
        XCTAssertTrue(viewModel.reservedComposeTabIDs.isEmpty)
    }

    func testActiveReplacementDuringEarlyTeardownIsNeitherCancelledNorCleanedUp() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4414)
        let viewModel = fixture.viewModel
        let tabID = fixture.primaryTabID
        let original = try await viewModel.ensureSessionReady(tabID: tabID)
        original.appendItem(.user("Original history"))
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved)

        // While the operation is suspended in early teardown, the owner is replaced by a session
        // with an active run.
        let replacement = AgentTabSession(tabID: tabID)
        let replacementRunID = UUID()
        viewModel.test_composeTabRemovalEarlyTeardownHook = { [viewModel, replacement] held in
            guard held === original else { return }
            viewModel.test_installLiveSession(replacement)
            replacement.runID = replacementRunID
            viewModel.setAgentRunActive(tabID, isActive: true)
            replacement.runState = .running
        }
        viewModel.staleResetRecoveryDiscardConfirmation = { _ in true }
        await fixture.promptManager.stashTab(tabID)
        viewModel.test_composeTabRemovalEarlyTeardownHook = nil

        XCTAssertTrue(fixture.composeTabIDs().contains(tabID), "The operation aborts on the replaced owner")
        XCTAssertTrue(viewModel.sessions[tabID] === replacement)
        XCTAssertEqual(replacement.runState, .running, "The older operation never cancels the replacement's run")
        XCTAssertEqual(replacement.runID, replacementRunID)
        XCTAssertTrue(viewModel.isTabRunning(tabID), "The replacement's run bookkeeping is untouched")
        XCTAssertNil(replacement.staleResetRemovalAdmission)
        XCTAssertEqual(original.items.map(\.text), ["Original history"])
        XCTAssertTrue(viewModel.reservedComposeTabIDs.isEmpty)
        // Cleanup for the test runtime bookkeeping.
        viewModel.setAgentRunActive(tabID, isActive: false)
        replacement.runState = .idle
    }

    func testWorkspaceChangeDuringHeldPhaseOneAbortsWithoutRetiringTargets() async throws {
        let owner = try await makeHarness(windowID: 4415)
        owner.session.appendItem(.user("History"))
        let saved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        let otherStorage = owner.storageURL.appendingPathComponent("other-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: otherStorage, withIntermediateDirectories: true)
        let otherWorkspace = WorkspaceModel(name: "Other", repoPaths: [otherStorage.path], customStoragePath: otherStorage)

        // The active workspace changes while phase 1 is held before the final save.
        owner.viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [owner] held in
            guard held.tabID == owner.tabID else { return }
            owner.viewModel.test_establishPersistenceWorkspace(otherWorkspace)
        }
        await owner.viewModel.handleComposeTabsWillClose([owner.tabID], reason: .close)
        owner.viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil

        XCTAssertTrue(owner.viewModel.sessions[owner.tabID] === owner.session, "The operation aborts; its target is not retired")
        XCTAssertNil(owner.session.staleResetRemovalAdmission)
        XCTAssertTrue(owner.viewModel.reservedComposeTabIDs.isEmpty)
        XCTAssertTrue(owner.viewModel.composeTabRemovalOperations.isEmpty)
        owner.viewModel.test_establishPersistenceWorkspace(owner.workspace)
        let disk = try await owner.viewModel.test_dataService.loadAgentSession(id: sessionID, for: owner.workspace)
        XCTAssertNotNil(disk, "Nothing was deleted from the original workspace")
        // The released owner accepts work again.
        owner.session.appendItem(.user("After the abort"))
        let resaved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(resaved)
    }

    func testWorkspaceChangeAfterCommitUsesCapturedCleanupResourcesOnly() async throws {
        let owner = try await makeHarness(windowID: 4416)
        owner.session.appendItem(.user("History"))
        let saved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        // A different workspace holds a session for the same compose tab ID.
        let otherStorage = owner.storageURL.appendingPathComponent("other-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: otherStorage, withIntermediateDirectories: true)
        let otherWorkspace = WorkspaceModel(name: "Other", repoPaths: [otherStorage.path], customStoragePath: otherStorage)
        let foreignSessionID = sessionID
        let foreignFileURL = try await owner.viewModel.test_dataService.saveAgentSession(
            AgentSession(id: foreignSessionID, workspaceID: otherWorkspace.id, composeTabID: owner.tabID, name: "Foreign"),
            for: otherWorkspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let foreignBytes = try Data(contentsOf: foreignFileURL)

        // The active workspace changes after the verdict, while the destructive phase is held.
        let foreignSortDate = Date(timeIntervalSinceReferenceDate: 4416)
        let foreignIndexEntry = AgentSessionIndexEntry(
            id: foreignSessionID,
            tabID: owner.tabID,
            name: "Foreign",
            lastUserMessageAt: foreignSortDate,
            savedAt: foreignSortDate,
            lastRunStateRaw: nil,
            itemCount: 1,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: nil,
            hasUnknownConversationContent: false,
            remoteHostID: nil,
            remoteHostName: nil,
            isMCPOriginated: false,
            origin: nil,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
        owner.viewModel.test_composeTabRemovalPhaseTwoHook = { [owner] held in
            guard held.tabID == owner.tabID else { return }
            owner.viewModel.test_establishPersistenceWorkspace(otherWorkspace)
            guard let foreignOwner = owner.viewModel.test_sessionIndexOwner else {
                XCTFail("Foreign workspace owner was not installed")
                return
            }
            owner.viewModel.test_installSessionIndexSnapshot(
                [foreignSessionID: foreignIndexEntry],
                owner: foreignOwner,
                latestOwner: foreignOwner,
                activeWorkspace: otherWorkspace
            )
        }
        await owner.viewModel.handleComposeTabsWillClose([owner.tabID], reason: .close)
        owner.viewModel.test_composeTabRemovalPhaseTwoHook = nil

        XCTAssertNil(owner.viewModel.sessions[owner.tabID], "Logical Agent removal committed before cleanup suspended")
        XCTAssertEqual(
            try? Data(contentsOf: foreignFileURL),
            foreignBytes,
            "Captured cleanup never targets the newly active workspace"
        )
        // The committed deletion's UUID-wide tombstone logically retires the same ID everywhere.
        let foreign = try await owner.viewModel.test_dataService.loadAgentSession(id: foreignSessionID, for: otherWorkspace)
        XCTAssertNil(foreign)
        XCTAssertEqual(owner.viewModel.ownerValidatedSessionIndex[foreignSessionID], foreignIndexEntry)
        XCTAssertEqual(owner.viewModel.ownerValidatedSessionListSortDates[owner.tabID], foreignSortDate)
        owner.viewModel.test_establishPersistenceWorkspace(owner.workspace)
        let original = try await owner.viewModel.test_dataService.loadAgentSession(id: sessionID, for: owner.workspace)
        XCTAssertNil(original, "Committed cleanup deletes only the captured original-workspace lifetime")
        XCTAssertTrue(owner.viewModel.reservedComposeTabIDs.isEmpty)
        XCTAssertTrue(owner.viewModel.composeTabRemovalOperations.isEmpty)
    }

    func testDiscardConsentIsRevalidatedAgainstEpisodesEnteredDuringConfirmation() async throws {
        let fixture = try await makeRetainedFixture(ownerWindowID: 4393, peerWindowID: 4394)
        let owner = fixture.owner
        let consentedID = try XCTUnwrap(owner.session.staleResetRecovery?.id)

        // A second tab in the same removal set is bound to another persisted session and is
        // still saveable when the confirmation is presented.
        let secondTabID = UUID()
        let second = try await owner.viewModel.ensureSessionReady(tabID: secondTabID)
        second.appendItem(.user("Second tab history"))
        let secondSaved = await owner.viewModel.flushSave(for: secondTabID)
        XCTAssertTrue(secondSaved)
        let secondSessionID = try XCTUnwrap(second.activeAgentSessionID)
        let secondPeerTab = UUID()
        let secondPeer = try await fixture.peer.viewModel.ensureSessionReady(tabID: secondPeerTab)
        XCTAssertNotNil(fixture.peer.viewModel.test_installPersistentSessionBinding(sessionID: secondSessionID, on: secondPeer))
        _ = await fixture.peer.viewModel.test_hydrateBoundSession(tabID: secondPeerTab)

        // While the user is looking at the confirmation for the first tab, the second tab's
        // conversation is reset by the peer and the second tab's own save discovers it.
        let prompts = DiscardRequestRecorder()
        owner.viewModel.staleResetRecoveryDiscardConfirmation = { [prompts, fixture, owner, second] request in
            prompts.requests.append(request)
            fixture.peer.viewModel.clearChat(tabID: secondPeerTab)
            _ = await fixture.peer.viewModel.flushSave(for: secondPeerTab)
            second.appendItem(.user("Second tab unsaved work"))
            _ = await owner.viewModel.flushSaveDetailed(for: second.tabID)
            return true
        }
        let admitted = await owner.viewModel.confirmStaleResetRecoveryDiscard(
            tabIDs: [owner.tabID, secondTabID],
            operation: "Closing the tab"
        )
        XCTAssertFalse(admitted, "Consent covered one episode; a second tab entered recovery meanwhile, so removal needs a new confirmation")
        XCTAssertEqual(prompts.requests.count, 1)
        XCTAssertEqual(prompts.requests.first?.tabCount, 1)
        XCTAssertEqual(owner.session.staleResetRecovery?.id, consentedID, "Nothing is relinquished when consent is stale")
        XCTAssertNotNil(second.staleResetRecovery)
        XCTAssertEqual(second.items.map(\.text), ["Second tab history", "Second tab unsaved work"])
    }

    // MARK: - Ingestion boundaries

    func testRemoteRecoveryRetiresTheAttachmentSoHeldRowsCannotMutateTheReplacement() async throws {
        let owner = try await makeHarness(windowID: 4395)
        let sessionID = try XCTUnwrap(owner.viewModel.test_ensureSessionBoundToTab(owner.session))
        owner.session.remoteHost = AgentSessionRemoteHostBinding(
            hostID: "host-1",
            hostDisplayName: "Studio Mac",
            remoteSessionID: sessionID.uuidString
        )
        owner.session.appendItem(.user("Pre-reset prompt"))
        let saved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(saved)
        // A delivery captured by the attachment that exists before recovery.
        let retiredGeneration = owner.viewModel.remoteCoordinator.test_deliveryGeneration(tabID: owner.tabID)
        owner.session.runState = .running

        let peer = try await makeHarness(windowID: 4396, workspace: owner.workspace, storageURL: owner.storageURL)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        peer.viewModel.clearChat(tabID: peer.tabID)
        let resetSaved = await peer.viewModel.flushSave(for: peer.tabID)
        XCTAssertTrue(resetSaved)

        owner.session.appendItem(.user("Sent after the peer reset"))
        let rejected = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        XCTAssertEqual(rejected, .notWritten)
        try await waitUntil("stop settled into retained") {
            if case .retained(problem: nil) = owner.session.staleResetRecovery?.phase { return true }
            return false
        }
        XCTAssertFalse(owner.session.runState.isActive, "The detached projection's mirrored run is frozen locally")
        XCTAssertFalse(owner.viewModel.remoteCoordinator.isAttached(tabID: owner.tabID))
        XCTAssertNotEqual(
            owner.viewModel.remoteCoordinator.test_deliveryGeneration(tabID: owner.tabID),
            retiredGeneration,
            "Stopping retired the attachment's delivery generation"
        )
        let recoveryID = try XCTUnwrap(owner.session.staleResetRecovery?.id)

        // Confirmed reload adopts the reset snapshot and its authority.
        let reloaded = await owner.viewModel.reloadLatestForStaleResetRecovery(tabID: owner.tabID, recoveryID: recoveryID)
        XCTAssertNil(reloaded)
        XCTAssertNil(owner.session.staleResetRecovery)
        XCTAssertNotNil(owner.session.persistenceState(for: sessionID))
        let replacementTexts = owner.session.items.map(\.text)
        XCTAssertFalse(replacementTexts.contains("Pre-reset prompt"))
        XCTAssertFalse(replacementTexts.contains("Sent after the peer reset"))
        let replacementRevision = owner.session.sourceItemsRevision

        // The retired attachment's delayed delivery arrives after application: dropped, and it
        // can neither mutate nor dirty the replacement.
        owner.viewModel.remoteCoordinator.test_handleEvent(
            .transcriptRows(
                items: [AgentChatItem.user("Late row from the retired attachment", sequenceIndex: 0)],
                removedIDs: [],
                hostRowIDByClientItemID: [:]
            ),
            tabID: owner.tabID,
            deliveryGeneration: retiredGeneration
        )
        XCTAssertEqual(owner.session.items.map(\.text), replacementTexts, "A retired delivery never mutates the replacement")
        XCTAssertEqual(owner.session.sourceItemsRevision, replacementRevision)
        _ = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        let diskAfterLateDelivery = try await owner.persistedSession()
        XCTAssertFalse(
            diskAfterLateDelivery.toLiveItems().contains { $0.text == "Late row from the retired attachment" },
            "Nothing from the retired delivery becomes saveable content under the adopted authority"
        )

        // The fence is generation-based: a delivery under the current attachment still applies.
        let currentGeneration = owner.viewModel.remoteCoordinator.test_deliveryGeneration(tabID: owner.tabID)
        owner.viewModel.remoteCoordinator.test_handleEvent(
            .transcriptRows(
                items: [AgentChatItem.user("Row from the current attachment", sequenceIndex: 1)],
                removedIDs: [],
                hostRowIDByClientItemID: [:]
            ),
            tabID: owner.tabID,
            deliveryGeneration: currentGeneration
        )
        XCTAssertTrue(owner.session.items.contains { $0.text == "Row from the current attachment" })
    }

    func testLocalRecoveryWaitsForOwnedTerminalResourceTeardownBeforeRetaining() async throws {
        let owner = try await makeHarness(windowID: 4397)
        owner.session.appendItem(.user("Pre-reset prompt"))
        let saved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        let peer = try await makeHarness(windowID: 4398, workspace: owner.workspace, storageURL: owner.storageURL)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        peer.viewModel.clearChat(tabID: peer.tabID)
        let resetSaved = await peer.viewModel.flushSave(for: peer.tabID)
        XCTAssertTrue(resetSaved)

        // An owned run attempt whose terminal resources tear down asynchronously (held).
        let ownership = owner.session.beginRunAttempt(source: "AgentStaleResetOwnershipTests")
        let teardownGate = StaleResetGate()
        owner.session.installRunAttemptTerminalResources(ownership: ownership) { [teardownGate] _ in
            let teardown: AgentRunAttemptTerminalResources.Teardown = { await teardownGate.waitForRelease() }
            return teardown
        }
        owner.session.runID = UUID()
        owner.viewModel.setAgentRunActive(owner.tabID, isActive: true)
        owner.session.runState = .running

        owner.session.appendItem(.user("Sent after the peer reset"))
        let rejected = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        XCTAssertEqual(rejected, .notWritten)
        XCTAssertNotNil(owner.session.staleResetRecovery)
        try await waitUntil("terminal state published while the owned teardown is held") {
            teardownGate.isWaiting && owner.session.runState == .cancelled
        }
        XCTAssertEqual(
            owner.session.staleResetRecovery?.phase,
            .stopping(problem: nil),
            "Recovery stays stopping until the run attempt's terminal resources are torn down"
        )
        XCTAssertNil(owner.session.persistenceState)
        // A final source mutation delivered during the held teardown is retained.
        owner.session.appendItem(.user("Final row during teardown"))

        teardownGate.release()
        try await waitUntil("stop settled into retained after teardown") {
            if case .retained(problem: nil) = owner.session.staleResetRecovery?.phase { return true }
            return false
        }
        XCTAssertNil(owner.session.activeRunOwnership)
        XCTAssertNil(owner.session.runAttemptTerminalResources)
        XCTAssertFalse(owner.viewModel.isTabRunning(owner.tabID))
        let texts = owner.session.items.map(\.text)
        XCTAssertTrue(texts.contains("Sent after the peer reset"))
        XCTAssertTrue(texts.contains("Final row during teardown"))
        XCTAssertNil(owner.session.persistenceState)
    }

    // MARK: - Interactive creation at tab capacity

    func testInteractiveCreationReturnsAfterCommittedAutoStashWhileOwnedCleanupIsHeld() async throws {
        let capacity = try await makeCapacityFixture(windowID: 4430)
        let fixture = capacity.base
        let viewModel = fixture.viewModel
        let targetTabID = capacity.targetTabID
        let gate = StaleResetGate()
        viewModel.test_composeTabRemovalPhaseTwoHook = { [gate] held in
            guard held.tabID == targetTabID else { return }
            await gate.waitForRelease()
        }
        defer {
            viewModel.test_composeTabRemovalPhaseTwoHook = nil
            gate.release()
        }

        let creation = CreationResultBox()
        let creationTask = Task { @MainActor in
            creation.tabID = await viewModel.createAndActivateSessionTab(focusComposer: true)
            creation.finished = true
        }
        try await waitUntil("owned cleanup held") { gate.isWaiting }
        try await waitUntil("interactive creation returned while cleanup is held") { creation.finished }
        await creationTask.value

        let createdTabID = try XCTUnwrap(creation.tabID)
        XCTAssertEqual(fixture.promptManager.activeComposeTabID, createdTabID)
        XCTAssertEqual(viewModel.ui.composer.focusRequest?.tabID, createdTabID)
        XCTAssertEqual(fixture.composeTabIDs().count, capacity.softLimit, "Admission never overflows")
        XCTAssertFalse(fixture.composeTabIDs().contains(targetTabID))
        let stashed = try XCTUnwrap(fixture.stashedTabs().first { $0.tab.id == targetTabID })
        XCTAssertEqual(stashed.tab.activeAgentSessionID, capacity.targetSessionID)
        XCTAssertEqual(viewModel.tabDraftText[targetTabID], "Archived draft")
        XCTAssertNotNil(viewModel.reservedComposeTabIDs[targetTabID], "The committed operation keeps its reservation")
        XCTAssertEqual(viewModel.composeTabRemovalOperations.count, 1)
        let archived = try await viewModel.test_dataService.loadAgentSession(
            id: capacity.targetSessionID,
            for: fixture.workspace
        )
        XCTAssertNotNil(archived, "Stash never deletes the persisted session")

        // Other tabs stay removable while the archived target's cleanup is held.
        let fillerTabID = capacity.fillerTabIDs[0]
        await viewModel.deleteSession(tabID: fillerTabID)
        XCTAssertFalse(fixture.composeTabIDs().contains(fillerTabID))

        let blockedRestore = await fixture.promptManager.restoreStashedComposeTab(containingTabID: targetTabID)
        XCTAssertNil(blockedRestore, "Restore is refused while the reservation is held")
        XCTAssertFalse(fixture.composeTabIDs().contains(targetTabID))

        gate.release()
        try await waitUntil("owned cleanup finished") { viewModel.composeTabRemovalOperations.isEmpty }
        XCTAssertTrue(viewModel.reservedComposeTabIDs.isEmpty)

        let restored = await fixture.promptManager.restoreStashedComposeTab(containingTabID: targetTabID)
        XCTAssertEqual(restored?.id, targetTabID)
        XCTAssertTrue(fixture.composeTabIDs().contains(targetTabID))
        XCTAssertNotNil(viewModel.session(for: targetTabID, createIfNeeded: true))
    }

    func testDefaultCreationAndOptedInActiveTargetStashStillAwaitHeldCleanup() async throws {
        let capacity = try await makeCapacityFixture(windowID: 4431)
        let fixture = capacity.base
        let viewModel = fixture.viewModel
        let targetTabID = capacity.targetTabID
        let activeTarget = CreationResultBox()
        let firstGate = StaleResetGate()
        let secondGate = StaleResetGate()
        viewModel.test_composeTabRemovalPhaseTwoHook = { [firstGate, secondGate, activeTarget] held in
            if held.tabID == targetTabID {
                await firstGate.waitForRelease()
            } else if held.tabID == activeTarget.tabID {
                await secondGate.waitForRelease()
            }
        }
        defer {
            viewModel.test_composeTabRemovalPhaseTwoHook = nil
            firstGate.release()
            secondGate.release()
        }

        // Non-interactive creation keeps the existing wait on the owned cleanup.
        let creation = CreationResultBox()
        let creationTask = Task { @MainActor in
            creation.tabID = await viewModel.createAndActivateSessionTab()
            creation.finished = true
        }
        try await waitUntil("owned cleanup held") { firstGate.isWaiting }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(creation.finished, "Default creation waits for post-commit cleanup")
        firstGate.release()
        await creationTask.value
        let createdTabID = try XCTUnwrap(creation.tabID)
        XCTAssertTrue(viewModel.composeTabRemovalOperations.isEmpty)

        // Opting in does not defer a stash that activates a replacement tab.
        activeTarget.tabID = createdTabID
        let stash = CreationResultBox()
        let stashTask = Task { @MainActor in
            await fixture.promptManager.stashTab(
                createdTabID,
                cleanupWait: .deferEligibleInactiveAutoStashCleanup
            )
            stash.finished = true
        }
        try await waitUntil("active-target cleanup held") { secondGate.isWaiting }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(stash.finished, "An active-target stash waits even when deferral is requested")
        XCTAssertNotEqual(fixture.promptManager.activeComposeTabID, createdTabID)
        secondGate.release()
        await stashTask.value
        XCTAssertTrue(viewModel.composeTabRemovalOperations.isEmpty)
        XCTAssertTrue(viewModel.reservedComposeTabIDs.isEmpty)
    }

    func testVetoedCapacityStashRefusesCreationAndLeavesPriorSessionUntouched() async throws {
        let capacity = try await makeCapacityFixture(windowID: 4432)
        let fixture = capacity.base
        let viewModel = fixture.viewModel
        let targetTabID = capacity.targetTabID
        let priorParentSessionID = UUID()
        capacity.primary.parentSessionID = priorParentSessionID
        let tabIDsBefore = fixture.composeTabIDs()

        let replacement = AgentTabSession(tabID: targetTabID)
        viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = { [viewModel, replacement] held in
            guard held.tabID == targetTabID else { return }
            viewModel.test_installLiveSession(replacement)
        }
        defer { viewModel.test_composeTabsWillCloseBeforeFinalSaveHook = nil }

        let created = await viewModel.createAndActivateSessionTab(focusComposer: true)

        XCTAssertNil(created, "A vetoed stash frees no capacity, so creation is refused")
        XCTAssertEqual(fixture.composeTabIDs(), tabIDsBefore)
        XCTAssertEqual(fixture.promptManager.activeComposeTabID, fixture.primaryTabID)
        XCTAssertNil(viewModel.ui.composer.focusRequest)
        XCTAssertEqual(capacity.primary.parentSessionID, priorParentSessionID, "The prior session is never treated as fresh")
        XCTAssertEqual(capacity.primary.items.map(\.text), ["Primary history"])
        XCTAssertTrue(viewModel.sessions[targetTabID] === replacement)
        XCTAssertTrue(viewModel.reservedComposeTabIDs.isEmpty)
        XCTAssertTrue(viewModel.composeTabRemovalOperations.isEmpty)
    }

    func testWindowCloseDrainsDeferredCreationCleanupAndRefusesNewRemovalCommits() async throws {
        let capacity = try await makeCapacityFixture(windowID: 4433)
        let fixture = capacity.base
        let viewModel = fixture.viewModel
        let targetTabID = capacity.targetTabID
        let gate = StaleResetGate()
        viewModel.test_composeTabRemovalPhaseTwoHook = { [gate] held in
            guard held.tabID == targetTabID else { return }
            await gate.waitForRelease()
        }
        defer {
            viewModel.test_composeTabRemovalPhaseTwoHook = nil
            gate.release()
        }

        let creation = CreationResultBox()
        let creationTask = Task { @MainActor in
            creation.tabID = await viewModel.createAndActivateSessionTab(focusComposer: true)
            creation.finished = true
        }
        try await waitUntil("owned cleanup held") { gate.isWaiting }
        try await waitUntil("interactive creation returned") { creation.finished }
        await creationTask.value
        XCTAssertNotNil(creation.tabID)

        // A removal admitted and prepared before close begins must still be refused at the
        // synchronous commit once close is in progress.
        let lateTabID = capacity.fillerTabIDs[1]
        let lateAdmission = await viewModel.admitComposeTabRemoval(tabIDs: [lateTabID], reason: .close)
        let lateOperationID = try XCTUnwrap(lateAdmission)
        let latePrepared = await viewModel.prepareComposeTabRemoval(operationID: lateOperationID)
        XCTAssertTrue(latePrepared)

        let close = CreationResultBox()
        let closeTask = Task { @MainActor in
            await viewModel.prepareForWindowClose()
            close.finished = true
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(close.finished, "Window close waits for committed cleanup")

        let fillerTabID = capacity.fillerTabIDs[0]
        await fixture.promptManager.closeComposeTab(fillerTabID)
        XCTAssertTrue(fixture.composeTabIDs().contains(fillerTabID), "No removal commits after close begins")
        XCTAssertEqual(Set(viewModel.reservedComposeTabIDs.keys), [targetTabID, lateTabID])

        let lateMutation = CreationResultBox()
        let lateCommitted = viewModel.commitComposeTabRemoval(
            operationID: lateOperationID,
            promptMutation: {
                lateMutation.finished = true
                return true
            },
            promptCleanup: { _ in }
        )
        XCTAssertFalse(lateCommitted, "A prepared removal cannot commit after close begins")
        XCTAssertFalse(lateMutation.finished, "The refused commit never mutates Prompt")
        XCTAssertTrue(fixture.composeTabIDs().contains(lateTabID))
        viewModel.finalizeComposeTabRemoval(operationID: lateOperationID)
        XCTAssertNil(viewModel.reservedComposeTabIDs[lateTabID])
        XCTAssertEqual(Set(viewModel.reservedComposeTabIDs.keys), [targetTabID])

        gate.release()
        await closeTask.value
        XCTAssertTrue(close.finished)
        XCTAssertTrue(viewModel.composeTabRemovalOperations.isEmpty)
        XCTAssertTrue(viewModel.reservedComposeTabIDs.isEmpty)
    }

    func testAwaitedInteractiveCreationAdmitsAfterProvenStashDespiteConcurrentBackgroundCreation() async throws {
        let capacity = try await makeCapacityFixture(windowID: 4436)
        let fixture = capacity.base
        let viewModel = fixture.viewModel
        let targetTabID = capacity.targetTabID
        let gate = StaleResetGate()
        viewModel.test_composeTabRemovalPhaseTwoHook = { [gate] held in
            guard held.tabID == targetTabID else { return }
            await gate.waitForRelease()
        }
        defer {
            viewModel.test_composeTabRemovalPhaseTwoHook = nil
            gate.release()
        }

        let creation = CreationResultBox()
        let creationTask = Task { @MainActor in
            creation.tabID = await viewModel.createAndActivateSessionTab(focusComposer: false)
            creation.finished = true
        }
        try await waitUntil("owned cleanup held") { gate.isWaiting }
        XCTAssertFalse(creation.finished)
        XCTAssertEqual(fixture.composeTabIDs().count, capacity.softLimit - 1)

        // A background creation lands in the freed slot while the UI creation awaits cleanup.
        let backgroundTab = await fixture.promptManager.createBackgroundComposeTab(
            strategy: .blank,
            name: "Concurrent background",
            capacityPolicy: .mcpBackgroundAgent
        )
        let backgroundTabID = try XCTUnwrap(backgroundTab?.id)
        XCTAssertEqual(fixture.composeTabIDs().count, capacity.softLimit)

        gate.release()
        await creationTask.value
        let createdTabID = try XCTUnwrap(creation.tabID, "Proven removal admits the UI creation")
        let tabIDs = fixture.composeTabIDs()
        XCTAssertTrue(tabIDs.contains(createdTabID))
        XCTAssertTrue(tabIDs.contains(backgroundTabID))
        XCTAssertFalse(tabIDs.contains(targetTabID))
        XCTAssertEqual(tabIDs.count, capacity.softLimit + 1)
    }

    func testInteractiveCreationInOverLimitWorkspaceKeepsNetTabCount() async throws {
        let tabCount = Self.composeTabSoftLimit + 5
        let capacity = try await makeCapacityFixture(windowID: 4434, tabCount: tabCount)
        let fixture = capacity.base
        let viewModel = fixture.viewModel

        let created = await viewModel.createAndActivateSessionTab(focusComposer: true)

        let createdTabID = try XCTUnwrap(created, "An already over-limit workspace still admits one-out-one-in")
        XCTAssertEqual(fixture.promptManager.activeComposeTabID, createdTabID)
        XCTAssertEqual(fixture.composeTabIDs().count, tabCount)
        XCTAssertFalse(fixture.composeTabIDs().contains(capacity.targetTabID))
        XCTAssertTrue(fixture.stashedTabs().contains { $0.tab.id == capacity.targetTabID })
        try await waitUntil("owned cleanup finished") { viewModel.composeTabRemovalOperations.isEmpty }
        XCTAssertTrue(viewModel.reservedComposeTabIDs.isEmpty)
    }

    // MARK: - Cold-hydration save attribution (D2 characterization)

    /// Documents the CURRENT contract, not a desired one: a completed persisted session whose
    /// provider differs from the placeholder is cold-hydrated into a background tab. Its derived
    /// stamp keeps the placeholder run state/provider (hydration stamps before those restores), so
    /// the next background save rejects reuse and takes the persistence-only fallback, even though
    /// that fallback's production transforms reproduce the installed presentation exactly here.
    func testColdHydratedBackgroundSessionSaveReuseCharacterization() async throws {
        let owner = try await makeHarness(windowID: 4390)
        owner.session.selectedAgent = .openCode
        owner.session.appendItem(.user("Run the check"))
        let invocation = UUID()
        owner.session.appendItem(.toolCall(name: "bash", invocationID: invocation, argsJSON: #"{"command":"echo ok"}"#))
        owner.session.appendItem(.toolResult(name: "bash", invocationID: invocation, resultJSON: #"{"output":"ok"}"#))
        owner.session.appendItem(.assistant("Done"))
        owner.session.runState = .completed
        let ownerSaved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(ownerSaved)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        let persisted = try await owner.persistedSession()
        XCTAssertEqual(persisted.lastRunState, AgentSessionRunState.completed.rawValue)
        XCTAssertEqual(persisted.agentKind, AgentProviderKind.openCode.rawValue)
        let persistedSequence = try XCTUnwrap(persisted.transcript?.nextSequenceIndex)

        // Another owner stays active in the peer window; the bound tab hydrates in the background.
        let peer = try await makeHarness(windowID: 4391, workspace: owner.workspace, storageURL: owner.storageURL)
        let backgroundTabID = UUID()
        let background = try XCTUnwrap(peer.viewModel.session(for: backgroundTabID, createIfNeeded: true))
        let placeholder = (agent: background.selectedAgent, run: background.runState)
        XCTAssertNotEqual(placeholder.agent, .openCode)
        XCTAssertEqual(placeholder.run, .idle)
        let peerBoundAgent = peer.viewModel.selectedAgent
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: background))
        let hydrated = await peer.viewModel.test_hydrateBoundSession(tabID: backgroundTabID)
        XCTAssertTrue(hydrated === background)
        XCTAssertEqual(background.persistedLoadDisposition, .applied)
        XCTAssertTrue(background.hasLoadedPersistedState)
        XCTAssertEqual(background.activeAgentSessionID, sessionID)
        // Non-active-owner branch fixture, not a UI-activation regression: `currentTabID` is pinned
        // by the harness override. The peer's owner object and its published agent binding stay put.
        XCTAssertEqual(peer.viewModel.currentTabID, peer.tabID)
        XCTAssertTrue(peer.viewModel.session(for: peer.tabID, createIfNeeded: false) === peer.session)
        XCTAssertEqual(peer.viewModel.selectedAgent, peerBoundAgent)
        XCTAssertEqual(background.selectedAgent, .openCode)
        XCTAssertEqual(background.runState, .completed)
        XCTAssertEqual(background.nextSequenceIndex, persistedSequence)

        let protection = peer.viewModel.transcriptProjectionProtection(for: background, transcript: background.transcript)
        let current = AgentDerivedTranscriptSyncState(
            sourceItemsRevision: background.sourceItemsRevision,
            nextSequenceIndex: background.nextSequenceIndex,
            runState: background.runState,
            selectedAgent: background.selectedAgent,
            hidePendingQuestionToolCall: background.hasPendingQuestionUI,
            projectionProtection: protection
        )
        let delta = AgentDerivedTranscriptSyncState.diagnosticDeltaLabel(
            from: background.derivedTranscriptSyncState,
            to: current
        )
        let stamp = try XCTUnwrap(background.derivedTranscriptSyncState)
        XCTAssertEqual(stamp.runState, placeholder.run)
        // The normalized persisted provider is installed before hydration stamps; run state is not.
        XCTAssertEqual(stamp.selectedAgent, .openCode)
        XCTAssertEqual(delta, "syncDelta.run", "provider, sequence, revision, ask and protection already match")
        XCTAssertFalse(peer.viewModel.canReuseDerivedTranscriptForSave(for: background, projectionProtection: protection))
        XCTAssertNil(background.pendingDerivedTranscriptRefreshReason)
        XCTAssertNil(background.derivedTranscriptRefreshTask)

        // Independent reference: transforms equivalent to the save fallback, on the final inputs
        // (no reuse-prefix hint; the real written record below covers the production path).
        let rebuilt = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
            existingTranscript: background.transcript,
            workingItems: background.items,
            terminalState: background.runState,
            nextSequenceIndex: background.nextSequenceIndex,
            policy: .liveSession(hidePendingQuestionToolCall: background.hasPendingQuestionUI),
            protection: protection
        )
        let sanitized = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            rebuilt,
            previousSanitizedTranscript: background.transcript,
            context: AgentToolResultProcessingContext(),
            purpose: .runtimePresentation
        ).transcript
        let reference = AgentTranscriptProjectionBuilder.refreshCompletedFullTurnGroupedHistoryCaches(in: sanitized)
        let referenceCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: reference)

        // The fallback makes no semantic correction for this case.
        XCTAssertEqual(reference, background.transcript)
        XCTAssertEqual(referenceCounts, background.transcriptProjectionCounts)
        XCTAssertEqual(referenceCounts.canonicalVisibleRowCount, background.transcriptCanonicalVisibleRowCount)
        XCTAssertEqual(
            AgentTranscriptIO.lastUserInteractionDate(in: reference),
            AgentTranscriptIO.lastUserInteractionDate(in: background.transcript)
        )

        let previousOverride = AgentModePerfDiagnostics.debugProcessOverrideEnabled
        AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(true)
        defer { AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(previousOverride) }
        background.isDirty = true
        let backgroundSaved = await peer.viewModel.flushSave(for: backgroundTabID)
        XCTAssertTrue(backgroundSaved)
        let backgroundTag = "tabID=\(AgentModePerfDiagnostics.shortID(backgroundTabID))"
        let fallbackLines = AgentModePerfDiagnostics.recentMetricLinesSnapshot(limit: 1000)
            .filter { $0.contains(" save.session.persistenceOnlySnapshot ") && $0.contains(backgroundTag) }
        XCTAssertEqual(fallbackLines.count, 1)
        XCTAssertTrue(
            fallbackLines.first?.split(separator: " ").contains("syncDelta=syncDelta.run") == true,
            "\(fallbackLines)"
        )

        // The record committed by the fallback save (production prefix hint and storage policy),
        // read through the writer's data service, is semantically equal to the pre-hydration record;
        // only save metadata may differ. This checks the logical save, not physical rewritten bytes.
        let writerLoaded = try await peer.viewModel.test_dataService.loadAgentSession(id: sessionID, for: peer.workspace)
        let resaved = try XCTUnwrap(writerLoaded)
        XCTAssertEqual(resaved.transcript, persisted.transcript)
        XCTAssertEqual(resaved.itemCount, persisted.itemCount)
        XCTAssertEqual(resaved.lastUserMessageAt, persisted.lastUserMessageAt)
    }

    /// A session persisted while running is cold-hydrated into a background tab of a peer window whose
    /// own owner stays active, so its save is not active-owned. The tab is reused: its placeholder still
    /// holds a previous `.completed` run state, which hydration stamps before installing the restored
    /// idle state (see `testColdHydratedBackgroundSessionSaveReuseCharacterization`). The stale stamp
    /// rejects presentation reuse with no refresh pending, so the save rebuilds through the non-active
    /// persistence-only snapshot (`persistableTranscriptSnapshot`) at idle. The cancelled turn and span
    /// survive in memory, in the saved file's bytes, and through a reload.
    func testColdCancelledBackgroundSessionSaveKeepsCancelledTurnThroughPersistenceOnlySnapshot() async throws {
        let metricLines = try await assertColdCancelledBackgroundSessionSave(
            ownerWindowID: 4392,
            peerWindowID: 4393,
            placeholderRunState: .completed,
            endsWithUnmatchedToolCall: false
        )
        let fallbackLines = metricLines.filter { $0.contains(" save.session.persistenceOnlySnapshot ") }
        XCTAssertEqual(fallbackLines.count, 1, "The save took the non-active persistence-only snapshot: \(metricLines)")
        XCTAssertTrue(
            fallbackLines.first?.split(separator: " ").contains("syncDelta=syncDelta.run") == true,
            "\(fallbackLines)"
        )
        XCTAssertFalse(metricLines.contains { $0.contains(" save.session.localPendingToolRepair ") }, "\(metricLines)")
    }

    /// The same background save when the interrupted turn ends in a tool call without a result (bash
    /// was running at quit): the save's pending-tool repair converts that row in place as a non-active
    /// owner and refreshes the derived transcript (`.saveSession`), whose rebuild keeps the cancelled
    /// turn; the save then reuses that presentation.
    func testColdCancelledMidToolBackgroundSessionSaveKeepsCancelledTurnThroughPendingToolRepair() async throws {
        let metricLines = try await assertColdCancelledBackgroundSessionSave(
            ownerWindowID: 4394,
            peerWindowID: 4399,
            placeholderRunState: nil,
            endsWithUnmatchedToolCall: true
        )
        XCTAssertTrue(
            metricLines.contains {
                $0.contains(" save.session.localPendingToolRepair ") && $0.contains("activeOwned=false") && $0.contains("repairedCount=1")
            },
            "The save repaired the unmatched call as a non-active owner: \(metricLines)"
        )
        XCTAssertFalse(metricLines.contains { $0.contains(" save.session.persistenceOnlySnapshot ") }, "\(metricLines)")
    }

    /// Persists a two-turn OpenCode session at run state running, cold-hydrates it into a background tab
    /// of a peer window, saves that tab, and asserts the cancelled final turn and span in memory, in the
    /// saved bytes, and after a reload. Returns the save's DEBUG metric lines for the background tab.
    private func assertColdCancelledBackgroundSessionSave(
        ownerWindowID: Int,
        peerWindowID: Int,
        placeholderRunState: AgentSessionRunState?,
        endsWithUnmatchedToolCall: Bool
    ) async throws -> [String] {
        let owner = try await makeHarness(windowID: ownerWindowID)
        owner.session.selectedAgent = .openCode
        for turn in 0 ..< 2 {
            owner.session.appendItem(.user("Turn \(turn) request"))
            owner.session.appendItem(.assistant("Turn \(turn) reply"))
        }
        if endsWithUnmatchedToolCall {
            owner.session.appendItem(.toolCall(name: "bash", invocationID: UUID(), argsJSON: #"{"command":"sleep 60"}"#))
        }
        let lastRowID = try XCTUnwrap(owner.session.items.last?.id)
        owner.session.runState = .running
        let ownerSaved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(ownerSaved)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)
        let persisted = try await owner.persistedSession()
        // F-7: this same-launch read is a storage mutation, so the live owner's active run is kept as
        // saved; only the cold hydration below maps it to idle.
        XCTAssertEqual(persisted.lastRunState, AgentSessionRunState.running.rawValue, "A same-launch read keeps the saved active run")
        let fileURL = try XCTUnwrap(persisted.fileURL)

        // Another owner stays active in the peer window; the bound tab hydrates in the background.
        let peer = try await makeHarness(windowID: peerWindowID, workspace: owner.workspace, storageURL: owner.storageURL)
        let backgroundTabID = UUID()
        let background = try XCTUnwrap(peer.viewModel.session(for: backgroundTabID, createIfNeeded: true))
        if let placeholderRunState {
            background.runState = placeholderRunState
        }
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: background))
        let hydrated = await peer.viewModel.test_hydrateBoundSession(tabID: backgroundTabID)
        XCTAssertTrue(hydrated === background)
        XCTAssertEqual(background.persistedLoadDisposition, .applied)
        XCTAssertEqual(peer.viewModel.currentTabID, peer.tabID, "The background tab is not the active owner")
        XCTAssertFalse(peer.viewModel.canBuildOrPublishActiveTranscriptBindings(for: background))
        XCTAssertEqual(background.runState, .idle)
        let restoredTurn = try XCTUnwrap(background.transcript.turns.last)
        XCTAssertEqual(restoredTurn.terminalState, .cancelled)
        XCTAssertEqual(restoredTurn.responseSpans.map(\.lifecycle), [.cancelled])
        XCTAssertEqual(background.items.last?.id, lastRowID)
        XCTAssertEqual(background.items.last?.kind, endsWithUnmatchedToolCall ? .toolCall : .assistant)
        XCTAssertNil(background.pendingDerivedTranscriptRefreshReason)
        XCTAssertNil(background.derivedTranscriptRefreshTask)

        let previousOverride = AgentModePerfDiagnostics.debugProcessOverrideEnabled
        AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(true)
        defer { AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(previousOverride) }
        background.isDirty = true
        let backgroundSaved = await peer.viewModel.flushSave(for: backgroundTabID)
        await peer.viewModel.awaitInFlightSave(sessionID: sessionID)
        XCTAssertTrue(backgroundSaved)
        let backgroundTag = "tabID=\(AgentModePerfDiagnostics.shortID(backgroundTabID))"
        let metricLines = AgentModePerfDiagnostics.recentMetricLinesSnapshot(limit: 1000).filter { $0.contains(backgroundTag) }
        XCTAssertEqual(background.items.last?.id, lastRowID)
        if endsWithUnmatchedToolCall {
            XCTAssertEqual(background.items.last?.kind, .toolResult, "The repair converted the call in place")
        }

        func assertCancelled(_ transcript: AgentTranscript?, _ stage: String) throws {
            let turn = try XCTUnwrap(transcript?.turns.last, stage)
            XCTAssertEqual(turn.id, restoredTurn.id, stage)
            XCTAssertEqual(turn.terminalState, .cancelled, "\(stage): the interrupted turn stays cancelled")
            XCTAssertEqual(turn.responseSpans.map(\.lifecycle), [.cancelled], stage)
            XCTAssertTrue(turn.allActivities.contains { $0.id == lastRowID }, stage)
        }
        try assertCancelled(background.transcript, "in memory after save")
        let savedSession = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(savedSession.id, sessionID)
        XCTAssertEqual(savedSession.lastRunState, AgentSessionRunState.idle.rawValue)
        try assertCancelled(savedSession.transcript, "saved bytes")
        let reloaded = try await peer.viewModel.test_dataService.loadAgentSession(id: sessionID, for: peer.workspace)
        XCTAssertEqual(reloaded?.lastRunState, AgentSessionRunState.idle.rawValue)
        try assertCancelled(reloaded?.transcript, "reloaded")
        return metricLines
    }

    // MARK: - Full-save write diagnostics (lossless-restart Phase 0)

    /// `save.session.written` counts each successful full-session replacement exactly once, after the
    /// atomic writer returns; a clean (skipped) save and a writer failure count nothing, and a retry
    /// after the failure counts once.
    func testFullSessionWrittenDiagnosticCountsOnlyCommittedWrites() async throws {
        let previousOverride = AgentModePerfDiagnostics.debugProcessOverrideEnabled
        AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(true)
        defer { AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(previousOverride) }

        let owner = try await makeHarness(windowID: 4421)
        let baseline = Self.diagnosticsTabCounter("save.session.written", tabID: owner.tabID)
        owner.session.appendItem(.user("Counted prompt"))
        owner.session.appendItem(.assistant("Counted answer"))
        let saved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(saved)
        XCTAssertEqual(Self.diagnosticsTabCounter("save.session.written", tabID: owner.tabID), baseline + 1)
        let fields = try XCTUnwrap(Self.fullSessionWrittenEventFields(tabID: owner.tabID).last)
        XCTAssertEqual(fields["transcriptReset"], "false")
        XCTAssertGreaterThan(Int(fields["bytes"] ?? "") ?? 0, 0, "\(fields)")
        for key in ["duration", "prepare", "encode", "writerAwait"] {
            XCTAssertEqual(fields[key]?.hasSuffix("ms"), true, "\(key): \(fields)")
        }

        let skipped = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        XCTAssertEqual(skipped, .notWritten, "A clean session is skipped before the data service")
        XCTAssertEqual(Self.diagnosticsTabCounter("save.session.written", tabID: owner.tabID), baseline + 1)

        // A writer failure (read-only sessions folder) throws from the atomic writer: not counted.
        let persistedForPath = try await owner.persistedSession()
        let fileURL = try XCTUnwrap(persistedForPath.fileURL)
        let folderPath = fileURL.deletingLastPathComponent().path
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
        owner.session.appendItem(.user("Write fails"))
        let failed = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        XCTAssertEqual(failed, .notWritten)
        XCTAssertTrue(owner.session.isDirty)
        XCTAssertEqual(Self.diagnosticsTabCounter("save.session.written", tabID: owner.tabID), baseline + 1)

        try FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: folderPath)
        permissionsRestored = true
        let retried = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(retried)
        XCTAssertEqual(Self.diagnosticsTabCounter("save.session.written", tabID: owner.tabID), baseline + 2)
    }

    /// A committed peer reset counts once (marked `transcriptReset=true`); the owner's stale save,
    /// rejected by the reset-generation fence before encoding, counts nothing.
    func testFullSessionWrittenDiagnosticSkipsStaleResetRejection() async throws {
        let previousOverride = AgentModePerfDiagnostics.debugProcessOverrideEnabled
        AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(true)
        defer { AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(previousOverride) }

        let owner = try await makeHarness(windowID: 4422)
        owner.session.appendItem(.user("Pre-reset prompt"))
        owner.session.appendItem(.assistant("Pre-reset answer"))
        let ownerSaved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(ownerSaved)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)

        let peer = try await makeHarness(windowID: 4423, workspace: owner.workspace, storageURL: owner.storageURL)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        let peerBaseline = Self.diagnosticsTabCounter("save.session.written", tabID: peer.tabID)
        peer.viewModel.clearChat(tabID: peer.tabID)
        let resetSaved = await peer.viewModel.flushSave(for: peer.tabID)
        XCTAssertTrue(resetSaved)
        XCTAssertEqual(Self.diagnosticsTabCounter("save.session.written", tabID: peer.tabID), peerBaseline + 1)
        XCTAssertEqual(Self.fullSessionWrittenEventFields(tabID: peer.tabID).last?["transcriptReset"], "true")

        let ownerBaseline = Self.diagnosticsTabCounter("save.session.written", tabID: owner.tabID)
        owner.session.appendItem(.user("Sent after the peer reset"))
        let rejected = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        XCTAssertEqual(rejected, .notWritten)
        XCTAssertNotNil(owner.session.staleResetRecovery)
        XCTAssertEqual(Self.diagnosticsTabCounter("save.session.written", tabID: owner.tabID), ownerBaseline)
    }

    /// Phase 0 advisory fixture evidence, opt-in (about 14 s wall clock): a text-only stream delivers deltas every
    /// 100 ms for 12 s through the real 250 ms delta buffer, whose flushes mutate source items and
    /// re-arm the 1 s save debounce. Prints the observed save timeline (counter samples every ~100 ms;
    /// final-text observation polls every 10 ms). It asserts only that the final text eventually
    /// reaches the saved file; it never asserts that starvation occurs.
    func testRestartPhase0LongTextOnlyStreamSaveTimelineReport() async throws {
        try XCTSkipUnless(Self.restartSaveMetricsOptedIn, Self.restartSaveMetricsSkipMessage)
        let previousOverride = AgentModePerfDiagnostics.debugProcessOverrideEnabled
        AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(true)
        defer { AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(previousOverride) }

        let owner = try await makeHarness(windowID: 4424)
        owner.session.appendItem(.user("Stream a long answer"))
        let primed = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(primed)
        let persistedForPath = try await owner.persistedSession()
        let fileURL = try XCTUnwrap(persistedForPath.fileURL)

        func counter(_ key: String) -> Int {
            Self.diagnosticsTabCounter(key, tabID: owner.tabID)
        }
        let writtenBaseline = counter("save.session.written")
        let invokedBaseline = counter("save.session.invoked")
        let scheduleBaseline = counter("save.schedule")
        let replacedBaseline = counter("save.schedule.replaced")

        let streamSeconds: TimeInterval = 12
        let streamStart = Date()
        var chunkCount = 0
        var writeOffsetsDuringStream: [TimeInterval] = []
        var lastObservedWritten = writtenBaseline
        while Date().timeIntervalSince(streamStart) < streamSeconds {
            owner.viewModel.enqueueAssistantDelta("chunk-\(chunkCount) ", session: owner.session)
            chunkCount += 1
            try await Task.sleep(nanoseconds: 100_000_000)
            let written = counter("save.session.written")
            if written > lastObservedWritten {
                writeOffsetsDuringStream.append(Date().timeIntervalSince(streamStart))
                lastObservedWritten = written
            }
        }
        let streamEnd = Date()
        let finalToken = "chunk-\(chunkCount - 1) "
        let schedulesDuringStream = counter("save.schedule") - scheduleBaseline
        let replacedDuringStream = counter("save.schedule.replaced") - replacedBaseline
        let invokedDuringStream = counter("save.session.invoked") - invokedBaseline
        // A write between the last in-loop sample and here is not attributed to a stream offset.
        let writtenAfterLastSample = counter("save.session.written") - lastObservedWritten

        // Final-text persistence is the condition (satisfied immediately if a write already landed);
        // no save is forced, so the experiment is unchanged.
        try await waitUntil("final streamed text in the atomically replaced session file", timeout: 5) {
            (try? String(contentsOf: fileURL, encoding: .utf8))?.contains(finalToken) == true
        }
        let finalTextObservedAfterStreamEnd = Date().timeIntervalSince(streamEnd)
        let writtenThroughFinalText = counter("save.session.written") - writtenBaseline
        let savedText = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(owner.session.items.last?.text.hasSuffix(finalToken) == true)

        let boundaries = [0] + writeOffsetsDuringStream + [streamEnd.timeIntervalSince(streamStart)]
        let longestUnsaved = zip(boundaries, boundaries.dropFirst()).map { $1 - $0 }.max() ?? 0
        print(
            "[RestartPhase0] stream seconds=\(Self.format(streamSeconds)) chunks=\(chunkCount) deltaIntervalMS=100"
                + " saveSchedule=\(schedulesDuringStream) saveScheduleReplaced=\(replacedDuringStream)"
                + " saveInvoked=\(invokedDuringStream) writtenDuringStream=\(writeOffsetsDuringStream.count)"
                + " writeOffsetsS=\(writeOffsetsDuringStream.map { Self.format($0) })"
                + " longestUnsavedWindowS=\(Self.format(longestUnsaved))"
                + " writtenAfterLastSample=\(writtenAfterLastSample) writtenThroughFinalText=\(writtenThroughFinalText)"
                + " finalTextOnDiskObservedAfterStreamEndS=\(Self.format(finalTextObservedAfterStreamEnd))"
                + " finalBytes=\(savedText.utf8.count)"
        )
    }

    /// Phase 0 evidence, opt-in: full-save cost for one deterministic reference-size session through the real VM
    /// save, storage preparation, codec, and atomic writer (temporary storage only). Prints each
    /// repetition; no thresholds. `prepare`/`encode`/`writerAwait` run on the data-service actor, not
    /// the main actor; `measuredPhases` is their sum and excludes other data-service work (persistence
    /// gate wait, schedule-authority load, metadata-index upsert). `vmTotal` is the VM `save.session.complete` elapsed time from save entry: it
    /// includes suspension across the data-service await and index work, so it is not isolated
    /// main-actor cost.
    func testRestartPhase0LargeSessionSaveCostReport() async throws {
        try XCTSkipUnless(Self.restartSaveMetricsOptedIn, Self.restartSaveMetricsSkipMessage)
        let previousOverride = AgentModePerfDiagnostics.debugProcessOverrideEnabled
        AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(true)
        defer { AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(previousOverride) }

        let repetitions = 5
        // The spec's reference running-session size (about 1,500 source items).
        let targetItemCount = 1500
        let owner = try await makeHarness(windowID: 4425)
        // One source mutation installs the whole deterministic fixture (per-item appends would
        // measure fixture construction, not saves).
        var items: [AgentChatItem] = []
        var turn = 0
        while items.count + 4 <= targetItemCount {
            let invocationID = UUID()
            let base = items.count
            items.append(.user(
                "Turn \(turn) request. " + String(repeating: "Please inspect the module. ", count: 8),
                sequenceIndex: base
            ))
            items.append(.toolCall(
                name: "bash",
                invocationID: invocationID,
                argsJSON: #"{"command":"rg -n \"pattern\" Sources --max-count 40"}"#,
                sequenceIndex: base + 1
            ))
            items.append(.toolResult(
                name: "bash",
                invocationID: invocationID,
                resultJSON: #"{"output":""# + String(repeating: "Sources/File\(turn).swift:12: let value = compute() ", count: 30) + #""}"#,
                isError: false,
                sequenceIndex: base + 2
            ))
            items.append(.assistant(
                "Turn \(turn) reply. " + String(repeating: "The change keeps behavior identical. ", count: 20),
                sequenceIndex: base + 3
            ))
            turn += 1
        }
        let installStart = Date()
        owner.session.replaceItems(items)
        owner.session.nextSequenceIndex = items.count
        let installSeconds = Date().timeIntervalSince(installStart)
        let firstSaveStart = Date()
        let firstSaved = await owner.viewModel.flushSave(for: owner.tabID)
        let firstSaveSeconds = Date().timeIntervalSince(firstSaveStart)
        XCTAssertTrue(firstSaved)
        let firstWritten = Self.fullSessionWrittenEventFields(tabID: owner.tabID).last
        print(
            "[RestartPhase0] largeSessionFixture sourceItems=\(items.count) installS=\(Self.format(installSeconds, digits: 3))"
                + " firstSaveWallS=\(Self.format(firstSaveSeconds, digits: 3))"
                + " firstPersistedItemCount=\(firstWritten?["itemCount"] ?? "?") firstBytes=\(firstWritten?["bytes"] ?? "?")"
                + " firstMeasuredPhases=\(firstWritten?["duration"] ?? "?")"
        )
        for repetition in 0 ..< repetitions {
            owner.session.appendItem(.assistant("Repetition \(repetition) marker"))
            let wallStart = Date()
            let saved = await owner.viewModel.flushSave(for: owner.tabID)
            let wall = Date().timeIntervalSince(wallStart) * 1000
            XCTAssertTrue(saved)
            let written = try XCTUnwrap(Self.fullSessionWrittenEventFields(tabID: owner.tabID).last)
            let complete = Self.metricEventFields(named: "save.session.complete", tabID: owner.tabID).last
            print(
                "[RestartPhase0] largeSession sourceItems=\(items.count) persistedItemCount=\(written["itemCount"] ?? "?")"
                    + " turns=\(written["turnCount"] ?? "?") liveWorkingItems=\(owner.session.items.count) repetition=\(repetition)"
                    + " bytes=\(written["bytes"] ?? "?") prepare=\(written["prepare"] ?? "?")"
                    + " encode=\(written["encode"] ?? "?") writerAwait=\(written["writerAwait"] ?? "?")"
                    + " measuredPhases=\(written["duration"] ?? "?")"
                    + " vmTotal=\(complete?["duration"] ?? "?") flushWall=\(Self.format(wall / 1000, digits: 4))s"
            )
        }
    }

    /// Reuses the existing conductor-forwarded scale gate; no new opt-in mechanism.
    private static var restartSaveMetricsOptedIn: Bool {
        ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "1"
    }

    private static let restartSaveMetricsSkipMessage =
        "Lossless-restart Phase 0 save reports are opt-in advisory fixture evidence. Set RPCE_RUN_SCALE_TESTS=1."

    private static func diagnosticsTabCounter(_ key: String, tabID: UUID) -> Int {
        let counters = AgentModePerfDiagnostics.debugStateSnapshot(lineLimit: 1)["counters"] as? [String: Int] ?? [:]
        return counters["\(key).tab.\(tabID.uuidString)"] ?? 0
    }

    private static func fullSessionWrittenEventFields(tabID: UUID) -> [[String: String]] {
        metricEventFields(named: "save.session.written", tabID: tabID)
    }

    private static func metricEventFields(named name: String, tabID: UUID) -> [[String: String]] {
        let tabTag = "tabID=\(AgentModePerfDiagnostics.shortID(tabID))"
        return AgentModePerfDiagnostics.recentMetricLinesSnapshot(limit: 1000)
            .filter { $0.contains(" \(name) ") && $0.contains(tabTag) }
            .map { line in
                let pairs = line.split(separator: " ").compactMap { token -> (String, String)? in
                    let parts = token.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    return (String(parts[0]), String(parts[1]))
                }
                return Dictionary(pairs, uniquingKeysWith: { _, new in new })
            }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        format(seconds, digits: 2)
    }

    private static func format(_ seconds: TimeInterval, digits: Int) -> String {
        String(format: "%.\(digits)f", seconds)
    }

    // MARK: - Harness

    /// Mirrors `PromptViewModel.defaultComposeTabSoftLimit`, the interactive auto-stash threshold.
    private static let composeTabSoftLimit = 50

    private struct CapacityFixture {
        let base: PromptManagedFixture
        let softLimit: Int
        let primary: AgentTabSession
        /// Least recently used inactive tab with persisted history: the auto-stash target.
        let targetTabID: UUID
        let targetSessionID: UUID
        let fillerTabIDs: [UUID]
    }

    /// The Prompt-managed fixture filled to the interactive soft limit, with the active primary
    /// tab holding history (not a placeholder) and `extraTabIDs[0]` as the deterministic target.
    private func makeCapacityFixture(
        windowID: Int,
        tabCount: Int = AgentStaleResetOwnershipTests.composeTabSoftLimit
    ) async throws -> CapacityFixture {
        let fixture = try await makePromptManagedFixture(windowID: windowID)
        let viewModel = fixture.viewModel
        let softLimit = Self.composeTabSoftLimit
        let targetTabID = fixture.extraTabIDs[0]
        let index = try XCTUnwrap(fixture.workspaceManager.workspaces.firstIndex { $0.id == fixture.workspace.id })
        let targetIndex = try XCTUnwrap(
            fixture.workspaceManager.workspaces[index].composeTabs.firstIndex { $0.id == targetTabID }
        )
        fixture.workspaceManager.workspaces[index].composeTabs[targetIndex].lastModified = .distantPast
        // Pin every other inactive tab so auto-stash priority selects the target first even
        // after binding its session marks it dirty.
        for tabIndex in fixture.workspaceManager.workspaces[index].composeTabs.indices
            where ![targetTabID, fixture.primaryTabID].contains(fixture.workspaceManager.workspaces[index].composeTabs[tabIndex].id)
        {
            fixture.workspaceManager.workspaces[index].composeTabs[tabIndex].isPinned = true
        }
        let fillerCount = tabCount - fixture.workspaceManager.workspaces[index].composeTabs.count
        let fillers = (0 ..< fillerCount).map { ComposeTabState(id: UUID(), name: "Filler \($0)", isPinned: true) }
        fixture.workspaceManager.workspaces[index].composeTabs.append(contentsOf: fillers)
        fixture.promptManager.loadComposeTabsFromWorkspace(fixture.workspaceManager.workspaces[index])

        let primary = try await viewModel.ensureSessionReady(tabID: fixture.primaryTabID)
        primary.appendItem(.user("Primary history"))
        let primarySaved = await viewModel.flushSave(for: fixture.primaryTabID)
        XCTAssertTrue(primarySaved)
        let target = try await viewModel.ensureSessionReady(tabID: targetTabID)
        target.appendItem(.user("Archived history"))
        let targetSaved = await viewModel.flushSave(for: targetTabID)
        XCTAssertTrue(targetSaved)
        let targetSessionID = try XCTUnwrap(target.activeAgentSessionID)
        viewModel.tabDraftText[targetTabID] = "Archived draft"

        viewModel.test_setCurrentTabIDOverride(nil)
        XCTAssertEqual(viewModel.currentTabID, fixture.primaryTabID)
        XCTAssertEqual(fixture.composeTabIDs().count, tabCount)
        return CapacityFixture(
            base: fixture,
            softLimit: softLimit,
            primary: primary,
            targetTabID: targetTabID,
            targetSessionID: targetSessionID,
            fillerTabIDs: fillers.map(\.id)
        )
    }

    func testDeletedSessionCleanupNeverRemovesAReplacementInstalledDuringItsTeardown() async throws {
        let fixture = try await makePromptManagedFixture(windowID: 4391)
        let viewModel = fixture.viewModel
        let workspaceManager = fixture.workspaceManager
        let workspaceID = fixture.workspace.id
        let tabID = fixture.primaryTabID

        // Crash-window state: the session is durably deleted, the tab is still bound to it.
        let deletedID = UUID()
        _ = try await viewModel.test_dataService.saveAgentSession(
            AgentSession(id: deletedID, workspaceID: workspaceID, name: "Deleted elsewhere"),
            for: fixture.workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        try await viewModel.test_dataService.deleteAgentSession(id: deletedID, for: fixture.workspace)
        let old = try await viewModel.ensureSessionReady(tabID: tabID)
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: deletedID, on: old, updateWorkspaceMetadata: true))
        XCTAssertEqual(workspaceManager.activeAgentSessionID(forTabID: tabID, inWorkspaceID: workspaceID), deletedID)

        // Held at the awaited-teardown boundary: a replacement owner with a fresh UUID and dirty
        // content is installed on the same tab, then the old cleanup resumes.
        let box = ReplacementOwnerBox()
        viewModel.test_deletedSessionTeardownHook = { [box] held in
            guard box.replacement == nil else { return }
            box.heldOwnerWasOld = held === old
            box.ownerDetachedBeforeTeardown = viewModel.sessions[tabID] == nil
            box.durableBindingCleared = workspaceManager.activeAgentSessionID(forTabID: tabID, inWorkspaceID: workspaceID) == nil
            guard let fresh = try? await viewModel.ensureSessionReady(tabID: tabID) else { return }
            box.replacement = fresh
            box.replacementID = viewModel.ensureSessionBoundToTab(fresh)
            fresh.appendItem(.user("replacement content"))
            fresh.isDirty = true
        }
        await viewModel.finalizeDeletedAgentSessionReferences(
            sessionID: deletedID,
            workspaceID: workspaceID,
            reason: "restored_deleted_binding"
        )
        viewModel.test_deletedSessionTeardownHook = nil

        XCTAssertTrue(box.heldOwnerWasOld, "Only the captured owner is torn down")
        XCTAssertTrue(box.ownerDetachedBeforeTeardown, "The old owner leaves the tab before any awaited teardown")
        XCTAssertTrue(box.durableBindingCleared, "The durable workspace binding to the deleted UUID is cleared")
        let replacement = try XCTUnwrap(box.replacement)
        let replacementID = try XCTUnwrap(box.replacementID)
        XCTAssertFalse(replacement === old)
        XCTAssertNotEqual(replacementID, deletedID)
        XCTAssertTrue(viewModel.sessions[tabID] === replacement, "The replacement owner remains installed")
        XCTAssertEqual(replacement.activeAgentSessionID, replacementID)
        XCTAssertEqual(
            workspaceManager.activeAgentSessionID(forTabID: tabID, inWorkspaceID: workspaceID),
            replacementID,
            "The old cleanup never clears the replacement's durable binding"
        )
        XCTAssertTrue(replacement.items.contains { $0.text == "replacement content" })
        let saved = await viewModel.flushSave(for: tabID)
        XCTAssertTrue(saved, "The replacement saves cleanly")
        let persisted = try await viewModel.test_dataService.loadAgentSession(id: replacementID, for: fixture.workspace)
        XCTAssertTrue(try XCTUnwrap(persisted).toLiveItems().contains { $0.text == "replacement content" })
        let deleted = try await viewModel.test_dataService.loadAgentSession(id: deletedID, for: fixture.workspace)
        XCTAssertNil(deleted, "The deleted session stays deleted")
    }

    private struct PromptManagedFixture {
        let viewModel: AgentModeViewModel
        let promptManager: PromptViewModel
        let workspaceManager: WorkspaceManagerViewModel
        let workspace: WorkspaceModel
        let storageURL: URL
        let primaryTabID: UUID
        /// Two further compose tabs to the right of `primaryTabID` (batch-removal targets).
        let extraTabIDs: [UUID]

        /// Compose tabs as stored on the workspace model (the source the removal path mutates).
        @MainActor
        func composeTabIDs() -> [UUID] {
            workspaceManager.workspaces.first { $0.id == workspace.id }?.composeTabs.map(\.id) ?? []
        }

        @MainActor
        func stashedTabs() -> [StashedTab] {
            workspaceManager.workspaces.first { $0.id == workspace.id }?.stashedTabs ?? []
        }
    }

    /// Real PromptViewModel + WorkspaceManagerViewModel with two compose tabs and the Agent VM's
    /// production lifecycle hooks installed, so removal runs through the actual stash/close path.
    private func makePromptManagedFixture(windowID: Int) async throws -> PromptManagedFixture {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentStaleResetOwnershipTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: storageURL)
        }
        let primaryTabID = UUID()
        // Removal operations process targets in tab-ID order; sort so `extraTabIDs[0]` is first.
        let extraTabIDs = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let workspace = WorkspaceModel(
            name: "Agent Stale Reset Disposal",
            repoPaths: [storageURL.path],
            customStoragePath: storageURL,
            ephemeralFlag: true,
            composeTabs: [
                ComposeTabState(id: primaryTabID, name: "Primary"),
                ComposeTabState(id: extraTabIDs[0], name: "Second"),
                ComposeTabState(id: extraTabIDs[1], name: "Third")
            ],
            activeComposeTabID: primaryTabID
        )
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager, mcpHost: ServerNetworkManager.shared, routingWaiter: .shared, codexAuthRecovery: CodexManagedAuthRecoveryService.shared, modelOverrides: AppModelOverrideReader(), ohMyPiConnectionState: { OhMyPiConnectionAvailability.isEffectivelyConnected() }),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let promptManager = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: windowID,
            settingsManager: WindowSettingsManager(windowID: windowID)
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: promptManager,
            performInitialWorkspaceActivation: false
        )
        promptManager.attachWorkspaceManager(workspaceManager)
        workspaceManager.workspaces = [workspace]
        workspaceManager.activeWorkspace = workspace
        promptManager.loadComposeTabsFromWorkspace(workspace)

        let viewModel = AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: storageURL.path,
            testWorkspaceDirectory: storageURL,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        viewModel.test_establishPersistenceWorkspace(workspace)
        viewModel.test_setSidebarAutoArchiveDependencies(promptManager: promptManager, workspaceManager: workspaceManager)
        viewModel.test_installPromptManagerLifecycleHooks()
        viewModel.test_setCurrentTabIDOverride(primaryTabID)
        return PromptManagedFixture(
            viewModel: viewModel,
            promptManager: promptManager,
            workspaceManager: workspaceManager,
            workspace: workspace,
            storageURL: storageURL,
            primaryTabID: primaryTabID,
            extraTabIDs: extraTabIDs
        )
    }

    private struct Harness {
        let viewModel: AgentModeViewModel
        let workspace: WorkspaceModel
        let storageURL: URL
        let tabID: UUID
        let session: AgentTabSession

        struct MissingPersistedSession: Error {}

        @MainActor
        func persistedSession() async throws -> AgentSession {
            guard let sessionID = session.activeAgentSessionID,
                  let persisted = try await viewModel.test_dataService.loadAgentSession(id: sessionID, for: workspace)
            else {
                throw MissingPersistedSession()
            }
            return persisted
        }
    }

    private struct RetainedFixture {
        let owner: Harness
        let peer: Harness
        let sessionID: UUID
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
                .appendingPathComponent("AgentStaleResetOwnershipTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: storageURL)
            }
        }
        let workspace = existingWorkspace ?? WorkspaceModel(
            name: "Agent Stale Reset Ownership",
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
        return Harness(
            viewModel: viewModel,
            workspace: workspace,
            storageURL: storageURL,
            tabID: tabID,
            session: session
        )
    }

    /// Owner with persisted history; a peer commits a reset; the owner's next save is rejected
    /// and the recovery settles into `.retained` (no active run in this fixture).
    private func makeRetainedFixture(ownerWindowID: Int, peerWindowID: Int) async throws -> RetainedFixture {
        let owner = try await makeHarness(windowID: ownerWindowID)
        owner.session.appendItem(.user("Pre-reset prompt"))
        owner.session.appendItem(.assistant("Pre-reset answer"))
        let saved = await owner.viewModel.flushSave(for: owner.tabID)
        XCTAssertTrue(saved)
        let sessionID = try XCTUnwrap(owner.session.activeAgentSessionID)

        let peer = try await makeHarness(windowID: peerWindowID, workspace: owner.workspace, storageURL: owner.storageURL)
        XCTAssertNotNil(peer.viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: peer.session))
        _ = await peer.viewModel.test_hydrateBoundSession(tabID: peer.tabID)
        peer.viewModel.clearChat(tabID: peer.tabID)
        let resetSaved = await peer.viewModel.flushSave(for: peer.tabID)
        XCTAssertTrue(resetSaved)

        owner.session.appendItem(.user("Sent after the peer reset"))
        let rejected = await owner.viewModel.flushSaveDetailed(for: owner.tabID)
        XCTAssertEqual(rejected, .notWritten)
        XCTAssertNotNil(owner.session.staleResetRecovery)
        try await waitUntil("stop settled into retained") {
            if case .retained(problem: nil) = owner.session.staleResetRecovery?.phase { return true }
            return false
        }
        return RetainedFixture(owner: owner, peer: peer, sessionID: sessionID)
    }

    private func makeManagedAttachmentFile(in workspaceDirectory: URL, name: String) throws -> URL {
        let storageRoot = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let fileURL = storageRoot.appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)
        return fileURL
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                throw StaleResetWaitTimeout()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct StaleResetWaitTimeout: Error {}

/// Holds an asynchronous boundary (owned terminal-resource teardown) until the test releases it.
@MainActor
private final class StaleResetGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isWaiting = false

    func waitForRelease() async {
        if released { return }
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class CreationResultBox {
    var finished = false
    var tabID: UUID?
}

@MainActor
private final class ReplacementOwnerBox {
    var replacement: AgentTabSession?
    var replacementID: UUID?
    var heldOwnerWasOld = false
    var ownerDetachedBeforeTeardown = false
    var durableBindingCleared = false
}

@MainActor
private final class DiscardRequestRecorder {
    var requests: [AgentModeViewModel.AgentStaleResetDiscardRequest] = []
}
