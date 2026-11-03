import Foundation

@MainActor
package final class AgentModeProviderBindingService {
    package let preferences: AgentProviderPreferenceSnapshotStore

    package init(preferences: AgentProviderPreferenceSnapshotStore) {
        self.preferences = preferences
    }

    package func topLevelSettingsControlsBinding(providerID: AgentProviderBindingID) -> AgentProviderControlsBinding {
        preferences.topLevelSettingsControlsBinding(providerID: providerID)
    }

    package func controlsBinding(
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String? = nil,
        permissionProfile: AgentProviderPermissionProfile,
        isSubagent: Bool,
        externallyManagedReason: String?,
        claudePermissionSessionState: ClaudePermissionSessionState? = nil
    ) -> AgentProviderControlsBinding {
        preferences.controlsBinding(
            selectedAgent: selectedAgent,
            selectedModelRaw: selectedModelRaw,
            permissionProfile: permissionProfile,
            isSubagent: isSubagent,
            externallyManagedReason: externallyManagedReason,
            claudePermissionSessionState: claudePermissionSessionState
        )
    }

    package func runtimePermission(
        for agent: AgentProviderKind,
        profile: AgentProviderPermissionProfile
    ) -> AgentProviderRuntimePermissionBinding {
        preferences.runtimePermission(for: agent, profile: profile)
    }

    func permissionProfileForMCPActivation(isSubagent: Bool) -> AgentProviderPermissionProfile {
        permissionProfileForMCPActivation(isSubagent: isSubagent, provider: nil)
    }

    /// Provider-aware variant of `permissionProfileForMCPActivation(isSubagent:)`.
    ///
    /// MCP-originated agents use the same permission policy as sub-agents, including
    /// top-level sessions created by `agent_run.start` / `agent_manage.create_session`.
    /// When the global policy is `.custom`, the resolver consults the per-provider
    /// override; with `provider == nil` we fall back to `.mcpSafeDefaults` because we can't
    /// make a safer choice without the provider context.
    ///
    /// SEARCH-HELPER: Sub-agent Permissions, tri-state policy, Safe Managed resolution
    package func permissionProfileForMCPActivation(
        isSubagent: Bool,
        provider: AgentProviderBindingID?
    ) -> AgentProviderPermissionProfile {
        _ = isSubagent
        let defaults = preferences.defaults
        let global = AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults, secureStore: preferences.securePermissions)
        switch global {
        case .safeManaged:
            return .mcpSafeDefaults
        case .inheritProviderSettings:
            return .userConfigured
        case .custom:
            guard let provider else { return .mcpSafeDefaults }
            let level = AgentModePermissionPreferences.providerSubagentPermissionLevel(
                for: provider,
                defaults: defaults,
                secureStore: preferences.securePermissions
            )
            return .providerOverride(level)
        }
    }

    /// Active global sub-agent policy. Exposed so UI callers can bind to the tri-state
    /// without reaching into `AgentModePermissionPreferences` directly.
    func subagentPermissionPolicy() -> AgentSubagentPermissionPolicy {
        AgentModePermissionPreferences.subagentPermissionPolicy(defaults: preferences.defaults, secureStore: preferences.securePermissions)
    }

    func setSubagentPermissionPolicy(_ policy: AgentSubagentPermissionPolicy) {
        AgentModePermissionPreferences.setSubagentPermissionPolicy(policy, defaults: preferences.defaults, secureStore: preferences.securePermissions)
    }

    func providerSubagentPermissionLevel(for providerID: AgentProviderBindingID) -> AgentProviderPermissionLevelID {
        AgentModePermissionPreferences.providerSubagentPermissionLevel(for: providerID, defaults: preferences.defaults, secureStore: preferences.securePermissions)
    }

    func setProviderSubagentPermissionLevel(
        _ level: AgentProviderPermissionLevelID,
        for providerID: AgentProviderBindingID
    ) {
        AgentModePermissionPreferences.setProviderSubagentPermissionLevel(level, for: providerID, defaults: preferences.defaults, secureStore: preferences.securePermissions)
    }

    package func externallyManagedPermissionReason(
        isSubagent: Bool,
        isMCPControlled: Bool = true,
        permissionProfile: AgentProviderPermissionProfile
    ) -> String? {
        if isSubagent || isMCPControlled {
            switch permissionProfile {
            case .mcpSafeDefaults:
                return "MCP-started agents use the sub-agent Safe Managed permission defaults."
            case .userConfigured:
                return "MCP-started agents inherit your provider-configured permissions. Change the global sub-agent policy before starting an agent."
            case .providerOverride:
                return "MCP-started agents use the Custom per-provider mode selected in Agent Permissions."
            }
        }
        return nil
    }

    package func autoEditGuidance(
        for session: AgentTabSession
    ) -> AgentAutoEditPermissionGuidance? {
        autoEditGuidance(
            agent: session.selectedAgent,
            autoEditEnabled: session.autoEditEnabled
        )
    }

    func autoEditGuidance(
        agent: AgentProviderKind,
        autoEditEnabled: Bool
    ) -> AgentAutoEditPermissionGuidance? {
        guard autoEditEnabled == false else { return nil }

        if agent == .codexExec {
            guard CodexAgentToolPreferences.permissionLevel(defaults: preferences.defaults, secureStore: preferences.securePermissions) != .readOnly else { return nil }
            return AgentAutoEditPermissionGuidance(
                provider: .codex,
                message: "Codex sandbox allows file edits — set Read Only",
                actionTitle: "Set Read Only",
                action: .setCodexReadOnly
            )
        }

        if agent.usesClaudeTooling {
            guard ClaudeAgentToolPreferences.permissionLevel(defaults: preferences.defaults, secureStore: preferences.securePermissions) != .requireApproval else { return nil }
            return AgentAutoEditPermissionGuidance(
                provider: .claude,
                message: "Claude sandbox allows file edits — set Require Approval",
                actionTitle: "Set Require Approval",
                action: .setClaudeRequireApproval
            )
        }

        return nil
    }

    @discardableResult
    package func applyAutoEditGuidanceAction(
        _ action: AgentAutoEditPermissionGuidance.Action
    ) -> AgentProviderBindingID {
        switch action {
        case .setCodexReadOnly:
            setPermissionLevel(.codex(.readOnly))
        case .setClaudeRequireApproval:
            setPermissionLevel(.claude(.requireApproval))
        }
    }

    package func providerPreferenceChanged(
        providerID: AgentProviderBindingID,
        sessions: [AgentTabSession],
        currentTabID: UUID?,
        codexCoordinator: CodexAgentModeCoordinator,
        scheduleSave: @escaping (UUID) -> Void,
        updateActiveBindings: @escaping (AgentTabSession) -> Void,
        refreshGuidance: @escaping () -> Void
    ) {
        var shouldRefreshActiveBindings = false
        var shouldRefreshGuidance = false

        for session in sessions where session.selectedAgent.providerBindingID == providerID {
            scheduleSave(session.tabID)
            if session.tabID == currentTabID {
                shouldRefreshActiveBindings = true
                shouldRefreshGuidance = true
            }

            switch providerID {
            case .codex:
                codexCoordinator.handleToolPreferencesChanged(for: session)
            case .claude:
                // Claude launch settings are revalidated immediately before dispatch.
                // Avoid an eager untracked shutdown that could race a newly started run.
                break
            case .openCode:
                let runtime = runtimePermission(for: session.selectedAgent, profile: session.permissionProfile)
                guard let sessionModeID = runtime.acpSessionModeID,
                      session.runState.isActive,
                      let controller = session.acpController else { continue }
                // R6 owner capture: this permission change belongs to the run active now.
                let runtimeOwner = session.runtimeSessionScope
                Task { @MainActor in
                    let providerName = session.selectedAgent.displayName
                    if AgentRuntimeProviderService.enableDebugLogging { print("[ACP-Runner] tab=\(session.tabID) applying \(providerName) session mode=\(sessionModeID)") }
                    do {
                        await controller.setAutoApproveAllToolPermissions(runtime.autoApproveAllACPToolPermissions)
                        try await AgentRuntimeOperationOwner.$session.withValue(runtimeOwner) {
                            try await controller.setSessionMode(sessionModeID)
                        }
                        if runtime.acceptsPendingACPApprovalWhenActivated, let pendingApproval = session.pendingApproval {
                            await controller.respondToPermissionRequest(id: pendingApproval.requestID.displayValue, decision: .acceptForSession)
                        }
                    } catch {
                        if AgentRuntimeProviderService.enableDebugLogging { print("[ACP-Runner] tab=\(session.tabID) failed to apply \(providerName) session mode=\(sessionModeID) error=\(error.localizedDescription)") }
                    }
                    if session.tabID == currentTabID {
                        updateActiveBindings(session)
                    }
                }
            case .ohMyPi:
                break
            case .cursor:
                let runtime = runtimePermission(for: session.selectedAgent, profile: session.permissionProfile)
                guard session.runState.isActive, let controller = session.acpController else { continue }
                Task { @MainActor in
                    await controller.setAutoApproveAllToolPermissions(runtime.autoApproveAllACPToolPermissions)
                    if runtime.autoApproveAllACPToolPermissions, let pendingApproval = session.pendingApproval {
                        await controller.respondToPermissionRequest(id: pendingApproval.requestID.displayValue, decision: .acceptForSession)
                    }
                    if session.tabID == currentTabID {
                        updateActiveBindings(session)
                    }
                }
            }
        }

        if shouldRefreshActiveBindings, let active = sessions.first(where: { $0.tabID == currentTabID }) {
            updateActiveBindings(active)
        } else if shouldRefreshGuidance {
            refreshGuidance()
        }
    }

    @discardableResult
    package func setPermissionLevel(_ id: AgentProviderPermissionLevelID) -> AgentProviderBindingID {
        preferences.setPermissionLevel(id)
    }

    package func applyCodexToolSettingMutation(_ mutation: CodexToolSettingMutation) {
        preferences.applyCodexToolSettingMutation(mutation)
    }

    package func applyClaudeToolSettingMutation(_ mutation: ClaudeToolSettingMutation) {
        preferences.applyClaudeToolSettingMutation(mutation)
    }

    package func setClaudeEffortLevel(_ level: ClaudeCodeEffortLevel) {
        preferences.setClaudeEffortLevel(level)
    }

    package func setClaudeEffortLevel(
        _ level: ClaudeCodeEffortLevel,
        forModelRaw modelRaw: String?,
        agentKind: AgentProviderKind?
    ) {
        preferences.setClaudeEffortLevel(level, forModelRaw: modelRaw, agentKind: agentKind)
    }

    func claudeEffortLevel() -> ClaudeCodeEffortLevel {
        ClaudeAgentToolPreferences.effortLevel(defaults: preferences.defaults)
    }

    func claudeEffortLevel(
        forModelRaw modelRaw: String?,
        agentKind: AgentProviderKind?
    ) -> ClaudeCodeEffortLevel {
        guard let modelRaw, let agentKind else {
            return claudeEffortLevel()
        }
        return ClaudeAgentToolPreferences.effortLevel(
            forModelRaw: modelRaw,
            agentKind: agentKind,
            defaults: preferences.defaults
        )
    }

    package func bumpRevision(for providerID: AgentProviderBindingID) {
        preferences.bumpRevision(for: providerID)
    }
}
