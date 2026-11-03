import Foundation
import RepoPromptAgentCore

// MARK: - Stale transcript-reset recovery (stop-and-retain + explicitly confirmed paired reload)

//
// A committed peer transcript reset invalidates this owner's editable history: its full save is
// rejected with `staleTranscriptResetGeneration`. The owner then
//   1. retains its complete local working view in memory (the `TabSession` is the container; no
//      copy, no fresh stamp for rejected history, `isDirty` stays true),
//   2. drops save authority (`persistenceState == nil`, `hasLoadedPersistedState == false`),
//   3. stops the active run once through the ordinary cancellation/terminal lifecycle
//      (`cancelAgentRun(completion: .terminalTeardownCompleted)` flushes buffered assistant output,
//      finalizes streaming items, drains provider buffers and awaits teardown),
//   4. refuses new work at the backend admission points (submission, run start, reset, schedule
//      admission, rebinding) and asks before any lifecycle operation would discard the view, and
//   5. replaces the view only through an explicit, confirmed "Reload latest…" whose replacement
//      permit (item revision, mutation generation, quiescence, same lifetime stamp, covering reset
//      generation) is re-validated at apply time. Read failures leave the retained work untouched
//      and expose a retry; nothing retries automatically.
// Unsent composer text and pending attachments are never part of the discarded view.

extension AgentModeViewModel {
    static let staleResetRecoveryBlockedMessage =
        "This conversation was reset in another window. Use “Reload latest…” to replace the local view before sending again."
    static let staleResetRecoveryStopProblemMessage =
        "The running agent could not be stopped yet. Retry stopping before reloading."
    static let staleResetRecoveryReadFailedMessage =
        "The saved session could not be read. Your local conversation is unchanged; try reloading again."
    static let staleResetRecoveryMissingFileMessage =
        "The saved session file is missing. Your local conversation is unchanged; try reloading once it is restored."
    static let staleResetRecoveryChangedMessage =
        "The conversation changed while reloading. Your local conversation is unchanged; confirm the reload again."
    static let staleResetRecoveryReloadInProgressMessage =
        "A reload is already in progress."
    static let staleResetRecoveryGoneMessage =
        "This conversation is no longer awaiting a reload."

    /// Tabs whose retained local conversation cannot be saved (sorted for stable presentation).
    var staleResetRecoveryTabIDs: [UUID] {
        sessions.values
            .filter { $0.staleResetRecovery != nil }
            .map(\.tabID)
            .sorted { $0.uuidString < $1.uuidString }
    }

    static let composeTabRemovalInProgressMessage =
        "This tab is being closed."

    /// Backend admission predicate: no provider work, reset, or rebinding while recovery owns the
    /// view or while an admitted removal operation has reserved the owner.
    func staleResetRecoveryBlocksNewWork(_ session: AgentTabSession) -> Bool {
        newWorkBlockedMessage(for: session) != nil
    }

    /// User-facing reason new work is refused for `session`, or `nil` when it is admissible.
    func newWorkBlockedMessage(for session: AgentTabSession) -> String? {
        if session.staleResetRecovery != nil {
            return Self.staleResetRecoveryBlockedMessage
        }
        if reservedComposeTabIDs[session.tabID] != nil
            || session.staleResetRemovalAdmission?.isReserved == true
        {
            return Self.composeTabRemovalInProgressMessage
        }
        return nil
    }

    func staleResetRecoveryProps(for session: AgentTabSession) -> AgentStaleResetRecoveryProps? {
        guard let recovery = session.staleResetRecovery else { return nil }
        switch recovery.phase {
        case let .stopping(problem):
            return AgentStaleResetRecoveryProps(tabID: session.tabID, recoveryID: recovery.id, status: .stopping, problem: problem)
        case let .retained(problem):
            return AgentStaleResetRecoveryProps(tabID: session.tabID, recoveryID: recovery.id, status: .retained, problem: problem)
        case .reloading:
            return AgentStaleResetRecoveryProps(tabID: session.tabID, recoveryID: recovery.id, status: .reloading, problem: nil)
        }
    }

    // MARK: - Entry (owner-fenced)

    /// A full save issued by `saveToken`'s exact owner was rejected because a peer committed a
    /// transcript reset (`reportedResetGeneration`). Enters recovery only for that captured owner,
    /// never for a tab that was rebound (A→B or A→B→A), moved workspaces, was revoked, or already
    /// holds authority covering the reported reset; duplicate failures for an existing episode
    /// never restart the stop or replace its identity. Every mutation here precedes the first
    /// suspension.
    func handleStaleTranscriptResetForOwner(
        _ session: AgentTabSession,
        saveToken: SessionSaveCommitToken,
        submittedState: AgentSessionPersistenceState,
        reportedResetGeneration: UInt64
    ) {
        let sessionID = saveToken.binding.sessionID
        guard sessions[saveToken.tabID] === session,
              ObjectIdentifier(session) == saveToken.sessionIdentity,
              session.persistentSessionBindingIdentity == saveToken.binding,
              session.bindingTransitionGeneration == saveToken.bindingTransitionGeneration,
              !session.bindingTransitionInProgress,
              persistenceWorkspace?.id == saveToken.workspaceID,
              workspaceManager?.isSwitchingWorkspace != true,
              saveToken.workspaceOwner.map(sessionIndexStore.isOwnerCurrent) ?? (workspaceManager == nil),
              session.persistenceRevokedSessionID != sessionID
        else {
            #if DEBUG
                AgentModePerfDiagnostics.event(
                    "staleReset.ignored",
                    tabID: saveToken.tabID,
                    fields: ["sessionID": sessionID.uuidString, "reason": "ownerChanged"]
                )
            #endif
            return
        }
        if session.staleResetRecovery != nil {
            #if DEBUG
                AgentModePerfDiagnostics.event(
                    "staleReset.ignored",
                    tabID: session.tabID,
                    fields: ["sessionID": sessionID.uuidString, "reason": "duplicateFailure"]
                )
            #endif
            return
        }
        if let current = session.persistenceState(for: sessionID),
           current != submittedState,
           current.transcriptResetGeneration >= reportedResetGeneration
        {
            // Obsolete: this owner already adopted paired state covering the reported reset.
            return
        }

        let recovery = AgentStaleResetRecovery(
            id: UUID(),
            tabID: session.tabID,
            sessionIdentity: ObjectIdentifier(session),
            binding: saveToken.binding,
            bindingTransitionGeneration: saveToken.bindingTransitionGeneration,
            workspaceID: saveToken.workspaceID,
            workspaceOwner: saveToken.workspaceOwner,
            rejectedPersistenceState: submittedState,
            observedResetGeneration: reportedResetGeneration,
            phase: .stopping(problem: nil)
        )
        session.staleResetRecovery = recovery
        session.saveDebounceTask?.cancel()
        session.saveDebounceTask = nil
        cancelPersistedLoad(for: session)
        // Authority is dropped; the incarnation ID is kept so no creation path can ever target it.
        session.persistenceState = nil
        recoveryPersistenceStateDidChange(for: session)
        session.clearCurrentBindingHydration()
        session.hasLoadedPersistedState = false
        session.isDirty = true
        #if DEBUG
            AgentModePerfDiagnostics.event(
                "staleReset.entered",
                tabID: session.tabID,
                fields: [
                    "sessionID": sessionID.uuidString,
                    "recoveryID": recovery.id.uuidString,
                    "reportedResetGeneration": String(reportedResetGeneration)
                ]
            )
        #endif
        publishStaleResetRecoveryState(for: session)

        let tabID = session.tabID
        let recoveryID = recovery.id
        session.staleResetRecoveryTask = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await performStaleResetRecoveryStop(tabID: tabID, recoveryID: recoveryID)
        }
    }

    private func staleResetRecoveryOwnerIsCurrent(_ recovery: AgentStaleResetRecovery, session: AgentTabSession) -> Bool {
        sessions[recovery.tabID] === session
            && ObjectIdentifier(session) == recovery.sessionIdentity
            && session.staleResetRecovery?.id == recovery.id
            && session.persistentSessionBindingIdentity == recovery.binding
            && session.bindingTransitionGeneration == recovery.bindingTransitionGeneration
            && !session.bindingTransitionInProgress
            && persistenceWorkspace?.id == recovery.workspaceID
            && workspaceManager?.isSwitchingWorkspace != true
            && (recovery.workspaceOwner.map(sessionIndexStore.isOwnerCurrent) ?? (workspaceManager == nil))
            && session.persistenceRevokedSessionID != recovery.binding.sessionID
    }

    func publishStaleResetRecoveryState(for session: AgentTabSession) {
        syncComposerUIState(tabID: session.tabID)
        if session.tabID == currentTabID {
            updateBindingsFromSession(session)
        }
        requestUIRefresh(tabID: session.tabID, urgent: true)
        notifyScheduledSendBusyStateMayHaveChanged(tabIDs: [session.tabID])
    }

    /// Run-state publications may refresh the recovery notice; they never launch hydration.
    func refreshStaleResetRecoveryPresentationIfNeeded(for session: AgentTabSession) {
        guard session.staleResetRecovery != nil else { return }
        syncComposerUIState(tabID: session.tabID)
    }

    // MARK: - Stop (one attempt per entry / explicit retry)

    /// Everything that could still mutate this owner's transcript through the run lifecycle must
    /// have settled: run state inactive, run bookkeeping released, no run attempt, no terminal
    /// commit in progress, no buffered assistant output, no run task, and — for remote-host
    /// projections — no live attachment delivering events into the tab (the attachment is retired
    /// through the coordinator's stop lifecycle, which advances the tab's delivery generation so a
    /// delayed delivery from the old attachment is dropped even after a confirmed replacement).
    func staleResetRecoveryIngestionIsQuiescent(_ session: AgentTabSession) -> Bool {
        !session.runState.isActive
            && !isTabRunning(session.tabID)
            && session.activeRunOwnership == nil
            && !session.terminalCommitInProgress
            && session.pendingAssistantDelta.isEmpty
            && session.agentTask == nil
            && (session.remoteHost == nil || !remoteCoordinator.isAttached(tabID: session.tabID))
    }

    /// Remote-host projections: an *active* mirrored run is cancelled best-effort through the
    /// attached controller (the same condition the ordinary lifecycle uses; an inactive
    /// projection never issues a host command, so a stalled transport cannot block retirement),
    /// never appending an error bubble to the retained view. The attachment is then detached
    /// through the existing stop lifecycle, which cancels the event task, unsubscribes, and
    /// advances the tab's delivery generation — that detachment, not the host cancel, is what
    /// retires ingestion. The mirrored run state of the now-detached projection is frozen as
    /// cancelled locally.
    func retireRemoteIngestion(for session: AgentTabSession) async {
        let tabID = session.tabID
        if session.runState.isActive, remoteCoordinator.isAttached(tabID: tabID) {
            try? await remoteCoordinator.cancel(session: session)
        }
        guard sessions[tabID] === session else { return }
        cancelPendingInstruction(for: session)
        remoteCoordinator.stop(tabID: tabID)
        if session.runState.isActive {
            session.runState = .cancelled
        }
        setAgentRunActive(tabID, isActive: false)
        session.runID = nil
    }

    private func performStaleResetRecoveryStop(tabID: UUID, recoveryID: UUID) async {
        guard let session = sessions[tabID],
              let recovery = session.staleResetRecovery,
              recovery.id == recoveryID,
              staleResetRecoveryOwnerIsCurrent(recovery, session: session),
              case .stopping = recovery.phase
        else { return }
        if session.remoteHost != nil {
            await retireRemoteIngestion(for: session)
        } else if session.runState.isActive || isTabRunning(tabID) || session.activeRunOwnership != nil || session.terminalCommitInProgress {
            // The terminal commit flushes buffered assistant output into the retained view,
            // finalizes streaming items and pending tool calls, drains provider buffers, and the
            // completion awaits the registered teardown of the run attempt's resources.
            await cancelAgentRun(tabID: tabID, cause: .ordinary, completion: .terminalTeardownCompleted)
        }
        guard let afterCancel = session.staleResetRecovery,
              afterCancel.id == recoveryID,
              staleResetRecoveryOwnerIsCurrent(afterCancel, session: session),
              case .stopping = afterCancel.phase
        else { return }
        // Buffered output that no terminal commit consumed (remote projections, already-inactive
        // runs) is committed to the retained view rather than discarded.
        session.drainPendingAssistantDelta()
        var registrationActive = false
        if let sessionID = session.activeAgentSessionID {
            registrationActive = await AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)
        }
        guard let settled = session.staleResetRecovery,
              settled.id == recoveryID,
              staleResetRecoveryOwnerIsCurrent(settled, session: session),
              case .stopping = settled.phase
        else { return }
        var updated = settled
        if staleResetRecoveryIngestionIsQuiescent(session), !registrationActive {
            updated.phase = .retained(problem: nil)
        } else {
            updated.phase = .stopping(problem: Self.staleResetRecoveryStopProblemMessage)
        }
        session.staleResetRecovery = updated
        session.staleResetRecoveryTask = nil
        #if DEBUG
            AgentModePerfDiagnostics.event(
                "staleReset.stopSettled",
                tabID: tabID,
                fields: ["recoveryID": recoveryID.uuidString, "retained": String(updated.phase == .retained(problem: nil))]
            )
        #endif
        publishStaleResetRecoveryState(for: session)
    }

    /// Banner action: one more stop attempt after a reported stop problem. Never automatic.
    func retryStaleResetRecoveryStop(tabID: UUID, recoveryID: UUID) async -> String? {
        guard let session = sessions[tabID],
              let recovery = session.staleResetRecovery,
              recovery.id == recoveryID
        else { return Self.staleResetRecoveryGoneMessage }
        guard case .stopping = recovery.phase, session.staleResetRecoveryTask == nil else {
            return nil
        }
        var restarted = recovery
        restarted.phase = .stopping(problem: nil)
        session.staleResetRecovery = restarted
        publishStaleResetRecoveryState(for: session)
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await performStaleResetRecoveryStop(tabID: tabID, recoveryID: recoveryID)
        }
        session.staleResetRecoveryTask = task
        await task.value
        guard sessions[tabID] === session else { return nil }
        return staleResetRecoveryProps(for: session)?.problem
    }

    // MARK: - Explicitly confirmed paired reload

    /// Banner action after the user confirmed that the local conversation will be replaced.
    /// Issues exactly one paired read through the ordinary loader under a captured replacement
    /// permit; the payload is applied only if that permit is still current at apply time. Any
    /// failure leaves the retained view untouched and reports why.
    func reloadLatestForStaleResetRecovery(tabID: UUID, recoveryID: UUID) async -> String? {
        guard let session = sessions[tabID],
              let recovery = session.staleResetRecovery,
              recovery.id == recoveryID,
              staleResetRecoveryOwnerIsCurrent(recovery, session: session)
        else { return Self.staleResetRecoveryGoneMessage }
        switch recovery.phase {
        case .stopping:
            return Self.staleResetRecoveryStopProblemMessage
        case .reloading:
            return Self.staleResetRecoveryReloadInProgressMessage
        case .retained:
            break
        }
        guard session.staleResetRecoveryTask == nil else { return Self.staleResetRecoveryReloadInProgressMessage }
        guard staleResetRecoveryIngestionIsQuiescent(session) else {
            var blocked = recovery
            blocked.phase = .stopping(problem: Self.staleResetRecoveryStopProblemMessage)
            session.staleResetRecovery = blocked
            publishStaleResetRecoveryState(for: session)
            return Self.staleResetRecoveryStopProblemMessage
        }

        let attemptID = UUID()
        let consent = AgentStaleResetRecovery.ConsentRevision(
            sourceItemsRevision: session.sourceItemsRevision,
            persistenceMutationGeneration: session.persistenceMutationGeneration
        )
        var reloading = recovery
        reloading.phase = .reloading(attemptID: attemptID, consent: consent)
        session.staleResetRecovery = reloading
        session.hasLoadedPersistedState = false
        publishStaleResetRecoveryState(for: session)

        // Operation-owned outcome: the confirmed read's own disposition, never session state.
        let outcomeBox = StaleResetReloadOutcomeBox()
        let task = Task<Void, Never> { @MainActor [weak self, outcomeBox] in
            guard let self else { return }
            outcomeBox.disposition = await loadSessionFromDisk(for: session, staleResetRecoveryAttemptID: attemptID).disposition
        }
        session.staleResetRecoveryTask = task
        await task.value
        guard sessions[tabID] === session else { return nil }
        if session.staleResetRecoveryTask == task {
            session.staleResetRecoveryTask = nil
        }
        guard let remaining = session.staleResetRecovery else {
            // The paired replacement committed (marker cleared inside `applyPersistedHydration`).
            publishStaleResetRecoveryState(for: session)
            syncSidebarUIState(refresh: true, reason: .sessionIndex)
            return nil
        }
        guard remaining.id == recoveryID else { return nil }
        let problem: String = switch outcomeBox.disposition {
        case .noPayload:
            Self.staleResetRecoveryMissingFileMessage
        case .failed:
            Self.staleResetRecoveryReadFailedMessage
        case .applied, .suppressed, .unbound, .unresolved:
            Self.staleResetRecoveryChangedMessage
        }
        var retained = remaining
        retained.phase = .retained(problem: problem)
        session.staleResetRecovery = retained
        publishStaleResetRecoveryState(for: session)
        return problem
    }

    /// Apply-time validation of the replacement permit for a recovery reload. Identity/ownership,
    /// the exact consent revisions, quiescence, and the persisted lifetime are all re-checked
    /// here, after the read and before the first destructive mutation.
    func staleResetRecoveryReplacementPermitIsCurrent(
        _ session: AgentTabSession,
        attemptID: UUID,
        payload: AgentSessionHydrationPayload
    ) -> Bool {
        guard let recovery = session.staleResetRecovery,
              staleResetRecoveryOwnerIsCurrent(recovery, session: session),
              case let .reloading(currentAttemptID, consent) = recovery.phase,
              currentAttemptID == attemptID,
              session.sourceItemsRevision == consent.sourceItemsRevision,
              session.persistenceMutationGeneration == consent.persistenceMutationGeneration,
              staleResetRecoveryIngestionIsQuiescent(session)
        else { return false }
        // Same allowed lifetime as the rejected state: the pinned target, service, and deletion
        // generation must match exactly (a deletion or revocation is never converted into
        // permission to acquire a replacement incarnation), and the persisted reset generation
        // must cover the reported reset.
        guard payload.sessionID == recovery.binding.sessionID,
              payload.persistenceState.stamp == recovery.rejectedPersistenceState.stamp,
              payload.persistenceState.transcriptResetGeneration >= recovery.observedResetGeneration
        else { return false }
        return true
    }

    /// Recovery-specific preflight inside `applyPersistedHydration`, after every rejection check
    /// and before the first destructive mutation: transcript-specific buffers, anchors, footers,
    /// sidecars, and the discarded working copy's pending reset/removal bookkeeping are cleared
    /// so they cannot contaminate the loaded transcript. Composer text and pending attachments
    /// are deliberately untouched.
    func prepareSessionForStaleResetRecoveryReplacement(_ session: AgentTabSession) {
        clearPendingAssistantDelta(session)
        session.pendingTranscriptResetReceipt = nil
        session.pendingFinalizedScheduledSendItemRemovals.removeAll()
        session.pendingTurnRuntimeAnchors.removeAll()
        session.agentMessageRuntimeFootersByItemID.removeAll()
        session.replaceEphemeralToolResultPayloadMap([:], liveItemIDs: [])
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.backgroundRowIDs.removeAll()
        session.backgroundRowSourceIDs.removeAll()
        session.backgroundCurrentAssistantRowIDs.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus(nil, source: nil)
    }

    /// The paired replacement committed: authority is installed by the caller; the recovery
    /// episode ends here. The retained (discarded) work no longer dirties the adopted snapshot.
    func completeStaleResetRecoveryReplacement(_ session: AgentTabSession) {
        session.staleResetRecoveryTask = nil
        session.staleResetRecovery = nil
        session.isDirty = false
    }

    // MARK: - Lifecycle protection

    /// Pre-destructive preflight for compose-tab removal (close, stash, close-all, auto-archive,
    /// stashed-delete cascade): admission and commitment form one owner-fenced operation.
    ///
    /// 1. The final save of every dirty target runs here, before the vetoable commit. A committed
    ///    peer reset is discovered by exactly that save, so a tab whose working view turns out to
    ///    be unsavable enters stop-and-retain while the removal can still be refused (the close
    ///    listener runs after the decision and cannot veto).
    /// 2. Tabs without a recovery pass through unchanged. Tabs with a retained conversation
    ///    require explicit confirmation; without a presenter the removal is refused rather than
    ///    silently discarding the view.
    /// 3. Consent covers exactly the episodes shown. After the confirmation, every target is
    ///    revalidated: a target that entered a new or different episode meanwhile (for example a
    ///    reset discovered during the prompt) requires a new confirmation, and nothing is
    ///    admitted. Admission records the consented episode per target; the final removal
    ///    boundary revalidates it again after the listener's teardown save and relinquishes the
    ///    episode only as part of the whole batch's synchronous logical commit.
    private struct RemovalConsent {
        let tabID: UUID
        let episodeID: UUID?
    }

    private func entryOwnerIsCurrent(
        _ owner: ComposeTabRemovalOperation.EntryOwner,
        tabID: UUID
    ) -> Bool {
        sessions[tabID] === owner.session
            && owner.session.persistentSessionBindingIdentity == owner.binding
            && owner.session.bindingTransitionGeneration == owner.transitionGeneration
            && !owner.session.bindingTransitionInProgress
    }

    private func collectStaleResetRemovalConsent(
        entryOwnersByTabID: [UUID: ComposeTabRemovalOperation.EntryOwner],
        context: SessionPersistenceContext,
        operation: String
    ) async -> [RemovalConsent]? {
        let sortedOwners = entryOwnersByTabID.sorted { $0.key.uuidString < $1.key.uuidString }
        for (tabID, owner) in sortedOwners {
            guard sessionPersistenceContextIsCurrent(context),
                  entryOwnerIsCurrent(owner, tabID: tabID)
            else { return nil }
            let session = owner.session
            if session.staleResetRecovery == nil, session.isDirty {
                _ = await flushSaveDetailed(for: tabID, context: context)
                guard sessionPersistenceContextIsCurrent(context),
                      entryOwnerIsCurrent(owner, tabID: tabID)
                else { return nil }
            }
        }
        for (tabID, owner) in sortedOwners {
            guard sessionPersistenceContextIsCurrent(context),
                  entryOwnerIsCurrent(owner, tabID: tabID)
            else { return nil }
            if let stopTask = owner.session.staleResetRecoveryTask {
                await stopTask.value
                guard sessionPersistenceContextIsCurrent(context),
                      entryOwnerIsCurrent(owner, tabID: tabID)
                else { return nil }
            }
        }

        let consents = sortedOwners.map { tabID, owner in
            RemovalConsent(tabID: tabID, episodeID: owner.session.staleResetRecovery?.id)
        }
        let recoveryCount = consents.count(where: { $0.episodeID != nil })
        if recoveryCount > 0 {
            guard let confirmation = staleResetRecoveryDiscardConfirmation else {
                #if DEBUG
                    AgentModePerfDiagnostics.event(
                        "staleReset.discardRefused",
                        fields: ["tabCount": String(recoveryCount), "operation": operation]
                    )
                #endif
                return nil
            }
            let request = AgentStaleResetDiscardRequest(tabCount: recoveryCount, operation: operation)
            guard await confirmation(request),
                  sessionPersistenceContextIsCurrent(context)
            else { return nil }
        }

        for consent in consents {
            guard let owner = entryOwnersByTabID[consent.tabID],
                  entryOwnerIsCurrent(owner, tabID: consent.tabID),
                  owner.session.staleResetRecovery?.id == consent.episodeID
            else {
                return nil
            }
        }
        return consents
    }

    /// Operation-less confirmation is retained for confirmation UI coverage only. It never
    /// publishes an admission or a logical reservation.
    func confirmStaleResetRecoveryDiscard(tabIDs: Set<UUID>, operation: String) async -> Bool {
        guard let context = currentSessionPersistenceContext(),
              sessionPersistenceContextIsCurrent(context)
        else { return false }
        let owners = Dictionary(
            uniqueKeysWithValues: tabIDs.compactMap { tabID -> (UUID, ComposeTabRemovalOperation.EntryOwner)? in
                guard let session = sessions[tabID] else { return nil }
                return (
                    tabID,
                    ComposeTabRemovalOperation.EntryOwner(
                        session: session,
                        binding: session.persistentSessionBindingIdentity,
                        transitionGeneration: session.bindingTransitionGeneration
                    )
                )
            }
        )
        return await collectStaleResetRemovalConsent(
            entryOwnersByTabID: owners,
            context: context,
            operation: operation
        ) != nil
    }

    /// Captures consent without publishing ownership, then installs the complete operation claim
    /// in one no-await MainActor pass. Competing claims are never cleared or overwritten.
    func admitComposeTabRemoval(
        tabIDs: Set<UUID>,
        stashedTabIDs: Set<UUID> = [],
        reason: PromptViewModel.ComposeTabRemovalReason
    ) async -> UUID? {
        let operationID = UUID()
        let operationDescription = switch reason {
        case .close: "Closing the tab"
        case .stash: "Stashing the tab"
        case .deleteStashed: "Deleting the stashed tab"
        }
        guard !tabIDs.isEmpty,
              let context = currentSessionPersistenceContext(),
              let workspaceOwner = context.workspaceOwner,
              sessionIndexStore.isOwnerCurrent(workspaceOwner),
              sessionPersistenceContextIsCurrent(context),
              workspaceManager?.isSwitchingWorkspace != true,
              !tabIDs.contains(where: { reservedComposeTabIDs[$0] != nil })
        else { return nil }

        if !AppLaunchConfiguration.current.suppressesAgentSessionPersistence {
            for tabID in tabIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let session = sessions[tabID],
                      session.isDirty,
                      session.staleResetRecovery == nil,
                      session.activeAgentSessionID == nil
                else { continue }
                guard ensureSessionBoundToTab(session) != nil else { return nil }
            }
        }

        var entryOwnersByTabID: [UUID: ComposeTabRemovalOperation.EntryOwner] = [:]
        var absentTabIDs: Set<UUID> = []
        for tabID in tabIDs {
            if let session = sessions[tabID] {
                entryOwnersByTabID[tabID] = ComposeTabRemovalOperation.EntryOwner(
                    session: session,
                    binding: session.persistentSessionBindingIdentity,
                    transitionGeneration: session.bindingTransitionGeneration
                )
            } else {
                absentTabIDs.insert(tabID)
            }
        }

        guard let consents = await collectStaleResetRemovalConsent(
            entryOwnersByTabID: entryOwnersByTabID,
            context: context,
            operation: operationDescription
        ) else { return nil }
        let consentByTabID = Dictionary(uniqueKeysWithValues: consents.map { ($0.tabID, $0) })

        guard sessionPersistenceContextIsCurrent(context),
              !tabIDs.contains(where: { reservedComposeTabIDs[$0] != nil })
        else { return nil }

        var targets: [ComposeTabRemovalOperation.Target] = []
        var admissions: [(AgentTabSession, AgentStaleResetRemovalAdmission)] = []
        for tabID in tabIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let owner = entryOwnersByTabID[tabID] {
                let session = owner.session
                guard entryOwnerIsCurrent(owner, tabID: tabID),
                      session.staleResetRemovalAdmission == nil,
                      session.staleResetRecovery?.id == consentByTabID[tabID]?.episodeID
                else { return nil }
                let admission = AgentStaleResetRemovalAdmission(
                    id: UUID(),
                    operationID: operationID,
                    sessionIdentity: ObjectIdentifier(session),
                    binding: owner.binding,
                    transitionGeneration: owner.transitionGeneration,
                    consentedEpisodeID: consentByTabID[tabID]?.episodeID,
                    isReserved: true
                )
                admissions.append((session, admission))
                targets.append(ComposeTabRemovalOperation.Target(
                    tabID: tabID,
                    session: session,
                    binding: owner.binding,
                    transitionGeneration: owner.transitionGeneration,
                    admissionID: admission.id,
                    consentedEpisodeID: admission.consentedEpisodeID
                ))
            } else {
                guard sessions[tabID] == nil else { return nil }
            }
        }

        let operation = ComposeTabRemovalOperation(
            id: operationID,
            reason: reason,
            persistenceContext: context,
            requestedTabIDs: tabIDs,
            requestedStashedTabIDs: stashedTabIDs,
            absentTabIDs: absentTabIDs,
            targets: targets
        )
        for (session, admission) in admissions {
            session.staleResetRemovalAdmission = admission
        }
        for tabID in tabIDs {
            reservedComposeTabIDs[tabID] = operationID
        }
        composeTabRemovalOperations[operationID] = operation
        notifyScheduledSendBusyStateMayHaveChanged(tabIDs: tabIDs)
        return operationID
    }

    /// The operation still runs against the workspace owner it captured at entry (same
    /// persistence workspace, same session-index activation epoch). A switch away — or away and
    /// back — invalidates it; storage work never targets a newly active workspace.
    func removalOperationContextIsCurrent(_ operation: ComposeTabRemovalOperation) -> Bool {
        sessionPersistenceContextIsCurrent(operation.persistenceContext)
            && operation.persistenceContext.workspaceOwner.map(sessionIndexStore.isOwnerCurrent) == true
            && workspaceManager?.isApplyingComposeTabRemoval != true
    }

    /// The complete requested set is exactly as admitted: every captured owner is current and
    /// every tab that was absent at entry is still absent.
    func removalTargetSetIsCurrent(_ operation: ComposeTabRemovalOperation) -> Bool {
        operation.targets.allSatisfy { removalTargetOwnerIsCurrent($0) }
            && operation.absentTabIDs.allSatisfy { sessions[$0] == nil }
    }

    /// The captured owner still occupies its tab with the admitted binding, transition
    /// generation, and admission. Evaluated after every asynchronous boundary of the removal
    /// operation before anything is decided or destroyed; a replaced or rebound owner is never
    /// destroyed by the operation that captured its predecessor.
    func removalTargetOwnerIsCurrent(_ target: ComposeTabRemovalOperation.Target) -> Bool {
        let session = target.session
        return sessions[target.tabID] === session
            && session.persistentSessionBindingIdentity == target.binding
            && session.bindingTransitionGeneration == target.transitionGeneration
            && !session.bindingTransitionInProgress
            && session.staleResetRemovalAdmission?.id == target.admissionID
    }

    /// Releases the logical tab reservations this operation holds (only entries it owns).
    func releaseComposeTabReservations(for operation: ComposeTabRemovalOperation) {
        for tabID in operation.requestedTabIDs where reservedComposeTabIDs[tabID] == operation.id {
            reservedComposeTabIDs.removeValue(forKey: tabID)
        }
    }

    /// Idempotent caller finalization. Before commitment it aborts and releases only this
    /// operation's claims. After commitment the operation-owned cleanup task retains ownership
    /// until it records completion or a handled failure.
    func finalizeComposeTabRemoval(operationID: UUID) {
        guard let operation = composeTabRemovalOperations[operationID] else { return }
        switch operation.phase {
        case .admitted, .preparing, .prepared:
            abortComposeTabRemoval(operation, vetoedTabIDs: [])
            composeTabRemovalOperations.removeValue(forKey: operationID)
        case .committed, .cleaning:
            operation.isCallerFinalized = true
        case .finished:
            operation.isCallerFinalized = true
            releaseComposeTabReservations(for: operation)
            composeTabRemovalOperations.removeValue(forKey: operationID)
            notifyScheduledSendBusyStateMayHaveChanged(tabIDs: operation.requestedTabIDs)
        case .aborted:
            releaseComposeTabReservations(for: operation)
            composeTabRemovalOperations.removeValue(forKey: operationID)
        }
    }

    /// Final consent check for one captured target: the owner is current and carries either no
    /// recovery or exactly the consented episode. A recovery first discovered by the operation's
    /// final save, or a different episode, is not covered.
    func removalTargetIsConsented(_ target: ComposeTabRemovalOperation.Target) -> Bool {
        guard removalTargetOwnerIsCurrent(target),
              let admission = target.session.staleResetRemovalAdmission,
              !admission.isCommitted
        else { return false }
        return target.session.staleResetRecovery?.id == target.consentedEpisodeID
    }

    /// Final settlement check for one captured target. The final-save receipt must identify the
    /// snapshot actually made durable (`.written`) or the clean live state (`.clean`), and the
    /// owner's persistence-relevant state — content revision and persistence-mutation generation —
    /// must still equal that receipt; nothing may be in flight or debounced and ingestion must be
    /// quiescent. A consented recovery owner (`.recovery`) is judged by consent, not settlement.
    /// Dirty state that could not be written (`.unsaved`) is never settled.
    func removalTargetIsSettled(_ target: ComposeTabRemovalOperation.Target) -> Bool {
        let session = target.session
        guard removalTargetOwnerIsCurrent(target),
              let admission = session.staleResetRemovalAdmission,
              admission.isFinalSaveCompleted,
              let kind = admission.finalSaveKind,
              session.saveDebounceTask == nil,
              staleResetRecoveryIngestionIsQuiescent(session)
        else { return false }
        if let sessionID = session.activeAgentSessionID, isSaveInFlight(sessionID: sessionID) {
            return false
        }
        switch kind {
        case .recovery:
            return session.staleResetRecovery != nil
        case .unsaved:
            return false
        case .clean, .written:
            return admission.finalSaveRevision == session.sourceItemsRevision
                && admission.finalSaveMutationGeneration == session.persistenceMutationGeneration
                && (!session.isDirty || session.staleResetRecovery != nil)
        }
    }

    /// The operation was refused or vetoed: every captured owner that is still current drops its
    /// reservation/admission (new work and rebinding are admissible again), vetoed owners publish
    /// their retained state, and detached remote projections without a retained view re-attach.
    func abortComposeTabRemoval(_ operation: ComposeTabRemovalOperation, vetoedTabIDs: Set<UUID>) {
        guard operation.phase != .committed,
              operation.phase != .cleaning,
              operation.phase != .finished
        else { return }
        operation.phase = .aborted
        releaseComposeTabReservations(for: operation)
        for target in operation.targets {
            let session = target.session
            guard sessions[target.tabID] === session else { continue }
            if session.staleResetRemovalAdmission?.id == target.admissionID {
                session.staleResetRemovalAdmission = nil
            }
            if vetoedTabIDs.contains(target.tabID) {
                publishStaleResetRecoveryState(for: session)
            }
            if session.remoteHost != nil, session.staleResetRecovery == nil {
                remoteCoordinator.attachPersistedSessionIfNeeded(session)
            }
        }
        #if DEBUG
            AgentModePerfDiagnostics.event(
                "staleReset.removalBatchVetoed",
                fields: [
                    "operationID": operation.id.uuidString,
                    "vetoedTabIDs": vetoedTabIDs.map(\.uuidString).sorted().joined(separator: ","),
                    "reason": String(describing: operation.reason)
                ]
            )
        #endif
        notifyScheduledSendBusyStateMayHaveChanged(tabIDs: operation.requestedTabIDs)
    }

    /// Synchronous owner retirement after the whole admitted batch passed its final ownership and
    /// settlement checks: relinquishes the consented episode, marks the admission committed (saves
    /// are refused from here on, so nothing can be discovered after the final save), and drops any
    /// debounced save. No suspension may occur between the batch check and this call.
    func commitStaleResetRemoval(_ session: AgentTabSession) {
        session.invalidateStaleResetRecoveryForLifecycle()
        session.staleResetRemovalAdmission?.isReserved = true
        session.staleResetRemovalAdmission?.isCommitted = true
        session.saveDebounceTask?.cancel()
        session.saveDebounceTask = nil
    }

    /// The user confirmed a workspace switch or window close that ends every session in this
    /// view model (the confirmation sheet listed the unsaved conversations): relinquish them.
    func discardStaleResetRecoveriesForConfirmedLifecycle() {
        for session in sessions.values {
            session.invalidateStaleResetRecoveryForLifecycle()
        }
    }
}

/// Main-actor box carrying one confirmed reload's operation-owned outcome out of its task.
@MainActor
private final class StaleResetReloadOutcomeBox {
    var disposition: AgentTabSession.PersistedLoadDisposition = .unresolved
}
