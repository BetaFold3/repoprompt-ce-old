import Foundation
import RepoPromptAgentCore

extension AgentModeViewModel {
    func makeStatusPillsSnapshot() -> AgentStatusPillsSnapshot {
        AgentStatusPillsSnapshot(
            currentTabID: currentTabID,
            selectedWorkflow: selectedWorkflow,
            stagedSlashCommand: stagedSlashCommandProps(tabID: currentTabID),
            selectedAgent: selectedAgent,
            profile: activeSession?.profile ?? .standard,
            autoEditPermissionGuidance: activeSession?.profile == .knowledge
                ? nil
                : autoEditPermissionGuidance,
            runState: runState,
            autoEditEnabled: autoEditEnabled,
            interviewFirst: interviewFirst,
            runLocation: runLocationProps(tabID: currentTabID),
            executionLocation: activeSession?.profile == .knowledge
                ? nil
                : executionLocationProps(tabID: currentTabID),
            activeAgentSessionID: activeSession?.activeAgentSessionID,
            activeRunID: activeSession?.runID
        )
    }

    func syncStatusPillsUIState() {
        ui.statusPills.update(makeStatusPillsSnapshot())
    }

    func runLocationProps(tabID: UUID?) -> AgentRunLocationProps? {
        guard let tabID,
              workspaceManager?.activeWorkspace?.isSystemWorkspace != true,
              remoteHostRegistry.hasHosts
        else {
            return nil
        }
        let hosts = (try? remoteHostRegistry.listHosts())?
            .filter { !$0.isRevokedByHost } ?? []
        let abbreviations = AgentRunLocationHostOption.abbreviations(
            for: hosts.map { (id: $0.id, displayName: $0.displayName) }
        )
        let hostOptions = hosts.map {
            AgentRunLocationHostOption(
                id: $0.id,
                displayName: $0.displayName,
                abbreviation: abbreviations[$0.id]
            )
        }
        guard !hostOptions.isEmpty else { return nil }

        let session = sessions[tabID]
        let selection = runLocationSelection(for: session)
        let selectedHostDisplayName: String? = {
            if case let .host(hostID) = selection {
                return hostOptions.first(where: { $0.id == hostID })?.displayName
                    ?? session?.remoteHost?.hostDisplayName
            }
            return nil
        }()
        let selectedHostAbbreviation: String? = {
            if case let .host(hostID) = selection {
                if let option = hostOptions.first(where: { $0.id == hostID }) {
                    return option.abbreviation
                }
                if let remoteHost = session?.remoteHost,
                   remoteHost.hostID == hostID
                {
                    return AgentRunLocationHostOption.abbreviations(
                        for: [(id: remoteHost.hostID, displayName: remoteHost.hostDisplayName)]
                    )[remoteHost.hostID]
                }
            }
            return nil
        }()
        let disabledReason: String? = if let session,
                                         let remoteReason = localSessionMutationDisabledReason(for: session),
                                         !isEligibleForInitialRunLocation(tabID: tabID, session: session)
        {
            remoteReason
        } else if isEligibleForInitialRunLocation(tabID: tabID, session: session) {
            nil
        } else {
            "Run location can only be changed before the first message."
        }
        return AgentRunLocationProps(
            tabID: tabID,
            selection: selection,
            selectedHostDisplayName: selectedHostDisplayName,
            selectedHostAbbreviation: selectedHostAbbreviation,
            hostOptions: hostOptions,
            isEnabled: disabledReason == nil,
            disabledReason: disabledReason
        )
    }

    func runLocationSelection(for session: AgentTabSession?) -> AgentRunLocation {
        guard let remoteHost = session?.remoteHost else { return .thisMac }
        return .host(hostID: remoteHost.hostID)
    }

    func shouldOfferRunLocallyInstead(tabID: UUID?, itemID: UUID) -> Bool {
        guard let tabID else { return false }
        return remoteRunLocallyFallbackItemIDByTabID[tabID] == itemID
            && canRunLocallyAfterRemoteFailure(tabID: tabID)
    }

    func runLocallyInsteadAfterRemoteFailure(tabID: UUID) {
        guard canRunLocallyAfterRemoteFailure(tabID: tabID) else { return }
        selectRunLocation(.thisMac, for: tabID)
    }

    private func canRunLocallyAfterRemoteFailure(tabID: UUID) -> Bool {
        guard remoteRunLocallyFallbackItemIDByTabID[tabID] != nil,
              let session = sessions[tabID],
              let remoteHost = session.remoteHost
        else { return false }
        // Offer the local fallback only for failed INITIAL starts (no host
        // session ever adopted). After a failed steer the adopted host session
        // may still be executing; falling back locally would stop/unbind while
        // the host run continues (dual execution) and the retained
        // remoteSessionID would hide the orphaned host session from pickup.
        return remoteHost.normalizedRemoteSessionID == nil && session.runState == .failed
    }

    func isEligibleForInitialRunLocation(tabID: UUID, session: AgentTabSession?) -> Bool {
        isEligibleForInitialStartLocation(tabID: tabID, session: session)
    }

    /// Persistent projection for the primary execution root. The initial intent
    /// remains deferred until first send; committed bindings remain visible afterward.
    func executionLocationProps(tabID: UUID?) -> AgentExecutionLocationProps? {
        guard let tabID,
              workspaceManager?.activeWorkspace?.isSystemWorkspace != true
        else {
            return nil
        }

        if isEligibleForInitialStartLocation(tabID: tabID, session: sessions[tabID]) {
            let session = sessions[tabID]
            let busy = session?.isPreparingInitialWorktree == true
            let remoteWorktreeReason = session?.remoteHost == nil ? nil : Self.remoteWorktreeManagedReason
            return AgentExecutionLocationProps(
                tabID: tabID,
                selection: session?.remoteHost == nil ? (session?.pendingInitialStartLocation ?? .local) : .local,
                indicator: nil,
                isInitialSelection: true,
                isEnabled: remoteWorktreeReason == nil && !busy,
                isOperationInProgress: busy,
                requiresActiveRunConfirmation: false,
                disabledReason: busy ? "Preparing the selected worktree…" : remoteWorktreeReason
            )
        }

        guard let session = sessions[tabID],
              hasLinkedAgentSession(for: tabID) || session.hasSentFirstMessage || !session.worktreeBindings.isEmpty
        else {
            return nil
        }
        let indicator = primaryExecutionWorktreeIndicator(forTabID: tabID)
        let selection: AgentInitialStartLocation = indicator.map { indicator in
            .existingWorktree(
                AgentExecutionWorktreeSelection(
                    repositoryID: indicator.repositoryID,
                    repoKey: "",
                    worktreeID: indicator.worktreeID,
                    path: indicator.worktreeRootPath,
                    name: indicator.worktreeName,
                    branch: indicator.branch,
                    head: nil,
                    isDetached: indicator.branch == nil,
                    label: indicator.label,
                    colorHex: indicator.colorHex,
                    isLocked: false,
                    lockReason: nil,
                    isPrunable: !indicator.isAvailable,
                    prunableReason: indicator.isAvailable ? nil : indicator.tooltipText
                )
            )
        } ?? .local
        let busy = session.isChangingExecutionLocation
        let disabledReason = session.remoteHost == nil ? executionLocationMutationDisabledReason(for: session) : Self.remoteWorktreeManagedReason
        return AgentExecutionLocationProps(
            tabID: tabID,
            selection: selection,
            indicator: indicator,
            isInitialSelection: false,
            isEnabled: disabledReason == nil && !busy,
            isOperationInProgress: busy,
            requiresActiveRunConfirmation: session.runState.isActive,
            disabledReason: busy ? "Changing execution location…" : disabledReason
        )
    }

    /// Initial-only compatibility shim used by the guarded first-send contract.
    func initialStartLocationProps(tabID: UUID?) -> AgentExecutionLocationProps? {
        guard let props = executionLocationProps(tabID: tabID), props.isInitialSelection else { return nil }
        return props
    }

    func isEligibleForInitialStartLocation(tabID: UUID, session: AgentTabSession?) -> Bool {
        guard workspaceManager?.activeWorkspace?.isSystemWorkspace != true else {
            return false
        }
        guard let session else { return !hasLinkedAgentSession(for: tabID) }
        guard !hasLinkedAgentSession(for: tabID) || session.hasLoadedPersistedState else { return false }
        return session.mcpControlContext == nil
            && !session.isMCPOriginated
            && session.parentSessionID == nil
            && !session.pendingHandoff.hasPayload
            && !session.hasSentFirstMessage
            && session.runState == .idle
            && session.runID == nil
            && session.activeRunAttemptID == nil
            && session.providerSessionID == nil
            && session.codexConversationID == nil
            && session.worktreeBindings.isEmpty
            && session.items.isEmpty
            && session.transcript.turns.isEmpty
    }

    static let remoteWorktreeManagedReason = "Worktrees are managed on the host for remote sessions."

    func localSessionMutationDisabledReason(tabID: UUID?) -> String? {
        guard let tabID,
              let session = sessions[tabID]
        else { return nil }
        return localSessionMutationDisabledReason(for: session)
    }

    func localSessionMutationDisabledReason(for session: AgentTabSession) -> String? {
        guard let remoteHost = session.remoteHost else { return nil }
        return "Managed on \(remoteHost.hostDisplayName)"
    }

    private func executionLocationMutationDisabledReason(for session: AgentTabSession) -> String? {
        if !session.hasLoadedPersistedState {
            return "Load this thread before changing its execution location."
        }
        if session.mcpControlContext != nil || session.isMCPOriginated || session.parentSessionID != nil {
            return "Execution location is managed by the parent or MCP run."
        }
        if session.pendingHandoff.defersProviderLockUntilSend {
            return "Send or clear the pending handoff before changing location."
        }
        return nil
    }

    func selectInitialStartLocation(_ selection: AgentInitialStartLocation, for tabID: UUID) {
        guard tabID == currentTabID,
              isEligibleForInitialStartLocation(tabID: tabID, session: sessions[tabID])
        else {
            return
        }
        guard let session = session(for: tabID, createIfNeeded: true) else { return }
        guard session.remoteHost == nil,
              !session.isPreparingInitialWorktree,
              session.pendingInitialStartLocation != selection
        else {
            return
        }
        session.pendingInitialStartLocation = selection
        syncComposerUIState(tabID: tabID)
        syncStatusPillsUIState()
    }

    private func hasSubmittedTurn(_ session: AgentTabSession) -> Bool {
        session.hasSentFirstMessage
            || session.items.contains { $0.kind == .user }
            || session.transcript.turns.contains { $0.request != nil }
    }

    @discardableResult
    func applyHostRunLocation(hostID: String, to session: AgentTabSession) -> Bool {
        guard session.remoteHost == nil,
              !hasSubmittedTurn(session),
              let host = try? remoteHostRegistry.host(id: hostID),
              !host.isRevokedByHost
        else { return false }

        session.locallyAttributedStartItemID = nil
        session.remoteHost = AgentSessionRemoteHostBinding(
            hostID: host.id,
            hostDisplayName: host.displayName,
            remoteSessionID: ""
        )
        session.pendingInitialStartLocation = .local
        session.selectedModelRaw = RemoteHostAgentCatalog.hostDefaultModelID
        if session.tabID == currentTabID {
            setSelectedModelRawDuringStateRestore(RemoteHostAgentCatalog.hostDefaultModelID)
        }
        loadRemoteHostCatalogIfNeeded(hostID: host.id)
        return true
    }

    @discardableResult
    func applyWorkspaceDefaultRunLocationIfNeeded(
        to session: AgentTabSession,
        workspace: WorkspaceModel? = nil
    ) -> Bool {
        guard let hostID = (workspace ?? workspaceManager?.activeWorkspace)?.defaultRemoteHostID else {
            return false
        }
        return applyHostRunLocation(hostID: hostID, to: session)
    }

    func selectRunLocation(_ selection: AgentRunLocation, for tabID: UUID) {
        let isRemoteFailureLocalFallback = selection == .thisMac
            && canRunLocallyAfterRemoteFailure(tabID: tabID)
        guard tabID == currentTabID,
              let props = runLocationProps(tabID: tabID),
              props.isEnabled || isRemoteFailureLocalFallback,
              props.selection != selection
        else { return }
        guard let session = session(for: tabID, createIfNeeded: false) else { return }
        switch selection {
        case .thisMac:
            clearRemoteStartWindowPickerIfOwned(by: tabID)
            if session.remoteHost != nil {
                remoteCoordinator.stop(tabID: tabID)
            }
            let undeliveredUserItemIDs = Set(session.items.lazy.filter {
                $0.kind == .user && $0.isUndeliveredRemoteSend
            }.map(\.id))
            if !undeliveredUserItemIDs.isEmpty {
                session.mutateItemsBatch { items in
                    for index in items.indices where undeliveredUserItemIDs.contains(items[index].id) {
                        items[index].isUndeliveredRemoteSend = false
                    }
                }
                for itemID in undeliveredUserItemIDs {
                    session.remoteResendPayloadsByItemID.removeValue(forKey: itemID)
                    session.remoteResendInFlightItemIDs.remove(itemID)
                    session.pendingRemoteOptimisticUserItemIDs.remove(itemID)
                    session.pendingRemoteOptimisticProviderTextByItemID.removeValue(forKey: itemID)
                }
            }
            session.locallyAttributedStartItemID = nil
            session.remoteHost = nil
            remoteRunLocallyFallbackItemIDByTabID.removeValue(forKey: tabID)
            if session.selectedModelRaw == RemoteHostAgentCatalog.hostDefaultModelID {
                let fallback = defaultModelRaw(for: session.selectedAgent)
                session.selectedModelRaw = fallback
                if tabID == currentTabID {
                    setSelectedModelRawDuringStateRestore(fallback)
                }
            }
        case let .host(hostID):
            guard !hasSubmittedTurn(session) else { return }
            if session.remoteHost != nil {
                guard let host = try? remoteHostRegistry.host(id: hostID),
                      !host.isRevokedByHost
                else { return }
                remoteCoordinator.stop(tabID: tabID)
                session.locallyAttributedStartItemID = nil
                session.remoteHost = nil
            }
            guard applyHostRunLocation(hostID: hostID, to: session) else { return }
        }
        session.isDirty = true
        scheduleSave(for: tabID)
        syncComposerUIState(tabID: tabID)
        syncStatusPillsUIState()
    }

    func setInterviewFirst(_ enabled: Bool) {
        guard interviewFirst != enabled else { return }
        interviewFirst = enabled
        syncStatusPillsUIState()
    }

    /// The session's interview-first choice. The active session also honours a choice made before
    /// that session object was bound to the tab (the projected `interviewFirst`).
    func effectiveInterviewFirst(for session: AgentTabSession) -> Bool {
        session.interviewFirst || (session === activeSession && interviewFirst)
    }

    /// Sets one session's interview-first choice, keeping the active-tab projection in step.
    func setInterviewFirst(_ enabled: Bool, for session: AgentTabSession) {
        session.interviewFirst = enabled
        if session === activeSession, interviewFirst != enabled {
            interviewFirst = enabled
        }
    }

    func toggleInterviewFirst() {
        setInterviewFirst(!interviewFirst)
    }
}
