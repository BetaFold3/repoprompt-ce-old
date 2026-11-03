import Combine
import Foundation
import RepoPromptAgentCore

// MARK: - VM ↔ UI contract (Agent Mode scheduled sends, plan §3.3/§3.4)

//
// UI entry points (all `@MainActor`, called from `AgentInputBar` through `AgentScheduledSendActions`):
//   • `executeComposerScheduleAttempt(text:notBefore:runAlongsideOtherSessions:claim:)`
//       → `.scheduled(id:)` after the record is durably saved, otherwise `.blocked(message:)`.
//   • `updateScheduledSend(tabID:scheduleID:text:notBefore:runAlongsideOtherSessions:)`
//   • `cancelScheduledSend(tabID:scheduleID:)`
//   • `sendScheduledSendNow(tabID:scheduleID:runAlongsideOtherSessions:)`
//   • `discardUnreadableScheduledSend(tabID:)`
//       → `nil` on success, otherwise a user-facing message.
// Props inputs: `TabSession.scheduledSend`, `scheduledSendPendingFinalization`,
// `scheduledSendBusyState(tabID:)`, `canScheduleSend(tabID:session:)`,
// `scheduleTargetIsNewSessionStart(tabID:session:)`.
// Message marker: `AgentChatItem.scheduledSend` is stamped when the schedule hands off its input.
// Its `kind` says what that proves (R9): only `providerAccepted` means "Sent"; `savedInQueue` is
// saved input owned by a durable recovery intent, and `legacyUnknown` (old data, or the inactive
// path's `didSend` heuristic) proves neither.
//
// Persistence rules: the ordinary session save never mutates the on-disk schedule members of an
// existing file. Every schedule change goes through `AgentSessionDataService.mutateScheduledSend`
// (CAS on `updatedAt`). Complete schedule actions are serialized per session
// (`runScheduledSendAction`) so reads, writes, rollbacks, and attachment cleanup of one action
// never interleave with another.
//
// Acceptance ownership (plan P1.3): before the guarded provider handoff the view model captures a
// DataService-issued recovery context (pinned file/folder, deletion generation, canonical
// snapshot) and the coordinator reserves process ownership inside the final gate
// (`authorizeProviderHandoff`). On acceptance the immutable payload (attempt, receipt, stamped
// item, context) is transferred synchronously (`reportAcceptance`); the coordinator's single
// bounded worker owns the durable commit (`finalizeScheduledSend(recovery:)`), including
// reconstruction after accidental file loss and settlement after explicit deletion. This view
// model only projects the coordinator's status (`scheduledSendPendingFinalization`), adopts the
// file on terminal states, and forwards the persistence-only "Retry saving" action. It never
// retries persistence, restores `.dispatching`, or re-drives the provider for an accepted attempt.

typealias ScheduledDispatchRunStarter = @MainActor (
    _ tabID: UUID,
    _ providerText: String,
    _ attachments: [AgentImageAttachment],
    _ taggedFileAttachments: [AgentTaggedFileAttachment]
) async -> CodexAgentModeCoordinator.NativeSendOutcome?

extension Notification.Name {
    /// Posted after this process durably committed a schedule mutation or finalization.
    /// `userInfo["sessionID"]` is the `AgentSession.id`; `userInfo["windowID"]` the poster.
    static let agentScheduledSendDidCommit = Notification.Name("AgentModeViewModel.agentScheduledSendDidCommit")
}

/// Shared timing rules for the composer control and the banner editors.
enum AgentScheduledSendTiming {
    static let step: TimeInterval = 15 * 60
    static let maxDelay: TimeInterval = 24 * 60 * 60
    static let quickPickOffsets: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60]
    static let customStepCountRange = 1 ... Int(maxDelay / step)
    /// Tolerance for edits made a few seconds before the picked time elapses.
    static let pastGraceInterval: TimeInterval = 60

    static func customDelay(stepCount: Int) -> TimeInterval {
        let clampedStepCount = min(
            max(stepCount, customStepCountRange.lowerBound),
            customStepCountRange.upperBound
        )
        return TimeInterval(clampedStepCount) * step
    }

    static func customDelayMinutes(stepCount: Int) -> Int {
        Int(customDelay(stepCount: stepCount) / 60)
    }

    static func customNotBefore(stepCount: Int, now: Date = Date()) -> Date {
        now.addingTimeInterval(customDelay(stepCount: stepCount))
    }

    static func editorRange(originalNotBefore: Date, now: Date = Date()) -> ClosedRange<Date> {
        min(originalNotBefore, now) ... max(originalNotBefore, now.addingTimeInterval(maxDelay))
    }

    static func validationMessage(for notBefore: Date, now: Date = Date()) -> String? {
        if notBefore < now.addingTimeInterval(-pastGraceInterval) {
            return "Choose a time in the future for the scheduled message."
        }
        if notBefore > now.addingTimeInterval(maxDelay) {
            return "Scheduled messages can be delayed by at most 24 hours."
        }
        return nil
    }
}

extension AgentModeViewModel {
    // MARK: - Coordinator attachment and triggers

    func attachScheduledSendCoordinator(_ coordinator: AgentScheduledSendCoordinator) {
        if let scheduledSendCoordinator, scheduledSendCoordinator === coordinator,
           scheduledSendHostRegistrationID != nil
        {
            return
        }
        detachScheduledSendCoordinator()
        scheduledSendCoordinator = coordinator
        scheduledSendHostRegistrationID = coordinator.register(self)
        scheduledSendCommitObserver = NotificationCenter.default.publisher(for: .agentScheduledSendDidCommit)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self,
                      let sessionID = notification.userInfo?["sessionID"] as? UUID
                else { return }
                // A process-owned commit has no window identity; every matching host refreshes.
                let posterWindowID = notification.userInfo?["windowID"] as? Int
                handleForeignScheduledSendCommit(sessionID: sessionID, posterWindowID: posterWindowID)
            }
        scheduledSendRecoveryObserver = NotificationCenter.default.publisher(for: .agentScheduledSendRecoveryDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self,
                      let sessionID = notification.userInfo?["sessionID"] as? UUID
                else { return }
                let kind = (notification.userInfo?["changeKind"] as? String)
                    .flatMap(AgentScheduledSendRecoveryChangeKind.init(rawValue:))
                switch kind {
                case .committed?, .explicitlyDeleted?:
                    // Durable terminal state written by the process worker (no window identity):
                    // every host projecting this session adopts the file.
                    handleForeignScheduledSendCommit(sessionID: sessionID, posterWindowID: nil)
                case .reserved?, .accepted?, .saving?, .waitingToRetry?, .needsAttention?, .released?, nil:
                    guard let session = sessions.values.first(where: { $0.activeAgentSessionID == sessionID }) else { return }
                    reconcileScheduledSendRecoveryProjection(for: session)
                }
            }
        scheduledSendPendingConfirmationObserver = NotificationCenter.default.publisher(for: .agentScheduledSendPendingConfirmationDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let sessionID = notification.userInfo?["sessionID"] as? UUID else { return }
                for session in sessions.values where session.activeAgentSessionID == sessionID {
                    syncComposerUIState(tabID: session.tabID)
                }
            }
        scheduledSendDispositionObserver = NotificationCenter.default
            .publisher(for: .agentScheduledSendDispositionDidChange, object: coordinator)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let sessionID = notification.userInfo?["sessionID"] as? UUID else { return }
                for session in sessions.values where session.activeAgentSessionID == sessionID {
                    syncComposerUIState(tabID: session.tabID)
                }
            }
        scheduledSendDeletionObserver = NotificationCenter.default.publisher(for: .agentSessionDeletionDidCommit)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let sessionID = notification.userInfo?["sessionID"] as? UUID else { return }
                // Explicit deletion committed under the persistence gate invalidates every peer
                // projection of that durable session; no schedule writer may recreate the file.
                for session in sessions.values where session.activeAgentSessionID == sessionID {
                    handleDurableSessionDeleted(session, sessionID: sessionID)
                }
            }
        // Late delivery evidence (written after the run went inactive) wakes an awaiting hold.
        scheduledSendDeliveryEvidenceObserver = NotificationCenter.default.publisher(for: .agentRecoveryDeliveryEvidenceDidSettle)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let lane = notification.object as? AgentRecoverySessionLane else { return }
                // A retired predecessor's late no-handoff settlement (F1) also wakes its successor owner.
                for session in sessions.values where session.recoveryLane?.sessionID == lane.sessionID {
                    recheckScheduledSendTransferAwaitingEvidence(for: session)
                }
            }
        // F-10: a transfer whose repair gave up while startup was closed or failed (then Retry
        // succeeded) is repaired once admission opens; the repair is CAS-exact and idempotent.
        scheduledSendStartupAdmissionObserver = NotificationCenter.default
            .publisher(for: .agentScheduledSendStartupAdmissionDidChange, object: coordinator)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, scheduledSendCoordinator === coordinator, coordinator.isStartupAdmissionOpen else { return }
                for session in sessions.values {
                    retryScheduledSendTransferIfNeeded(for: session)
                }
            }
        // Presentation of process-retained attempts is rebuilt from coordinator-owned values.
        for session in sessions.values {
            adoptScheduledSendRecoveryProjection(for: session)
        }
    }

    func detachScheduledSendCoordinator() {
        if let scheduledSendCoordinator, let scheduledSendHostRegistrationID {
            scheduledSendCoordinator.unregister(registrationID: scheduledSendHostRegistrationID)
        }
        scheduledSendHostRegistrationID = nil
        scheduledSendCoordinator = nil
        scheduledSendCommitObserver?.cancel()
        scheduledSendCommitObserver = nil
        scheduledSendRecoveryObserver?.cancel()
        scheduledSendRecoveryObserver = nil
        scheduledSendDeletionObserver?.cancel()
        scheduledSendDeletionObserver = nil
        scheduledSendPendingConfirmationObserver?.cancel()
        scheduledSendPendingConfirmationObserver = nil
        scheduledSendDispositionObserver?.cancel()
        scheduledSendDispositionObserver = nil
        scheduledSendDeliveryEvidenceObserver?.cancel()
        scheduledSendDeliveryEvidenceObserver = nil
        scheduledSendStartupAdmissionObserver?.cancel()
        scheduledSendStartupAdmissionObserver = nil
    }

    func notifyScheduledSendRunStateChanged(for session: AgentTabSession) {
        guard let coordinator = scheduledSendCoordinator,
              let sessionID = session.activeAgentSessionID
        else { return }
        // Terminal publications may clear `runID` around the state change; the last observed run
        // identity is the evidence the coordinator matches against its captured run.
        let runID = session.runID ?? (session.runState.isActive ? nil : session.lastObservedRunID)
        coordinator.runStateDidChange(
            sessionID: sessionID,
            runID: runID,
            state: session.runState
        )
        notifyScheduledSendBusyStateMayHaveChanged(tabIDs: [session.tabID])
        recheckScheduledSendTransferAwaitingEvidence(for: session)
    }

    func notifyScheduledSendHydrationCompleted(for session: AgentTabSession) {
        scheduledSendCoordinator?.recordDidChange()
        reconcileScheduledSendRecoveryProjection(for: session)
    }

    /// Change-detected busy trigger: any busy-to-idle boundary (run bookkeeping, queue drain,
    /// reservation release, composer claim release) re-evaluates the coordinator.
    func notifyScheduledSendBusyStateMayHaveChanged(tabIDs: Set<UUID>) {
        guard let coordinator = scheduledSendCoordinator else { return }
        var changed = false
        for tabID in tabIDs {
            guard let session = sessions[tabID] else { continue }
            let state = scheduledSendBusyState(tabID: tabID)
            if session.lastReportedScheduledSendBusyState != state {
                session.lastReportedScheduledSendBusyState = state
                changed = true
            }
        }
        if changed {
            coordinator.recordDidChange()
        }
    }

    private func notifyScheduledSendRecordChanged() {
        scheduledSendCoordinator?.recordDidChange()
    }

    private func postScheduledSendCommitNotification(sessionID: UUID) {
        NotificationCenter.default.post(
            name: .agentScheduledSendDidCommit,
            object: nil,
            userInfo: ["sessionID": sessionID, "windowID": scheduledSendWindowID]
        )
    }

    private func handleForeignScheduledSendCommit(sessionID: UUID, posterWindowID: Int?) {
        if let posterWindowID, posterWindowID == scheduledSendWindowID { return }
        if let session = sessions.values.first(where: { $0.activeAgentSessionID == sessionID }) {
            if session.scheduledSendPendingFinalization != nil {
                reconcileScheduledSendRecoveryProjection(for: session)
            } else {
                refreshScheduledSendProjection(for: session)
            }
        } else if ownerValidatedSessionIndex[sessionID] != nil {
            // Index-only placeholder: refresh its discovery summary from the authoritative file.
            Task { @MainActor [weak self] in
                await self?.refreshIndexScheduledSendSummaryFromDisk(sessionID: sessionID)
            }
        }
    }

    /// Re-projects a session after another writer committed: hydrated sessions resync from disk,
    /// unhydrated ones hydrate (which installs the authoritative record). Never touches a
    /// session that owns a live attempt.
    private func refreshScheduledSendProjection(for session: AgentTabSession) {
        guard !session.ownsLiveScheduledAttempt else { return }
        if session.hasLoadedPersistedState {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await runScheduledSendAction(on: session) {
                    _ = await self.resyncScheduledSendFromDisk(session: session)
                }
            }
        } else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await ensureHydrated(tabID: session.tabID)
                scheduledSendCoordinator?.recordDidChange()
            }
        }
    }

    private func refreshIndexScheduledSendSummaryFromDisk(sessionID: UUID) async {
        guard let workspace = persistenceWorkspace,
              let owner = sessionIndexStore.sessionIndexOwner,
              owner.workspaceID == workspace.id,
              sessionIndexStore.isOwnerCurrent(owner),
              ownerValidatedSessionIndex[sessionID] != nil
        else { return }
        let storagePath = workspace.customStoragePath
        // The index-only refresh needs header fields, not a full transcript decode.
        guard let record = try? await dataService.metadataRecordForSessionID(sessionID, for: workspace),
              record.id == sessionID,
              sessionIndexStore.isOwnerCurrent(owner),
              persistenceWorkspace?.id == workspace.id,
              persistenceWorkspace?.customStoragePath == storagePath,
              var entry = ownerValidatedSessionIndex[sessionID]
        else { return }
        guard entry.scheduledSendSummary != record.scheduledSendSummary
            || entry.lastScheduledDispatch != record.lastScheduledDispatch
        else { return }
        entry.scheduledSendSummary = record.scheduledSendSummary
        entry.lastScheduledDispatch = record.lastScheduledDispatch
        applyLocalSessionIndexUpsert(entry)
        scheduledSendCoordinator?.recordDidChange()
    }

    // MARK: - Action serialization

    /// Runs one complete schedule action for `session` after every earlier action finished.
    func runScheduledSendAction<T>(
        on session: AgentTabSession,
        _ body: @escaping @MainActor () async -> T
    ) async -> T {
        let previous = session.scheduledSendActionTask
        let box = ScheduledSendActionResultBox<T>()
        let task = Task<Void, Never> { @MainActor in
            _ = await previous?.value
            box.value = await body()
        }
        session.scheduledSendActionTask = task
        await task.value
        if session.scheduledSendActionTask == task {
            session.scheduledSendActionTask = nil
        }
        return box.value!
    }

    // MARK: - Composer scheduling

    /// Whether the composer may schedule for this tab (local, unscheduled, not MCP-controlled).
    func canScheduleSend(tabID: UUID?, session: AgentTabSession?) -> Bool {
        guard let tabID else { return false }
        if let session {
            guard session.remoteHost == nil,
                  session.staleResetRecovery == nil,
                  session.scheduledSend == nil,
                  session.scheduledSendPendingFinalization == nil,
                  session.mcpControlContext == nil
            else { return false }
        }
        return !isMCPControlled(tabID: tabID) && !workspaceSwitchInFlight
    }

    /// Semantic "first prompt" predicate shared by the composer control and the schedule
    /// implementation: a tab without a linked session, or a linked session that never carried a
    /// turn, schedules a workspace-gated new-session start (plan §1 item 4).
    func scheduleTargetIsNewSessionStart(tabID: UUID?, session: AgentTabSession?) -> Bool {
        guard let tabID else { return false }
        guard hasLinkedAgentSession(for: tabID) else { return true }
        guard let session else { return false }
        return Self.sessionIsUntouchedForScheduling(session)
    }

    static func sessionIsUntouchedForScheduling(_ session: AgentTabSession) -> Bool {
        session.items.isEmpty
            && session.transcript.turns.isEmpty
            && !session.hasSentFirstMessage
            && session.providerSessionID == nil
            && !session.runState.isActive
            && session.runID == nil
    }

    /// Schedules the composer draft instead of sending it. Mirrors `executeComposerSubmitAttempt`
    /// routing (existing session or fresh destination tab), including initial worktree preparation,
    /// but never touches the send paths.
    @discardableResult
    func executeComposerScheduleAttempt(
        text: String,
        notBefore: Date,
        runAlongsideOtherSessions: Bool,
        claim: AgentComposerSubmitClaim
    ) async -> UserTurnSubmissionResult {
        await executeComposerScheduleAttempt(
            text: text,
            notBefore: notBefore,
            runAlongsideOtherSessions: runAlongsideOtherSessions,
            claim: claim,
            createAndActivateSessionTab: { [weak self] in
                await self?.createAndActivateSessionTab()
            }
        )
    }

    @discardableResult
    func executeComposerScheduleAttempt(
        text: String,
        notBefore: Date,
        runAlongsideOtherSessions: Bool,
        claim: AgentComposerSubmitClaim,
        createAndActivateSessionTab: () async -> UUID?
    ) async -> UserTurnSubmissionResult {
        let target = claim.attempt.target
        let sourceSession = claim.sourceSession
        guard composerSubmitClaimIsCurrent(claim) else {
            logRejectedSubmitTarget(target, session: sessions[target.tabID], reason: "schedule_claim_not_current", persistent: true)
            return .blocked(message: Self.staleComposerSubmitTargetMessage)
        }
        defer {
            releaseComposerSubmitClaim(claim)
        }
        if let timingMessage = AgentScheduledSendTiming.validationMessage(for: notBefore) {
            return .blocked(message: timingMessage)
        }

        switch target.route {
        case .existingAgentSession:
            guard let preparedSession = try? await ensureSessionReady(tabID: target.tabID) else {
                logRejectedSubmitTarget(target, session: sessions[target.tabID], reason: "schedule_session_not_ready", persistent: true)
                return .blocked(message: Self.composeTabRemovalInProgressMessage)
            }
            guard preparedSession === sourceSession,
                  composerSubmitClaimIsCurrent(claim)
            else {
                logRejectedSubmitTarget(target, session: preparedSession, reason: "schedule_prepared_session_or_claim_changed", persistent: true)
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            if let blockedMessage = newWorkBlockedMessage(for: preparedSession) {
                logRejectedSubmitTarget(target, session: preparedSession, reason: "schedule_new_work_blocked", persistent: true)
                return .blocked(message: blockedMessage)
            }
            if let rejectionReason = submitTargetRejectionReason(
                target,
                session: preparedSession,
                validateSubmissionToken: false
            ) {
                logRejectedSubmitTarget(target, session: preparedSession, reason: rejectionReason, persistent: true)
                resyncAfterRejectedSubmitTarget(target)
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            let pendingState = Self.pendingUserTurnState(from: preparedSession)
            if let initialLocation = target.expectedInitialStartLocation,
               initialLocation != .local,
               pendingState.initialStartLocation == initialLocation
            {
                let sourceSnapshot = FirstSendSourceSnapshot(
                    session: preparedSession,
                    fallbackSelectedAgent: selectedAgent,
                    fallbackSelectedModelRaw: selectedModelRaw,
                    fallbackSelectedReasoningEffortRaw: selectedReasoningEffortRaw,
                    fallbackAutoEditEnabled: autoEditEnabled
                )
                preparedSession.isPreparingInitialWorktree = true
                syncComposerUIState(tabID: target.tabID)
                syncStatusPillsUIState()
                defer {
                    preparedSession.isPreparingInitialWorktree = false
                    if target.tabID == currentTabID {
                        syncComposerUIState(tabID: target.tabID)
                        syncStatusPillsUIState()
                    }
                }
                if let blocked = preflightInitialUserTurn(text: text, session: preparedSession) {
                    return blocked
                }
                do {
                    try await prepareInitialExecutionLocation(initialLocation, for: preparedSession) {
                        !Task.isCancelled
                            && self.composerSubmitClaimIsCurrent(claim)
                            && self.sessions[target.tabID] === preparedSession
                            && sourceSnapshot.matches(self.sessions[target.tabID])
                            && Self.pendingUserTurnState(from: preparedSession) == pendingState
                    }
                } catch {
                    return .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
                guard !Task.isCancelled,
                      composerSubmitClaimIsCurrent(claim),
                      sessions[target.tabID] === preparedSession,
                      sourceSnapshot.matches(sessions[target.tabID]),
                      Self.pendingUserTurnState(from: preparedSession) == pendingState
                else {
                    logRejectedSubmitTarget(target, session: sessions[target.tabID], reason: "schedule_state_changed_during_location_preparation", persistent: true)
                    return .blocked(message: Self.staleComposerSubmitTargetMessage)
                }
                preparedSession.pendingInitialStartLocation = .local
                if target.tabID == currentTabID {
                    applySessionToBindings(preparedSession)
                }
            } else {
                guard preparedSession.pendingInitialStartLocation == .local else {
                    logRejectedSubmitTarget(target, session: preparedSession, reason: "schedule_initial_start_location_pending", persistent: true)
                    return .blocked(message: Self.staleComposerSubmitTargetMessage)
                }
            }
            let isNewSessionStart = Self.sessionIsUntouchedForScheduling(preparedSession)
            switch await installScheduledSend(
                text: text,
                on: preparedSession,
                notBefore: notBefore,
                runAlongsideOtherSessions: runAlongsideOtherSessions,
                isNewSessionStart: isNewSessionStart
            ) {
            case let .success(scheduleID):
                clearComposerDraftIfUnchanged(for: claim)
                return .scheduled(id: scheduleID)
            case let .failure(failure):
                return .blocked(message: failure.message)
            }

        case .createAgentSessionFromSourceTab:
            let pendingState = Self.pendingUserTurnState(from: sourceSession)
            guard pendingState.remoteHost == nil else {
                return .blocked(message: Self.scheduledSendRemoteUnsupportedMessage)
            }
            let sourceSnapshot = FirstSendSourceSnapshot(
                session: sourceSession,
                fallbackSelectedAgent: selectedAgent,
                fallbackSelectedModelRaw: selectedModelRaw,
                fallbackSelectedReasoningEffortRaw: selectedReasoningEffortRaw,
                fallbackAutoEditEnabled: autoEditEnabled
            )
            let preparesExecutionLocation = pendingState.initialStartLocation != .local
            if preparesExecutionLocation {
                sourceSession.isPreparingInitialWorktree = true
                syncComposerUIState(tabID: target.tabID)
                syncStatusPillsUIState()
            }
            defer {
                if preparesExecutionLocation {
                    sourceSession.isPreparingInitialWorktree = false
                    if target.tabID == currentTabID {
                        syncComposerUIState(tabID: target.tabID)
                        syncStatusPillsUIState()
                    }
                }
            }
            guard let destinationTabID = await createAndActivateSessionTab() else {
                return .blocked(message: "Failed to create a new agent session.")
            }
            guard !Task.isCancelled,
                  composerSubmitClaimIsCurrent(claim),
                  sessions[target.tabID] === sourceSession,
                  sourceSnapshot.matches(sessions[target.tabID]),
                  destinationTabID != target.tabID
            else {
                logRejectedSubmitTarget(target, session: sessions[target.tabID], reason: "schedule_state_changed_after_destination_created", persistent: true)
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return .blocked(message: Self.staleComposerSubmitTargetMessage)
            }
            guard let destinationSession = session(for: destinationTabID, createIfNeeded: true),
                  isFreshFirstSendDestination(destinationSession)
            else {
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return .blocked(message: "Failed to create a new agent session.")
            }
            if preparesExecutionLocation {
                destinationSession.isPreparingInitialWorktree = true
                syncComposerUIState(tabID: destinationTabID)
            }
            defer {
                if preparesExecutionLocation {
                    destinationSession.isPreparingInitialWorktree = false
                    if destinationTabID == currentTabID {
                        syncComposerUIState(tabID: destinationTabID)
                    }
                }
            }
            sourceSnapshot.applySessionSettings(to: destinationSession)
            installPendingUserTurnState(pendingState, on: destinationSession)
            if let blocked = preflightInitialUserTurn(text: text, session: destinationSession) {
                clearPendingUserTurnState(on: destinationSession)
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return blocked
            }
            if preparesExecutionLocation {
                do {
                    try await prepareInitialExecutionLocation(pendingState.initialStartLocation, for: destinationSession) {
                        !Task.isCancelled
                            && self.composerSubmitClaimIsCurrent(claim)
                            && self.sessions[destinationTabID] === destinationSession
                            && self.sessions[target.tabID] === sourceSession
                            && sourceSnapshot.matches(self.sessions[target.tabID])
                            && Self.pendingUserTurnState(from: destinationSession) == pendingState
                    }
                } catch {
                    clearPendingUserTurnState(on: destinationSession)
                    await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                    return .blocked(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
                guard !Task.isCancelled,
                      composerSubmitClaimIsCurrent(claim),
                      sessions[destinationTabID] === destinationSession,
                      sessions[target.tabID] === sourceSession,
                      sourceSnapshot.matches(sessions[target.tabID]),
                      Self.pendingUserTurnState(from: destinationSession) == pendingState
                else {
                    logRejectedSubmitTarget(target, session: sessions[target.tabID], reason: "schedule_state_changed_during_destination_preparation", persistent: true)
                    clearPendingUserTurnState(on: destinationSession)
                    return .blocked(message: Self.staleComposerSubmitTargetMessage)
                }
            }
            destinationSession.pendingInitialStartLocation = .local
            switch await installScheduledSend(
                text: text,
                on: destinationSession,
                notBefore: notBefore,
                runAlongsideOtherSessions: runAlongsideOtherSessions,
                isNewSessionStart: true
            ) {
            case let .success(scheduleID):
                // The destination now owns the attachments and workflow; the source tab keeps
                // its (now sessionless) composer state cleared exactly like a first send.
                clearPendingUserTurnState(on: sourceSession)
                clearComposerDraftIfUnchanged(for: claim)
                if destinationTabID == currentTabID {
                    applySessionToBindings(destinationSession)
                }
                return .scheduled(id: scheduleID)
            case let .failure(failure):
                clearPendingUserTurnState(on: destinationSession)
                await discardFreshFirstSendDestinationIfPossible(destinationTabID)
                return .blocked(message: failure.message)
            }
        }
    }

    struct ScheduledSendInstallFailure: Error, Equatable {
        let message: String
    }

    /// Freezes the session's pending composer state (text, attachments, workflow, interview
    /// flag) into a new scheduled-send record and saves it durably before reporting success.
    /// On failure the pending state is restored untouched so the draft is never lost. Runs as a
    /// serialized schedule action; banner actions queued behind it observe the committed result.
    func installScheduledSend(
        text: String,
        on session: AgentTabSession,
        notBefore: Date,
        runAlongsideOtherSessions: Bool,
        isNewSessionStart: Bool
    ) async -> Result<UUID, ScheduledSendInstallFailure> {
        await runScheduledSendAction(on: session) { [self] in
            await performInstallScheduledSend(
                text: text,
                on: session,
                notBefore: notBefore,
                runAlongsideOtherSessions: runAlongsideOtherSessions,
                isNewSessionStart: isNewSessionStart
            )
        }
    }

    private func performInstallScheduledSend(
        text: String,
        on session: AgentTabSession,
        notBefore: Date,
        runAlongsideOtherSessions: Bool,
        isNewSessionStart: Bool
    ) async -> Result<UUID, ScheduledSendInstallFailure> {
        let tabID = session.tabID
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.remoteHost == nil else {
            return .failure(.init(message: Self.scheduledSendRemoteUnsupportedMessage))
        }
        if let blockedMessage = newWorkBlockedMessage(for: session) {
            return .failure(.init(message: blockedMessage))
        }
        guard session.mcpControlContext == nil, !isMCPControlled(tabID: tabID) else {
            return .failure(.init(message: "This session is controlled by an MCP client and can't schedule messages."))
        }
        guard session.scheduledSend == nil, session.scheduledSendPendingFinalization == nil else {
            return .failure(.init(message: "This session already has a scheduled message. Edit or cancel it first."))
        }
        guard let workspaceID = persistenceWorkspace?.id else {
            return .failure(.init(message: "Open a workspace before scheduling a message."))
        }
        if let blocked = preflightInitialUserTurn(text: trimmedText, session: session),
           case let .blocked(message) = blocked
        {
            return .failure(.init(message: message.isEmpty ? "Type a message or add an attachment before scheduling." : message))
        }
        guard resolvedNativeSlashCommand(in: trimmedText, session: session) == nil else {
            return .failure(.init(message: "Native slash commands can't be scheduled. Send them directly instead."))
        }

        let attachments = session.pendingImageAttachments
        let taggedFiles = session.pendingTaggedFileAttachments
        let selectedWorkflowSnapshot = session.selectedWorkflow
        let bubbleWorkflow: AgentWorkflowDefinition? = if let selectedWorkflowSnapshot {
            selectedWorkflowSnapshot
        } else {
            resolvedSlashSkillInvocations(in: trimmedText).first?.definition.asBubbleWorkflowDefinition()
        }
        let consumesInterviewFirst = effectiveInterviewFirst(for: session) && Self.sessionQualifiesForInterviewFirst(session)
        let now = Date()
        let record = AgentScheduledSendPersist(
            id: UUID(),
            createdAt: now,
            updatedAt: now,
            notBefore: notBefore,
            state: .scheduled,
            confirmationReason: nil,
            rawText: trimmedText,
            attachments: attachments,
            taggedFileAttachments: taggedFiles,
            workflow: bubbleWorkflow,
            interviewFirst: consumesInterviewFirst,
            isNewSessionStart: isNewSessionStart,
            runAlongsideOtherSessions: runAlongsideOtherSessions,
            firstEligibleAt: nil,
            attempt: nil,
            lastFailureMessage: nil
        )

        // Move (never copy) the pending composer state into the record.
        session.pendingImageAttachments.removeAll()
        session.pendingTaggedFileAttachments.removeAll()
        session.selectedWorkflow = nil
        if tabID == currentTabID {
            selectedWorkflow = nil
        }
        if consumesInterviewFirst {
            setInterviewFirst(false, for: session)
        }
        session.scheduledSend = .v1(record)
        session.scheduledSendWorkspaceID = workspaceID
        session.isDirty = true
        updateBindingsFromSession(session)
        syncComposerUIState(tabID: tabID)
        syncStatusPillsUIState()

        let persisted = await commitScheduledSend(
            session: session,
            member: .v1(record),
            expectedUpdatedAt: session.scheduledSendPersistedUpdatedAt
        )
        guard persisted else {
            // Rollback is owned by this action: restore the exact frozen state; never touch files.
            if session.pendingScheduledSendRecord?.id == record.id {
                session.scheduledSend = nil
                session.scheduledSendWorkspaceID = nil
            }
            session.pendingImageAttachments = attachments
            session.pendingTaggedFileAttachments = taggedFiles
            session.selectedWorkflow = selectedWorkflowSnapshot
            if tabID == currentTabID {
                selectedWorkflow = selectedWorkflowSnapshot
            }
            if consumesInterviewFirst {
                setInterviewFirst(true, for: session)
            }
            updateBindingsFromSession(session)
            syncComposerUIState(tabID: tabID)
            syncStatusPillsUIState()
            return .failure(.init(message: "The scheduled message could not be saved. Please try again."))
        }
        if isNewSessionStart,
           AgentSessionTitleNaming.isDefaultSessionTitle(resolvedSessionDisplayName(for: tabID)),
           let derivedName = AgentSessionTitleNaming.derivedSessionName(from: trimmedText)
        {
            renameSession(tabID: tabID, to: derivedName)
        }
        updateLocalSessionIndexScheduledSendSummary(for: session)
        syncSidebarUIState(refresh: true, reason: .sessionIndex)
        notifyScheduledSendRecordChanged()
        return .success(record.id)
    }

    static let scheduledSendRemoteUnsupportedMessage =
        "Scheduled messages aren't available for remote-host sessions yet."

    // MARK: - Banner actions

    func updateScheduledSend(
        tabID: UUID,
        scheduleID: UUID,
        text: String,
        notBefore: Date,
        runAlongsideOtherSessions: Bool,
        removingImageAttachmentIDs: Set<UUID> = [],
        removingTaggedFileAttachmentIDs: Set<UUID> = []
    ) async -> String? {
        guard let session = sessions[tabID] else { return Self.scheduledSendMissingMessage }
        let token = session.activeAgentSessionID.flatMap { sessionID in
            scheduledSendCoordinator?.beginUserSupersession(sessionID: sessionID, scheduleID: scheduleID)
        }
        defer { if let token { scheduledSendCoordinator?.releaseUserSupersession(token) } }
        return await runScheduledSendAction(on: session) { [self] in
            guard let record = session.pendingScheduledSendRecord, record.id == scheduleID else {
                return Self.scheduledSendMissingMessage
            }
            guard !session.ownsLiveScheduledAttempt, record.state != .dispatching else {
                return Self.scheduledSendDispatchingMessage
            }
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let retainedAttachments = record.attachments.filter {
                !removingImageAttachmentIDs.contains($0.id)
            }
            let retainedTaggedFiles = record.taggedFileAttachments.filter {
                !removingTaggedFileAttachmentIDs.contains($0.id)
            }
            guard !trimmedText.isEmpty || !retainedAttachments.isEmpty || !retainedTaggedFiles.isEmpty else {
                return "Type a message or keep an attachment before saving the scheduled message."
            }
            if let timingMessage = AgentScheduledSendTiming.validationMessage(for: notBefore) {
                return timingMessage
            }
            guard resolvedNativeSlashCommand(in: trimmedText, session: session) == nil else {
                return "Native slash commands can't be scheduled. Send them directly instead."
            }
            let removedAttachments = record.attachments.filter {
                removingImageAttachmentIDs.contains($0.id)
            }
            var updated = record
            updated.rawText = trimmedText
            updated.attachments = retainedAttachments
            updated.taggedFileAttachments = retainedTaggedFiles
            updated.notBefore = notBefore
            updated.runAlongsideOtherSessions = runAlongsideOtherSessions
            updated.state = .scheduled
            updated.confirmationReason = nil
            updated.lastFailureMessage = nil
            updated.firstEligibleAt = nil
            updated.updatedAt = Date()
            if let message = await commitScheduledSendChange(updated, previous: record, session: session) {
                return message
            }
            clearScheduledSendAttachmentFiles(
                removedAttachments.filter { removed in
                    !retainedAttachments.contains { retained in
                        Self.scheduledAttachmentLocalPath(retained)
                            == Self.scheduledAttachmentLocalPath(removed)
                    }
                }
            )
            if let token,
               scheduledSendCoordinator?.completeUserSupersession(token, committedRevision: session.scheduledSendPersistedUpdatedAt) == false
            {
                // The user's edit is durable, but a newer clock/wake decision still blocks
                // automatic sending until it is confirmed.
                syncComposerUIState(tabID: tabID)
                return Self.scheduledSendConfirmationChangedMessage
            }
            return nil
        }
    }

    func cancelScheduledSend(tabID: UUID, scheduleID: UUID) async -> String? {
        guard let session = sessions[tabID] else { return Self.scheduledSendMissingMessage }
        let token = session.activeAgentSessionID.flatMap { sessionID in
            scheduledSendCoordinator?.beginUserSupersession(sessionID: sessionID, scheduleID: scheduleID)
        }
        defer { if let token { scheduledSendCoordinator?.releaseUserSupersession(token) } }
        return await runScheduledSendAction(on: session) { [self] in
            guard let record = session.pendingScheduledSendRecord, record.id == scheduleID else {
                return Self.scheduledSendMissingMessage
            }
            guard !session.ownsLiveScheduledAttempt, record.state != .dispatching else {
                return Self.scheduledSendDispatchingMessage
            }
            let expected = session.scheduledSendPersistedUpdatedAt
            session.scheduledSend = nil
            session.isDirty = true
            syncComposerUIState(tabID: tabID)
            let persisted = await commitScheduledSend(session: session, member: nil, expectedUpdatedAt: expected)
            guard persisted else {
                if session.scheduledSend == nil, session.scheduledSendPersistedUpdatedAt == expected {
                    session.scheduledSend = .v1(record)
                    syncComposerUIState(tabID: tabID)
                }
                return "The scheduled message could not be cancelled. Please try again."
            }
            // This action owned the record; nothing else references these managed files.
            clearScheduledSendAttachmentFiles(record.attachments)
            session.scheduledSendWorkspaceID = nil
            if let token {
                // A cancelled schedule no longer requires confirmation; a newer decision (if any)
                // is retired with the schedule on the next evaluation.
                _ = scheduledSendCoordinator?.completeUserSupersession(token, committedRevision: nil)
            }
            if let itemID = record.attempt?.itemID {
                removeUnsentScheduledUserItem(id: itemID, from: session)
            }
            updateLocalSessionIndexScheduledSendSummary(for: session)
            syncSidebarUIState(refresh: true, reason: .sessionIndex)
            notifyScheduledSendRecordChanged()
            return nil
        }
    }

    /// Confirms a pending, needs-confirmation, or failed record and asks the coordinator to
    /// dispatch it as soon as the busy gate allows. The original `notBefore` is kept for the
    /// message marker (plan §6, minor points).
    func sendScheduledSendNow(
        tabID: UUID,
        scheduleID: UUID,
        runAlongsideOtherSessions: Bool
    ) async -> String? {
        guard let session = sessions[tabID] else { return Self.scheduledSendMissingMessage }
        guard let coordinator = scheduledSendCoordinator, let sessionID = session.activeAgentSessionID else {
            return "Scheduled sending is unavailable in this window."
        }
        // User supersession of any pending clock/wake confirmation decision: reserved before the
        // serialized action, consumed only after the durable revision is known. Any coordinator
        // write outstanding for this durable session (possibly on another host) is drained
        // first, outside this tab's serializer, and the durable revision is refreshed from disk so
        // consent is never installed for a revision an older write is about to replace.
        let token = coordinator.beginUserSupersession(sessionID: sessionID, scheduleID: scheduleID)
        defer { coordinator.releaseUserSupersession(token) }
        await coordinator.drainOutstandingHostMutation(sessionID: sessionID)
        return await runScheduledSendAction(on: session) { [self] in
            guard sessions[tabID] === session, session.activeAgentSessionID == sessionID else {
                return Self.scheduledSendMissingMessage
            }
            await coordinator.drainOutstandingHostMutation(sessionID: sessionID)
            // The durable revision is established, never assumed: consent is installed only for a
            // revision this action verified after the drain. A missing or unreadable file is a
            // retryable refusal (the token is released, the pending decision stays), and a binding
            // that changed across any await ends the action without claiming success.
            let resync = await resyncScheduledSendFromDisk(session: session)
            guard sessions[tabID] === session, session.activeAgentSessionID == sessionID else {
                return Self.scheduledSendMissingMessage
            }
            switch resync {
            case .adopted:
                break
            case .staleOwner:
                return Self.scheduledSendMissingMessage
            case .fileMissing, .readFailed:
                syncComposerUIState(tabID: tabID)
                return Self.scheduledSendVerificationFailedMessage
            }
            guard let record = session.pendingScheduledSendRecord, record.id == scheduleID else {
                return Self.scheduledSendMissingMessage
            }
            guard !session.ownsLiveScheduledAttempt, record.state != .dispatching else {
                return Self.scheduledSendDispatchingMessage
            }
            if record.runAlongsideOtherSessions != runAlongsideOtherSessions {
                var updated = record
                updated.runAlongsideOtherSessions = runAlongsideOtherSessions
                updated.updatedAt = Date()
                if let message = await commitScheduledSendChange(updated, previous: record, session: session) {
                    return message
                }
                guard sessions[tabID] === session, session.activeAgentSessionID == sessionID else {
                    return Self.scheduledSendMissingMessage
                }
            }
            // Consent targets exactly the verified projected revision.
            guard let committedRevision = session.scheduledSendPersistedUpdatedAt,
                  let verifiedRecord = session.pendingScheduledSendRecord,
                  verifiedRecord.id == scheduleID,
                  verifiedRecord.updatedAt == committedRevision
            else {
                syncComposerUIState(tabID: tabID)
                return Self.scheduledSendVerificationFailedMessage
            }
            guard coordinator.completeUserSupersession(token, committedRevision: committedRevision) else {
                syncComposerUIState(tabID: tabID)
                return Self.scheduledSendConfirmationChangedMessage
            }
            let disposition = coordinator.confirmAndSendNow(
                scheduleID: scheduleID,
                runAlongsideOtherSessions: runAlongsideOtherSessions,
                committedRevision: committedRevision
            )
            syncComposerUIState(tabID: tabID)
            switch disposition {
            case let .rejected(refusal):
                return Self.scheduledSendNowRefusalMessage(refusal)
            case .blocked, .progressing:
                // Consent is recorded; a recovery blocker is shown persistently in the banner.
                return nil
            }
        }
    }

    /// F6 / review B R1: why a due scheduled message was refused durable admission. The schedule is
    /// then marked failed (it is not retried automatically), so every case says it was not sent.
    static func scheduledRecoveryAdmissionRefusalMessage(_ refusal: AgentRecoveryAdmissionRefusal) -> String {
        switch refusal {
        case .startupNotReady:
            "The scheduled message was not sent because RepoPrompt was still checking what was interrupted by the last restart."
        case let .startupFailed(reason):
            // Already plain: `AgentRecoveryStorageFailureCause.startupFailureDescription`.
            "The scheduled message was not sent. \(reason)"
        case let .restricted(reason):
            "The scheduled message was not sent: \(reason) Review it in the recovery banner."
        case .crashHeld:
            "The scheduled message was not sent because the previous run in this session may still have been working when RepoPrompt closed. Confirm it stopped from the recovery banner."
        case .unsavedPredecessorInput:
            "The scheduled message was not sent because earlier unsaved input in this session needs to be restored or discarded first (recovery banner)."
        case .resetPreparationInProgress:
            "The scheduled message was not sent because the conversation was being cleared."
        case .shutdownInProgress:
            "The scheduled message was not sent because RepoPrompt was saving this session before closing."
        case .recoveryActionInProgress:
            "The scheduled message was not sent because a recovery choice in this workspace was in progress."
        case .laneRetired, .bindingMismatch:
            "The scheduled message was not sent because the session changed before it could be saved."
        case .composerUnavailable, .untrackedInput:
            "The scheduled message could not be saved for recovery, so it was not sent."
        }
    }

    /// User-facing text for a Send now that installed no consent (one per scheduler early return).
    static func scheduledSendNowRefusalMessage(_ refusal: AgentScheduledSendNowRefusal) -> String {
        switch refusal {
        case .startupAdmissionClosed(.recoveryFailed):
            "Scheduled sending is paused because the recovery check failed. Retry it, then try Send now again."
        case .startupAdmissionClosed:
            "RepoPrompt is still checking for interrupted work. Try Send now again in a moment."
        case .transferHeld:
            "The last send of this message is still being checked. It won't be sent again until that finishes."
        case .confirmationPending:
            scheduledSendConfirmationChangedMessage
        case .scheduleNotFound:
            "The scheduler can't see this message right now. Please try again."
        }
    }

    static let scheduledSendConfirmationChangedMessage =
        "The system clock or wake state changed again. Review the scheduled message and confirm it once more."

    /// Send now could not establish the saved revision it would confirm (missing or unreadable
    /// session file after the drain). Retryable: no consent was installed and nothing was sent.
    static let scheduledSendVerificationFailedMessage =
        "The scheduled message couldn't be verified against the saved session. Please try again."

    /// Discards a persisted scheduled-send member this build cannot read (plan §3.1). The CAS
    /// compares the semantic JSON value so a member replaced by another writer is never dropped.
    func discardUnreadableScheduledSend(tabID: UUID) async -> String? {
        guard let session = sessions[tabID] else { return Self.scheduledSendMissingMessage }
        return await runScheduledSendAction(on: session) { [self] in
            guard case let .unreadable(jsonValue)? = session.scheduledSend else {
                return Self.scheduledSendMissingMessage
            }
            guard let workspace = persistenceWorkspace,
                  let sessionID = ensureSessionBoundToTab(session),
                  let persistenceState = await ensurePersistenceState(for: session, sessionID: sessionID, workspace: workspace)
            else {
                return "The scheduled message could not be discarded. Please try again."
            }
            do {
                _ = try await dataService.mutateScheduledSend(
                    sessionID: sessionID,
                    for: workspace,
                    persistenceStamp: persistenceState.stamp,
                    mutation: .discardUnreadable(expected: jsonValue)
                )
            } catch AgentScheduledSendMutationError.staleExpectedScheduledSendMember {
                await resyncScheduledSendFromDisk(session: session)
                return "The scheduled message changed elsewhere. Check the session again."
            } catch AgentScheduledSendMutationError.sessionNotFound {
                // Nothing durable holds the member; dropping it locally is complete.
            } catch {
                return "The scheduled message could not be discarded. Please try again."
            }
            session.scheduledSend = nil
            session.scheduledSendPersistedUpdatedAt = nil
            session.scheduledSendWorkspaceID = nil
            session.isDirty = true
            syncComposerUIState(tabID: tabID)
            updateLocalSessionIndexScheduledSendSummary(for: session)
            syncSidebarUIState(refresh: true, reason: .sessionIndex)
            postScheduledSendCommitNotification(sessionID: sessionID)
            notifyScheduledSendRecordChanged()
            return nil
        }
    }

    private static let scheduledSendMissingMessage = "This scheduled message no longer exists."
    private static let scheduledSendDispatchingMessage = "This scheduled message is being sent right now."

    private func commitScheduledSendChange(
        _ updated: AgentScheduledSendPersist,
        previous: AgentScheduledSendPersist,
        session: AgentTabSession
    ) async -> String? {
        let expected = session.scheduledSendPersistedUpdatedAt
        session.scheduledSend = .v1(updated)
        session.isDirty = true
        syncComposerUIState(tabID: session.tabID)
        let persisted = await commitScheduledSend(session: session, member: .v1(updated), expectedUpdatedAt: expected)
        guard persisted else {
            if session.pendingScheduledSendRecord == updated, session.scheduledSendPersistedUpdatedAt == expected {
                session.scheduledSend = .v1(previous)
                syncComposerUIState(tabID: session.tabID)
            }
            return "The scheduled message could not be saved. Please try again."
        }
        updateLocalSessionIndexScheduledSendSummary(for: session)
        notifyScheduledSendRecordChanged()
        return nil
    }

    // MARK: - Persistence lifetime (captured state)

    /// Returns this tab's captured persistence state for `sessionID`. State enters a tab only
    /// through the paired hydration load (`applyPersistedHydration`), this owner's own commits, or
    /// durable exclusive creation of a session that has never been persisted. Creation requires
    /// `initialSession` (the owner's full persisted payload) and commits the session file before any
    /// state is returned; without it, a never-persisted session has no authority (`nil`). An
    /// incarnation that exists on disk but was not hydrated by this tab is not adoptable here, and a
    /// revoked lifetime is never re-acquired.
    func ensurePersistenceState(
        for session: AgentTabSession,
        sessionID: UUID,
        workspace: WorkspaceModel,
        context: SessionPersistenceContext? = nil,
        initialSession: AgentSession? = nil,
        trustedCanonicalItemCount: Int? = nil
    ) async -> AgentSessionPersistenceState? {
        await acquirePersistenceState(
            for: session,
            sessionID: sessionID,
            workspace: workspace,
            context: context,
            initialSession: initialSession,
            trustedCanonicalItemCount: trustedCanonicalItemCount
        ).state
    }

    /// `ensurePersistenceState` plus whether this call durably created the session file from
    /// `initialSession`. `createdDurably` is `true` even when the created authority is not returned
    /// for the current save (context no longer current, owner replaced or revoked), so the save
    /// can report the committed snapshot honestly instead of "nothing written".
    func acquirePersistenceState(
        for session: AgentTabSession,
        sessionID: UUID,
        workspace: WorkspaceModel,
        context: SessionPersistenceContext? = nil,
        initialSession: AgentSession? = nil,
        trustedCanonicalItemCount: Int? = nil
    ) async -> (state: AgentSessionPersistenceState?, createdDurably: Bool) {
        guard context == nil || (
            context?.workspaceID == workspace.id
                && context.map { self.sessionPersistenceContextIsCurrent($0) } == true
        ) else { return (nil, false) }
        if let state = session.persistenceState(for: sessionID), state.stamp.workspaceID == workspace.id {
            return (state, false)
        }
        guard session.persistenceRevokedSessionID != sessionID,
              session.persistedIncarnationSessionID != sessionID,
              let initialSession,
              initialSession.id == sessionID
        else { return (nil, false) }
        #if DEBUG
            if let hook = test_initialPersistencePreparationHook {
                await hook(session)
            }
        #endif
        guard context == nil || context.map({ self.sessionPersistenceContextIsCurrent($0) }) == true else {
            return (nil, false)
        }
        // Exact originating owner lifetime: a rebinding (even to the same ID) mints a new binding
        // generation and acquires authority only through its own paired hydration load.
        let originBinding = session.persistentSessionBindingIdentity
        let prepared: AgentSessionPersistenceState
        do {
            prepared = try await dataService.prepareInitialAgentSessionPersistence(
                initialSession: initialSession,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: trustedCanonicalItemCount
            ).persistenceState
        } catch AgentScheduledSendMutationError.sessionAlreadyExists {
            // Not this tab's incarnation (or another creator won): ownership comes only from a
            // paired hydration load; the winner is never adopted from here.
            return (nil, false)
        } catch {
            print("[AgentModeVM][Persistence] could not create the initial session file: \(error)")
            return (nil, false)
        }
        #if DEBUG
            if let hook = test_initialPersistenceCommittedHook {
                await hook(session)
            }
        #endif
        // The file is committed and this creator's authority is the only way to reach it again.
        // Retain it for the exact originating owner lifetime whether or not the persistence
        // context is still current, so a later save of the same owner never re-attempts creation
        // (which would fail with `sessionAlreadyExists` and leave the tab unable to save). A
        // replaced tab, a rebinding, or a revoked lifetime never adopts it. The stamp pins its own
        // workspace, and the first guard already rejected a workspace mismatch.
        guard sessions[session.tabID] === session,
              session.persistentSessionBindingIdentity == originBinding,
              session.activeAgentSessionID == sessionID,
              session.persistenceRevokedSessionID != sessionID
        else { return (nil, true) }
        let owned: AgentSessionPersistenceState
        if let existing = session.persistenceState(for: sessionID) {
            // A concurrent capture already established ownership; never replace it.
            owned = existing
        } else {
            session.persistenceState = prepared
            recoveryPersistenceStateDidChange(for: session)
            session.persistedIncarnationSessionID = sessionID
            owned = prepared
        }
        // Only this call's current-save use of the authority is context-sensitive.
        guard context == nil || context.map({ self.sessionPersistenceContextIsCurrent($0) }) == true else {
            return (nil, true)
        }
        return (owned, true)
    }

    // MARK: - Persistence (CAS)

    /// Commits an immutable desired schedule member for `session` through the data service CAS.
    /// `expectedUpdatedAt` is the on-disk revision this action observed; the first durable write
    /// of a session that has no file yet falls back to a full save (which writes supplied schedule
    /// fields only on creation) and then re-runs the CAS. The persistence target is pinned to the
    /// workspace that owns the schedule.
    @discardableResult
    func commitScheduledSend(
        session: AgentTabSession,
        member: AgentScheduledSendMember?,
        expectedUpdatedAt: Date?,
        completedDispatch: AgentScheduledSendProvenance? = nil
    ) async -> Bool {
        if case .committed = await commitScheduledSendDetailed(
            session: session,
            member: member,
            expectedUpdatedAt: expectedUpdatedAt,
            completedDispatch: completedDispatch
        ) {
            return true
        }
        return false
    }

    /// Precise outcome of one durable schedule commit: the coordinator's acknowledged mutations
    /// distinguish a real commit from conflict, unavailability, deletion, and write failure.
    func commitScheduledSendDetailed(
        session: AgentTabSession,
        member: AgentScheduledSendMember?,
        expectedUpdatedAt: Date?,
        completedDispatch: AgentScheduledSendProvenance? = nil
    ) async -> AgentScheduledSendHostMutationOutcome {
        guard !AppLaunchConfiguration.current.suppressesAgentSessionPersistence else { return .committed(committedUpdatedAt: nil) }
        guard let workspace = scheduledSendPersistenceWorkspace(for: session),
              let sessionID = ensureSessionBoundToTab(session)
        else { return .unavailable }

        let mutation: AgentScheduledSendMutation
        switch member {
        case let .v1(record)?:
            mutation = .upsert(expectedUpdatedAt: expectedUpdatedAt, value: record)
        case .unreadable?:
            return .failed("Unreadable scheduled messages cannot be written.")
        case nil:
            guard let expectedUpdatedAt else {
                if let completedDispatch {
                    session.lastScheduledDispatch = completedDispatch
                }
                return .committed(committedUpdatedAt: nil)
            }
            mutation = .clear(expectedUpdatedAt: expectedUpdatedAt, completedDispatch: completedDispatch)
        }

        var attemptedCreation = false
        while true {
            // A never-persisted session has no CAS authority (`ensurePersistenceState` without
            // `initialSession` returns nil): until this owner's first full save has exclusively
            // created the file (`persistedIncarnationSessionID`), a schedule CAS never targets or
            // creates it. A failed creation captures no authority and is retried by a later save.
            if expectedUpdatedAt == nil,
               session.persistedIncarnationSessionID != sessionID,
               session.persistenceRevokedSessionID != sessionID
            {
                // Genuine initial creation: the full save commits the file from the owner's
                // snapshot (including this member) and adopts its authority before the CAS below.
                guard !attemptedCreation, member != nil else {
                    return .failed("The session file could not be created.")
                }
                attemptedCreation = true
                session.isDirty = true
                // Creation needs durable commitment, not a clean projection: a request that
                // coalesced behind the write only leaves the projection dirty (a fresh save is
                // already requested). The CAS below verifies the exact installed record against
                // the created file, so a durable write is never reported as creation failure.
                let creation = await flushSaveDetailed(for: session.tabID)
                guard creation.didWriteDurably else {
                    return .failed("The session file could not be created.")
                }
                // A durable creation is reported even when this owner was rebound during it; the
                // CAS below only proceeds for the captured binding and its own incarnation, so a
                // rebound tab rolls the schedule back instead of carrying it into another session.
                guard session.activeAgentSessionID == sessionID,
                      session.persistedIncarnationSessionID == sessionID
                else {
                    return .failed("The session changed while its file was being created.")
                }
                continue
            }
            guard let persistenceState = await ensurePersistenceState(for: session, sessionID: sessionID, workspace: workspace) else {
                return session.persistenceRevokedSessionID == sessionID ? .destinationDeleted : .unavailable
            }
            do {
                let result = try await dataService.mutateScheduledSend(
                    sessionID: sessionID,
                    for: workspace,
                    persistenceStamp: persistenceState.stamp,
                    mutation: mutation
                )
                let committedUpdatedAt = result.session.scheduledSend?.persistedValue?.updatedAt
                session.scheduledSendPersistedUpdatedAt = committedUpdatedAt
                session.lastScheduledDispatch = result.session.lastScheduledDispatch
                if case let .repairNeeded(detail) = result.metadataIndexStatus {
                    // Committed success: the session file is authoritative; the index self-repairs.
                    print("[AgentModeVM][ScheduledSend] metadata index repair needed after commit: \(detail)")
                }
                postScheduledSendCommitNotification(sessionID: sessionID)
                return .committed(committedUpdatedAt: committedUpdatedAt)
            } catch AgentScheduledSendMutationError.staleDeletionGeneration,
                AgentScheduledSendMutationError.invalidPersistenceStamp,
                AgentScheduledSendMutationError.sessionDeleted,
                AgentScheduledSendMutationError.staleIncarnation
            {
                // Committed deletion or a stale lifetime for this exact owner: never recreate the
                // file or refresh the stamp from this tab's state.
                handleDurableSessionDeleted(session, sessionID: sessionID)
                return .destinationDeleted
            } catch AgentScheduledSendMutationError.sessionNotFound {
                // Valid lifetime, file missing: accidental loss, not deletion. Nothing is revoked or
                // recreated here; the retained recovery reconstructs it and the write is retried.
                return .failed("The session file is missing; it will be restored before this change is saved.")
            } catch let AgentScheduledSendMutationError.staleExpectedUpdatedAt(_, actual) {
                if let actual, actual == member?.persistedValue?.updatedAt {
                    // A full save already created the file with this exact record.
                    session.scheduledSendPersistedUpdatedAt = actual
                    if let completedDispatch {
                        session.lastScheduledDispatch = completedDispatch
                    }
                    return .committed(committedUpdatedAt: actual)
                }
                await resyncScheduledSendFromDisk(session: session)
                return .conflict
            } catch AgentScheduledSendMutationError.staleExpectedAttempt,
                AgentScheduledSendMutationError.scheduledSendNotDispatching,
                AgentScheduledSendMutationError.staleExpectedScheduledSendMember
            {
                await resyncScheduledSendFromDisk(session: session)
                return .conflict
            } catch {
                print("[AgentModeVM][ScheduledSend] persistence failed: \(error)")
                return .failed(String(describing: error))
            }
        }
    }

    private func scheduledSendPersistenceWorkspace(for session: AgentTabSession) -> WorkspaceModel? {
        guard let workspace = persistenceWorkspace else { return nil }
        if let pinned = session.scheduledSendWorkspaceID, pinned != workspace.id {
            print("[AgentModeVM][ScheduledSend] refusing to persist schedule for workspace \(pinned) into \(workspace.id)")
            return nil
        }
        return workspace
    }

    /// Result of one authoritative schedule resync. Only `.adopted` establishes a verified
    /// durable revision; every other case leaves the local projection untouched.
    enum ScheduledSendResyncOutcome: Equatable {
        /// The on-disk record was installed on the captured owner at this persisted revision.
        case adopted(persistedUpdatedAt: Date?)
        /// No file exists for the durable session (accidental loss, not deletion evidence).
        case fileMissing
        /// The storage read threw.
        case readFailed
        /// No persistence target, or the captured tab no longer projects this durable session.
        case staleOwner
    }

    /// Another writer (window) changed the persisted schedule: adopt disk as the authority. A
    /// missing file is *not* deletion evidence (committed deletion arrives through the data
    /// service's deletion event or a stale-lifetime error) and leaves projections, ownership, and
    /// any retained recovery untouched; a read error leaves the projection as well. The captured
    /// owner is re-validated after the read, and coordinator-owned recovery is reconciled from the
    /// authoritative record even when no further recovery notification will arrive. The returned
    /// outcome lets callers that must act on a verified revision (Send now) distinguish an
    /// authoritative snapshot from a missing, failed, or stale-owner read.
    @discardableResult
    func resyncScheduledSendFromDisk(session: AgentTabSession) async -> ScheduledSendResyncOutcome {
        guard let workspace = scheduledSendPersistenceWorkspace(for: session),
              let sessionID = session.activeAgentSessionID
        else { return .staleOwner }
        let persisted: AgentSession
        do {
            #if DEBUG
                if let injected = test_scheduledSendResyncReadFailureInjector?(sessionID) {
                    throw injected
                }
            #endif
            guard let loaded = try await dataService.loadAgentSession(id: sessionID, for: workspace) else {
                return .fileMissing
            }
            persisted = loaded
        } catch {
            return .readFailed
        }
        guard sessions[session.tabID] === session, session.activeAgentSessionID == sessionID else { return .staleOwner }
        defer { adoptScheduledSendRecoveryProjection(for: session) }
        session.scheduledSend = persisted.scheduledSend
        session.lastScheduledDispatch = persisted.lastScheduledDispatch
        session.scheduledSendPersistedUpdatedAt = persisted.scheduledSend?.persistedValue?.updatedAt
        if persisted.scheduledSend == nil {
            session.scheduledSendWorkspaceID = nil
        } else if session.scheduledSendWorkspaceID == nil {
            session.scheduledSendWorkspaceID = persisted.workspaceID ?? workspace.id
        }
        reconcileProvenanceForFinalizedItems(in: session, persisted: persisted)
        updateLocalSessionIndexScheduledSendSummary(for: session)
        syncComposerUIState(tabID: session.tabID)
        notifyScheduledSendRecordChanged()
        return .adopted(persistedUpdatedAt: session.scheduledSendPersistedUpdatedAt)
    }

    /// A finalization committed elsewhere carries the accepted item's marker; mirror it locally so
    /// a second window never shows an unmarked bubble for a delivered scheduled message.
    private func reconcileProvenanceForFinalizedItems(in session: AgentTabSession, persisted: AgentSession) {
        guard let receipt = persisted.lastScheduledDispatch else { return }
        let stampedIDs = Set(
            (persisted.transcript?.turns ?? []).compactMap { turn -> UUID? in
                guard let request = turn.request, request.scheduledSend == receipt else { return nil }
                return request.id
            }
        )
        for itemID in stampedIDs {
            stampScheduledSendProvenance(receipt, onItemID: itemID, in: session)
        }
    }

    // MARK: - Hydration

    /// Installs persisted schedule state on hydration and normalizes restart cases (plan §3.3).
    /// Items are installed earlier in `applyPersistedHydration` (`hydrateSession(...)`), so the
    /// provenance and duplicate-item checks below observe the hydrated transcript.
    /// A `.dispatching` record whose session holds a live admission in this process (another
    /// window is mid-dispatch) is projected as-is and reconciled from the owner's commit.
    func installHydratedScheduledSend(from agentSession: AgentSession, into session: AgentTabSession) {
        if agentSession.fileURL != nil {
            // Projection of an on-disk incarnation: later saves must not recreate it after
            // deletion. Persistence state itself arrives only with the paired hydration load.
            session.persistedIncarnationSessionID = agentSession.id
        }
        session.lastScheduledDispatch = agentSession.lastScheduledDispatch
        session.scheduledSendPersistedUpdatedAt = agentSession.scheduledSend?.persistedValue?.updatedAt
        session.isScheduledDispatchInFlight = false
        session.scheduledSendWorkspaceID = agentSession.scheduledSend == nil
            ? nil
            : (agentSession.workspaceID ?? persistenceWorkspace?.id)
        guard let member = agentSession.scheduledSend else {
            session.scheduledSend = nil
            return
        }
        guard case let .v1(record) = member else {
            session.scheduledSend = member
            return
        }
        let alreadyDelivered = agentSession.lastScheduledDispatch?.scheduleID == record.id
            || session.items.contains { $0.scheduledSend?.scheduleID == record.id }
        if alreadyDelivered {
            session.scheduledSend = nil
            let expected = record.updatedAt
            Task { @MainActor [weak self] in
                guard let self else { return }
                await runScheduledSendAction(on: session) {
                    _ = await self.commitScheduledSend(session: session, member: nil, expectedUpdatedAt: expected)
                }
            }
            return
        }
        guard record.state == .dispatching else {
            session.scheduledSend = member
            return
        }
        if scheduledSendCoordinator?.activeAdmission(sessionID: agentSession.id) != nil {
            // Live attempt owned by this process: project without normalizing. Once acceptance
            // is retained, this host presents the recovery from coordinator-owned values.
            session.scheduledSend = member
            adoptScheduledSendRecoveryProjection(for: session)
            return
        }
        if session.recoveryAdmissionMode == .mandatory {
            // Lossless-restart barrier: the attempt may already have been transferred to a durable
            // recovery intent. Project it as-is and hold it (no delivery-unknown confirmation, no
            // dispatch) until startup reconciliation released admission and the R9 repair ran.
            session.scheduledSend = member
            if let attempt = record.attempt {
                scheduledSendCoordinator?.holdTransfer(AgentScheduledSendTransferHold(
                    sessionID: agentSession.id,
                    scheduleID: record.id,
                    scheduleAttemptID: attempt.attemptID,
                    reason: .awaitingRecovery
                ))
            }
            resolveScheduledSendTransfer(for: session, record: record)
            return
        }
        normalizeInterruptedScheduledDispatch(record, in: session)
    }

    /// Legacy restart normalization of an unowned `.dispatching` attempt: delivery is unknown and
    /// sending again needs explicit confirmation.
    private func normalizeInterruptedScheduledDispatch(_ record: AgentScheduledSendPersist, in session: AgentTabSession) {
        let duplicateItemExists = record.attempt.map { attempt in
            session.items.contains { $0.id == attempt.itemID }
        } ?? false
        let normalized = AgentScheduledSendTransfer.deliveryUnknownNormalization(
            of: record,
            duplicateItemExists: duplicateItemExists
        )
        session.scheduledSend = .v1(normalized)
        let expected = record.updatedAt
        Task { @MainActor [weak self] in
            guard let self else { return }
            await runScheduledSendAction(on: session) {
                guard session.pendingScheduledSendRecord == normalized else { return }
                _ = await self.commitScheduledSend(session: session, member: .v1(normalized), expectedUpdatedAt: expected)
                self.updateLocalSessionIndexScheduledSendSummary(for: session)
            }
        }
    }

    // MARK: - R9 receipt transfer (lossless restart, mandatory recovery only)

    /// Unresolved lossless-restart recovery for `session`: an unresolved receipt transfer, an
    /// unconfirmed crash hold, missing mandatory recovery dependencies, or an unowned
    /// `.dispatching` attempt still awaiting repair. Reported as busy so the scheduler never admits.
    func scheduledSendHasUnresolvedRecovery(_ session: AgentTabSession) -> Bool {
        guard let sessionID = session.activeAgentSessionID else { return false }
        if scheduledSendCoordinator?.transferHold(sessionID: sessionID) != nil {
            return true
        }
        // An explicit recovery action of this session or its workspace is between its acquisition and
        // its recorded outcome (review A P1-01 / B F3a). The projection comes from the app-shared
        // coordinator hold (cross-window): automatic work waits, `runAlongsideOtherSessions`
        // included. The action's own normal dispatch never consults this.
        if recoveryCoordinator?.isCoveredByRecoveryAction(sessionID: sessionID) == true {
            return true
        }
        if let recoveryCoordinator {
            // Startup restrictions (unknown status, duplicate destination, unreadable workspace).
            if recoveryCoordinator.restrictions.blocks(
                sessionID: sessionID,
                workspaceID: session.scheduledSendWorkspaceID ?? persistenceWorkspace?.id
            ) {
                return true
            }
            // R6: a possible other writer of its conversation, an unassociated writer or tool-only
            // survivor on its worktree, or global ownership uncertainty keeps automatic work paused.
            // Keys come from this session object itself (hydrated scheduler candidates included), not
            // only from the windows hosting it.
            if recoveryCoordinator.runtimeBlocksAutomaticWork(
                sessionID: sessionID,
                additionalKeys: runtimeOwnershipKeys(for: session),
                worktreeUnresolved: runtimeWorktreeIsUnresolved(for: session)
            ) {
                return true
            }
            if let lane = session.recoveryLane, lane.sessionID == sessionID {
                if recoveryCoordinator.blockingCrashHold(for: lane.binding) != nil {
                    return true
                }
            } else if recoveryCoordinator.crashHold(for: sessionID) != nil {
                return true
            }
        }
        guard session.recoveryAdmissionMode == .mandatory else { return false }
        // Mandatory recovery fails closed when its dependencies are missing.
        guard recoveryCoordinator != nil, session.recoveryLane != nil else { return true }
        if session.pendingScheduledSendRecord?.state == .dispatching,
           !session.ownsLiveScheduledAttempt,
           scheduledSendCoordinator?.activeAdmission(sessionID: sessionID) == nil
        {
            return true
        }
        return false
    }

    /// Re-runs the R9 repair for a mandatory-recovery session whose `.dispatching` attempt is
    /// projected but unresolved (lane claimed later, startup retried, or a held transfer). Safe to
    /// call repeatedly; it only acts on the exact projected attempt.
    func retryScheduledSendTransferIfNeeded(for session: AgentTabSession) {
        guard session.recoveryAdmissionMode == .mandatory,
              !session.ownsLiveScheduledAttempt,
              let record = session.pendingScheduledSendRecord,
              record.state == .dispatching
        else { return }
        resolveScheduledSendTransfer(for: session, record: record)
    }

    /// Outcome of one R9 transfer repair of a session's projected `.dispatching` attempt.
    enum ScheduledSendTransferRepairOutcome: Equatable {
        /// Nothing to repair: no pending unowned `.dispatching` attempt, or it changed meanwhile.
        case notApplicable
        /// The receipt was committed and the pending schedule cleared in one CAS.
        case completed(AgentScheduledSendProvenance)
        /// No linked intent (or this attempt's own rollback): the legacy delivery-unknown
        /// normalization was projected and its commit queued.
        case normalized
        /// Held (pending schedule and payload unchanged) until explicit resolution.
        case held(String)
        /// The entry's preconditions were not met; nothing was read or written.
        case refused(String)
    }

    /// Startup-reconcile entry for the R9 transfer repair (the final activation's eager sweep).
    /// Runs the same repair as hydration, but from inside the recovery coordinator's `Reconcile`
    /// closure, so the transfer is decided before either barrier opens. It never awaits a startup
    /// barrier (awaiting `awaitStartup()` from reconciliation would deadlock) and never opens one;
    /// public hydration repair, evaluation, consent, and dispatch stay blocked until they open.
    ///
    /// Authority is the foundation lane, not the barriers. Refused (nothing read or written) unless:
    /// - the scheduler's startup admission is `.awaitingRecovery` (this entry exists only before the
    ///   gates open; after that, hydration repair and `retryScheduledSendTransferIfNeeded` apply);
    /// - the recovery coordinator is `.loading` (its reconciliation is running);
    /// - the session is mandatory, hydrated, not stale-reset, and its lane was claimed through this
    ///   coordinator's DataService gate (same store), is not retired, and binds its active session.
    /// The outcome is decided inside the session's serialized schedule action.
    func repairScheduledSendTransferForRecoveryStartup(
        for session: AgentTabSession
    ) async -> ScheduledSendTransferRepairOutcome {
        guard let scheduler = scheduledSendCoordinator,
              case .awaitingRecovery = scheduler.startupAdmission
        else {
            return .refused("The scheduler is not waiting for recovery startup.")
        }
        guard let recoveryCoordinator, recoveryCoordinator.startupState == .loading else {
            return .refused("Recovery reconciliation is not running.")
        }
        guard session.recoveryAdmissionMode == .mandatory,
              session.hasLoadedPersistedState,
              session.staleResetRecovery == nil,
              let sessionID = session.activeAgentSessionID,
              let lane = session.recoveryLane,
              !lane.isRetired,
              lane.sessionID == sessionID,
              lane.store === recoveryCoordinator.store
        else {
            return .refused("The session has no current recovery lane.")
        }
        guard let record = session.pendingScheduledSendRecord,
              record.state == .dispatching,
              !session.ownsLiveScheduledAttempt
        else {
            return .notApplicable
        }
        // Hydration normally installed this already; the hold must exist before any read.
        holdScheduledSendTransfer(sessionID: sessionID, record: record, reason: .awaitingRecovery)
        return await runScheduledSendAction(on: session) {
            await self.performScheduledSendTransferRepair(session: session, sessionID: sessionID, record: record)
        }
    }

    /// Bounded wait for the dispatch that installed an `.awaitingProviderEvidence` hold to release its
    /// in-flight ownership. Delivery evidence itself is never polled: the lane's settle signal wakes
    /// the re-check when a late evidence write lands.
    static let scheduledEvidenceRecheckAttempts = 40
    static let scheduledEvidenceRecheckDelay: Duration = .milliseconds(50)

    /// Re-runs the R9 repair once for an `.awaitingProviderEvidence` hold of `session` while its run is
    /// not active, after every delivery-evidence write tracked by the session's lane has landed
    /// (accepted → `providerAccepted`, settled back → `savedInQueue`, uncertain → unresolved hold).
    /// A still-`dispatching` intent stays held (fail-safe) until the next trigger: a run-state
    /// change, or `agentRecoveryDeliveryEvidenceDidSettle` for the lane. Never confirms, retries
    /// delivery, or releases attachments.
    func recheckScheduledSendTransferAwaitingEvidence(for session: AgentTabSession) {
        guard session.recoveryAdmissionMode == .mandatory,
              !session.runState.isActive,
              let sessionID = session.activeAgentSessionID,
              let hold = scheduledSendCoordinator?.transferHold(sessionID: sessionID),
              hold.reason == .awaitingProviderEvidence
        else { return }
        Task { @MainActor [weak self, weak session] in
            for attempt in 0 ..< Self.scheduledEvidenceRecheckAttempts {
                if attempt > 0 {
                    try? await Task.sleep(for: Self.scheduledEvidenceRecheckDelay)
                }
                // Evidence enqueued so far lands first; later writes wake a new re-check.
                await session?.recoveryLane?.deliveryEvidenceWritesSettled()
                guard let self, let session,
                      !session.runState.isActive,
                      session.activeAgentSessionID == sessionID,
                      let current = scheduledSendCoordinator?.transferHold(scheduleID: hold.scheduleID),
                      current.scheduleAttemptID == hold.scheduleAttemptID,
                      current.reason == .awaitingProviderEvidence
                else { return }
                // The dispatch that installed the hold may still be finishing (in-flight ownership).
                guard !session.ownsLiveScheduledAttempt,
                      scheduledSendCoordinator?.activeAdmission(sessionID: sessionID) == nil
                else { continue }
                guard let record = session.pendingScheduledSendRecord,
                      record.id == hold.scheduleID,
                      record.attempt?.attemptID == hold.scheduleAttemptID,
                      record.state == .dispatching
                else { return }
                await runScheduledSendAction(on: session) {
                    // F1: a run-start handoff still owned by its runner is never decided here.
                    switch await self.settleScheduledDeferredHandoffIfNeeded(session: session, sessionID: sessionID, record: record) {
                    case .notDeferred:
                        _ = await self.performScheduledSendTransferRepair(session: session, sessionID: sessionID, record: record)
                    case .pending, .undecided, .resolved:
                        break
                    }
                }
                // Still awaiting evidence: the lane's settle signal (or a run-state change) re-checks.
                return
            }
        }
    }

    private enum ScheduledDeferredHandoffSettlement {
        /// Read succeeded and no deferred run-start handoff owns the linked intent (no registry entry,
        /// or the intent already has a delivery attempt): the R9 repair decides.
        case notDeferred
        /// Its runner still owes the commit or a no-handoff settlement: keep holding.
        case pending
        /// Nothing could be read safely (owner not current; lane unavailable, retired, or another
        /// session's; record read failed): decide nothing.
        case undecided
        /// The handoff's proven no-handoff was applied (or the release failed and is held).
        case resolved
    }

    /// F1: an `.awaitingProviderEvidence` hold whose linked intent is carried by a deferred run-start
    /// handoff (adopted plan §5). While that handoff is pending nothing is decided: a `queued` intent
    /// is not proof of non-handoff, and the R9 repair would read it as saved input. Only the handoff's
    /// own no-handoff settlement, with the intent still `queued` and no delivery attempt, withdraws
    /// the intent, removes the scheduled bubble, and fails the schedule with the scheduled
    /// explanation (the handoff's own reason is logged). A committed handoff is left to the R9
    /// repair (acceptance evidence, never the commit, is Sent). The settlement is read from the
    /// coordinator's registry, so a successor owner sees its predecessor's pending handoff.
    private func settleScheduledDeferredHandoffIfNeeded(
        session: AgentTabSession,
        sessionID: UUID,
        record: AgentScheduledSendPersist
    ) async -> ScheduledDeferredHandoffSettlement {
        guard scheduledSendTransferOwnerIsCurrent(session, sessionID: sessionID, record: record),
              let attempt = record.attempt,
              let lane = session.recoveryLane,
              !lane.isRetired,
              lane.sessionID == sessionID,
              case let .success(recoveryRecord) = await lane.readRecord()
        else { return .undecided }
        guard let intentID = AgentScheduledSendTransfer.linkedIntentID(record: record, recoveryRecord: recoveryRecord),
              let state = lane.deferredRunStartHandoffState(intentID: intentID),
              AgentScheduledSendTransfer.intentNeverDispatched(intentID: intentID, in: recoveryRecord)
        else { return .notDeferred }
        guard case let .notHandedOff(message) = state else { return .pending }
        guard scheduledSendTransferOwnerIsCurrent(session, sessionID: sessionID, record: record),
              session.recoveryLane === lane
        else { return .undecided }
        // The handoff's own settlement is consumed here, whatever the release outcome.
        lane.clearDeferredRunStartHandoff(intentID: intentID)
        guard case .success = await lane.withdraw(intentID: intentID) else {
            holdScheduledSendTransfer(
                sessionID: sessionID,
                record: record,
                reason: .unresolved("This scheduled message's saved copy could not be released.")
            )
            syncComposerUIState(tabID: session.tabID)
            return .resolved
        }
        lane.clearHeldIntent(intentID)
        removeUnsentScheduledUserItem(id: attempt.itemID, from: session)
        // The banner always shows the scheduled explanation; the handoff's own reason is logged.
        AgentDeliveryRecordDiagnostics.scheduledNotHandedOff(scheduleID: record.id, sourceMessage: message)
        // The failed record is committed before the hold is released: releasing re-evaluates the
        // scheduler, which must never see this attempt as an unowned `.dispatching` record. A failed
        // commit keeps an unresolved hold, so the scheduler never re-reads the attempt.
        let dispatchingMember = session.scheduledSend
        let wasDirty = session.isDirty
        guard await markScheduledSendFailed(session: session, record: record, message: Self.scheduledNotHandedOffMessage) else {
            // Memory agrees with the hold and with disk (still `.dispatching`); a later save never
            // persists the unsaved failure behind the hold.
            session.scheduledSend = dispatchingMember
            session.isDirty = wasDirty
            updateLocalSessionIndexScheduledSendSummary(for: session)
            holdScheduledSendTransfer(
                sessionID: sessionID,
                record: record,
                reason: .unresolved("This scheduled message was not sent, but its status could not be saved.")
            )
            syncComposerUIState(tabID: session.tabID)
            return .resolved
        }
        releaseScheduledSendTransferHold(record: record)
        notifyScheduledSendRecordChanged()
        return .resolved
    }

    static let scheduledNotHandedOffMessage = "The scheduled message was not sent: its run ended before the message was handed off."

    /// Waits for the scheduler barrier and recovery startup, then repairs, holds, or normalizes the
    /// exact projected attempt inside the session's serialized schedule action.
    func resolveScheduledSendTransfer(for session: AgentTabSession, record: AgentScheduledSendPersist) {
        guard let sessionID = session.activeAgentSessionID else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Without a scheduler there is no barrier authority: stay projected and held (busy).
            guard let coordinator = scheduledSendCoordinator,
                  await coordinator.awaitStartupAdmission()
            else { return }
            guard let recoveryCoordinator, await recoveryCoordinator.awaitStartup() == .ready else {
                holdScheduledSendTransfer(
                    sessionID: sessionID,
                    record: record,
                    reason: .unresolved("Recovery startup has not completed.")
                )
                return
            }
            await runScheduledSendAction(on: session) {
                guard record.attempt != nil,
                      recoveryCoordinator.hasDeferredRunStartHandoff(sessionID: sessionID)
                else {
                    // No attempt, or no deferred run-start handoff of this session exists in this
                    // process (Codex, restart): nothing can be pending, so the R9 repair decides as before.
                    _ = await self.performScheduledSendTransferRepair(session: session, sessionID: sessionID, record: record)
                    return
                }
                // F1: a successor owner (tab replaced or reopened) never reads a predecessor's still
                // pending run-start handoff as saved input; it waits for that handoff's settlement.
                switch await self.settleScheduledDeferredHandoffIfNeeded(session: session, sessionID: sessionID, record: record) {
                case .notDeferred:
                    _ = await self.performScheduledSendTransferRepair(session: session, sessionID: sessionID, record: record)
                case .pending:
                    self.holdScheduledSendTransfer(sessionID: sessionID, record: record, reason: .awaitingProviderEvidence)
                    self.syncComposerUIState(tabID: session.tabID)
                case .undecided:
                    // Its own guards hold (lane or record unavailable) or skip (owner changed); a
                    // pending handoff could not be ruled out, so it never decides from disk here.
                    if self.scheduledSendTransferOwnerIsCurrent(session, sessionID: sessionID, record: record) {
                        _ = self.holdScheduledSendTransferForRepair(
                            session: session,
                            sessionID: sessionID,
                            record: record,
                            message: "The recovery record for this session is not available yet."
                        )
                    }
                case .resolved:
                    break
                }
            }
        }
    }

    private func holdScheduledSendTransfer(
        sessionID: UUID,
        record: AgentScheduledSendPersist,
        reason: AgentScheduledSendTransferHoldReason
    ) {
        guard let attempt = record.attempt else { return }
        scheduledSendCoordinator?.holdTransfer(AgentScheduledSendTransferHold(
            sessionID: sessionID,
            scheduleID: record.id,
            scheduleAttemptID: attempt.attemptID,
            reason: reason
        ))
    }

    private func releaseScheduledSendTransferHold(record: AgentScheduledSendPersist) {
        guard let attempt = record.attempt else { return }
        scheduledSendCoordinator?.releaseTransferHold(scheduleID: record.id, scheduleAttemptID: attempt.attemptID)
    }

    private func scheduledSendTransferOwnerIsCurrent(
        _ session: AgentTabSession,
        sessionID: UUID,
        record: AgentScheduledSendPersist
    ) -> Bool {
        sessions[session.tabID] === session
            && session.activeAgentSessionID == sessionID
            && session.pendingScheduledSendRecord == record
            && !session.ownsLiveScheduledAttempt
            && scheduledSendCoordinator?.activeAdmission(sessionID: sessionID) == nil
    }

    /// Hydrated-owner R9 repair: delegates the decision and its commit to the shared gate-held
    /// DataService repair (the same one startup uses for closed sessions), then adopts the
    /// authoritative schedule only while this owner still projects the exact attempt. A
    /// delivery-unknown normalization is committed before `.normalized` is returned.
    private func performScheduledSendTransferRepair(
        session: AgentTabSession,
        sessionID: UUID,
        record: AgentScheduledSendPersist
    ) async -> ScheduledSendTransferRepairOutcome {
        guard scheduledSendTransferOwnerIsCurrent(session, sessionID: sessionID, record: record) else { return .notApplicable }
        if record.attempt != nil {
            // An attempt can be linked only through this session's recovery record.
            guard let lane = session.recoveryLane, !lane.isRetired, lane.sessionID == sessionID else {
                return holdScheduledSendTransferForRepair(
                    session: session,
                    sessionID: sessionID,
                    record: record,
                    message: "The recovery record for this session is not available yet."
                )
            }
        }
        guard let workspace = scheduledSendPersistenceWorkspace(for: session),
              let persistenceState = await ensurePersistenceState(for: session, sessionID: sessionID, workspace: workspace)
        else {
            return holdScheduledSendTransferForRepair(
                session: session,
                sessionID: sessionID,
                record: record,
                message: "The scheduled message's session is not available yet."
            )
        }
        guard scheduledSendTransferOwnerIsCurrent(session, sessionID: sessionID, record: record) else { return .notApplicable }
        let outcome = await dataService.repairScheduledSendTransfer(
            sessionID: sessionID,
            for: workspace,
            persistenceStamp: persistenceState.stamp,
            expectedRecord: record
        )
        switch outcome {
        case .notApplicable:
            // The durable schedule moved (or the session is gone): adopt disk; the hold applies
            // only while this exact attempt is projected.
            await resyncScheduledSendFromDisk(session: session)
            if session.pendingScheduledSendRecord?.attempt?.attemptID != record.attempt?.attemptID {
                releaseScheduledSendTransferHold(record: record)
            }
            return .notApplicable
        case .normalized:
            releaseScheduledSendTransferHold(record: record)
            await adoptRepairedScheduledSend(session: session, sessionID: sessionID)
            return .normalized
        case .cancelled:
            // R10: a committed cancellation was finished; the pending schedule is gone.
            releaseScheduledSendTransferHold(record: record)
            await adoptRepairedScheduledSend(session: session, sessionID: sessionID)
            return .notApplicable
        case let .completed(receipt):
            releaseScheduledSendTransferHold(record: record)
            await adoptRepairedScheduledSend(session: session, sessionID: sessionID)
            if session.activeAgentSessionID == sessionID,
               let itemID = receipt.queueLink?.userItemID ?? record.attempt?.itemID
            {
                stampScheduledSendProvenance(receipt, onItemID: itemID, in: session)
            }
            return .completed(receipt)
        case let .held(message):
            // Evidence this process is still expected to write (its own provider handoff, intent
            // still `dispatching`) keeps waiting; anything else is unresolved until explicit action.
            var awaitsOwnEvidence = false
            if scheduledSendCoordinator?.transferHold(scheduleID: record.id)?.reason == .awaitingProviderEvidence,
               let lane = session.recoveryLane,
               case let .success(recoveryRecord) = await lane.readRecord()
            {
                awaitsOwnEvidence = AgentScheduledSendTransfer.linkedIntentDeliveryState(
                    record: record,
                    recoveryRecord: recoveryRecord
                ) == .dispatching
            }
            holdScheduledSendTransfer(
                sessionID: sessionID,
                record: record,
                reason: awaitsOwnEvidence ? .awaitingProviderEvidence : .unresolved(message)
            )
            syncComposerUIState(tabID: session.tabID)
            return .held(message)
        }
    }

    private func holdScheduledSendTransferForRepair(
        session: AgentTabSession,
        sessionID: UUID,
        record: AgentScheduledSendPersist,
        message: String
    ) -> ScheduledSendTransferRepairOutcome {
        holdScheduledSendTransfer(sessionID: sessionID, record: record, reason: .unresolved(message))
        syncComposerUIState(tabID: session.tabID)
        return .held(message)
    }

    /// R10 "Cancel pending schedule" for this owner's held transfer: the DataService commits the
    /// cancellation decision on the linked intent and then clears that exact schedule (no receipt).
    /// Only after that clear succeeds is the hold released and the held-transfer restriction lifted.
    /// The linked input stays visible with its own (uncertain) delivery evidence; nothing is resent.
    /// Returns a user-facing failure, or `nil` on success.
    func cancelHeldScheduledSendTransfer(session: AgentTabSession, sessionID: UUID) async -> String? {
        guard let record = session.pendingScheduledSendRecord, record.state == .dispatching,
              scheduledSendTransferOwnerIsCurrent(session, sessionID: sessionID, record: record)
        else { return "The scheduled message's status changed. Review it again." }
        guard let workspace = scheduledSendPersistenceWorkspace(for: session),
              let persistenceState = await ensurePersistenceState(for: session, sessionID: sessionID, workspace: workspace)
        else { return "The scheduled message's session is not available yet." }
        guard scheduledSendTransferOwnerIsCurrent(session, sessionID: sessionID, record: record) else {
            return "The scheduled message's status changed. Review it again."
        }
        switch await dataService.cancelScheduledSendTransfer(
            sessionID: sessionID,
            for: workspace,
            persistenceStamp: persistenceState.stamp,
            expectedRecord: record
        ) {
        case .cancelled:
            releaseScheduledSendTransferHold(record: record)
            await adoptRepairedScheduledSend(session: session, sessionID: sessionID)
            syncComposerUIState(tabID: session.tabID)
            return nil
        case let .held(message):
            return message
        case .notApplicable, .normalized, .completed:
            await resyncScheduledSendFromDisk(session: session)
            return "The scheduled message's status changed. Review it again."
        }
    }

    /// Adopts a committed R9 repair (resync re-validates the owner) and lifts the session's
    /// startup held-transfer restriction.
    private func adoptRepairedScheduledSend(session: AgentTabSession, sessionID: UUID) async {
        await resyncScheduledSendFromDisk(session: session)
        recoveryCoordinator?.noteScheduleTransferResolved(sessionID: sessionID)
    }

    /// R9 step 3: one CAS writes the schedule receipt and clears the pending schedule. Attachment
    /// files are never released here: ownership moves with the recovery intent, and cleanup is
    /// owned by the shared attachment-ownership check. Returns `true` when the transfer committed.
    @discardableResult
    private func completeScheduledSendTransfer(
        session: AgentTabSession,
        sessionID: UUID,
        record: AgentScheduledSendPersist,
        receipt: AgentScheduledSendProvenance
    ) async -> Bool {
        let outcome = await commitScheduledSendDetailed(
            session: session,
            member: nil,
            expectedUpdatedAt: record.updatedAt,
            completedDispatch: receipt
        )
        switch outcome {
        case .committed:
            if session.activeAgentSessionID == sessionID {
                if session.pendingScheduledSendRecord == record {
                    session.scheduledSend = nil
                    session.scheduledSendWorkspaceID = nil
                }
                session.lastScheduledDispatch = receipt
                if let itemID = receipt.queueLink?.userItemID ?? record.attempt?.itemID {
                    stampScheduledSendProvenance(receipt, onItemID: itemID, in: session)
                }
            }
            releaseScheduledSendTransferHold(record: record)
            updateLocalSessionIndexScheduledSendSummary(for: session)
            syncComposerUIState(tabID: session.tabID)
            notifyScheduledSendRecordChanged()
            return true
        case .destinationDeleted:
            releaseScheduledSendTransferHold(record: record)
            return false
        case .conflict:
            // Disk moved (resynced): the hold applies only while this exact attempt is projected.
            if session.pendingScheduledSendRecord?.attempt?.attemptID != record.attempt?.attemptID {
                releaseScheduledSendTransferHold(record: record)
            } else {
                holdScheduledSendTransfer(
                    sessionID: sessionID,
                    record: record,
                    reason: .unresolved("The scheduled message changed while its transfer was being saved.")
                )
            }
            return false
        case .unavailable:
            holdScheduledSendTransfer(
                sessionID: sessionID,
                record: record,
                reason: .unresolved("The scheduled message's transfer could not be saved yet.")
            )
            return false
        case let .failed(message):
            holdScheduledSendTransfer(
                sessionID: sessionID,
                record: record,
                reason: .unresolved("The scheduled message's transfer could not be saved: \(message)")
            )
            return false
        }
    }

    // MARK: - Removal / cleanup

    /// Called before a live session leaves `sessions`. Deleting the persisted session also
    /// abandons the record, so its managed attachment files are removed; stashing keeps both.
    func releaseScheduledSendForRemovedSession(_ session: AgentTabSession, deletesPersistedSession: Bool) {
        // Accepted-but-unfinalized work is process-owned; removing the tab detaches presentation only.
        guard deletesPersistedSession, let record = session.pendingScheduledSendRecord else { return }
        clearScheduledSendAttachmentFiles(record.attachments)
        session.scheduledSend = nil
        session.scheduledSendWorkspaceID = nil
    }

    private func clearScheduledSendAttachmentFiles(_ attachments: [AgentImageAttachment]) {
        guard clearConsumedAttachmentsAfterProviderConsumption,
              !attachments.isEmpty,
              let workspaceDirectory = attachmentWorkspaceDirectoryProvider()?.standardizedFileURL
        else { return }
        attachmentStore.clearConsumedLocalFiles(attachments, workspaceDirectory: workspaceDirectory)
    }

    private static func scheduledAttachmentLocalPath(_ attachment: AgentImageAttachment) -> String? {
        guard case let .localFile(path) = attachment.source else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func removeUnsentScheduledUserItem(id itemID: UUID, from session: AgentTabSession) {
        guard let index = session.items.firstIndex(where: { $0.id == itemID && $0.kind == .user }),
              session.items[index].scheduledSend == nil
        else { return }
        _ = session.removeItem(at: index)
        session.pendingTurnRuntimeAnchors.removeAll { $0.userItemID == itemID }
        requestUIRefresh(tabID: session.tabID, urgent: true)
        scheduleSave(for: session.tabID)
    }

    func updateLocalSessionIndexScheduledSendSummary(for session: AgentTabSession) {
        guard session.hasLoadedPersistedState,
              let sessionID = session.activeAgentSessionID,
              var entry = ownerValidatedSessionIndex[sessionID]
        else { return }
        let summary = AgentSessionScheduledSendSummary.make(from: session.scheduledSend)
        guard entry.scheduledSendSummary != summary
            || entry.lastScheduledDispatch != session.lastScheduledDispatch
        else { return }
        entry.scheduledSendSummary = summary
        entry.lastScheduledDispatch = session.lastScheduledDispatch
        applyLocalSessionIndexUpsert(entry)
    }

    // MARK: - Dispatch (plan §3.3)

    private func scheduledDispatchPreflightFailure(record: AgentScheduledSendPersist, session: AgentTabSession) -> String? {
        if session.remoteHost != nil {
            return Self.scheduledSendRemoteUnsupportedMessage
        }
        guard AgentModelCatalog.isAgentAvailable(session.selectedAgent, availability: agentAvailabilityContext) else {
            return unavailableAgentMessage(for: session.selectedAgent)
        }
        if session.profile == .knowledge,
           !KnowledgeSessionPolicy.supportedProviders.contains(session.selectedAgent)
        {
            return "Knowledge sessions currently support Claude Code and Codex. Choose a supported provider before sending."
        }
        if let workspacePath = workspacePathProvider() {
            for taggedFile in record.taggedFileAttachments {
                let path = (workspacePath as NSString).appendingPathComponent(taggedFile.relativePath)
                if !FileManager.default.fileExists(atPath: path) {
                    return "The attached file \"\(taggedFile.displayName)\" no longer exists."
                }
            }
        }
        for attachment in record.attachments {
            if case let .localFile(path) = attachment.source, !FileManager.default.fileExists(atPath: path) {
                return "An attached image is no longer available."
            }
        }
        return nil
    }

    /// Busy evaluation that ignores this session's own in-flight scheduled attempt, for use by
    /// the dispatch path and the coordinator's final handoff validator.
    private func scheduledSendBusyStateExcludingOwnAttempt(for session: AgentTabSession) -> AgentScheduledSendBusyState {
        let wasInFlight = session.isScheduledDispatchInFlight
        session.isScheduledDispatchInFlight = false
        defer { session.isScheduledDispatchInFlight = wasInFlight }
        return scheduledSendBusyState(tabID: session.tabID)
    }

    /// Provider acceptance for a scheduled turn. Codex reports a native send outcome; every
    /// other runner returns `nil` from `startRun` after launching the run (a pre-startup failure
    /// commits `.failed` before returning), so acceptance is the launched run state.
    static func scheduledProviderAccepted(
        outcome: CodexAgentModeCoordinator.NativeSendOutcome?,
        agent: AgentProviderKind,
        runState: AgentSessionRunState
    ) -> Bool {
        if let outcome {
            return outcome.didSend
        }
        guard agent != .codexExec else { return false }
        return runState.isActive || runState == .completed
    }

    private static func scheduledHandoffWasRevoked(_ outcome: CodexAgentModeCoordinator.NativeSendOutcome?) -> Bool {
        if case let .stale(reason)? = outcome {
            return reason == AgentModeRunService.providerHandoffRevokedReason
        }
        return false
    }

    /// Appends the scheduled user turn through the shared seam and starts the idle run exactly
    /// like a composer first send (Codex uses the same serialized dispatch gate and fallback
    /// context). Never enters steering, `pendingInstructions`, or waiting-instruction resumption.
    private struct ScheduledSubmitResult {
        let outcome: CodexAgentModeCoordinator.NativeSendOutcome?
        /// The appended user item exactly as prepared (pre-marker), retained as the accepted snapshot.
        let userItem: AgentChatItem?
        /// F1: a non-Codex start whose `nil` outcome means a runner owns the input and owes its
        /// handoff's settlement (`AgentModeRunService.startRun`). Codex keeps its own `nil` meaning.
        /// Every start computes it the same way (`selectedAgent != .codexExec`, captured before the
        /// start's await); results that never started a run pass `false`.
        let runnerOwnsInputOnNil: Bool
    }

    /// F1: before a runner may own the scheduled intent, its owner marks it awaited, so the
    /// runner's no-handoff settlement is kept for the hold (`finishMandatoryScheduledDispatch`
    /// clears the mark on every exit that is not that hold).
    private func noteScheduledRunStartAwaited(
        _ identity: AgentQueuedInputIdentity?,
        in session: AgentTabSession,
        runnerOwnsInputOnNil: Bool
    ) {
        guard runnerOwnsInputOnNil, let intentID = identity?.intentID else { return }
        session.recoveryLane?.noteDeferredRunStartHandoffAwaitedByOwner(intentID: intentID)
    }

    private func submitScheduledUserTurn(
        tabID: UUID,
        session: AgentTabSession,
        record: AgentScheduledSendPersist,
        attempt: AgentScheduledSendPersist.Attempt,
        recoveryIdentity: AgentQueuedInputIdentity?,
        providerHandoffAuthorization: @escaping @MainActor () -> Bool
    ) async -> ScheduledSubmitResult {
        guard !session.runState.isActive, session.remoteHost == nil else {
            return ScheduledSubmitResult(
                outcome: .stale(reason: "The session became busy before the scheduled message could start."),
                userItem: nil,
                runnerOwnsInputOnNil: false
            )
        }
        let trimmedText = record.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prepared = appendPreparedUserTurn(
            tabID: tabID,
            session: session,
            trimmedText: trimmedText,
            attachmentsToSend: record.attachments,
            taggedFilesToSend: record.taggedFileAttachments,
            activeWorkflow: record.workflow,
            nativePreparedTurn: nil,
            inputSource: .scheduled(record: record, attempt: attempt),
            preassignedUserItemID: nil,
            admittedInterviewFirst: nil
        )
        let wrappedText = prepared.wrappedText

        if let scheduledDispatchRunStarter {
            // Mirror the run service's final guarded boundary for injected provider starts.
            guard providerHandoffAuthorization() else {
                return ScheduledSubmitResult(
                    outcome: .stale(reason: AgentModeRunService.providerHandoffRevokedReason),
                    userItem: prepared.userItem,
                    runnerOwnsInputOnNil: false
                )
            }
            let runnerOwnsInputOnNil = session.selectedAgent != .codexExec
            noteScheduledRunStartAwaited(recoveryIdentity, in: session, runnerOwnsInputOnNil: runnerOwnsInputOnNil)
            let outcome = await scheduledDispatchRunStarter(tabID, wrappedText, record.attachments, record.taggedFileAttachments)
            return ScheduledSubmitResult(outcome: outcome, userItem: prepared.userItem, runnerOwnsInputOnNil: runnerOwnsInputOnNil)
        }
        if session.selectedAgent == .codexExec {
            // Mandatory recovery carries the linked intent's durable identity (queue ID == intent ID);
            // untracked identities exist only while recovery is inactive and fail closed otherwise.
            guard let identity = recoveryIdentity
                ?? AgentQueuedInputIdentity.untracked(userItemID: prepared.userItem.id, in: session)
            else {
                return ScheduledSubmitResult(
                    outcome: .stale(reason: Self.durableQueueAdmissionRequiredMessage),
                    userItem: prepared.userItem,
                    runnerOwnsInputOnNil: false
                )
            }
            let dispatchTicket = session.codexDispatchSerialGate.issueTicket()
            let fallbackContext = AgentTabSession.CodexFallbackSubmissionContext(
                queueID: identity.intentID ?? UUID(),
                providerText: wrappedText,
                images: record.attachments,
                taggedFileAttachments: record.taggedFileAttachments,
                draftText: trimmedText,
                identity: identity,
                origin: .manual,
                dispatchTicket: dispatchTicket
            )
            let outcome = await startAgentRun(
                tabID: tabID,
                initialMessage: wrappedText,
                attachments: record.attachments,
                taggedFileAttachments: record.taggedFileAttachments,
                // Codex carries its identity in the fallback context.
                inputConstituents: nil,
                codexFallbackContext: fallbackContext,
                providerHandoffAuthorization: providerHandoffAuthorization
            )
            return ScheduledSubmitResult(outcome: outcome, userItem: prepared.userItem, runnerOwnsInputOnNil: false)
        }
        // The linked intent's durable identity (mandatory recovery), or untracked while inactive.
        guard let identity = recoveryIdentity
            ?? AgentQueuedInputIdentity.untracked(userItemID: prepared.userItem.id, in: session)
        else {
            return ScheduledSubmitResult(
                outcome: .stale(reason: Self.durableQueueAdmissionRequiredMessage),
                userItem: prepared.userItem,
                runnerOwnsInputOnNil: false
            )
        }
        _ = enqueueUserTurnTokenEstimate(
            wrappedText: wrappedText,
            attachments: record.attachments,
            session: session
        )
        let runnerOwnsInputOnNil = session.selectedAgent != .codexExec
        noteScheduledRunStartAwaited(identity, in: session, runnerOwnsInputOnNil: runnerOwnsInputOnNil)
        let outcome = await startAgentRun(
            tabID: tabID,
            initialMessage: wrappedText,
            attachments: record.attachments,
            taggedFileAttachments: record.taggedFileAttachments,
            inputConstituents: [identity],
            providerHandoffAuthorization: providerHandoffAuthorization
        )
        return ScheduledSubmitResult(outcome: outcome, userItem: prepared.userItem, runnerOwnsInputOnNil: runnerOwnsInputOnNil)
    }

    /// Releases a persisted `.dispatching` attempt that never reached the provider: the record
    /// returns to its pre-attempt content at a new revision so the coordinator re-arms it. The
    /// coordinator carries the user's Send-now consent and the armed observation to that revision
    /// (`admissionRolledBack`) because no user edit or successor intervened.
    private func revertDispatchingAttempt(
        record: AgentScheduledSendPersist,
        dispatching: AgentScheduledSendPersist,
        session: AgentTabSession,
        lease: AgentScheduledSendAdmissionLease
    ) async {
        var reverted = record
        reverted.updatedAt = Date()
        session.scheduledSend = .v1(reverted)
        let committed = await commitScheduledSend(session: session, member: .v1(reverted), expectedUpdatedAt: dispatching.updatedAt)
        // Consent travels only to a revision that is durable; a failed CAS means a concurrent
        // writer moved the record and the override is withdrawn by the next evaluation.
        if committed {
            scheduledSendCoordinator?.admissionRolledBack(lease: lease, revertedUpdatedAt: reverted.updatedAt)
        }
        syncComposerUIState(tabID: session.tabID)
        notifyScheduledSendRecordChanged()
    }

    /// Undoes the run-preparation side effects of a handoff that was revoked before any provider
    /// work: staged handoff payload injection and the enqueued non-Codex token estimate. An
    /// identity-scoped stage (or a delivery/recovery hold) is never touched here: the start tail
    /// settles exactly the stage its own text carried, and a hold outlives a revoked attempt.
    private func rollBackRevokedHandoffPreparation(session: AgentTabSession) {
        if session.pendingHandoff.isStagedForSend,
           session.pendingHandoff.stage == nil,
           session.pendingHandoff.deliveryHold == nil
        {
            session.pendingHandoff.isStagedForSend = false
        }
        if session.selectedAgent != .codexExec {
            _ = dequeuePendingNonCodexUserTokens(for: session)
        }
    }

    private func stampScheduledSendProvenance(
        _ provenance: AgentScheduledSendProvenance,
        onItemID itemID: UUID,
        in session: AgentTabSession
    ) {
        guard let index = session.items.firstIndex(where: { $0.id == itemID }),
              session.items[index].scheduledSend != provenance
        else { return }
        var item = session.items[index]
        item.scheduledSend = provenance
        session.replaceItem(at: index, with: item)
    }

    /// Returns whether the failure is durable (or there is nothing left to mark: deleted session).
    @discardableResult
    private func markScheduledSendFailed(
        session: AgentTabSession,
        record: AgentScheduledSendPersist,
        message: String
    ) async -> Bool {
        // The durable session was explicitly deleted while this attempt was in flight: there is
        // nothing to mark and no file may be recreated.
        guard session.scheduledSend != nil else { return true }
        var failed = record
        failed.state = .failed
        failed.lastFailureMessage = message
        failed.confirmationReason = nil
        failed.updatedAt = Date()
        let expected = session.scheduledSendPersistedUpdatedAt
        session.scheduledSend = .v1(failed)
        session.isDirty = true
        let committed = await commitScheduledSend(session: session, member: .v1(failed), expectedUpdatedAt: expected)
        updateLocalSessionIndexScheduledSendSummary(for: session)
        syncComposerUIState(tabID: session.tabID)
        return committed
    }

    // MARK: - Recovery projection (coordinator-owned persistence)

    /// Builds this host's presentation of a process-retained accepted attempt from coordinator-
    /// owned values (status + immutable payload). Any host projecting the retained `.dispatching`
    /// attempt may adopt it: the dispatching owner, a peer window, or a reopened/hydrated tab. No
    /// owner-local state is required. Returns `true` when a projection was installed.
    @discardableResult
    func adoptScheduledSendRecoveryProjection(for session: AgentTabSession) -> Bool {
        guard session.scheduledSendPendingFinalization == nil,
              let coordinator = scheduledSendCoordinator,
              let sessionID = session.activeAgentSessionID,
              let status = coordinator.recoveryStatus(sessionID: sessionID),
              let payload = coordinator.acceptedPayload(sessionID: sessionID),
              payload.attempt.attemptID == status.key.attemptID,
              session.pendingScheduledSendRecord?.attempt?.attemptID == payload.attempt.attemptID
        else { return false }
        session.scheduledSendPendingFinalization = AgentScheduledSendPendingFinalization(
            key: status.key,
            lease: status.lease,
            attempt: payload.attempt,
            receipt: payload.receipt,
            acceptedItem: payload.acceptedItem,
            status: status.phase
        )
        stampScheduledSendProvenance(payload.receipt, onItemID: payload.attempt.itemID, in: session)
        syncComposerUIState(tabID: session.tabID)
        return true
    }

    /// Reconciles this view model's presentation of a retained accepted attempt from the process
    /// coordinator's current state: installs it when absent, updates its phase, or adopts the
    /// file once the attempt settled. Never performs finalization, retries, or ownership release
    /// itself; those belong to the coordinator worker.
    func reconcileScheduledSendRecoveryProjection(for session: AgentTabSession) {
        guard let sessionID = session.activeAgentSessionID else { return }
        guard let pending = session.scheduledSendPendingFinalization else {
            adoptScheduledSendRecoveryProjection(for: session)
            return
        }
        if let status = scheduledSendCoordinator?.recoveryStatus(sessionID: sessionID),
           status.key == pending.key
        {
            guard status.phase != pending.status else { return }
            var updated = pending
            updated.status = status.phase
            session.scheduledSendPendingFinalization = updated
            syncComposerUIState(tabID: session.tabID)
            return
        }
        // Terminal (durably committed or explicitly deleted): the file is the authority. The
        // live-attempt guard stays up until disk is adopted so no host normalizes the stale
        // `.dispatching` projection in between.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await runScheduledSendAction(on: session) {
                guard session.scheduledSendPendingFinalization?.key == pending.key else { return }
                await self.adoptSettledScheduledSendState(
                    session: session,
                    attempt: pending.attempt,
                    receipt: pending.receipt
                )
            }
        }
    }

    /// Adopts disk after a retained attempt settled. Must run inside the session's serialized
    /// action. A file that still carries this exact attempt (transiently unreadable commit) keeps
    /// the acceptance evidence as the local truth; a missing file was explicitly deleted.
    private func adoptSettledScheduledSendState(
        session: AgentTabSession,
        attempt: AgentScheduledSendPersist.Attempt,
        receipt: AgentScheduledSendProvenance
    ) async {
        await resyncScheduledSendFromDisk(session: session)
        if session.pendingScheduledSendRecord?.attempt == attempt {
            session.scheduledSend = nil
            session.scheduledSendPersistedUpdatedAt = nil
            session.scheduledSendWorkspaceID = nil
            session.lastScheduledDispatch = receipt
            stampScheduledSendProvenance(receipt, onItemID: attempt.itemID, in: session)
        }
        session.scheduledSendPendingFinalization = nil
        updateLocalSessionIndexScheduledSendSummary(for: session)
        syncComposerUIState(tabID: session.tabID)
        syncSidebarUIState(refresh: true, reason: .sessionIndex)
        notifyScheduledSendRecordChanged()
    }

    /// The durable session `sessionID` behind `session` no longer exists (deletion committed under
    /// the persistence gate, or this owner's captured lifetime is stale). Drops every schedule
    /// projection so no candidate, normalization, or creation fallback can write it back. Items
    /// are untouched; the tab is torn down by the deletion flow that owns it. A failure that
    /// belongs to a previous binding of the tab never touches its current session.
    func handleDurableSessionDeleted(_ session: AgentTabSession, sessionID: UUID) {
        guard session.activeAgentSessionID == sessionID else { return }
        // Ownership of the deleted incarnation is revoked for good: no fresh stamp for this ID.
        session.persistenceState = nil
        recoveryPersistenceStateDidChange(for: session)
        session.persistenceRevokedSessionID = sessionID
        // A deleted destination has no transfer left to repair; its hold is released.
        if let hold = scheduledSendCoordinator?.transferHold(sessionID: sessionID) {
            scheduledSendCoordinator?.releaseTransferHold(scheduleID: hold.scheduleID, scheduleAttemptID: hold.scheduleAttemptID)
        }
        guard session.scheduledSend != nil
            || session.scheduledSendPendingFinalization != nil
            || session.scheduledSendPersistedUpdatedAt != nil
        else { return }
        session.scheduledSend = nil
        session.scheduledSendPendingFinalization = nil
        session.scheduledSendPersistedUpdatedAt = nil
        session.scheduledSendWorkspaceID = nil
        updateLocalSessionIndexScheduledSendSummary(for: session)
        syncComposerUIState(tabID: session.tabID)
        notifyScheduledSendRecordChanged()
    }

    /// Banner action for a retained accepted attempt in attention state: persistence-only retry
    /// routed to the process coordinator. Never a provider action.
    func retryScheduledSendSaving(tabID: UUID) async -> String? {
        guard let session = sessions[tabID], let sessionID = session.activeAgentSessionID else {
            return Self.scheduledSendMissingMessage
        }
        guard let coordinator = scheduledSendCoordinator else {
            return "Scheduled sending is unavailable in this window."
        }
        if case .needsAttention? = coordinator.pendingConfirmationStatus(sessionID: sessionID)?.phase {
            // Persistence-only retry of the confirmation obligation; sending stays paused.
            _ = coordinator.retryPendingConfirmation(sessionID: sessionID)
            syncComposerUIState(tabID: tabID)
            return nil
        }
        guard coordinator.retryRecovery(sessionID: sessionID) else {
            reconcileScheduledSendRecoveryProjection(for: session)
            return session.scheduledSendPendingFinalization == nil
                ? nil
                : "Saving is already in progress for this message."
        }
        reconcileScheduledSendRecoveryProjection(for: session)
        return nil
    }
}

/// Mutable box for a serialized action's typed result.
@MainActor
private final class ScheduledSendActionResultBox<T> {
    var value: T?
}

// MARK: - Coordinator host

extension AgentModeViewModel: AgentScheduledSendCoordinatorHost {
    func scheduledSendSessionName(tabID: UUID) -> String? {
        guard let session = sessions[tabID], session.activeAgentSessionID != nil else { return nil }
        return resolvedSessionDisplayName(for: tabID)
    }

    func scheduledSendBusySessionName(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> String? {
        guard persistenceWorkspace?.id == workspaceID else { return nil }
        let busySessions = sessions.values.filter {
            $0.activeAgentSessionID != sessionID && scheduledSendBusyState(tabID: $0.tabID).isBusy
        }
        guard let session = busySessions.sorted(by: { $0.tabID.uuidString < $1.tabID.uuidString }).first
        else { return nil }
        return resolvedSessionDisplayName(for: session.tabID)
    }

    func scheduledSendCandidates() -> [AgentScheduledSendCandidate] {
        guard let workspaceID = persistenceWorkspace?.id else { return [] }
        var candidates: [AgentScheduledSendCandidate] = []
        var coveredSessionIDs: Set<UUID> = []
        for session in sessions.values {
            guard let sessionID = session.activeAgentSessionID,
                  !session.ownsLiveScheduledAttempt,
                  // A retained stale-reset view is neither hydrated nor available for dispatch.
                  session.staleResetRecovery == nil
            else { continue }
            if session.hasLoadedPersistedState {
                guard let record = session.pendingScheduledSendRecord else { continue }
                candidates.append(AgentScheduledSendCandidate(
                    sessionID: sessionID,
                    tabID: session.tabID,
                    workspaceID: session.scheduledSendWorkspaceID ?? workspaceID,
                    scheduledSend: record,
                    isHydrated: true
                ))
                coveredSessionIDs.insert(sessionID)
            } else if let placeholder = ownerValidatedSessionIndex[sessionID]?.scheduledSendSummary?.placeholderRecord {
                candidates.append(AgentScheduledSendCandidate(
                    sessionID: sessionID,
                    tabID: session.tabID,
                    workspaceID: workspaceID,
                    scheduledSend: placeholder,
                    isHydrated: false
                ))
                coveredSessionIDs.insert(sessionID)
            }
        }
        // Discovery hint for open tabs whose session has not been materialized yet.
        let openTabIDs = Set(promptManager?.currentComposeTabs.map(\.id) ?? [])
        for entry in ownerValidatedSessionIndex.values where !coveredSessionIDs.contains(entry.id) {
            guard openTabIDs.contains(entry.tabID),
                  sessions[entry.tabID] == nil,
                  let placeholder = entry.scheduledSendSummary?.placeholderRecord
            else { continue }
            candidates.append(AgentScheduledSendCandidate(
                sessionID: entry.id,
                tabID: entry.tabID,
                workspaceID: workspaceID,
                scheduledSend: placeholder,
                isHydrated: false
            ))
        }
        return candidates
    }

    func scheduledSendBusyState(tabID: UUID) -> AgentScheduledSendBusyState {
        guard let session = sessions[tabID] else { return AgentScheduledSendBusyState() }
        let hasQueuedInstructions = !session.pendingInstructions.isEmpty
            || !session.pendingClaudeSteeringInstructions.isEmpty
            || !session.pendingACPSteeringInstructions.isEmpty
        // A run whose state already went terminal but whose run bookkeeping is still active is
        // a cancellation/teardown that has not settled yet; the bookkeeping change re-triggers.
        let cancellationIsSettling = !session.runState.isActive && isTabRunning(tabID)
        let hasReservation = session.isComposerSubmissionInFlight
            || session.staleResetRecovery != nil
            || session.staleResetRemovalAdmission?.isReserved == true
            || session.isPreparingInitialWorktree
            || session.isChangingExecutionLocation
            || session.ownsLiveScheduledAttempt
            || session.mcpFollowUpRunPending
            || session.pendingMCPElicitationRequest != nil
            || session.mcpControlContext != nil
            || isMCPControlled(tabID: tabID)
            // Two-stage shutdown froze this session: a due schedule waits (never fails) and is
            // re-evaluated when a cancelled Stage A reopens admission.
            || isRecoveryShutdownFrozen(session)
        return AgentScheduledSendBusyState(
            runID: session.runID,
            runState: session.runState,
            hasPendingApproval: session.pendingApproval != nil,
            hasPendingAskUser: session.pendingAskUser != nil,
            hasPendingUserInputRequest: session.pendingUserInputRequest != nil,
            hasPendingPermissionsRequest: session.pendingPermissionsRequest != nil,
            hasPendingInstructions: hasQueuedInstructions,
            cancellationIsSettling: cancellationIsSettling,
            hasStartOrDispatchReservation: hasReservation,
            hasUnresolvedRecovery: scheduledSendHasUnresolvedRecovery(session)
        )
    }

    /// R6 ownership keys of `session`: its durable session, each native conversation it knows (Codex
    /// thread, Claude/ACP session) and its effective worktree; the session and worktree alone before
    /// any conversation is known. The Codex thread field is Codex's by construction; the generic
    /// provider session ID records no provider of its own (the selected agent may have changed
    /// since), so it keeps an unknown provider, which overlaps every runtime (conservative).
    /// Whether `session`'s effective worktree cannot be resolved (its lookup throws); a session with
    /// no worktree at all is resolved. R6 automatic work treats an unresolved worktree as blocked.
    func runtimeWorktreeIsUnresolved(for session: AgentTabSession) -> Bool {
        do {
            _ = try effectiveWorkspacePath(for: session)
            return false
        } catch {
            return true
        }
    }

    func runtimeOwnershipKeys(for session: AgentTabSession) -> [AgentRuntimeOwnershipKeys] {
        let worktree = (try? effectiveWorkspacePath(for: session)) ?? nil
        let sessionID = session.activeAgentSessionID
        func trimmed(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        var conversations: [(id: String, provider: AgentRuntimeProvider?)] = []
        if let codexThread = trimmed(session.codexConversationID) {
            conversations.append((codexThread, .codex))
        }
        if let providerSession = trimmed(session.providerSessionID) {
            conversations.append((providerSession, nil))
        }
        guard !conversations.isEmpty else {
            return [AgentRuntimeOwnershipKeys(sessionID: sessionID, conversationID: nil, worktreePath: worktree)]
        }
        return conversations.map {
            AgentRuntimeOwnershipKeys(sessionID: sessionID, conversationID: $0.id, provider: $0.provider, worktreePath: worktree)
        }
    }

    /// The single predicate behind `hasUnresolvedRecoverySession`, itemized so the schedule banner
    /// can say what a new-session start waits for (lossless restart F2).
    func scheduledSendRecoveryBlocker(
        inWorkspace workspaceID: UUID,
        excluding sessionID: UUID
    ) -> AgentScheduledSendRecoveryBlocker? {
        var blocker = AgentScheduledSendRecoveryBlocker()
        if let recoveryCoordinator {
            // App-scoped startup results cover closed sessions too (every window shares the coordinator).
            let summary = recoveryCoordinator.unresolvedSessionSummary(inWorkspace: workspaceID, excluding: sessionID)
            blocker.interruptedSessionIDs = summary.crashHeldSessionIDs
            blocker.restrictedSessionIDs = summary.restrictedSessionIDs
            blocker.workspaceRestriction = summary.workspaceRestriction
            // Review A P1-01: an explicit recovery action held anywhere in this workspace (any window).
            blocker.recoveryActionInProgress = recoveryCoordinator.hasRecoveryAction(inWorkspace: workspaceID, excluding: sessionID)
        }
        if persistenceWorkspace?.id == workspaceID {
            // R6: a surviving runtime on this workspace's worktree keeps new-session starts paused.
            blocker.runtimeOwnershipUnresolved = recoveryCoordinator?.runtimeBlocksAutomaticWork(
                worktreePath: workspacePathProvider()
            ) == true
            // Same membership as the pre-F2 predicate: every other open tab counts, bound or not. An
            // unbound tab cannot report unresolved recovery today, but would block unattributed.
            for session in sessions.values
                where session.activeAgentSessionID != sessionID && scheduledSendHasUnresolvedRecovery(session)
            {
                if let openSessionID = session.activeAgentSessionID {
                    blocker.unresolvedOpenSessionIDs.insert(openSessionID)
                } else {
                    blocker.unattributed = true
                }
            }
        }
        return blocker.isBlocking ? blocker : nil
    }

    func hasBusySession(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> Bool {
        guard persistenceWorkspace?.id == workspaceID else { return false }
        return sessions.values.contains { session in
            session.activeAgentSessionID != sessionID
                && scheduledSendBusyState(tabID: session.tabID).isBusy
        }
    }

    func scheduledSendBusyStateExcludingDispatchReservation(tabID: UUID) -> AgentScheduledSendBusyState {
        guard let session = sessions[tabID] else { return AgentScheduledSendBusyState() }
        return scheduledSendBusyStateExcludingOwnAttempt(for: session)
    }

    /// Workspace busy aggregation for the coordinator's final handoff validator. The owning host
    /// excludes only the dispatching tab itself (its reservation is the handoff); foreign hosts
    /// receive `nil` and report every busy session in the workspace.
    func hasBusySessionForScheduledSendHandoff(
        inWorkspace workspaceID: UUID,
        excludingDispatchReservationForTabID tabID: UUID?
    ) -> Bool {
        guard persistenceWorkspace?.id == workspaceID else { return false }
        return sessions.values.contains { session in
            guard session.tabID != tabID else { return false }
            return scheduledSendBusyState(tabID: session.tabID).isBusy
        }
    }

    /// Destination ownership for the coordinator's validators: this host owns the tab and the
    /// tab is bound to the admitted durable session.
    func ownsScheduledSendDestination(tabID: UUID, sessionID: UUID) -> Bool {
        guard let session = sessions[tabID] else { return false }
        return session.activeAgentSessionID == sessionID
    }

    /// Whether any tab on this host bound to `sessionID` is busy. The owning dispatch tab is
    /// evaluated without its own reservation; every other tab counts fully.
    func scheduledSendDestinationIsBusy(
        sessionID: UUID,
        excludingDispatchReservationForTabID tabID: UUID?
    ) -> Bool {
        sessions.values.contains { session in
            guard session.activeAgentSessionID == sessionID else { return false }
            if session.tabID == tabID {
                return scheduledSendBusyStateExcludingOwnAttempt(for: session).isBusy
            }
            return scheduledSendBusyState(tabID: session.tabID).isBusy
        }
    }

    /// The coordinator observed a newer authoritative revision than this host projects
    /// (typically an unhydrated placeholder): refresh from disk or hydrate instead of skipping.
    func scheduledSendProjectionNeedsRefresh(tabID: UUID, sessionID: UUID) {
        if let session = sessions[tabID], session.activeAgentSessionID == sessionID {
            refreshScheduledSendProjection(for: session)
        } else if ownerValidatedSessionIndex[sessionID] != nil {
            Task { @MainActor [weak self] in
                await self?.refreshIndexScheduledSendSummaryFromDisk(sessionID: sessionID)
            }
        }
    }

    func ensureHydrated(tabID: UUID) async -> Bool {
        let tabIsOpen = promptManager?.currentComposeTabs.contains(where: { $0.id == tabID }) ?? false
        guard sessions[tabID] != nil || tabIsOpen else { return false }
        guard let session = try? await ensureSessionReady(tabID: tabID) else { return false }
        return session.hasLoadedPersistedState && sessions[tabID] === session
    }

    /// Coordinator-issued exact mutation: validated, committed through the shared CAS path inside
    /// this session's serialized action, and adopted only if this host is still the owner. The
    /// replacement is never projected before it is durable.
    func persistScheduledSendMutation(
        tabID: UUID,
        request: AgentScheduledSendHostMutationRequest
    ) async -> AgentScheduledSendHostMutationOutcome {
        guard let session = sessions[tabID],
              session.activeAgentSessionID == request.sessionID,
              session.staleResetRecovery == nil
        else {
            return .unavailable
        }
        // An unresolved R9 transfer is never rewritten into a confirmation (or anything else) by
        // the scheduler; only the transfer repair decides it.
        guard scheduledSendCoordinator?.transferHold(scheduleID: request.scheduleID) == nil else {
            return .unavailable
        }
        guard session.hasLoadedPersistedState else {
            // Unhydrated discovery candidates cannot be mutated durably; hydrate so the
            // coordinator's next pass reaches a real record.
            Task { @MainActor [weak self] in
                _ = await self?.ensureHydrated(tabID: tabID)
            }
            return .unavailable
        }
        return await runScheduledSendAction(on: session) { [self] in
            guard sessions[tabID] === session,
                  session.activeAgentSessionID == request.sessionID,
                  !session.ownsLiveScheduledAttempt
            else { return .unavailable }
            guard let current = session.pendingScheduledSendRecord, current.id == request.scheduleID else {
                return session.persistenceRevokedSessionID == request.sessionID ? .destinationDeleted : .conflict
            }
            guard current == request.expected else { return .conflict }
            let outcome = await commitScheduledSendDetailed(
                session: session,
                member: .v1(request.replacement),
                expectedUpdatedAt: request.expected.updatedAt
            )
            if case .committed = outcome,
               sessions[tabID] === session,
               session.activeAgentSessionID == request.sessionID,
               session.pendingScheduledSendRecord == request.expected
            {
                // Adopt the durable result into this owner's projection.
                session.scheduledSend = .v1(request.replacement)
                session.isDirty = true
                updateLocalSessionIndexScheduledSendSummary(for: session)
                syncComposerUIState(tabID: tabID)
                notifyScheduledSendRecordChanged()
            }
            return outcome
        }
    }

    func dispatchScheduledSend(
        tabID: UUID,
        scheduleID: UUID,
        lease: AgentScheduledSendAdmissionLease
    ) async -> ScheduledDispatchOutcome {
        guard let session = sessions[tabID] else { return .failedBeforeHandoff }
        return await runScheduledSendAction(on: session) { [self] in
            await performScheduledDispatch(tabID: tabID, session: session, scheduleID: scheduleID, lease: lease)
        }
    }

    private func performScheduledDispatch(
        tabID: UUID,
        session: AgentTabSession,
        scheduleID: UUID,
        lease: AgentScheduledSendAdmissionLease
    ) async -> ScheduledDispatchOutcome {
        guard let coordinator = scheduledSendCoordinator else { return .failedBeforeHandoff }
        guard sessions[tabID] === session,
              session.hasLoadedPersistedState,
              session.staleResetRecovery == nil,
              session.activeAgentSessionID == lease.sessionID,
              let record = session.pendingScheduledSendRecord,
              record.id == scheduleID
        else {
            return .failedBeforeHandoff
        }
        // Admission freshness: the lease must still name this exact revision and deadline.
        guard coordinator.isValid(lease, for: record) else { return .deferredBusy }
        let eligibleState = record.state == .scheduled
            || (lease.allowsNeedsConfirmation && (record.state == .needsConfirmation || record.state == .failed))
        guard eligibleState else { return .failedBeforeHandoff }
        guard !session.ownsLiveScheduledAttempt else { return .deferredBusy }
        guard !scheduledSendBusyState(tabID: tabID).isBusy else { return .deferredBusy }
        if record.isNewSessionStart,
           !lease.runAlongsideOtherSessions,
           hasBusySession(inWorkspace: lease.workspaceID, excluding: lease.sessionID)
        {
            return .deferredBusy
        }

        session.isScheduledDispatchInFlight = true
        syncComposerUIState(tabID: tabID)
        defer {
            session.isScheduledDispatchInFlight = false
            syncComposerUIState(tabID: tabID)
        }

        if let failureMessage = scheduledDispatchPreflightFailure(record: record, session: session) {
            await markScheduledSendFailed(session: session, record: record, message: failureMessage)
            return .failedBeforeHandoff
        }
        // Mandatory lossless-restart recovery: every dependency of durable admission and provider
        // evidence must exist before an attempt is written; nothing falls back to legacy sending.
        let recoveryMandatory = session.recoveryAdmissionMode == .mandatory
        if recoveryMandatory,
           let failureMessage = scheduledRecoveryAdmissionPreflightFailure(record: record, session: session)
        {
            await markScheduledSendFailed(session: session, record: record, message: failureMessage)
            return .failedBeforeHandoff
        }

        // At-most-once: persist the attempt before the optimistic item exists anywhere.
        let startedAt = Date()
        let attempt = AgentScheduledSendPersist.Attempt(
            attemptID: UUID(),
            itemID: record.attempt?.itemID ?? UUID(),
            startedAt: startedAt
        )
        var dispatching = record
        dispatching.state = .dispatching
        dispatching.attempt = attempt
        dispatching.confirmationReason = nil
        dispatching.lastFailureMessage = nil
        dispatching.updatedAt = startedAt
        let expectedBeforeAttempt = session.scheduledSendPersistedUpdatedAt
        session.scheduledSend = .v1(dispatching)
        session.isDirty = true
        syncComposerUIState(tabID: tabID)
        guard await commitScheduledSend(session: session, member: .v1(dispatching), expectedUpdatedAt: expectedBeforeAttempt),
              session.pendingScheduledSendRecord == dispatching
        else {
            if session.pendingScheduledSendRecord == dispatching {
                session.scheduledSend = .v1(record)
                syncComposerUIState(tabID: tabID)
            }
            return .failedBeforeHandoff
        }

        #if DEBUG
            if let hook = test_scheduledSendAfterDispatchCommitHook {
                await hook(session)
            }
        #endif

        // Freshness after persistence: the coordinator's final handoff validator aggregates the
        // process-wide gates (lease revision/epoch/deadline, owning registration and tab, this
        // session's busy state excluding its own reservation, and every foreign host's workspace
        // busy state). It is carried into `startAgentRun` and re-checked immediately before the
        // provider runner is invoked. A superseded admission releases without retiring.
        // Process-owned recovery: a DataService-issued destination for this exact attempt is
        // captured under the persistence gate before the guarded handoff. The final validation
        // runs after this await; the handoff reservation is made synchronously inside it.
        guard sessions[tabID] === session,
              session.activeAgentSessionID == lease.sessionID,
              let recoveryWorkspace = scheduledSendPersistenceWorkspace(for: session),
              let recoveryStamp = await ensurePersistenceState(for: session, sessionID: lease.sessionID, workspace: recoveryWorkspace)?.stamp,
              let recoveryContext = try? await dataService.prepareScheduledSendRecovery(
                  sessionID: lease.sessionID,
                  for: recoveryWorkspace,
                  persistenceStamp: recoveryStamp,
                  expectedUpdatedAt: dispatching.updatedAt,
                  expectedAttempt: attempt
              ),
              sessions[tabID] === session,
              session.activeAgentSessionID == lease.sessionID,
              let handoffValidator = coordinator.finalHandoffValidator(for: lease)
        else {
            await revertDispatchingAttempt(record: record, dispatching: dispatching, session: session, lease: lease)
            return .deferredBusy
        }
        let recoveryKey = AgentScheduledSendRecoveryKey(
            sessionID: lease.sessionID,
            leaseID: lease.id,
            attemptID: attempt.attemptID
        )

        // R9 step 2 (mandatory recovery): the linked durable intent is committed `queued` before any
        // handoff, so a fallback queue entry or a crash leaves exactly one durable owner.
        var recoveryAdmission: (identity: AgentQueuedInputIdentity, lane: AgentRecoverySessionLane)?
        if recoveryMandatory {
            switch await admitScheduledRecoveryIntent(session: session, record: dispatching, attempt: attempt) {
            case let .admitted(identity, lane):
                recoveryAdmission = (identity, lane)
            case let .notAdmitted(message):
                await markScheduledSendFailed(session: session, record: dispatching, message: message)
                notifyScheduledSendRecordChanged()
                return .failedBeforeHandoff
            case .committedButStale:
                holdScheduledSendTransfer(
                    sessionID: lease.sessionID,
                    record: dispatching,
                    reason: .unresolved("The session changed while this scheduled message was being saved.")
                )
                return .heldForRecovery
            }
            // Revalidate the exact owner and admission after the store await, before any handoff.
            guard recoveryAdmission != nil,
                  sessions[tabID] === session,
                  session.activeAgentSessionID == lease.sessionID,
                  session.pendingScheduledSendRecord == dispatching,
                  coordinator.finalHandoffValidator(for: lease) == handoffValidator
            else {
                if let recoveryAdmission {
                    return await rollBackScheduledRecoveryAdmission(
                        recoveryAdmission,
                        record: record,
                        dispatching: dispatching,
                        session: session,
                        lease: lease
                    )
                }
                return .failedBeforeHandoff
            }
        }

        // Re-drive of a failed attempt reuses the item id; drop any stale unsent bubble first.
        removeUnsentScheduledUserItem(id: attempt.itemID, from: session)
        // The captured coordinator (never a later `self.scheduledSendCoordinator` read) owns the
        // handoff reservation and receives acceptance; the closure retains only immutable values.
        let submitResult = await submitScheduledUserTurn(
            tabID: tabID,
            session: session,
            record: dispatching,
            attempt: attempt,
            recoveryIdentity: recoveryAdmission?.identity,
            providerHandoffAuthorization: { [coordinator, handoffValidator, recoveryContext, attempt] in
                coordinator.authorizeProviderHandoff(handoffValidator, context: recoveryContext, attempt: attempt)
            }
        )
        let outcome = submitResult.outcome

        if let recoveryAdmission {
            return await finishMandatoryScheduledDispatch(
                ScheduledRecoveryDispatchContext(
                    tabID: tabID,
                    session: session,
                    record: record,
                    dispatching: dispatching,
                    attempt: attempt,
                    lease: lease,
                    coordinator: coordinator,
                    recoveryKey: recoveryKey,
                    recoveryContext: recoveryContext,
                    identity: recoveryAdmission.identity,
                    lane: recoveryAdmission.lane
                ),
                submitResult: submitResult
            )
        }

        if Self.scheduledHandoffWasRevoked(outcome) {
            // The process-wide gate closed during run preparation: nothing reached the provider.
            coordinator.reportProviderOutcomeNotAccepted(key: recoveryKey)
            removeUnsentScheduledUserItem(id: attempt.itemID, from: session)
            rollBackRevokedHandoffPreparation(session: session)
            await revertDispatchingAttempt(record: record, dispatching: dispatching, session: session, lease: lease)
            return .deferredBusy
        }

        if case let .deliveryUnknown(message)? = outcome {
            // Durable-input outcome (not expected while admission is inactive): fail closed by holding
            // the attempt with its payload and bubble. Never a pre-handoff failure or a retry.
            coordinator.reportProviderOutcomeNotAccepted(key: recoveryKey)
            holdScheduledSendTransfer(
                sessionID: lease.sessionID,
                record: dispatching,
                reason: .unresolved(message.isEmpty ? "Delivery of this scheduled message could not be confirmed." : message)
            )
            return .heldForRecovery
        }

        if Self.scheduledProviderAccepted(outcome: outcome, agent: session.selectedAgent, runState: session.runState) {
            // Recovery inactive: the legacy heuristic (`didSend` / launched run state) still drives
            // finalization exactly as before, but it is not acceptance evidence, so its receipt
            // records `legacyUnknown`. Mandatory recovery never takes this path.
            let receipt = AgentScheduledSendProvenance(
                scheduleID: dispatching.id,
                attemptID: attempt.attemptID,
                scheduledFor: dispatching.notBefore,
                sentAt: Date()
            )
            return await adoptScheduledProviderAcceptance(
                tabID: tabID,
                session: session,
                lease: lease,
                coordinator: coordinator,
                recoveryKey: recoveryKey,
                recoveryContext: recoveryContext,
                dispatching: dispatching,
                attempt: attempt,
                submitResult: submitResult,
                receipt: receipt
            )
        }

        coordinator.reportProviderOutcomeNotAccepted(key: recoveryKey)
        let failureMessage = Self.scheduledNotAcceptedMessage(outcome)
        removeUnsentScheduledUserItem(id: attempt.itemID, from: session)
        await markScheduledSendFailed(session: session, record: dispatching, message: failureMessage)
        notifyScheduledSendRecordChanged()
        return .failedBeforeHandoff
    }

    private static func scheduledNotAcceptedMessage(_ outcome: CodexAgentModeCoordinator.NativeSendOutcome?) -> String {
        switch outcome {
        case let .failed(message):
            message
        case let .stale(reason):
            reason
        case .cancelled:
            "The run was cancelled before the scheduled message was sent."
        case let .deliveryUnknown(message):
            message
        case .sent, .queuedFallback:
            "The scheduled message could not be sent."
        case nil:
            "The agent runtime changed before the scheduled message could be sent."
        }
    }

    /// Acceptance evidence for this exact attempt: the immutable payload and its persistence move
    /// to the process coordinator synchronously (existing ownership-transfer contract).
    private func adoptScheduledProviderAcceptance(
        tabID: UUID,
        session: AgentTabSession,
        lease: AgentScheduledSendAdmissionLease,
        coordinator: AgentScheduledSendCoordinator,
        recoveryKey: AgentScheduledSendRecoveryKey,
        recoveryContext: AgentScheduledSendRecoveryContext,
        dispatching: AgentScheduledSendPersist,
        attempt: AgentScheduledSendPersist.Attempt,
        submitResult: ScheduledSubmitResult,
        receipt: AgentScheduledSendProvenance
    ) async -> ScheduledDispatchOutcome {
        stampScheduledSendProvenance(receipt, onItemID: attempt.itemID, in: session)
        // Immutable accepted snapshot: the exact prepared item, stamped with the receipt.
        var acceptedItem = session.items.first(where: { $0.id == attempt.itemID && $0.kind == .user })
            ?? submitResult.userItem
            ?? AgentChatItem.user(
                Self.userBubbleText(
                    trimmedText: dispatching.rawText.trimmingCharacters(in: .whitespacesAndNewlines),
                    attachments: dispatching.attachments,
                    taggedFiles: dispatching.taggedFileAttachments,
                    workflow: dispatching.workflow
                ),
                id: attempt.itemID,
                attachments: dispatching.attachments,
                taggedFileAttachments: dispatching.taggedFileAttachments,
                workflow: dispatching.workflow
            )
        acceptedItem.scheduledSend = receipt
        // Synchronous ownership transfer: the immutable payload and the single persistence
        // worker belong to the process coordinator before any further suspension. Tab,
        // workspace, registration, or cancellation state never gates this transfer.
        coordinator.reportAcceptance(
            key: recoveryKey,
            payload: AgentScheduledSendAcceptedPayload(
                context: recoveryContext,
                attempt: attempt,
                receipt: receipt,
                acceptedItem: acceptedItem,
                expectedUpdatedAt: dispatching.updatedAt
            )
        )
        // Read the coordinator's current state after reporting: the attempt may already have
        // settled (explicit deletion during the provider await) in which case no projection
        // is installed and the file is adopted instead.
        if let status = coordinator.recoveryStatus(sessionID: lease.sessionID), status.key == recoveryKey {
            session.scheduledSendPendingFinalization = AgentScheduledSendPendingFinalization(
                key: recoveryKey,
                lease: lease,
                attempt: attempt,
                receipt: receipt,
                acceptedItem: acceptedItem,
                status: status.phase
            )
            syncComposerUIState(tabID: tabID)
        } else {
            await adoptSettledScheduledSendState(session: session, attempt: attempt, receipt: receipt)
        }
        // Durable commitment is reported by the coordinator; registration alone is not acceptance.
        return .unknownAfterHandoff
    }

    // MARK: Mandatory recovery dispatch (R2/R9)

    /// Everything a mandatory-recovery scheduled dispatch carries past the provider await.
    private struct ScheduledRecoveryDispatchContext {
        let tabID: UUID
        let session: AgentTabSession
        /// Pre-attempt record (rollback target).
        let record: AgentScheduledSendPersist
        let dispatching: AgentScheduledSendPersist
        let attempt: AgentScheduledSendPersist.Attempt
        let lease: AgentScheduledSendAdmissionLease
        let coordinator: AgentScheduledSendCoordinator
        let recoveryKey: AgentScheduledSendRecoveryKey
        let recoveryContext: AgentScheduledSendRecoveryContext
        let identity: AgentQueuedInputIdentity
        /// Lane that admitted the intent; its evidence reads stay valid after retirement.
        let lane: AgentRecoverySessionLane
    }

    private enum ScheduledRecoveryAdmissionResult {
        case admitted(AgentQueuedInputIdentity, AgentRecoverySessionLane)
        /// Nothing durable was admitted; no handoff may happen.
        case notAdmitted(String)
        /// The intent was committed but its lane retired during the await (stale-target hold).
        case committedButStale
    }

    /// Fails closed before any attempt is written when durable admission is unavailable. Every
    /// provider route carries the linked identity to its boundary (Codex in its fallback context,
    /// every other route as `startAgentRun(inputConstituents:)`), so no provider is refused here.
    private func scheduledRecoveryAdmissionPreflightFailure(
        record: AgentScheduledSendPersist,
        session: AgentTabSession
    ) -> String? {
        guard recoveryCoordinator != nil,
              let lane = session.recoveryLane,
              !lane.isRetired,
              lane.sessionID == session.activeAgentSessionID
        else {
            return "Scheduled sending is paused until this session's recovery record is available."
        }
        guard scheduledRecoveryContent(record, lane: lane) != nil else {
            return "An attached image could not be saved for recovery, so the scheduled message was not sent."
        }
        return nil
    }

    /// Original scheduled input (raw text, managed images, tagged files, captured workflow,
    /// interview choice). `nil` when an image is not in managed recovery storage.
    private func scheduledRecoveryContent(
        _ record: AgentScheduledSendPersist,
        lane: AgentRecoverySessionLane
    ) -> AgentRecoveryInputContent? {
        var images: [AgentRecoveryImageReference] = []
        for attachment in record.attachments {
            guard let reference = lane.store.existingImageReference(for: attachment, sessionID: lane.sessionID) else {
                return nil
            }
            images.append(reference)
        }
        return AgentRecoveryInputContent(
            text: record.rawText,
            images: images,
            taggedFiles: record.taggedFileAttachments.map(AgentRecoveryTaggedFileReference.init),
            workflow: record.workflow.map(AgentRecoveryWorkflowSnapshot.init),
            interviewFirst: record.interviewFirst
        )
    }

    /// Commits the linked `queued` intent (origin `.scheduled`, deterministic item, schedule
    /// reference) and issues its queue receipt. Never reports queue success to the user.
    private func admitScheduledRecoveryIntent(
        session: AgentTabSession,
        record: AgentScheduledSendPersist,
        attempt: AgentScheduledSendPersist.Attempt
    ) async -> ScheduledRecoveryAdmissionResult {
        guard let lane = session.recoveryLane, !lane.isRetired,
              let content = scheduledRecoveryContent(record, lane: lane)
        else {
            return .notAdmitted("Scheduled sending is paused until this session's recovery record is available.")
        }
        // The exact pending-handoff prefix this send prepends is committed with the intent, before
        // any queue acknowledgement or handoff can clear it.
        let pendingHandoff: AgentRecoveryPendingHandoffSnapshot?
        switch await capturePendingHandoffForAdmission(session: session) {
        case let .captured(snapshot):
            pendingHandoff = snapshot
        case let .blocked(message):
            return .notAdmitted(message)
        }
        guard session.recoveryLane === lane, !lane.isRetired else {
            return .notAdmitted("Scheduled sending is paused until this session's recovery record is available.")
        }
        let admission = AgentRecoveryAdmission(
            binding: lane.binding,
            userItemID: attempt.itemID,
            origin: .scheduled,
            target: .session,
            original: content,
            scheduleReference: AgentScheduledSendTransfer.recoveryScheduleReference(scheduleID: record.id, attempt: attempt),
            pendingHandoff: pendingHandoff
        )
        switch await lane.admitQueued(admission) {
        case let .success(admitted):
            return .admitted(AgentQueuedInputIdentity(receipt: admitted.receipt), lane)
        case let .failure(.refused(refusal)):
            // F6: a refusal is not a save failure, and its raw case is never shown. `.notAdmitted`
            // marks the schedule failed (final; nothing retries it), so no text promises a resume.
            AgentRecoveryFailureDiagnostics.presentationFailure(
                site: "scheduled_admission_refused_\(refusal.diagnosticName)",
                failure: refusal
            )
            return .notAdmitted(Self.scheduledRecoveryAdmissionRefusalMessage(refusal))
        case let .failure(.commitFailed(failure)):
            AgentRecoveryFailureDiagnostics.presentationFailure(site: "scheduled_admission_commit_failed", failure: failure)
            return .notAdmitted("The scheduled message could not be saved for recovery (\(Self.recoveryListDescription(of: failure))).")
        case .failure(.staleAfterCommit), .failure(.dispatchStaleAfterCommit):
            // `dispatchStaleAfterCommit` is dispatch-only; admission never reports it.
            return .committedButStale
        }
    }

    /// Withdraws this attempt's own never-dispatched intent, then rolls the schedule back to its
    /// pre-attempt revision. If withdrawal cannot be proven, the attempt is held instead so the
    /// input never has two owners.
    private func rollBackScheduledRecoveryAdmission(
        _ admission: (identity: AgentQueuedInputIdentity, lane: AgentRecoverySessionLane),
        record: AgentScheduledSendPersist,
        dispatching: AgentScheduledSendPersist,
        session: AgentTabSession,
        lease: AgentScheduledSendAdmissionLease
    ) async -> ScheduledDispatchOutcome {
        guard let intentID = admission.identity.intentID,
              case .success = await admission.lane.withdraw(intentID: intentID)
        else {
            holdScheduledSendTransfer(
                sessionID: lease.sessionID,
                record: dispatching,
                reason: .unresolved("This scheduled message's saved copy could not be released.")
            )
            return .heldForRecovery
        }
        await revertDispatchingAttempt(record: record, dispatching: dispatching, session: session, lease: lease)
        return .deferredBusy
    }

    /// Maps the provider outcome to durable evidence only: a matching store-issued queue receipt
    /// with the intent still `queued` (`savedInQueue`) or recorded affirmative acceptance
    /// (`providerAccepted`). `didSend`, fallback reasons, and a launched run are never acceptance.
    /// Ambiguity (`.deliveryUnknown`, an unconfirmed `.sent`, unreadable or conflicting evidence)
    /// is held with the schedule, its payload, and the bubble kept: never a pre-handoff failure,
    /// confirmation, or automatic retry.
    private func finishMandatoryScheduledDispatch(
        _ context: ScheduledRecoveryDispatchContext,
        submitResult: ScheduledSubmitResult
    ) async -> ScheduledDispatchOutcome {
        let session = context.session
        let outcome = submitResult.outcome
        let coordinator = context.coordinator
        guard let intentID = context.identity.intentID else {
            coordinator.reportProviderOutcomeNotAccepted(key: context.recoveryKey)
            holdScheduledSendTransfer(
                sessionID: context.lease.sessionID,
                record: context.dispatching,
                reason: .unresolved("The scheduled message has no durable identity.")
            )
            return .heldForRecovery
        }

        if Self.scheduledHandoffWasRevoked(outcome) {
            // The process-wide gate closed during run preparation: nothing reached the provider.
            coordinator.reportProviderOutcomeNotAccepted(key: context.recoveryKey)
            removeUnsentScheduledUserItem(id: context.attempt.itemID, from: session)
            rollBackRevokedHandoffPreparation(session: session)
            context.lane.clearDeferredRunStartHandoff(intentID: intentID)
            return await rollBackScheduledRecoveryAdmission(
                (context.identity, context.lane),
                record: context.record,
                dispatching: context.dispatching,
                session: session,
                lease: context.lease
            )
        }

        if case let .deliveryUnknown(message)? = outcome {
            // The handoff began but its result is not proven (or its evidence could not be written):
            // the intent stays `dispatching`/`deliveryUnknown`. Keep the schedule, payload, and bubble.
            coordinator.reportProviderOutcomeNotAccepted(key: context.recoveryKey)
            context.lane.clearDeferredRunStartHandoff(intentID: intentID)
            holdScheduledSendTransfer(
                sessionID: context.lease.sessionID,
                record: context.dispatching,
                reason: .unresolved(message.isEmpty ? "Delivery of this scheduled message could not be confirmed." : message)
            )
            return .heldForRecovery
        }

        if outcome == nil, submitResult.runnerOwnsInputOnNil {
            // F1: a runner owns this input and owes its handoff's settlement; the non-Codex dispatch
            // commit is deferred to it, so the intent may still be `queued` here. Neither `nil` nor a
            // record read proves non-delivery: hold the schedule, payload, intent, and bubble. The
            // hold resolves only on the handoff's own settlement (committed evidence → the R9
            // transfer after acceptance; a proven no-handoff of the still-queued intent → failed).
            coordinator.reportProviderOutcomeNotAccepted(key: context.recoveryKey)
            holdScheduledSendTransfer(
                sessionID: context.lease.sessionID,
                record: context.dispatching,
                reason: .awaitingProviderEvidence
            )
            recheckScheduledSendTransferAwaitingEvidence(for: session)
            return .heldForRecovery
        }
        // An explicit outcome: no runner owns this input, so no deferred settlement will be consumed.
        context.lane.clearDeferredRunStartHandoff(intentID: intentID)

        let queueReceiptMatches: Bool = if case .queuedFallback? = outcome {
            outcome?.durableQueueReceipt?.intent.intentID == intentID
        } else {
            false
        }
        let recoveryRecord: AgentRecoveryRecordState
        switch await context.lane.readRecord() {
        case let .success(state):
            recoveryRecord = state
        case let .failure(failure):
            AgentRecoveryFailureDiagnostics.presentationFailure(site: "scheduled_delivery_evidence_unreadable", failure: failure)
            coordinator.reportProviderOutcomeNotAccepted(key: context.recoveryKey)
            holdScheduledSendTransfer(
                sessionID: context.lease.sessionID,
                record: context.dispatching,
                reason: .unresolved("Delivery evidence could not be read (\(Self.recoveryListDescription(of: failure))).")
            )
            return .heldForRecovery
        }

        // Our own intent never began a delivery attempt and no queue took it: verified no handoff.
        let neverDispatched = AgentScheduledSendTransfer.intentNeverDispatched(intentID: intentID, in: recoveryRecord)
        let outcomeIsNonDelivery = switch outcome {
        case .failed?, .stale?, .cancelled?, nil:
            true
        case .sent?, .queuedFallback?, .deliveryUnknown?:
            false
        }
        if neverDispatched, outcomeIsNonDelivery {
            // An explicit pre-runner `.failed`/`.stale`/`.cancelled` (or Codex's `nil`): nothing was handed off.
            coordinator.reportProviderOutcomeNotAccepted(key: context.recoveryKey)
            removeUnsentScheduledUserItem(id: context.attempt.itemID, from: session)
            guard case .success = await context.lane.withdraw(intentID: intentID) else {
                holdScheduledSendTransfer(
                    sessionID: context.lease.sessionID,
                    record: context.dispatching,
                    reason: .unresolved("This scheduled message's saved copy could not be released.")
                )
                return .heldForRecovery
            }
            await markScheduledSendFailed(
                session: session,
                record: context.dispatching,
                message: Self.scheduledNotAcceptedMessage(outcome)
            )
            notifyScheduledSendRecordChanged()
            return .failedBeforeHandoff
        }
        // A queue entry must be proven by its store receipt; a provider send must be proven by the
        // intent's recorded evidence. Anything else (`.sent` with no attempt evidence, a fallback
        // without a matching receipt) is held as uncertain.
        if neverDispatched, !queueReceiptMatches {
            coordinator.reportProviderOutcomeNotAccepted(key: context.recoveryKey)
            holdScheduledSendTransfer(
                sessionID: context.lease.sessionID,
                record: context.dispatching,
                reason: .unresolved("Delivery of this scheduled message could not be confirmed.")
            )
            return .heldForRecovery
        }

        switch AgentScheduledSendTransfer.resolve(record: context.dispatching, recoveryRecord: recoveryRecord, sentAt: Date()) {
        case let .completeTransfer(receipt) where receipt.isProviderAccepted:
            return await adoptScheduledProviderAcceptance(
                tabID: context.tabID,
                session: session,
                lease: context.lease,
                coordinator: coordinator,
                recoveryKey: context.recoveryKey,
                recoveryContext: context.recoveryContext,
                dispatching: context.dispatching,
                attempt: context.attempt,
                submitResult: submitResult,
                receipt: receipt
            )
        case let .completeTransfer(receipt):
            // Saved input owned by the linked intent, which is durably `queued` (fallback queue, or
            // settled back after a proven non-handoff). Never provider acceptance.
            coordinator.reportProviderOutcomeNotAccepted(key: context.recoveryKey)
            let committed = await completeScheduledSendTransfer(
                session: session,
                sessionID: context.lease.sessionID,
                record: context.dispatching,
                receipt: receipt
            )
            // A failed transfer commit is held by `completeScheduledSendTransfer`.
            return committed ? .accepted : .heldForRecovery
        case .noLinkedIntent, .rolledBack:
            coordinator.reportProviderOutcomeNotAccepted(key: context.recoveryKey)
            holdScheduledSendTransfer(
                sessionID: context.lease.sessionID,
                record: context.dispatching,
                reason: .unresolved("The saved copy of this scheduled message is missing.")
            )
            return .heldForRecovery
        case .cancelTransfer:
            // A cancellation decision for this exact attempt: held until the repair finishes it.
            coordinator.reportProviderOutcomeNotAccepted(key: context.recoveryKey)
            holdScheduledSendTransfer(
                sessionID: context.lease.sessionID,
                record: context.dispatching,
                reason: .unresolved("This scheduled message's pending schedule was cancelled.")
            )
            return .heldForRecovery
        case let .hold(message):
            // A still-`dispatching` intent is this process's own handoff whose affirmative evidence
            // follows dispatch (non-Codex routes accept on the provider's response or turn
            // completion): it waits for that evidence and is re-checked when the run settles.
            // `deliveryUnknown`, `failed`, and withdrawn-after-attempt evidence are unresolved.
            coordinator.reportProviderOutcomeNotAccepted(key: context.recoveryKey)
            let awaitsEvidence = AgentScheduledSendTransfer.linkedIntentDeliveryState(
                record: context.dispatching,
                recoveryRecord: recoveryRecord
            ) == .dispatching
            holdScheduledSendTransfer(
                sessionID: context.lease.sessionID,
                record: context.dispatching,
                reason: awaitsEvidence ? .awaitingProviderEvidence : .unresolved(message)
            )
            if awaitsEvidence {
                recheckScheduledSendTransferAwaitingEvidence(for: session)
            }
            return .heldForRecovery
        }
    }
}
