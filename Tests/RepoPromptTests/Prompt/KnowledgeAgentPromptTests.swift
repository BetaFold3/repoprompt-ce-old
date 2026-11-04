@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class KnowledgeAgentPromptTests: XCTestCase {
    func testKnowledgePromptUsesFocusedWorkspaceAndOracleSurface() {
        let prompt = SystemPromptService.agentModePrompt(
            agentKind: .claudeCode,
            sessionProfile: .knowledge
        )

        for tool in [
            "get_file_tree",
            "file_search",
            "read_file",
            "apply_edits",
            "oracle_utils",
            "ask_oracle",
            "oracle_chat_log"
        ] {
            // Claude Code renders RepoPrompt tools with their advertised qualified names.
            XCTAssertTrue(prompt.contains("`mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__\(tool)`"), tool)
            XCTAssertFalse(prompt.contains("`\(tool)`"), tool)
        }
        for forbidden in ["git", "bash", "agent_run", "agent_explore", "context_builder"] {
            XCTAssertFalse(prompt.localizedCaseInsensitiveContains("`\(forbidden)`"), forbidden)
            XCTAssertFalse(prompt.localizedCaseInsensitiveContains("__\(forbidden)`"), forbidden)
        }
        XCTAssertFalse(prompt.contains("packet_context_clean"))
        XCTAssertFalse(prompt.contains("model_preset_id"))
        XCTAssertTrue(prompt.contains("Default to zero critique rounds"))
        XCTAssertTrue(prompt.contains("Judge the evidence"))
        XCTAssertTrue(prompt.contains("Never resend a pending question"))
        XCTAssertTrue(prompt.contains("without `operation_ids`"))
        XCTAssertTrue(prompt.contains("does not warm a prompt cache"))
        XCTAssertTrue(prompt.contains("`consultations` accepts 1...16 independent lanes"))
        XCTAssertTrue(prompt.contains("stable indexed operation receipts"))
        XCTAssertTrue(prompt.contains("Resume or cancel pending lanes"))
    }

    func testKnowledgePromptKeepsProviderMediaClaimsTruthful() {
        let claude = SystemPromptService.agentModePrompt(
            agentKind: .claudeCode,
            sessionProfile: .knowledge
        )
        XCTAssertTrue(claude.contains("provider-native `Read` tool"))
        XCTAssertTrue(claude.contains("PDFs"))

        let codex = SystemPromptService.agentModePrompt(
            agentKind: .codexExec,
            sessionProfile: .knowledge
        )
        XCTAssertTrue(codex.contains("native `view_image`"))
        XCTAssertTrue(codex.contains("Do not claim native PDF support"))
        XCTAssertFalse(codex.contains("provider-native `Read` tool"))
    }

    func testKnowledgePromptIsStableForEachProvider() {
        for provider in [AgentProviderKind.claudeCode, .codexExec] {
            XCTAssertEqual(
                SystemPromptService.agentModePrompt(agentKind: provider, sessionProfile: .knowledge),
                SystemPromptService.agentModePrompt(agentKind: provider, sessionProfile: .knowledge)
            )
        }
    }

    func testKnowledgeRootPromptDescribesParallelResearchWorkers() {
        for provider in [AgentProviderKind.claudeCode, .codexExec] {
            let root = SystemPromptService.agentModePrompt(
                agentKind: provider,
                sessionProfile: .knowledge,
                delegationAudience: .agentRunOnly
            )
            XCTAssertTrue(root.contains("RepoPrompt's Knowledge agent"), "\(provider)")
            XCTAssertTrue(root.contains("**Knowledge research workers**"), "\(provider)")
            XCTAssertTrue(root.contains("agent_run`"), "\(provider)")
            XCTAssertTrue(root.contains("`detach:true`"), "\(provider)")
            XCTAssertTrue(root.contains("`op:\"wait\"`"), "\(provider)")
            XCTAssertTrue(root.contains("Omitting `model_id` gives a worker this session's provider and model"), "\(provider)")
            XCTAssertTrue(root.contains("URLs or workspace paths and their uncertainties"), "\(provider)")
            XCTAssertTrue(root.contains("you own the final answer and any workspace artifacts"), "\(provider)")
            XCTAssertTrue(root.contains("Workers cannot start or control other agents"), "\(provider)")
            XCTAssertFalse(root.contains("agent-delegation tasks"), "\(provider): the root prohibition is replaced")
            XCTAssertFalse(root.contains("**Research worker**"), "\(provider)")
            for forbidden in ["agent_manage", "agent_explore", "model_id=\"pair\"", "Pair worker"] {
                XCTAssertFalse(root.contains(forbidden), "\(provider): \(forbidden)")
            }
            XCTAssertEqual(
                root,
                SystemPromptService.agentModePrompt(
                    agentKind: provider,
                    sessionProfile: .knowledge,
                    delegationAudience: .agentRunOnly
                ),
                "\(provider): root text is static for the session"
            )
        }
    }

    func testKnowledgeWorkerPromptReportsBackAndCannotDelegate() {
        for provider in [AgentProviderKind.claudeCode, .codexExec] {
            let worker = SystemPromptService.agentModePrompt(
                agentKind: provider,
                sessionProfile: .knowledge,
                delegationAudience: AgentDelegationPolicy.RunToolPolicy.leaf.promptAudience
            )
            XCTAssertTrue(worker.contains("**Research worker**"), "\(provider)")
            XCTAssertTrue(worker.contains("You are a Knowledge research worker"), "\(provider)")
            XCTAssertTrue(worker.contains("Return your findings in your final message"), "\(provider)")
            XCTAssertTrue(worker.contains("You cannot start or control other agents."), "\(provider)")
            XCTAssertTrue(worker.contains("agent-delegation tasks"), "\(provider)")
            XCTAssertFalse(worker.contains("**Knowledge research workers**"), "\(provider)")
            for forbidden in ["agent_run", "agent_manage", "agent_explore", "Pair worker"] {
                XCTAssertFalse(worker.contains(forbidden), "\(provider): \(forbidden)")
            }
        }
    }

    func testKnowledgePromptWithoutAudienceKeepsStandaloneProhibition() {
        let standalone = SystemPromptService.agentModePrompt(
            agentKind: .claudeCode,
            sessionProfile: .knowledge
        )
        XCTAssertTrue(standalone.contains(
            "Do not perform coding, build, Git, shell, worktree, computer-use, or agent-delegation tasks. Explain when a request belongs in a standard Agent Mode session."
        ))
        XCTAssertFalse(standalone.contains("**Knowledge research workers**"))
        XCTAssertFalse(standalone.contains("**Research worker**"))
        XCTAssertNotEqual(
            standalone,
            SystemPromptService.agentModePrompt(
                agentKind: .claudeCode,
                sessionProfile: .knowledge,
                delegationAudience: .agentRunOnly
            )
        )
    }

    func testStandardPromptDoesNotAdoptKnowledgeIdentity() {
        let standard = SystemPromptService.agentModePrompt(agentKind: .claudeCode)
        let knowledge = SystemPromptService.agentModePrompt(
            agentKind: .claudeCode,
            sessionProfile: .knowledge
        )

        XCTAssertFalse(standard.contains("RepoPrompt's Knowledge agent"))
        XCTAssertTrue(knowledge.contains("RepoPrompt's Knowledge agent"))
        XCTAssertNotEqual(standard, knowledge)
    }
}
