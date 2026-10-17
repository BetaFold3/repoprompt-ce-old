import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import RepoPromptShared
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class WorkflowPromptCatalogTests: XCTestCase {
    func testWorkflowCommandOrdersAndNamesStayStable() {
        XCTAssertEqual(
            RepoPromptWorkflowID.mcpPromptOrder.map(\.commandName),
            [
                "rp-build",
                "rp-investigate",
                "rp-deep-plan",
                "rp-reminder",
                "rp-oracle-export",
                "rp-review",
                "rp-refactor",
                "rp-orchestrate",
                "rp-optimize"
            ]
        )
        XCTAssertEqual(
            RepoPromptWorkflowID.installOrder.map(\.commandName),
            [
                "rp-investigate",
                "rp-build",
                "rp-reminder",
                "rp-oracle-export",
                "rp-review",
                "rp-refactor",
                "rp-orchestrate",
                "rp-optimize",
                "rp-deep-plan"
            ]
        )
        XCTAssertEqual(RepoPromptWorkflowID.allCases.count, 9)
    }

    func testCatalogMetadataMatchesWorkflowIDs() {
        XCTAssertEqual(WorkflowPromptCatalog.descriptors.count, RepoPromptWorkflowID.allCases.count)
        XCTAssertEqual(WorkflowPromptCatalog.mcpPromptDescriptors.map(\.id), RepoPromptWorkflowID.mcpPromptOrder)
        XCTAssertEqual(WorkflowPromptCatalog.installDescriptors.map(\.id), RepoPromptWorkflowID.installOrder)

        for descriptor in WorkflowPromptCatalog.descriptors {
            XCTAssertEqual(descriptor.name, descriptor.id.commandName)
            XCTAssertFalse(descriptor.description.isEmpty, descriptor.name)
        }
    }

    func testRenderedManagedPromptFrontmatterCompatibility() {
        XCTAssertEqual(RepoPromptWorkflowPrompts.skillsVersion, 70)

        for descriptor in WorkflowPromptCatalog.installDescriptors {
            let rendered = RepoPromptWorkflowPrompts.render(id: descriptor.id, variant: .mcp)
            XCTAssertTrue(rendered.hasPrefix("---\n"), descriptor.name)
            XCTAssertTrue(rendered.contains("name: \"\(descriptor.name)\""), descriptor.name)
            XCTAssertTrue(rendered.contains("repoprompt_managed: true"), descriptor.name)
            XCTAssertTrue(rendered.contains("repoprompt_skills_version: 70"), descriptor.name)
            XCTAssertTrue(rendered.contains("repoprompt_variant: mcp"), descriptor.name)
            XCTAssertFalse(RepoPromptWorkflowPrompts.stripYAMLFrontmatter(rendered).hasPrefix("---"), descriptor.name)
        }
    }

    func testNamedOracleGuidanceStaysFailClosedAcrossAgentAndReminderPrompts() {
        let reminder = RepoPromptWorkflowPrompts.render(id: .reminder, variant: .mcp)
        let standardAgent = SystemPromptService.agentModePrompt()
        let engineerAgent = SystemPromptService.agentModePrompt(taskLabelKind: .engineer)

        for (label, prompt) in [
            ("rp-reminder", reminder),
            ("standard agent", standardAgent),
            ("engineer agent", engineerAgent)
        ] {
            XCTAssertTrue(prompt.contains("model-preset selector"), label)
            XCTAssertTrue(prompt.contains("oracle_utils"), label)
            XCTAssertTrue(prompt.contains("exact preset UUID"), label)
            XCTAssertTrue(prompt.contains("same tool-call batch"), label)
            XCTAssertTrue(prompt.contains("`chat_name` is"), label)
            XCTAssertTrue(prompt.contains("never selects a model"), label)
            XCTAssertTrue(prompt.contains("`model_preset_id`"), label)
            XCTAssertTrue(prompt.contains("do not synthesize"), label)
        }
        XCTAssertTrue(reminder.contains("re-packages the current workspace selection"))
        XCTAssertTrue(reminder.contains("fresh chat with a concise summary"))
    }

    func testResumableOracleGuidanceCoversAgentWorkflowsReminderAndRolePrompts() {
        let workflowIDs: [RepoPromptWorkflowID] = [
            .investigate,
            .deepPlan,
            .optimize,
            .orchestrate,
            .refactor
        ]
        var prompts: [(label: String, text: String)] = workflowIDs.map {
            (
                "\($0.commandName) [agent]",
                RepoPromptWorkflowPrompts.render(id: $0, variant: .agent)
            )
        }
        prompts.append(
            (
                "rp-reminder [mcp]",
                RepoPromptWorkflowPrompts.render(id: .reminder, variant: .mcp)
            )
        )
        prompts.append(
            (
                "rp-reminder [agent]",
                RepoPromptWorkflowPrompts.render(id: .reminder, variant: .agent)
            )
        )
        prompts.append(("standard agent", SystemPromptService.agentModePrompt()))
        prompts.append(("engineer agent", SystemPromptService.agentModePrompt(taskLabelKind: .engineer)))
        prompts.append(
            (
                "knowledge agent",
                SystemPromptService.agentModePrompt(
                    agentKind: .claudeCode,
                    sessionProfile: .knowledge
                )
            )
        )

        for prompt in prompts {
            XCTAssertTrue(prompt.text.contains("Never resend a pending question"), prompt.label)
            XCTAssertTrue(prompt.text.contains("`op:\"wait\"`"), prompt.label)
            XCTAssertTrue(prompt.text.contains("without `operation_ids`"), prompt.label)
            XCTAssertTrue(prompt.text.contains("respond to the user first"), prompt.label)
            XCTAssertTrue(prompt.text.contains("does not warm a prompt cache"), prompt.label)
            XCTAssertTrue(prompt.text.contains("`op:\"cancel\"`"), prompt.label)
            XCTAssertTrue(prompt.text.contains("not persisted across app relaunch"), prompt.label)
            XCTAssertTrue(prompt.text.contains("stable indexed operation receipts"), prompt.label)
            XCTAssertTrue(prompt.text.contains("Resume or cancel pending lanes"), prompt.label)
            XCTAssertTrue(prompt.text.contains("provider cache TTL"), prompt.label)
            XCTAssertFalse(prompt.text.lowercased().contains("cache-safe"), prompt.label)
        }

        for workflowID in workflowIDs {
            for variant in [WorkflowPromptVariant.mcp, .cli] {
                let rendered = RepoPromptWorkflowPrompts.render(id: workflowID, variant: variant)
                XCTAssertFalse(rendered.contains("**Resumable Oracle waits.**"), workflowID.commandName)
            }
        }
    }

    func testAgentWorkflowTemplatesRenderFromProviderNeutralCatalog() {
        for workflow in AgentWorkflow.allCases {
            let rendered = RepoPromptWorkflowPrompts.render(id: workflow.workflowPromptID, variant: .agent)
            XCTAssertFalse(rendered.isEmpty, workflow.rawValue)
            XCTAssertEqual(workflow.template, rendered, workflow.rawValue)
        }

        let waitFirstWorkflowIDs: [RepoPromptWorkflowID] = [
            .investigate,
            .deepPlan,
            .optimize,
            .orchestrate,
            .refactor
        ]
        let waitFirstVariants: [(name: String, variant: WorkflowPromptVariant)] = [
            ("mcp", .mcp),
            ("cli", .cli),
            ("agent", .agent)
        ]
        for workflowID in waitFirstWorkflowIDs {
            for renderedVariant in waitFirstVariants {
                let rendered = RepoPromptWorkflowPrompts.render(
                    id: workflowID,
                    variant: renderedVariant.variant
                )
                let label = "\(workflowID.commandName) [\(renderedVariant.name)]"

                XCTAssertTrue(rendered.contains("Detach independent parallel starts"), label)
                XCTAssertTrue(rendered.contains("pass every pending ID in `session_ids` to `agent_run op=wait`"), label)
                XCTAssertTrue(rendered.contains("Wait returns as soon as any watched session finishes, needs interaction"), label)
                XCTAssertTrue(rendered.contains("upper bounds rather than mandatory sleeps"), label)
                XCTAssertTrue(rendered.contains("Maintain a caller-owned outstanding-ID set"), label)
                XCTAssertTrue(rendered.contains("do not rebuild it solely from response `pending_session_ids`"), label)
                XCTAssertTrue(rendered.contains("nonterminal interaction/status winner"), label)
                XCTAssertTrue(rendered.contains("Handle **every** returned interaction"), label)
                XCTAssertTrue(rendered.contains("Remove only terminal workers from the outstanding set"), label)
                XCTAssertTrue(rendered.contains("Retain or re-add nonterminal interaction/status winners after responding"), label)
                XCTAssertTrue(rendered.contains("wait again while any outstanding IDs remain"), label)
                XCTAssertTrue(rendered.contains("A timeout returns the current state while the worker remains active; do not abandon it—wait again"), label)
                XCTAssertTrue(rendered.contains("Use `op=poll` only for a deliberate instantaneous inspection"), label)
                XCTAssertTrue(rendered.contains("Do not set `include_status_updates` merely to show activity"), label)
                XCTAssertTrue(rendered.contains("A wait or transport heartbeat does not itself send a provider-model request"), label)
                XCTAssertTrue(rendered.contains("does not warm a prompt cache"), label)
                XCTAssertFalse(rendered.lowercased().contains("poll periodically"), label)
                XCTAssertFalse(rendered.contains("Forgetting to poll"), label)
            }
        }

        let claudeAutomaticWaitSeconds = Int(MCPTimeoutPolicy.agentLifecycleClaudeAutomaticWaitSeconds)
        let claudeExtendedAutomaticWaitSeconds = Int(
            MCPTimeoutPolicy.agentLifecycleClaudeExtendedCacheAutomaticWaitSeconds
        )
        let codexAutomaticWaitSeconds = Int(MCPTimeoutPolicy.agentLifecycleCodexAutomaticWaitSeconds)
        let otherAutomaticWaitSeconds = Int(MCPTimeoutPolicy.agentLifecycleOtherAutomaticWaitSeconds)
        let unresolvedAutomaticWaitSeconds = Int(MCPTimeoutPolicy.agentLifecycleUnresolvedAutomaticWaitSeconds)
        let fallbackWaitSummary = if otherAutomaticWaitSeconds == unresolvedAutomaticWaitSeconds {
            "other or unresolved parents \(otherAutomaticWaitSeconds) seconds"
        } else {
            "other parents \(otherAutomaticWaitSeconds) seconds and unresolved parents \(unresolvedAutomaticWaitSeconds) seconds"
        }
        let automaticWaitProviderSummary = "Claude \(claudeAutomaticWaitSeconds) seconds (\(claudeExtendedAutomaticWaitSeconds) seconds when the parent's effective Claude configuration explicitly sets a one-hour prompt cache), Codex \(codexAutomaticWaitSeconds) seconds, and \(fallbackWaitSummary)"

        let maximumExplicitWaitSeconds = Int(MCPTimeoutPolicy.agentLifecycleMaximumExplicitTimeoutSeconds)
        let explicitWaitRangeFormatter = NumberFormatter()
        explicitWaitRangeFormatter.locale = Locale(identifier: "en_US_POSIX")
        explicitWaitRangeFormatter.numberStyle = .decimal
        explicitWaitRangeFormatter.usesGroupingSeparator = true
        explicitWaitRangeFormatter.groupingSeparator = ","
        explicitWaitRangeFormatter.groupingSize = 3
        let formattedMaximumExplicitWaitSeconds = explicitWaitRangeFormatter.string(
            from: NSNumber(value: maximumExplicitWaitSeconds)
        ) ?? String(maximumExplicitWaitSeconds)
        let explicitWaitRange = "0...\(formattedMaximumExplicitWaitSeconds)"

        let automaticWaitWorkflowIDs = waitFirstWorkflowIDs + [.reminder]
        for workflowID in automaticWaitWorkflowIDs {
            for renderedVariant in waitFirstVariants {
                let rendered = RepoPromptWorkflowPrompts.render(
                    id: workflowID,
                    variant: renderedVariant.variant
                )
                let label = "\(workflowID.commandName) [\(renderedVariant.name)]"

                XCTAssertTrue(rendered.contains("For routine supervision, omit `timeout` / `timeout_seconds`"), label)
                XCTAssertTrue(rendered.contains("omission selects the automatic wait from the effective parent provider"), label)
                XCTAssertTrue(
                    rendered.contains("effective parent provider: \(automaticWaitProviderSummary)."),
                    label
                )
                XCTAssertTrue(
                    rendered.contains("\(claudeExtendedAutomaticWaitSeconds) seconds when the parent's effective Claude configuration explicitly sets a one-hour prompt cache"),
                    label
                )
                XCTAssertTrue(rendered.contains("upper bounds rather than mandatory sleeps"), label)
                XCTAssertTrue(rendered.contains("A timeout returns the current state while the worker remains active"), label)
                XCTAssertTrue(rendered.contains("does not itself send a provider-model request"), label)
                XCTAssertTrue(rendered.contains("does not warm a prompt cache"), label)
                XCTAssertTrue(rendered.contains("The next parent-model continuation may refresh a cache"), label)
                XCTAssertTrue(rendered.contains("depending on the actual provider product and account path"), label)
                XCTAssertTrue(rendered.contains("Longer explicit waits trade fewer supervisory model calls"), label)
                XCTAssertTrue(rendered.contains("greater chance of cache expiry on short-retention paths"), label)
                XCTAssertTrue(rendered.contains("Use an explicit override only for"), label)
                XCTAssertTrue(rendered.contains("known caller constraint"), label)
                XCTAssertTrue(rendered.contains("not merely because a worker may run for a long time"), label)
                XCTAssertTrue(
                    rendered.contains("accepted explicit range is `\(explicitWaitRange)` seconds; zero means poll"),
                    label
                )
                XCTAssertFalse(rendered.lowercased().contains("cache-safe"), label)
                XCTAssertFalse(rendered.lowercased().contains("codex ttl"), label)

                for line in rendered.split(separator: "\n") {
                    if line.contains("agent_run op=") {
                        XCTAssertFalse(line.contains("timeout="), "\(label): \(line)")
                        XCTAssertFalse(line.contains("timeout_seconds="), "\(label): \(line)")
                    }
                    if line.contains("{\"tool\":\"agent_run\"") {
                        XCTAssertFalse(line.contains("\"timeout\":"), "\(label): \(line)")
                        XCTAssertFalse(line.contains("\"timeout_seconds\":"), "\(label): \(line)")
                    }
                }
            }
        }
    }
}
