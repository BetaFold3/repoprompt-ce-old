import Foundation
import OSLog
import RepoPromptAgentCore

/// Always-on composer submit rejection reasons (unified logging, persisted at `.notice`), for
/// after-the-fact diagnosis in a normal run. Logs only fixed reason strings and identifiers, never
/// draft text or other user content.
enum AgentComposerSubmitDiagnostics {
    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "ComposerSubmit")

    /// A rejection in the composer view (`AgentInputBar.sendMessage()` / `scheduleMessage(...)`).
    static func viewRejected(reason: String, currentTabID: UUID?, propsTabID: UUID?, targetTabID: UUID?) {
        logger.notice(
            "view_rejected reason=\(reason, privacy: .public) currentTab=\(currentTabID?.uuidString ?? "nil", privacy: .public) propsTab=\(propsTabID?.uuidString ?? "nil", privacy: .public) targetTab=\(targetTabID?.uuidString ?? "nil", privacy: .public)"
        )
    }

    /// A rejection in the view model's composer submit path (`executeComposerSubmitAttempt`).
    static func submitRejected(reason: String, route: String, targetTabID: UUID, currentTabID: UUID?) {
        logger.notice(
            "submit_rejected reason=\(reason, privacy: .public) route=\(route, privacy: .public) targetTab=\(targetTabID.uuidString, privacy: .public) currentTab=\(currentTabID?.uuidString ?? "nil", privacy: .public)"
        )
    }
}

extension AgentModeViewModel {
    /// `materializingSession: false` never creates a session: a tab without one gets no submit target.
    func makeComposerProps(tabID explicitTabID: UUID? = nil, materializingSession: Bool = true) -> AgentComposerProps {
        let tabID = explicitTabID ?? currentTabID
        let session = tabID.flatMap { sessions[$0] }
        let isMCPControlled = isMCPControlled(tabID: tabID)
        let modelSelectionInteractivity = modelSelectionInteractivity(tabID: tabID)
        let availableAgentsForTab = selectableAgents(forTabID: tabID)
        let selectedAgentForTab = session?.selectedAgent ?? selectedAgent
        let canSendWithProviderForTab = availableAgentsForTab.contains(selectedAgentForTab)
        let isCodexRunActive: Bool = {
            guard selectedAgent == .codexExec, let tabID else { return false }
            return isTabRunning(tabID)
        }()
        let cancelTarget: AgentRunCancelTarget? = {
            guard let tabID,
                  let session,
                  session.runState.isActive,
                  session.runState != .waitingForUser,
                  session.runID != nil
            else { return nil }
            return makeRunCancelTarget(tabID: tabID, session: session)
        }()
        let submitTarget = session != nil || materializingSession
            ? makeComposerSubmitTarget(tabID: tabID, session: session)
            : nil
        let remoteCatalog = remoteHostCatalogSnapshot(for: session)
        let isRemoteSession = session?.remoteHost != nil
        let scheduledSend: AgentScheduledSendProps? = session.flatMap { session in
            switch session.scheduledSend {
            case nil:
                nil
            case .unreadable?:
                AgentScheduledSendProps.unreadable(tabID: session.tabID)
            case let .v1(record)?:
                AgentScheduledSendProps(
                    tabID: session.tabID,
                    scheduledSend: record,
                    blockingSessionName: scheduledSendBlockingSessionName(
                        for: record,
                        session: session
                    ),
                    recoveryPhase: session.scheduledSendPendingFinalization?.status,
                    pendingConfirmation: session.activeAgentSessionID.flatMap { sessionID in
                        scheduledSendCoordinator?.pendingConfirmationStatus(sessionID: sessionID)
                    }.flatMap { $0.scheduleID == record.id ? $0 : nil },
                    recoveryBlocker: scheduledSendCoordinator?.recoveryBlocker(scheduleID: record.id)
                )
            }
        }
        let canSchedule = canScheduleSend(tabID: tabID, session: session)
        let scheduleTargetIsNewSessionStart = scheduleTargetIsNewSessionStart(tabID: tabID, session: session)
        let selectedModelRawForProps = session?.selectedModelRaw ?? selectedModelRaw
        let selectedModelDisplayNameForProps = remoteCatalog?.displayName(forModelID: selectedModelRawForProps)
            ?? selectedModelDisplayName
        return AgentComposerProps(
            currentTabID: tabID,
            submitTarget: submitTarget,
            attachments: AgentAttachmentStripSnapshot(
                scopeTabID: tabID,
                imageAttachments: pendingImageAttachments,
                taggedFileAttachments: pendingTaggedFileAttachments
            ),
            scheduledSend: scheduledSend,
            staleResetRecovery: session.flatMap { staleResetRecoveryProps(for: $0) },
            canSchedule: canSchedule,
            scheduleTargetIsNewSessionStart: scheduleTargetIsNewSessionStart,
            runState: runState,
            cancelTarget: cancelTarget,
            isAgentBusy: isAgentBusy,
            isWaitingForInstruction: isWaitingForInstruction,
            canUseLinkedAgentSession: hasLinkedAgentSession(for: tabID),
            isCurrentTabMCPControlled: isMCPControlled,
            areModelControlsDisabled: modelSelectionInteractivity.isDisabled,
            providerControls: activeProviderControlsBinding,
            isCodexRunActive: isCodexRunActive,
            hasAvailableAgentProviders: isRemoteSession ? true : !availableAgentsForTab.isEmpty,
            canSendWithCurrentProvider: isRemoteSession ? true : canSendWithProviderForTab,
            unavailableSelectedAgentMessage: isRemoteSession
                ? nil
                : (canSendWithProviderForTab ? nil : unavailableSelectedAgentMessage),
            runLocation: runLocationSelection(for: session),
            runLocationHostDisplayName: session?.remoteHost?.hostDisplayName,
            remoteHostCatalog: remoteCatalog,
            selectedAgent: session?.selectedAgent ?? selectedAgent,
            selectedModelRaw: selectedModelRawForProps,
            selectedModelDisplayName: selectedModelDisplayNameForProps,
            ohMyPiThinkingSelections: session?.ohMyPiThinkingSelections ?? .empty,
            selectedReasoningEffortRaw: selectedReasoningEffortRaw,
            selectedReasoningEffortDisplayName: selectedReasoningEffortDisplayName,
            availableAgents: availableAgentsForTab,
            isProviderPickerLockedForCurrentTab: isProviderPickerLocked(tabID: tabID),
            lockedAgentSelectionMessage: lockedAgentSelectionMessage(tabID: tabID),
            autoEditEnabled: autoEditEnabled,
            stagedSlashCommand: stagedSlashCommandProps(tabID: tabID),
            draftRestorationEvent: draftRestorationEvent.map(AgentDraftRestorationProps.init),
            fileTagLookupContextIdentity: agentWorkspaceLookupContextIdentity(tabID: tabID, session: session),
            delegatedQuestions: delegatedQuestionBannerRows(forParentTabID: tabID),
            recoveryList: recoveryListProps(forActiveSession: session),
            isShutdownFrozen: isShutdownFrozen
        )
    }

    private func scheduledSendBlockingSessionName(
        for scheduledSend: AgentScheduledSendPersist,
        session: AgentTabSession
    ) -> String? {
        guard scheduledSend.firstEligibleAt != nil else { return nil }
        if !scheduledSend.isNewSessionStart {
            return scheduledSendSessionName(session)
        }

        for (candidateTabID, candidateSession) in sessions where candidateTabID != session.tabID {
            if scheduledSendBusyState(tabID: candidateTabID).isBusy {
                return scheduledSendSessionName(candidateSession)
            }
        }
        return nil
    }

    private func scheduledSendSessionName(_ session: AgentTabSession) -> String? {
        guard let sessionID = session.activeAgentSessionID,
              let name = sessionIndex[sessionID]?.name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return name
    }

    func makeComposerSubmitTarget(tabID: UUID?, session: AgentTabSession?) -> AgentComposerSubmitTarget? {
        guard let tabID else { return nil }
        let existingSession = session ?? sessions[tabID]
        guard let resolvedSession = existingSession ?? self.session(for: tabID, createIfNeeded: true) else {
            return nil
        }
        // V1-3: the default tab of a fresh workspace never passes through
        // `createAndActivateSessionTab()` — its session materializes lazily
        // right here on the first composer sync. Apply the workspace-default
        // run location exactly once at that creation so the run-location pill
        // and the first-send snapshot carry the host binding + pinned model.
        // One-shot: an existing session is never re-bound, so an explicit
        // "This Mac" selection sticks. Hydrated sessions (persistent binding
        // installed at creation → activeAgentSessionID != nil) and MCP flows
        // (ensureSessionReady / mcpResolveOrCreateSessionTarget never call
        // this composer seam) keep their no-auto-bind behavior.
        if existingSession == nil,
           resolvedSession.activeAgentSessionID == nil,
           isEligibleForInitialStartLocation(tabID: tabID, session: resolvedSession)
        {
            applyWorkspaceDefaultRunLocationIfNeeded(to: resolvedSession)
        }
        let expectedInitialStartLocation = initialStartLocationProps(tabID: tabID)?.selection
        if workspaceSwitchInFlight, (expectedInitialStartLocation ?? .local) == .local {
            return nil
        }
        guard !resolvedSession.isComposerSubmissionInFlight,
              !resolvedSession.isPreparingInitialWorktree,
              !resolvedSession.isChangingExecutionLocation
        else { return nil }
        let expectedSourceAgentSessionID = composerSourceAgentSessionID(tabID: tabID, session: resolvedSession)
        let hasLinkedSession = hasLinkedAgentSession(for: tabID)
        let route: AgentComposerSubmitTarget.Route
        if hasLinkedSession {
            guard expectedSourceAgentSessionID != nil else { return nil }
            route = .existingAgentSession
        } else {
            guard expectedSourceAgentSessionID == nil else { return nil }
            guard !resolvedSession.runState.isActive,
                  resolvedSession.runID == nil,
                  resolvedSession.activeRunAttemptID == nil
            else { return nil }
            route = .createAgentSessionFromSourceTab
        }

        let expectedRunState = resolvedSession.runState
        let expectedRunID = resolvedSession.runID
        let expectedRunAttemptID = resolvedSession.activeRunAttemptID
        guard !expectedRunState.isActive || expectedRunID != nil else { return nil }
        return AgentComposerSubmitTarget(
            tabID: tabID,
            route: route,
            expectedSourceTabSessionIdentity: ObjectIdentifier(resolvedSession),
            expectedSourceAgentSessionID: expectedSourceAgentSessionID,
            expectedPersistentBindingIdentity: resolvedSession.persistentSessionBindingIdentity,
            expectedBindingTransitionGeneration: resolvedSession.bindingTransitionGeneration,
            expectedRunState: expectedRunState,
            expectedRunID: expectedRunID,
            expectedRunAttemptID: expectedRunAttemptID,
            expectedSubmissionToken: resolvedSession.composerSubmissionToken,
            expectedInitialStartLocation: expectedInitialStartLocation
        )
    }

    func syncComposerUIState(tabID: UUID? = nil) {
        #if DEBUG
            test_syncComposerCallCount += 1
        #endif
        // The composer store holds one tab's props: the current tab's (F7). Props built for another
        // tab mix that tab's state with the visible session's, so an explicit non-current tab never
        // publishes; its scheduler busy state is still reported. With no current tab, the no-tab
        // props are published so another tab's props never linger.
        let ownerTabID = currentTabID
        if tabID == nil || tabID == ownerTabID || ownerTabID == nil {
            ui.composer.update(makeComposerProps(tabID: ownerTabID))
        }
        if let observedTabID = tabID ?? ownerTabID {
            notifyScheduledSendBusyStateMayHaveChanged(tabIDs: [observedTabID])
        }
    }

    func syncAllActiveUIState(tabID: UUID? = nil) {
        #if DEBUG
            AgentModePerfDiagnostics.increment("ui.syncAllActiveUIState", tabID: tabID)
            AgentModePerfDiagnostics.event("ui.syncAllActiveUIState", tabID: tabID)
        #endif
        syncComposerUIState(tabID: tabID)
        syncStatusPillsUIState()
        let selectionSummary = currentOwnerCanonicalSelectionSummary()
        syncRuntimeMetricsUIState(
            liveSelectedFileCount: selectionSummary?.totalExplicitFileCount,
            liveSelectionSummary: selectionSummary
        )
        // Sidebar revision should publish only on sidebar-relevant changes (session
        // list, sort, search, visible count). `syncSidebarUIState()` still republishes
        // the snapshot when those inputs differ; callers that truly need to force a
        // sidebar revision bump (e.g. sessions/sessionIndex/run-state mutations) call
        // `syncSidebarUIState(refresh: true)` directly.
        syncSidebarUIState()
        syncTranscriptUIState()
        syncRunInteractionUIState()
    }

    /// Non-flushing read of the current owner's canonical stored selection. Nil (the previous
    /// full-sync value) unless the active workspace's explicit active tab, `currentTabID`, and
    /// the active session all agree and that tab exists in that workspace. No fallbacks.
    private func currentOwnerCanonicalSelectionSummary() -> AgentContextSelectionSummary? {
        guard let workspaceManager,
              let workspace = workspaceManager.activeWorkspace,
              let tabID = currentTabID,
              activeSession?.tabID == tabID,
              workspace.activeComposeTabID == tabID,
              let tab = workspaceManager.composeTab(
                  for: WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: tabID)
              )
        else { return nil }
        return AgentContextExportResolver.selectionSummary(for: tab.selection)
    }

    func syncActiveUIState(tabID: UUID? = nil, invalidation: ActiveUIInvalidation) {
        guard !invalidation.isEmpty else { return }
        #if DEBUG
            AgentModePerfDiagnostics.increment("ui.syncActiveUIState", tabID: tabID)
            AgentModePerfDiagnostics.event(
                "ui.syncActiveUIState",
                tabID: tabID,
                fields: [
                    "composer": String(invalidation.contains(.composer)),
                    "status": String(invalidation.contains(.statusPills)),
                    "runtime": String(invalidation.contains(.runtimeMetrics)),
                    "transcript": String(invalidation.contains(.transcript)),
                    "run": String(invalidation.contains(.runInteraction))
                ]
            )
        #endif
        if invalidation.contains(.composer) {
            syncComposerUIState(tabID: tabID)
        }
        if invalidation.contains(.statusPills) {
            syncStatusPillsUIState()
        }
        if invalidation.contains(.runtimeMetrics) {
            syncRuntimeMetricsUIState()
        }
        if invalidation.contains(.transcript) {
            syncTranscriptUIState()
        }
        if invalidation.contains(.runInteraction) {
            syncRunInteractionUIState()
        }
    }
}
