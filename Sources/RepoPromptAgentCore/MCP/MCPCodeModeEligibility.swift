import Foundation

/// Per-run RepoPrompt `code_mode` exposure resolved from the run's final launch configuration
/// (plan §6 D3), carried immutably by the bootstrap lease spec and the installed connection
/// policy. Never derived from the handshake client name; unknown capability stays `.native`.
package enum MCPCodeModeEligibility: Equatable {
    /// The provider's native tool exposure; no RepoPrompt `code_mode`.
    case native
    /// RepoPrompt tools are called directly, with optional `code_mode` alongside them.
    case directTools
    /// Codex: a second, read-only RepoPrompt server entry listed in the thread-level
    /// `features.code_mode.direct_only_tool_namespaces`. The run's primary connection stays
    /// native; only the run's authenticated companion connection gets the four exploration
    /// tools plus `code_mode`. Resolved only when a Codex controller launched that companion.
    case codexReadOnlyCompanion(serverName: String)

    /// The RepoPrompt-owned executor tool name, gated by `.directTools` eligibility or, for a
    /// Codex companion run, by the connection being that run's authenticated companion.
    package static let codeModeToolName = MCPWindowToolName.codeMode

    /// Default Codex companion server entry name; its Codex tool namespace is
    /// `mcp__RepoPromptCE_Direct`.
    package static let codexReadOnlyCompanionServerName = "RepoPromptCE-Direct"

    /// The direct exploration tools a Codex read-only companion may offer (with `code_mode`).
    package static let readOnlyCompanionToolNames: Set<String> = [
        MCPWindowToolName.readFile,
        MCPWindowToolName.search,
        MCPWindowToolName.getCodeStructure,
        MCPWindowToolName.getFileTree
    ]

    /// Knowledge and non-Agent Mode runs (Context Builder discovery, unknown) never get `code_mode`.
    package static func normalized(
        _ requested: MCPCodeModeEligibility,
        purpose: MCPRunPurpose,
        sessionProfile: AgentSessionProfile
    ) -> MCPCodeModeEligibility {
        guard purpose == .agentModeRun, sessionProfile != .knowledge else { return .native }
        return requested
    }
}

/// The per-provider "RepoPrompt tools" setting (plan §6 D3): `native` (default) or
/// `direct + code_mode`. Applies from the next run; unknown stored values read as `native`.
package enum RepoPromptToolsMode: String, CaseIterable {
    case native
    case directCodeMode = "direct_code_mode"
}

/// Typed provenance for one tool event (plan §6 D3 flat child cards). The MCP host binds
/// `current` only while it re-enters a `code_mode` child, so tool-event observers delivered
/// inline for that child read the actual parent invocation; every other event reads nil.
package struct AgentToolEventLinkage: Equatable {
    package let codeModeParentInvocationID: UUID

    package init(codeModeParentInvocationID: UUID) {
        self.codeModeParentInvocationID = codeModeParentInvocationID
    }

    @TaskLocal package static var current: AgentToolEventLinkage?
}
