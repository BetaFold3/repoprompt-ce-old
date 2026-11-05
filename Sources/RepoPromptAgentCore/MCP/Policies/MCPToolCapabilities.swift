import Foundation

/// Capability-level grouping for MCP tool policy decisions.
/// Policies should express intent in terms of capabilities and derive tool names from this map.
package enum MCPToolCapability: CaseIterable, Hashable {
    case conversationSend
    case conversationHelper
    case conversationLog
    case contextMutate
    case contextRender
    case routingAdvanced
    case discovery
    case userInteraction
    case agentExternalControl
    case agentExploreControl
    case agentReasoningControl
    case agentSessionControl
    case fileContentEdit
    case fileManagement
    case structuralExplore
    case agentConversationSend
    case gitRead
    case worktreeManage
    case appSettings
    /// Cross-workspace steering of owner-granted target workspaces (`workspace_steer`). Granted to
    /// every Agent Mode run, including delegation leaves, explore and Knowledge sessions; it is
    /// deliberately not an agent-control capability, so leaf restrictions and role hiding skip it.
    case workspaceSteering
    /// Inline rich presentation (`present_rich`). Granted only to a trusted local Agent Mode run
    /// attempt whose captured workspace policy is enabled (`AgentRichPresentationToolPolicy`);
    /// never a static grant, never to discovery, Oracle, external or unbound clients. The tool
    /// stays unregistered until the rich-presentation spec's Step 4.
    case richPresentation

    /// Stable snake_case name for MCP discovery serialization.
    var externalName: String {
        switch self {
        case .conversationSend: "conversation_send"
        case .conversationHelper: "conversation_helper"
        case .conversationLog: "conversation_log"
        case .contextMutate: "context_mutate"
        case .contextRender: "context_render"
        case .routingAdvanced: "routing_advanced"
        case .discovery: "discovery"
        case .userInteraction: "user_interaction"
        case .agentExternalControl: "agent_external_control"
        case .agentExploreControl: "agent_explore_control"
        case .agentReasoningControl: "agent_reasoning_control"
        case .agentConversationSend: "agent_conversation_send"
        case .agentSessionControl: "agent_session_control"
        case .fileContentEdit: "file_content_edit"
        case .fileManagement: "file_management"
        case .structuralExplore: "structural_explore"
        case .gitRead: "git_read"
        case .worktreeManage: "worktree_manage"
        case .appSettings: "app_settings"
        case .workspaceSteering: "workspace_steering"
        case .richPresentation: "rich_presentation"
        }
    }
}

package enum MCPToolCapabilities {
    private static let capabilityToTools: [MCPToolCapability: Set<String>] = [
        .conversationSend: [
            "oracle_send"
        ],
        .agentConversationSend: [
            "ask_oracle"
        ],
        .conversationHelper: [
            "oracle_utils"
        ],
        .conversationLog: [
            "oracle_chat_log"
        ],
        .contextMutate: [
            "manage_selection",
            "prompt"
        ],
        .contextRender: [
            "workspace_context"
        ],
        .routingAdvanced: [
            "bind_context",
            "manage_workspaces"
        ],
        .discovery: [
            "context_builder"
        ],
        .userInteraction: [
            "ask_user"
        ],
        .agentExternalControl: [
            "agent_run",
            "agent_manage"
        ],
        .agentExploreControl: [
            "agent_explore"
        ],
        .agentReasoningControl: [
            "share_thoughts",
            "wait_for_next_user_instruction"
        ],
        .agentSessionControl: [
            "set_status"
        ],
        .fileContentEdit: [
            "apply_edits"
        ],
        .fileManagement: [
            "file_actions"
        ],
        .structuralExplore: [
            "get_file_tree",
            "get_code_structure"
        ],
        .gitRead: [
            "git"
        ],
        .worktreeManage: [
            "manage_worktree"
        ],
        .appSettings: [
            "app_settings"
        ],
        .workspaceSteering: [
            "workspace_steer"
        ],
        .richPresentation: [
            "present_rich"
        ]
    ]

    package static func toolNames(for capabilities: Set<MCPToolCapability>) -> Set<String> {
        capabilities.reduce(into: Set<String>()) { partialResult, capability in
            partialResult.formUnion(capabilityToTools[capability] ?? [])
        }
    }

    package static func capabilities(for toolName: String) -> Set<MCPToolCapability> {
        Set(capabilityToTools.compactMap { capability, tools in
            tools.contains(toolName) ? capability : nil
        })
    }
}
