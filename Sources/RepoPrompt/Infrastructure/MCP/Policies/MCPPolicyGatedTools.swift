import Foundation
import RepoPromptAgentCore

/// Tools that are hidden from normal MCP connections unless explicitly granted via `additionalTools`
/// in a connection policy. These include special-purpose tools and legacy compatibility surfaces.
enum MCPPolicyGatedTools {
    static let gatedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentReasoningControl,
        .agentSessionControl,

        .agentConversationSend,
        .conversationLog,
        // Only Agent Mode runs are granted `workspace_steer`; external MCP clients never see it.
        .workspaceSteering,
        // Granted only to an Agent Mode run attempt whose captured workspace policy enables it
        // (`AgentRichPresentationToolPolicy`); Oracle, external and unbound clients never see it.
        .richPresentation
    ]

    /// Tool names that require explicit policy grant to be visible/callable.
    static let names: Set<String> = MCPToolCapabilities.toolNames(for: gatedCapabilities)
}
