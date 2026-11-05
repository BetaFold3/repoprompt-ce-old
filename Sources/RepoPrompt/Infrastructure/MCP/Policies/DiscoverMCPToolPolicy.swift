import Foundation
import RepoPromptAgentCore

/// MCP tool policy for Context Builder agent runs.
/// Controls which tools are restricted and which special tools are granted.
enum DiscoverMCPToolPolicy {
    /// Context Builder agents should explore and plan, not make changes or manage state.
    static let restrictedCapabilities: Set<MCPToolCapability> = [
        .conversationSend,
        .agentConversationSend,
        .conversationHelper,
        .fileContentEdit,
        .fileManagement,
        .routingAdvanced,
        .discovery,
        .appSettings,
        .worktreeManage,

        .agentExternalControl,
        .agentExploreControl,
        .agentReasoningControl,
        .agentSessionControl,
        // Context Builder runs never present rich content.
        .richPresentation
    ]

    static let restrictedTools: Set<String> = MCPToolCapabilities.toolNames(for: restrictedCapabilities)

    /// Tools granted to discovery runs (from MCPPolicyGatedTools).
    /// These are conditionally granted based on user settings (allowClarifyingQuestions).
    static let grantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction
    ]

    static let grantedTools: Set<String> = MCPToolCapabilities.toolNames(for: grantedCapabilities)
}
