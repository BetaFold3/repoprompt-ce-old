import Foundation

@MainActor
enum AgentModeMCPPolicyInstaller {
    static let policyTTL: TimeInterval = 60
    static let policyReason = "agent-mode-run"

    static func additionalTools(
        for agent: AgentProviderKind,
        sessionProfile: AgentSessionProfile = .standard,
        runOwnership: AgentRunOwnership? = nil
    ) -> Set<String> {
        AgentModeMCPToolPolicy.grantedTools(
            forAgent: agent,
            sessionProfile: sessionProfile,
            runOwnership: runOwnership
        )
    }
}
