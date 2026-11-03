import Foundation

@MainActor
final class ChatWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
    private weak var workspaceManager: WorkspaceManagerViewModel?
    private weak var oracleViewModel: OracleViewModel?

    init(workspaceManager: WorkspaceManagerViewModel, oracleViewModel: OracleViewModel) {
        self.workspaceManager = workspaceManager
        self.oracleViewModel = oracleViewModel
    }

    func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
        let count = activeChatCount()
        guard count > 0 else { return [] }
        return [WorkspaceSwitchSessionItem(
            id: "chat",
            count: count,
            singularLabel: "active chat session",
            pluralLabel: "active chat sessions"
        )]
    }

    func cancelSwitchSessions() async {
        guard let workspaceManager, let oracleViewModel else { return }
        guard activeChatCount() > 0 else { return }

        await oracleViewModel.cancelAllActiveSessionStreams()
        workspaceManager.setActiveChatTabs([])
        workspaceManager.isChatBusy = false
    }

    private func activeChatCount() -> Int {
        guard let workspaceManager else { return 0 }
        return max(workspaceManager.tabsWithActiveChat.count, workspaceManager.isChatBusy ? 1 : 0)
    }
}

@MainActor
final class ContextBuilderWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
    private weak var contextBuilderAgentViewModel: ContextBuilderAgentViewModel?

    init(contextBuilderAgentViewModel: ContextBuilderAgentViewModel) {
        self.contextBuilderAgentViewModel = contextBuilderAgentViewModel
    }

    func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
        let count = activeContextBuilderCount()
        guard count > 0 else { return [] }
        return [WorkspaceSwitchSessionItem(
            id: "context-builder",
            count: count,
            singularLabel: "active context builder session",
            pluralLabel: "active context builder sessions"
        )]
    }

    func cancelSwitchSessions() async {
        await contextBuilderAgentViewModel?.cancelAllActiveRuns()
    }

    private func activeContextBuilderCount() -> Int {
        let contextBuilderTabs = contextBuilderAgentViewModel?.tabsWithActiveContextBuilderRun ?? []
        let planTabs = contextBuilderAgentViewModel?.tabsWithActivePlanGeneration ?? []
        return contextBuilderTabs.union(planTabs).count
    }
}

@MainActor
final class AgentModeWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
    private weak var agentModeViewModel: AgentModeViewModel?

    init(agentModeViewModel: AgentModeViewModel) {
        self.agentModeViewModel = agentModeViewModel
    }

    func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
        var items: [WorkspaceSwitchSessionItem] = []
        let count = activeAgentCount()
        if count > 0 {
            items.append(WorkspaceSwitchSessionItem(
                id: "agent-mode",
                count: count,
                singularLabel: "active agent session",
                pluralLabel: "active agent sessions"
            ))
        }
        // A retained local conversation that cannot be saved (stale-reset recovery) is discarded
        // by a workspace switch, window close, or quit: the same confirmation surfaces list it.
        let unsavedCount = agentModeViewModel?.staleResetRecoveryTabIDs.count ?? 0
        if unsavedCount > 0 {
            items.append(WorkspaceSwitchSessionItem(
                id: "agent-mode-unsaved-recovery",
                count: unsavedCount,
                singularLabel: "unsaved agent conversation awaiting reload",
                pluralLabel: "unsaved agent conversations awaiting reload"
            ))
        }
        return items
    }

    func cancelSwitchSessions() async {
        guard let agentModeViewModel else { return }
        // The user confirmed the switch with the unsaved conversations listed: relinquish them
        // before ordinary discard so no late recovery continuation touches the new owner.
        agentModeViewModel.discardStaleResetRecoveriesForConfirmedLifecycle()
        let activeTabs = agentModeViewModel.tabsWithActiveAgentRun
        for tabID in activeTabs {
            await agentModeViewModel.cancelAgentRun(tabID: tabID, cause: .ordinary, completion: .terminalPublished)
        }
    }

    private func activeAgentCount() -> Int {
        agentModeViewModel?.tabsWithActiveAgentRun.count ?? 0
    }
}
