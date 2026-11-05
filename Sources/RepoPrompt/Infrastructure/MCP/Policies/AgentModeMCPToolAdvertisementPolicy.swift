import Foundation
import RepoPromptAgentCore

/// Advertisement-only tool filtering for MCP-started agent runs based on task label role.
///
/// This policy controls which tools are **hidden from `ListTools`** responses based on the
/// agent's role. It is intentionally separate from execution-time restrictions (`restrictedTools`)
/// — hidden tools are not advertised but remain technically callable if invoked by name.
///
/// Related:
/// - MCPToolCapabilities.swift (capability → tool name mapping)
/// - DiscoverMCPToolPolicy.swift (Context Builder restrictions — reused for explore role)
/// - AgentModeMCPToolPolicy.swift (agent mode execution-time restrictions)
/// - MCPConnectionManager.swift (ListTools handler — consumer of this policy)
enum AgentModeMCPToolAdvertisementPolicy {
    // MARK: - Precomputed hidden tool sets

    /// Tools hidden from `explore` role agents.
    /// Explore agents get a minimal read-only toolset: file_search, get_file_tree,
    /// get_code_structure, read_file, git, ask_user, set_status.
    /// Everything else is hidden: editing, oracle, context_builder, agent delegation,
    /// manage_selection, workspace_context, prompt.
    private static let exploreHiddenTools: Set<String> = {
        // Start from Context Builder restrictions (which already block edits, oracle, context_builder, agent control)
        var capabilities = DiscoverMCPToolPolicy.restrictedCapabilities
        // Remove reasoning/session control — explore agents can use set_status and share_thoughts
        capabilities.remove(.agentReasoningControl)
        capabilities.remove(.agentSessionControl)
        // App settings are safe allowlisted preferences and should be visible to agent-mode subagents;
        // discovery/context-builder runs remain restricted by DiscoverMCPToolPolicy itself.
        capabilities.remove(.appSettings)
        // Explore sessions may present rich content when their attempt was granted it; the grant
        // itself (not this advertisement filter) is the authorization.
        capabilities.remove(.richPresentation)
        // Add conversation log hiding — explore agents don't need oracle_chat_log
        capabilities.insert(.conversationLog)
        // Hide context mutation tools (manage_selection, prompt) and context render (workspace_context)
        // Explore agents should use read_file and file_search directly, not curate selections
        capabilities.insert(.contextMutate)
        capabilities.insert(.contextRender)

        return MCPToolCapabilities.toolNames(for: capabilities)
    }()

    /// Tools hidden from non-explore role agents (engineer, pair, design) by default.
    /// The run policy's `allowsAgentExternalControlTools` flag (set by `AgentDelegationPolicy` for
    /// depth-0/1 sessions) opts back into agent_run/agent_manage. The flag is advertisement-only,
    /// not authorization: delegation leaves are denied through per-run `restrictedTools`.
    private static let nonExploreRoleHiddenTools: Set<String> = MCPToolCapabilities.toolNames(for: [.agentExternalControl])

    // MARK: - Public API

    /// Returns the set of tool names that should be hidden from `ListTools` for the given role.
    ///
    /// - Parameter taskLabelKind: The resolved task label role, or `nil` for direct/non-role connections.
    /// - Returns: Tool names to hide. Empty set means no role-based hiding.
    static func hiddenToolNames(for taskLabelKind: AgentModelCatalog.TaskLabelKind?) -> Set<String> {
        let exploreControlTools = MCPToolCapabilities.toolNames(for: [.agentExploreControl])
        guard let taskLabelKind else { return exploreControlTools }
        switch taskLabelKind {
        case .explore:
            return exploreHiddenTools.union(exploreControlTools)
        case .engineer, .pair, .design:
            return nonExploreRoleHiddenTools
        }
    }

    /// Whether a tool should be advertised for the given role.
    ///
    /// - Parameters:
    ///   - toolName: The MCP tool name to check.
    ///   - taskLabelKind: The resolved task label role, or `nil` for direct/non-role connections.
    /// - Returns: `true` if the tool should be included in `ListTools` results.
    static func shouldAdvertise(toolName: String, taskLabelKind: AgentModelCatalog.TaskLabelKind?) -> Bool {
        if MCPToolCapabilities.capabilities(for: toolName).contains(.agentExploreControl) {
            guard let taskLabelKind else { return false }
            switch taskLabelKind {
            case .explore:
                return false
            case .engineer, .pair, .design:
                return true
            }
        }

        guard let taskLabelKind else { return true }
        switch taskLabelKind {
        case .explore:
            return !exploreHiddenTools.contains(toolName)
        case .engineer, .pair, .design:
            return !nonExploreRoleHiddenTools.contains(toolName)
        }
    }

    /// Whether a tool should be advertised for the given role, optionally allowing
    /// agent control tools when the current run policy permits orchestration.
    static func shouldAdvertise(
        toolName: String,
        taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        allowsAgentExternalControlTools: Bool
    ) -> Bool {
        if taskLabelKind != .explore,
           allowsAgentExternalControlTools,
           MCPToolCapabilities.capabilities(for: toolName).contains(.agentExternalControl)
        {
            return true
        }
        return shouldAdvertise(toolName: toolName, taskLabelKind: taskLabelKind)
    }
}
