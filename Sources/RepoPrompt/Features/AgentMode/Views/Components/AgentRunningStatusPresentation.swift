import RepoPromptAgentCore

/// Formats known raw RepoPrompt tool names and recognizable external MCP tool names without
/// rewriting ordinary status prose.
enum AgentRunningStatusPresentation {
    static func displayText(for status: String?) -> String {
        if let canonicalName = MCPIntegrationHelper.canonicalRepoPromptToolName(status) {
            return toolDisplayName(for: canonicalName)
        }
        if let external = ExternalMCPToolPresentation(rawToolName: status) {
            return external.compactLabel
        }
        return status ?? "Thinking…"
    }
}
