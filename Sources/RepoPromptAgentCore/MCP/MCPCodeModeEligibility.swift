import Foundation

/// Per-run RepoPrompt `code_mode` exposure resolved from the run's final launch configuration
/// (plan §6 D3), carried immutably by the bootstrap lease spec. Never derived from the handshake
/// client name. Every production launch resolves `.native` until the Step 5 resolver exists;
/// unknown capability stays `.native`.
package enum MCPCodeModeEligibility: Equatable {
    /// The provider's native tool exposure; no RepoPrompt `code_mode`.
    case native
    /// RepoPrompt tools are called directly, with optional `code_mode` alongside them.
    case directTools
    /// Codex: a second, read-only RepoPrompt server entry listed in the thread-level
    /// `features.code_mode.direct_only_tool_namespaces`.
    case codexReadOnlyCompanion(serverName: String)

    /// Knowledge and non-Agent Mode runs (Context Builder discovery, unknown) never get `code_mode`.
    static func normalized(
        _ requested: MCPCodeModeEligibility,
        purpose: MCPRunPurpose,
        sessionProfile: AgentSessionProfile
    ) -> MCPCodeModeEligibility {
        guard purpose == .agentModeRun, sessionProfile != .knowledge else { return .native }
        return requested
    }
}
