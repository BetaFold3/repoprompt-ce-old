import Foundation

extension MCPBootstrapLeaseSpec {
    @MainActor
    static func agentMode(
        tabID: UUID,
        runID: UUID,
        gateID: UUID,
        windowID: Int,
        agent: AgentProviderKind,
        sessionProfile: AgentSessionProfile = .standard,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false,
        additionalRestrictedTools: Set<String> = [],
        runHasNativeShell: Bool = false
    ) -> MCPBootstrapLeaseSpec {
        MCPBootstrapLeaseSpec(
            runID: runID,
            gateID: gateID,
            windowID: windowID,
            tabID: tabID,
            clientName: agent.mcpClientNameHint,
            // Delegation-leaf restrictions are unioned, never substituted, so they hide and deny
            // their tools even when grants or the advertisement flag would otherwise expose them.
            // A run with a native shell does plain Git inspection there, so the full `git` tool
            // is hidden and denied; `git_review_snapshot` stays available for Oracle review.
            restrictedTools: AgentModeMCPToolPolicy.restrictedTools
                .union(additionalRestrictedTools)
                .union(runHasNativeShell ? AgentModeMCPToolPolicy.nativeShellRestrictedTools : []),
            additionalTools: AgentModeMCPPolicyInstaller.additionalTools(
                for: agent,
                sessionProfile: sessionProfile
            ),
            allowedToolsOverride: sessionProfile == .knowledge
                ? AgentModeMCPToolPolicy.knowledgeAllowedTools
                : nil,
            sessionProfile: sessionProfile,
            oneShot: true,
            reason: AgentModeMCPPolicyInstaller.policyReason,
            ttl: AgentModeMCPPolicyInstaller.policyTTL,
            purpose: .agentModeRun,
            taskLabelKind: taskLabelKind,
            allowsAgentExternalControlTools: allowsAgentExternalControlTools,
            requiresExpectedAgentPID: agent.requiresExpectedPIDOwnedAgentModeMCPRouting
        )
    }
}

extension MCPBootstrapLease {
    static func agentModePolicyInstaller(
        _ connectionPolicyInstaller: @escaping AgentConnectionPolicyInstaller
    ) -> (MCPBootstrapLeaseSpec) async -> Void {
        { leaseSpec in
            guard let clientName = leaseSpec.clientName else { return }
            await connectionPolicyInstaller(
                clientName,
                leaseSpec.windowID,
                leaseSpec.restrictedTools,
                leaseSpec.oneShot,
                leaseSpec.reason,
                leaseSpec.ttl,
                leaseSpec.tabID,
                leaseSpec.runID,
                leaseSpec.additionalTools,
                leaseSpec.allowedToolsOverride,
                leaseSpec.sessionProfile,
                leaseSpec.purpose,
                leaseSpec.taskLabelKind,
                leaseSpec.allowsAgentExternalControlTools,
                leaseSpec.requiresExpectedAgentPID
            )
        }
    }
}
