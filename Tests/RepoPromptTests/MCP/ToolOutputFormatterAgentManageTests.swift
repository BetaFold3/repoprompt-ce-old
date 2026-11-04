import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class ToolOutputFormatterAgentManageTests: XCTestCase {
    func testListAgentsCollapsesGpt56MaxUltraVariantsWithoutInvalidNestedIDs() throws {
        let value: Value = .object([
            "agents": .array([
                .object([
                    "name": .string("Codex"),
                    "available": .bool(true),
                    "default_model_id": .string("codex:gpt-5.6-sol-low"),
                    "models": .array([
                        model(id: "codex:gpt-5.6-sol-low", name: "GPT-5.6 Sol Low", effort: "low"),
                        model(id: "codex:gpt-5.6-sol-xhigh", name: "GPT-5.6 Sol XHigh", effort: "xhigh"),
                        model(id: "codex:gpt-5.6-sol-max", name: "GPT-5.6 Sol Max", effort: "max"),
                        model(id: "codex:gpt-5.6-sol-ultra", name: "GPT-5.6 Sol Ultra", effort: "ultra"),
                        model(id: "codex:gpt-5.1-codex-max", name: "GPT-5.1 Codex Max", effort: nil)
                    ])
                ])
            ])
        ])

        let text = try onlyText(ToolOutputFormatter.formatAgentManage(args: ["op": .string("list_agents")], value: value))

        XCTAssertTrue(text.contains("`codex:gpt-5.6-sol-{low|xhigh|max|ultra}` — GPT-5.6 Sol"), text)
        XCTAssertEqual(text.components(separatedBy: "gpt-5.6-sol-{").count - 1, 1, text)
        XCTAssertFalse(text.contains("gpt-5.6-sol-ultra-{ultra}"), text)
        XCTAssertFalse(text.contains("gpt-5.6-sol-ultra-ultra"), text)
        XCTAssertFalse(text.contains("GPT-5.6 Sol Ultra"), text)
        XCTAssertTrue(text.contains("`codex:gpt-5.1-codex-max` — GPT-5.1 Codex Max"), text)
    }

    func testListAgentsAdvertisesExactClaudeColonEffortTargetsAlongsideCodexShorthand() throws {
        let value: Value = .object([
            "agents": .array([
                .object([
                    "name": .string("Claude Code"),
                    "available": .bool(true),
                    "default_model_id": .string("claudeCode:claude-opus-5-5"),
                    "models": .array([
                        model(id: "claudeCode:claude-opus-5-5", name: "Claude Opus 5.5", effort: nil),
                        model(id: "claudeCode:claude-opus-5-5:low", name: "Claude Opus 5.5 Low", effort: "low"),
                        model(id: "claudeCode:claude-opus-5-5:medium", name: "Claude Opus 5.5 Medium", effort: "medium"),
                        model(id: "claudeCode:claude-opus-5-5:xhigh", name: "Claude Opus 5.5 XHigh", effort: "xhigh"),
                        model(id: "claudeCode:claude-opus-5-5:max", name: "Claude Opus 5.5 Max", effort: "max")
                    ])
                ]),
                .object([
                    "name": .string("Codex"),
                    "available": .bool(true),
                    "default_model_id": .string("codex:gpt-5.6-sol-low"),
                    "models": .array([
                        model(id: "codex:gpt-5.6-sol-low", name: "GPT-5.6 Sol Low", effort: "low"),
                        model(id: "codex:gpt-5.6-sol-high", name: "GPT-5.6 Sol High", effort: "high")
                    ])
                ])
            ])
        ])

        let text = try onlyText(ToolOutputFormatter.formatAgentManage(args: ["op": .string("list_agents")], value: value))

        XCTAssertTrue(text.contains("`claudeCode:claude-opus-5-5` — Claude Opus 5.5"), text)
        for effort in ["low", "medium", "xhigh", "max"] {
            XCTAssertTrue(text.contains("`claudeCode:claude-opus-5-5:\(effort)` — "), text)
            XCTAssertFalse(text.contains("claude-opus-5-5:\(effort)-{"), text)
        }
        XCTAssertFalse(text.contains("claude-opus-5-5-{"), text)
        XCTAssertFalse(text.contains("claude-opus-5-5:{"), text)
        XCTAssertTrue(text.contains("`codex:gpt-5.6-sol-{low|high}` — GPT-5.6 Sol"), text)
    }

    @MainActor
    func testRenderedClaudeEffortTargetsAreAcceptedBySelectionResolver() throws {
        let value: Value = .object([
            "agents": .array([
                .object([
                    "name": .string("Claude Code"),
                    "available": .bool(true),
                    "models": .array([
                        model(id: "claudeCode:opus:medium", name: "Opus Medium", effort: "medium"),
                        model(id: "claudeCode:claude-opus-5-5:medium", name: "Claude Opus 5.5 Medium", effort: "medium")
                    ])
                ])
            ])
        ])
        let text = try onlyText(ToolOutputFormatter.formatAgentManage(args: ["op": .string("list_agents")], value: value))
        let renderedIDs = text.components(separatedBy: "`").filter { $0.hasPrefix("claudeCode:") }
        XCTAssertEqual(renderedIDs, ["claudeCode:opus:medium", "claudeCode:claude-opus-5-5:medium"], text)

        let availability = AgentModelCatalog.AvailabilityContext(claudeCodeAvailable: true)
        for renderedID in renderedIDs {
            let resolved = try AgentMCPSelectionResolver.resolve(modelID: renderedID, availability: availability)
            XCTAssertEqual(resolved.agentRaw, AgentProviderKind.claudeCode.rawValue)
            XCTAssertEqual(resolved.modelRaw, String(renderedID.dropFirst("claudeCode:".count)))
            XCTAssertNil(resolved.taskLabelKind)
        }
        XCTAssertThrowsError(
            try AgentMCPSelectionResolver.resolve(
                modelID: "claudeCode:claude-opus-5-5:medium-{medium}",
                availability: availability
            )
        )
    }

    private func model(id: String, name: String, effort: String?) -> Value {
        var object: [String: Value] = [
            "model_id": .string(id),
            "name": .string(name)
        ]
        if let effort {
            object["reasoning_effort"] = .string(effort)
        }
        return .object(object)
    }

    private func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        let first = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = first else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }
}
