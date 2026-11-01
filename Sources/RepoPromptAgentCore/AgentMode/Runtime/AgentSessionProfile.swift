import Foundation

package enum AgentSessionProfile: String, Codable, Equatable {
    case standard
    case knowledge
}

package enum KnowledgeSessionPolicy {
    package static let supportedProvidersOrdered: [AgentProviderKind] = [
        .claudeCode,
        .codexExec
    ]

    package static let supportedProviders = Set(supportedProvidersOrdered)

    static let allowedMCPToolNames: Set<String> = [
        MCPWindowToolName.getFileTree,
        MCPWindowToolName.search,
        MCPWindowToolName.readFile,
        MCPWindowToolName.applyEdits,
        MCPWindowToolName.oracleUtils,
        MCPWindowToolName.askOracle,
        MCPWindowToolName.oracleChatLog,
        // Knowledge roots start and control fresh Knowledge research workers. Delegation leaf
        // restrictions remove it again for workers (`AgentDelegationPolicy.knowledgeLeaf`).
        MCPWindowToolName.agentRun,
        // Knowledge sessions in an Assistant workspace may list and steer granted workspaces
        // (docs/context/specs/2026-11-01-assistant-workspace-steering-spec.md).
        MCPWindowToolName.workspaceSteer
    ]

    /// Closed per-operation allowlist for `agent_run` calls from a Knowledge caller. An
    /// operation added to `agent_run` later stays denied for Knowledge sessions until it is
    /// listed here deliberately.
    package static let allowedAgentRunOperations: Set<String> = [
        "start",
        "poll",
        "wait",
        "cancel",
        "steer",
        "respond"
    ]
}
