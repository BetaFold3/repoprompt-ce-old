import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptWorkspace
@_spi(TestSupport) @testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
import XCTest

@MainActor
final class AgentManageListAgentsCursorParameterMetadataTests: XCTestCase {
    func testCompactSchemaIncludesTemplateFlagAndUniqueThoughtLevelAlias() throws {
        let catalog = makeCatalog([
            "gpt-5.6-sol": [
                parameter(id: "context", category: "model_config", defaultValue: "272k"),
                parameter(id: "effort", category: "thought_level", defaultValue: "high")
            ],
            "ambiguous-thought": [
                parameter(id: "thinking", category: "thought_level", defaultValue: "true"),
                parameter(id: "effort", category: "thought_level", defaultValue: "high")
            ]
        ])
        let builder = CursorAgentParameterMetadataBuilder(catalog: catalog, isEnabled: { true })

        let compact = try XCTUnwrap(
            builder.metadata(
                agent: .cursor,
                targetID: "cursor:gpt-5.6-sol",
                includeParameters: false
            )?.objectValue
        )
        XCTAssertEqual(compact["syntax"]?.stringValue, "cursor-bracket-v1")
        XCTAssertEqual(
            compact["target_template"]?.stringValue,
            "cursor:gpt-5.6-sol[context=<value>,effort=<value>]"
        )
        XCTAssertEqual(
            compact["include_model_parameters_flag"]?.stringValue,
            "include_model_parameters"
        )
        XCTAssertEqual(compact["reasoning_effort_parameter_id"]?.stringValue, "effort")
        XCTAssertNil(compact["parameters"])

        let ambiguous = try XCTUnwrap(
            builder.metadata(
                agent: .cursor,
                targetID: "cursor:ambiguous-thought",
                includeParameters: false
            )?.objectValue
        )
        XCTAssertNil(ambiguous["reasoning_effort_parameter_id"])
    }

    func testOptInIncludesFullAxesOptionsDefaultsAndDescriptions() throws {
        let catalog = makeCatalog([
            "gpt-5.6-sol": [
                CursorModelParameterCatalog.ParameterSpec(
                    id: "reasoning",
                    category: "thought_level",
                    defaultValue: "medium",
                    options: [
                        .init(value: "low", name: "Low"),
                        .init(value: "medium", name: "Medium")
                    ],
                    description: "Reasoning effort"
                )
            ]
        ])
        let builder = CursorAgentParameterMetadataBuilder(catalog: catalog, isEnabled: { true })

        let metadata = try XCTUnwrap(
            builder.metadata(
                agent: .cursor,
                targetID: "cursor:gpt-5.6-sol",
                includeParameters: true
            )?.objectValue
        )
        let axes = try XCTUnwrap(metadata["parameters"]?.arrayValue)
        XCTAssertEqual(axes.count, 1)
        let axis = try XCTUnwrap(axes[0].objectValue)
        XCTAssertEqual(axis["id"]?.stringValue, "reasoning")
        XCTAssertEqual(axis["category"]?.stringValue, "thought_level")
        XCTAssertEqual(axis["default_value"]?.stringValue, "medium")
        XCTAssertEqual(axis["description"]?.stringValue, "Reasoning effort")

        let options = try XCTUnwrap(axis["options"]?.arrayValue).compactMap(\.objectValue)
        XCTAssertEqual(options.map { $0["value"]?.stringValue }, ["low", "medium"])
        XCTAssertEqual(options.map { $0["name"]?.stringValue }, ["Low", "Medium"])
    }

    func testCatalogAndNonBareTargetsOmitMetadata() {
        let catalog = makeCatalog([
            "empty": [],
            "parameterized": [
                parameter(id: "reasoning", category: "thought_level", defaultValue: "medium")
            ],
            "invalid-id": [
                parameter(id: "bad,id", category: "model_config", defaultValue: "on")
            ],
            "ohmypi:provider/model": [
                parameter(id: "reasoning", category: "thought_level", defaultValue: "medium")
            ]
        ])
        let builder = CursorAgentParameterMetadataBuilder(catalog: catalog, isEnabled: { true })

        XCTAssertNotNil(
            builder.metadata(
                agent: .cursor,
                targetID: "cursor:parameterized",
                includeParameters: true
            )
        )
        XCTAssertNil(
            builder.metadata(
                agent: .cursor,
                targetID: "cursor:missing",
                includeParameters: true
            )
        )
        XCTAssertNil(
            builder.metadata(
                agent: .cursor,
                targetID: "cursor:empty",
                includeParameters: true
            )
        )
        XCTAssertNil(
            builder.metadata(
                agent: .cursor,
                targetID: "cursor:parameterized[reasoning=high]",
                includeParameters: true
            )
        )
        XCTAssertNil(
            builder.metadata(
                agent: .cursor,
                targetID: "cursor:invalid-id",
                includeParameters: true
            )
        )
        XCTAssertNil(
            builder.metadata(
                agent: .ohMyPi,
                targetID: "ohMyPi:provider/model",
                includeParameters: true
            )
        )

        let disabledBuilder = CursorAgentParameterMetadataBuilder(
            catalog: catalog,
            isEnabled: { false }
        )
        XCTAssertNil(
            disabledBuilder.metadata(
                agent: .cursor,
                targetID: "cursor:parameterized",
                includeParameters: true
            )
        )
    }

    func testListAgentsPreservesTargetOrderCountAndNonCursorOutput() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        window.apiSettingsViewModel.isCursorConnected = true
        window.apiSettingsViewModel.isCodexConnected = true

        let baselineService = makeService(
            window: window,
            catalog: makeCatalog([:])
        )
        let enrichedService = makeService(
            window: window,
            catalog: makeCatalog([
                AgentModel.cursorAuto.rawValue: [
                    parameter(id: "reasoning", category: "thought_level", defaultValue: "medium")
                ],
                AgentModel.cursorComposer2.rawValue: [
                    parameter(id: "fast", category: "model_config", defaultValue: "false")
                ]
            ])
        )

        let baseline = try await baselineService.execute(args: ["op": .string("list_agents")])
        let enriched = try await enrichedService.execute(args: ["op": .string("list_agents")])
        let baselineModels = flattenedModels(in: baseline)
        let enrichedModels = flattenedModels(in: enriched)

        XCTAssertEqual(enrichedModels.count, baselineModels.count)
        XCTAssertEqual(
            enrichedModels.map { $0["model_id"]?.stringValue },
            baselineModels.map { $0["model_id"]?.stringValue }
        )

        let enrichedParameterized = enrichedModels.filter { $0["parameterization"] != nil }
        XCTAssertFalse(enrichedParameterized.isEmpty)
        XCTAssertTrue(enrichedParameterized.allSatisfy {
            $0["agent_id"]?.stringValue == AgentProviderKind.cursor.rawValue
        })
        for model in enrichedParameterized {
            let modelID = try XCTUnwrap(model["model_id"]?.stringValue)
            let template = try XCTUnwrap(
                model["parameterization"]?.objectValue?["target_template"]?.stringValue
            )
            XCTAssertTrue(template.hasPrefix("\(modelID)["))
            let parsed = try XCTUnwrap(
                CursorBracketModelID.parse(
                    CursorBracketModelID.strippingCursorPrefix(template)
                )
            )
            XCTAssertTrue(parsed.hasBracket)
        }

        XCTAssertEqual(
            try encoded(nonCursorAgents(in: enriched)),
            try encoded(nonCursorAgents(in: baseline))
        )

        let full = try await enrichedService.execute(args: [
            "op": .string("list_agents"),
            "include_model_parameters": .bool(true)
        ])
        let fullModels = flattenedModels(in: full)
        XCTAssertEqual(
            fullModels.map { $0["model_id"]?.stringValue },
            baselineModels.map { $0["model_id"]?.stringValue }
        )
        XCTAssertTrue(fullModels.contains {
            $0["parameterization"]?.objectValue?["parameters"]?.arrayValue?.isEmpty == false
        })

        do {
            _ = try await enrichedService.execute(args: [
                "op": .string("list_agents"),
                "include_model_parameters": .string("sometimes")
            ])
            XCTFail("Expected strict boolean parsing to reject the value.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("include_model_parameters must be a boolean value"))
        }
    }

    func testToolSchemaDeclaresIncludeModelParametersBooleanDefaultFalse() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let tools = await window.mcpServer.windowMCPTools
        let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.agentManage })
        let schema = try XCTUnwrap(Value(tool.inputSchema).objectValue)
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        let argument = try XCTUnwrap(properties["include_model_parameters"]?.objectValue)

        XCTAssertEqual(argument["type"]?.stringValue, "boolean")
        XCTAssertTrue(
            argument["description"]?.stringValue?.contains("Default false.") == true
        )
    }

    private func makeCatalog(
        _ snapshot: [String: [CursorModelParameterCatalog.ParameterSpec]]
    ) -> CursorModelParameterCatalog {
        let catalog = CursorModelParameterCatalog()
        catalog.test_restoreSnapshot(snapshot)
        return catalog
    }

    private func parameter(
        id: String,
        category: String,
        defaultValue: String
    ) -> CursorModelParameterCatalog.ParameterSpec {
        CursorModelParameterCatalog.ParameterSpec(
            id: id,
            category: category,
            defaultValue: defaultValue,
            options: [.init(value: defaultValue, name: defaultValue)],
            description: nil
        )
    }

    private func flattenedModels(in value: Value) -> [[String: Value]] {
        value.objectValue?["agents"]?.arrayValue?.flatMap { agent in
            agent.objectValue?["models"]?.arrayValue?.compactMap(\.objectValue) ?? []
        } ?? []
    }

    private func nonCursorAgents(in value: Value) -> [Value] {
        value.objectValue?["agents"]?.arrayValue?.filter { agent in
            let models = agent.objectValue?["models"]?.arrayValue ?? []
            return models.first?.objectValue?["agent_id"]?.stringValue != AgentProviderKind.cursor.rawValue
        } ?? []
    }

    private func encoded(_ value: [Value]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Cursor Parameter Metadata \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentManageCursorParameterMetadataTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeService(
        window: WindowState,
        catalog: CursorModelParameterCatalog
    ) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "cursor-parameter-metadata-tests",
                    windowID: window.windowID,
                    actorRoutedRunTab: nil
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            restrictDiscoveryToRoleLabels: { _ in false },
            cursorParameterMetadataBuilder: CursorAgentParameterMetadataBuilder(catalog: catalog, isEnabled: { true })
        )
    }
}
