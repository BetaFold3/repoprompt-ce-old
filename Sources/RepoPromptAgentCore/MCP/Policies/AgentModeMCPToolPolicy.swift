import Foundation

/// MCP tool policy for agent mode runs.
/// Controls which tools are restricted and which special tools are granted.
package enum AgentModeMCPToolPolicy {
    /// Agent mode is tab-scoped, so advanced routing and direct Oracle sends stay blocked.
    /// `oracle_utils` remains available for preset discovery; its Agent Mode operation
    /// restrictions are enforced by the Oracle service.
    static let restrictedCapabilities: Set<MCPToolCapability> = [
        .routingAdvanced,
        .conversationSend
    ]

    static let restrictedTools: Set<String> = MCPToolCapabilities.toolNames(for: restrictedCapabilities)

    /// Added to a run's restrictions when its final launch configuration gives the provider a
    /// native shell (`runHasNativeShell`). Only plain Git inspection moves to the shell; the
    /// review snapshot stays available.
    static let nativeShellRestrictedTools: Set<String> = MCPToolCapabilities.toolNames(for: [.gitRead])

    /// Positive ceiling for a Knowledge session. Global availability, ordinary
    /// restrictions, and policy-gated grants are still intersected with this set.
    package static let knowledgeAllowedTools = KnowledgeSessionPolicy.allowedMCPToolNames

    package static let knowledgeAskOracleDescription = """
    Consult an Oracle model using the current repository evidence. Resolve exact selectable preset names or UUIDs with oracle_utils op=models. A fresh chat needs an explicit model when more than one preset supports the mode; the rejection lists the exact preset UUIDs to retry with. For independent opinions, use one consultations batch with an explicit model per lane, or separate single sends with new_chat:true when independent admission is required. Continue completed lanes with their returned chat_id and new_chat:false; the lane keeps its own model preset, so model can be omitted, and the call fails rather than switching models if that preset is no longer usable.

    Routine sends and waits should omit timeout_seconds. Pending is normal: a timeout or steering wake leaves the Oracle running. Never resend a pending question; resume it with op:wait and its operation_id. After steering, respond to the user first, then resume waiting. After compaction, call op:wait without operation_ids to collect owned undelivered results; use oracle_chat_log with a known chat_id only for conversation recovery. A wait or transport heartbeat does not issue a provider-model request and does not warm a prompt cache. Use op:cancel only when the user asks or the question is known to be wrong. An unkeyed repeat is a new consultation; request_id protects an identical live send but is not persisted across app relaunch.

    consultations batches accept 1...16 lanes, return stable indexed operation receipts, queue behind actual per-tab Oracle capacity, and use the same bounded wait envelope as op:wait. Resume or cancel pending lanes by operation ID; request_id remains single-send-only. No packet, hash, manifest, or verification-gate ritual is required.
    """

    /// Knowledge-root `agent_run` description. It lists only what a Knowledge caller may do: start
    /// fresh Knowledge research workers and control its own workers. Workers never see `agent_run`.
    package static let knowledgeAgentRunDescription = """
    Start and control Knowledge research workers: fresh Knowledge sessions that each research one independent question or perspective and report back. From a Knowledge session only the following is available.

    op:start creates a new research worker with message as its question. Omit model_id to give the worker this session's provider, model, and effort, or pass an explicit Claude Code or Codex compound model_id (agent:model). Role labels, tab_id, session_id, workflows, and worktree arguments are rejected. A Codex worker requires Codex's Search tool to be turned on. Prefer detach:true and start every worker before waiting. The start receipt's knowledge_worker field reports the worker's provider and model.

    op:wait and op:poll with session_id or session_ids collect results from this session's own workers. Omit timeout for the automatic wait; pending is normal, so wait again instead of starting a new worker. op:steer (session_id, message), op:respond (session_id, interaction_id, response or answers), and op:cancel (session_id) act only on this session's own workers.

    Workers cannot start or control other agents, and no other session, including standard Agent Mode sessions, can be addressed.
    """

    /// Tools granted to legacy/generic agent mode runs (from MCPPolicyGatedTools).
    /// These enable user interaction, agent workflow control, and agent-only oracle recovery.
    static let grantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentReasoningControl,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog,
        .workspaceSteering
    ]

    static let grantedTools: Set<String> = MCPToolCapabilities.toolNames(for: grantedCapabilities)

    /// Tools granted to Claude native-style agent runs.
    /// Claude no longer relies on share_thoughts or wait_for_next_user_instruction,
    /// but it does use set_status to rename the active session.
    static let claudeNativeGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog,
        .workspaceSteering
    ]

    static let claudeNativeGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: claudeNativeGrantedCapabilities)

    /// Tools granted to Codex native agent runs.
    /// Codex native still needs ask_user + set_status even though it doesn't use
    /// share_thoughts or wait_for_next_user_instruction.
    /// set_status is title-only; running status now comes from native reasoning summaries.
    static let codexNativeGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog,
        .workspaceSteering
    ]

    static let codexNativeGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: codexNativeGrantedCapabilities)

    /// OpenCode ACP uses the Agent Mode app/session control surface.
    static let openCodeGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog,
        .workspaceSteering
    ]

    static let openCodeGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: openCodeGrantedCapabilities)

    /// Cursor ACP uses the same Agent Mode app/session control surface as OpenCode.
    static let cursorGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog,
        .workspaceSteering
    ]

    static let cursorGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: cursorGrantedCapabilities)

    /// OMP is launched with no native tools; RepoPrompt MCP is its sole tool surface.
    static let ohMyPiGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog,
        .workspaceSteering
    ]

    static let ohMyPiGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: ohMyPiGrantedCapabilities)

    static func grantedTools(
        forAgent agent: AgentProviderKind,
        sessionProfile: AgentSessionProfile = .standard
    ) -> Set<String> {
        let tools = switch agent {
        case .codexExec:
            codexNativeGrantedTools
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            claudeNativeGrantedTools
        case .openCode:
            openCodeGrantedTools
        case .cursor:
            cursorGrantedTools
        case .ohMyPi:
            ohMyPiGrantedTools
        }
        return sessionProfile == .knowledge
            ? tools.intersection(knowledgeAllowedTools)
            : tools
    }
}
