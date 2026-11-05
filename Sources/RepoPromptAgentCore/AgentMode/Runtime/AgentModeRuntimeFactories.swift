import Foundation

package typealias AgentHeadlessProviderFactory = (_ agent: AgentProviderKind, _ modelString: String?) throws -> HeadlessAgentProvider
package typealias AgentACPProviderFactory = (_ agent: AgentProviderKind, _ modelString: String?) -> (any ACPAgentProvider)?
package typealias AgentACPControllerFactory = (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController
package typealias AgentConnectionPolicyInstaller = (
    _ clientName: String,
    _ windowID: Int,
    _ restrictedTools: Set<String>,
    _ oneShot: Bool,
    _ reason: String?,
    _ ttl: TimeInterval,
    _ tabID: UUID?,
    _ runID: UUID?,
    _ additionalTools: Set<String>?,
    _ allowedToolsOverride: Set<String>?,
    _ sessionProfile: AgentSessionProfile,
    _ purpose: MCPRunPurpose,
    _ taskLabelKind: AgentModelCatalog.TaskLabelKind?,
    _ allowsAgentExternalControlTools: Bool,
    _ requiresExpectedAgentPID: Bool,
    // The admitted run attempt this policy belongs to (`nil` for non-Agent-Mode installs). Its
    // captured rich-presentation policy is stored with the policy and applied with it to each
    // connection, so request authority comes from the applied connection, not the latest run.
    _ runOwnership: AgentRunOwnership?
) async -> Void
package typealias AgentMCPServerEnabler = () async -> Void
package typealias AgentCodexActiveToolQuery = (_ runID: UUID) -> Bool
package typealias AgentCodexAgentRunWaitQuery = (_ runID: UUID) -> Bool
package typealias AgentCodexAgentRunWaitDrain = @MainActor (
    _ runID: UUID,
    _ source: String
) async -> AgentRunWaitDrainOutcome
