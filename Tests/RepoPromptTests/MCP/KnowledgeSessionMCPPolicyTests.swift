@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class KnowledgeSessionMCPPolicyTests: XCTestCase {
    func testKnowledgeToolCeilingIsExactAndFutureClosed() {
        let expected: Set<String> = [
            MCPWindowToolName.getFileTree,
            MCPWindowToolName.search,
            MCPWindowToolName.readFile,
            MCPWindowToolName.applyEdits,
            MCPWindowToolName.oracleUtils,
            MCPWindowToolName.askOracle,
            MCPWindowToolName.oracleChatLog,
            MCPWindowToolName.agentRun,
            MCPWindowToolName.workspaceSteer,
            // Ceiling membership only; the attempt's captured rich-presentation grant decides.
            AgentRichPresentationToolPolicy.toolName
        ]

        XCTAssertEqual(AgentModeMCPToolPolicy.knowledgeAllowedTools, expected)
        XCTAssertEqual(KnowledgeSessionPolicy.allowedMCPToolNames, expected)

        for toolName in expected {
            XCTAssertTrue(
                ServerNetworkManager.isAllowedByPositiveToolCeiling(
                    canonicalToolName: toolName,
                    allowedToolsOverride: expected
                ),
                toolName
            )
        }
        XCTAssertFalse(
            ServerNetworkManager.isAllowedByPositiveToolCeiling(
                canonicalToolName: MCPWindowToolName.manageSelection,
                allowedToolsOverride: expected
            )
        )
        XCTAssertFalse(
            ServerNetworkManager.isAllowedByPositiveToolCeiling(
                canonicalToolName: "future_tool",
                allowedToolsOverride: expected
            )
        )
        for delegationTool in [MCPWindowToolName.agentManage, MCPWindowToolName.agentExplore] {
            XCTAssertFalse(
                ServerNetworkManager.isAllowedByPositiveToolCeiling(
                    canonicalToolName: delegationTool,
                    allowedToolsOverride: expected
                ),
                "Knowledge sessions never get \(delegationTool)"
            )
        }
        XCTAssertTrue(
            ServerNetworkManager.isAllowedByPositiveToolCeiling(
                canonicalToolName: "future_tool",
                allowedToolsOverride: nil
            ),
            "A nil ceiling must preserve standard behavior"
        )
    }

    func testCallCeilingCanonicalizesBeforeFailClosedDenial() {
        let canonical = ServerNetworkManager.canonicalToolName(
            for: "discover_manage_selection"
        )
        XCTAssertEqual(canonical, MCPWindowToolName.manageSelection)

        let denial = ServerNetworkManager.positiveToolCeilingDenialMessage(
            forCanonicalToolName: canonical,
            allowedToolsOverride: AgentModeMCPToolPolicy.knowledgeAllowedTools
        )
        XCTAssertNotNil(denial)
        XCTAssertTrue(denial?.contains(MCPWindowToolName.manageSelection) == true)

        XCTAssertNil(
            ServerNetworkManager.positiveToolCeilingDenialMessage(
                forCanonicalToolName: MCPWindowToolName.readFile,
                allowedToolsOverride: AgentModeMCPToolPolicy.knowledgeAllowedTools
            )
        )
        XCTAssertNil(
            ServerNetworkManager.positiveToolCeilingDenialMessage(
                forCanonicalToolName: MCPWindowToolName.manageSelection,
                allowedToolsOverride: nil
            ),
            "Standard calls must remain unchanged"
        )
    }

    func testKnowledgePolicyStateSurvivesInitialAdmissionAndReconnect() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let clientName = "knowledge-policy-\(UUID().uuidString)"
            let runID = UUID()
            let initialConnectionID = UUID()
            let reconnectConnectionID = UUID()
            let windowID = 62001

            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                oneShot: true,
                reason: "knowledge policy persistence test",
                ttl: 10,
                runID: runID,
                additionalTools: AgentModeMCPPolicyInstaller.additionalTools(
                    for: .codexExec,
                    sessionProfile: .knowledge
                ),
                allowedToolsOverride: ["future_tool"],
                sessionProfile: .knowledge,
                purpose: .agentModeRun
            )

            let cachedState = await manager.debugRunPolicyState(for: runID)
            let cached = try XCTUnwrap(cachedState)
            XCTAssertEqual(cached.allowedToolsOverride, AgentModeMCPToolPolicy.knowledgeAllowedTools)
            XCTAssertEqual(cached.sessionProfile, .knowledge)

            let admitted = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: initialConnectionID,
                requireRunRouting: false
            )
            XCTAssertEqual(admitted.outcome, "applied")
            XCTAssertEqual(admitted.allowedToolsOverride, AgentModeMCPToolPolicy.knowledgeAllowedTools)
            XCTAssertEqual(admitted.sessionProfile, .knowledge)

            await manager.debugApplyRunPolicyState(
                runID: runID,
                connectionID: reconnectConnectionID
            )
            let reconnected = await manager.debugEffectivePolicyState(
                for: reconnectConnectionID
            )
            XCTAssertEqual(reconnected.allowedToolsOverride, AgentModeMCPToolPolicy.knowledgeAllowedTools)
            XCTAssertEqual(reconnected.sessionProfile, .knowledge)

            await manager.clearClientConnectionPolicy(
                for: clientName,
                windowID: windowID,
                runID: runID
            )
            await manager.removeConnection(initialConnectionID)
            await manager.removeConnection(reconnectConnectionID)
            await manager.cleanupRunRoutingState(for: runID, windowID: windowID)
        #else
            throw XCTSkip("Connection policy diagnostics require DEBUG helpers.")
        #endif
    }

    func testKnowledgeAskOracleDescriptionProjectionLeavesStandardUnchanged() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let base = "standard ask_oracle description"

            let standard = await manager.debugAdvertisedToolDescription(
                for: MCPWindowToolName.askOracle,
                baseDescription: base,
                purpose: .agentModeRun,
                sessionProfile: .standard
            )
            XCTAssertEqual(standard, base)

            let projected = await manager.debugAdvertisedToolDescription(
                for: MCPWindowToolName.askOracle,
                baseDescription: base,
                purpose: .agentModeRun,
                sessionProfile: .knowledge
            )
            XCTAssertEqual(projected, AgentModeMCPToolPolicy.knowledgeAskOracleDescription)
            XCTAssertTrue(projected.contains("oracle_utils op=models"))
            XCTAssertTrue(projected.contains("new_chat:true"))
            XCTAssertTrue(projected.contains("chat_id"))
            XCTAssertTrue(projected.contains("Pending is normal"))
            XCTAssertTrue(projected.contains("op:wait"))
            XCTAssertTrue(projected.contains("without operation_ids"))
            XCTAssertTrue(projected.contains("does not warm a prompt cache"))
            XCTAssertTrue(projected.contains("consultations batches accept 1...16 lanes"))
            XCTAssertTrue(projected.contains("stable indexed operation receipts"))
            XCTAssertTrue(projected.contains("Resume or cancel pending lanes"))
            XCTAssertTrue(projected.contains("not persisted across app relaunch"))

            let unrelated = await manager.debugAdvertisedToolDescription(
                for: MCPWindowToolName.readFile,
                baseDescription: base,
                purpose: .agentModeRun,
                sessionProfile: .knowledge
            )
            XCTAssertEqual(unrelated, base)
        #else
            throw XCTSkip("Tool description diagnostics require DEBUG helpers.")
        #endif
    }

    func testKnowledgeAgentRunDescriptionListsOnlyResearchWorkerBehavior() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let base = "standard agent_run description"

            let standard = await manager.debugAdvertisedToolDescription(
                for: MCPWindowToolName.agentRun,
                baseDescription: base,
                purpose: .agentModeRun,
                sessionProfile: .standard
            )
            XCTAssertEqual(standard, base)

            let projected = await manager.debugAdvertisedToolDescription(
                for: MCPWindowToolName.agentRun,
                baseDescription: base,
                purpose: .agentModeRun,
                sessionProfile: .knowledge
            )
            XCTAssertEqual(projected, AgentModeMCPToolPolicy.knowledgeAgentRunDescription)
            XCTAssertTrue(projected.contains("Knowledge research workers"))
            XCTAssertTrue(projected.contains("Omit model_id"))
            XCTAssertTrue(projected.contains("Role labels, tab_id, session_id, workflows, and worktree arguments are rejected"))
            XCTAssertTrue(projected.contains("detach:true"))
            XCTAssertTrue(projected.contains("this session's own workers"))
            XCTAssertTrue(projected.contains("Workers cannot start or control other agents"))
            for absent in ["agent_manage", "agent_explore", "explore", "engineer", "pair", "design"] {
                XCTAssertFalse(projected.contains(absent), absent)
            }
        #else
            throw XCTSkip("Tool description diagnostics require DEBUG helpers.")
        #endif
    }
}
