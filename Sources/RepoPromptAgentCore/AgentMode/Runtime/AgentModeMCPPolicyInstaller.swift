import Foundation

@MainActor
enum AgentModeMCPPolicyInstaller {
    static let policyTTL: TimeInterval = 60
    static let policyReason = "agent-mode-run"

    static func additionalTools(
        for agent: AgentProviderKind,
        sessionProfile: AgentSessionProfile = .standard
    ) -> Set<String> {
        AgentModeMCPToolPolicy.grantedTools(
            forAgent: agent,
            sessionProfile: sessionProfile
        )
    }

    static func install(
        agent: AgentProviderKind,
        windowID: Int,
        tabID: UUID,
        runID: UUID,
        sessionProfile: AgentSessionProfile = .standard,
        allowedToolsOverride: Set<String>? = nil,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false,
        connectionPolicyInstaller: AgentConnectionPolicyInstaller
    ) async {
        guard let clientName = agent.mcpClientNameHint else { return }
        await connectionPolicyInstaller(
            clientName,
            windowID,
            AgentModeMCPToolPolicy.restrictedTools,
            true,
            policyReason,
            policyTTL,
            tabID,
            runID,
            additionalTools(for: agent, sessionProfile: sessionProfile),
            sessionProfile == .knowledge
                ? AgentModeMCPToolPolicy.knowledgeAllowedTools
                : allowedToolsOverride,
            sessionProfile,
            .agentModeRun,
            taskLabelKind,
            allowsAgentExternalControlTools,
            agent.requiresExpectedPIDOwnedAgentModeMCPRouting,
            // Direct installs carry no launch-resolved eligibility; only the run lease does.
            .native
        )
    }
}
