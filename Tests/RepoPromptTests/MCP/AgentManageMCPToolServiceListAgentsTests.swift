import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptAgentCore
@testable import RepoPromptWorkspace
@_spi(TestSupport) @testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
import XCTest

@MainActor
final class AgentManageMCPToolServiceListAgentsTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .ohMyPi)
        #if DEBUG
            await OMPQualificationSharedGateTestIsolation.shared.acquire()
            OhMyPiAgentModeSmokeGate.shared.resetForTesting()
        #endif
    }

    override func tearDown() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .ohMyPi)
        #if DEBUG
            OhMyPiAgentModeSmokeGate.shared.resetForTesting()
            await OMPQualificationSharedGateTestIsolation.shared.release()
        #endif
        try await super.tearDown()
    }

    func testListAgentsModelEntriesIncludeStructuredRemotePickerFields() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        window.apiSettingsViewModel.isClaudeCodeConnected = true
        window.apiSettingsViewModel.isCodexConnected = true
        window.apiSettingsViewModel.isOpenCodeConnected = true
        let service = makeService(window: window)

        let value = try await service.execute(args: ["op": .string("list_agents")])

        let object = try XCTUnwrap(value.objectValue)
        let agents = try XCTUnwrap(object["agents"]?.arrayValue)
        XCTAssertFalse(agents.isEmpty)

        let modelObjects = agents.flatMap { agentValue -> [[String: Value]] in
            let models = agentValue.objectValue?["models"]?.arrayValue ?? []
            return models.compactMap(\.objectValue)
        }
        let structuredModel = try XCTUnwrap(modelObjects.first { model in
            model["model_id"]?.stringValue?.isEmpty == false
                && model["agent_id"]?.stringValue?.isEmpty == false
                && model["base_model_id"]?.stringValue?.isEmpty == false
                && model["model_display_name"]?.stringValue?.isEmpty == false
        })

        XCTAssertNotNil(structuredModel["name"]?.stringValue)
        XCTAssertNotNil(structuredModel["is_default"]?.boolValue)

        let effortModel = try XCTUnwrap(modelObjects.first { model in
            model["effort"]?.stringValue?.isEmpty == false
                && model["effort_display_name"]?.stringValue?.isEmpty == false
        })
        XCTAssertEqual(effortModel["reasoning_effort"]?.stringValue, effortModel["effort"]?.stringValue)
        XCTAssertNotEqual(effortModel["name"]?.stringValue, effortModel["model_display_name"]?.stringValue)
    }

    func testConnectedOhMyPiListAgentsAdvertisesDefaultSentinel() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        window.apiSettingsViewModel.isOhMyPiConnected = true

        let value = try await makeService(window: window).execute(args: ["op": .string("list_agents")])
        let agents = try XCTUnwrap(value.objectValue?["agents"]?.arrayValue)
        let ohMyPi = try XCTUnwrap(agents.compactMap(\.objectValue).first { agent in
            agent["models"]?.arrayValue?.contains { model in
                model.objectValue?["agent_id"]?.stringValue == AgentProviderKind.ohMyPi.rawValue
            } == true
        })
        XCTAssertEqual(ohMyPi["name"]?.stringValue, "Oh My Pi")
        XCTAssertEqual(ohMyPi["available"]?.boolValue, true)
        let models = try XCTUnwrap(ohMyPi["models"]?.arrayValue).compactMap(\.objectValue)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0]["model_id"]?.stringValue, "ohMyPi:default")
        XCTAssertEqual(ohMyPi["default_model_id"]?.stringValue, "ohMyPi:default")
    }

    func testQualificationLedgerKeepsSharedGateIsolationContract() throws {
        let ledgerURL = try RepoRoot.url()
            .appendingPathComponent("Scripts/Fixtures/test-suite-contract-ledger.tsv")
        let lines = try String(contentsOf: ledgerURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let header = try XCTUnwrap(lines.first)
        let fileIndex = try XCTUnwrap(header.firstIndex(of: "file"))
        let methodIndex = try XCTUnwrap(header.firstIndex(of: "method"))
        let sharedStateIndex = try XCTUnwrap(header.firstIndex(of: "shared_state_tags"))
        let lifecycleIndex = try XCTUnwrap(header.firstIndex(of: "lifecycle_owner"))
        let assertionIndex = try XCTUnwrap(header.firstIndex(of: "observable_oracle"))
        let notesIndex = try XCTUnwrap(header.firstIndex(of: "notes"))
        let target = try XCTUnwrap(lines.dropFirst().first {
            $0.indices.contains(methodIndex)
                && $0[methodIndex] == "testConnectedOhMyPiListAgentsAdvertisesDefaultSentinel"
        })

        XCTAssertEqual(
            Set(target[sharedStateIndex].split(separator: ";").map(String.init)),
            ["process_local_omp_lease", "OhMyPiAgentModeSmokeGate.shared"]
        )
        XCTAssertEqual(target[lifecycleIndex], "test_case+tearDown_reset")

        let lifecycleRows = lines.dropFirst().filter {
            $0.indices.contains(fileIndex)
                && $0[fileIndex] == "Tests/RepoPromptTests/AgentMode/AgentModeRunServiceLifecycleTests.swift"
        }
        XCTAssertFalse(lifecycleRows.isEmpty)
        for row in lifecycleRows {
            let method = row.indices.contains(methodIndex) ? row[methodIndex] : "<missing method>"
            XCTAssertTrue(
                row.indices.contains(sharedStateIndex)
                    && row[sharedStateIndex].split(separator: ";").contains("OhMyPiAgentModeSmokeGate.shared"),
                method
            )
            XCTAssertTrue(
                row.indices.contains(lifecycleIndex)
                    && row[lifecycleIndex].split(separator: "+").contains("tearDown_reset"),
                method
            )
        }

        let qualifiedSelection = try XCTUnwrap(lines.dropFirst().first {
            $0.indices.contains(methodIndex)
                && $0[methodIndex] == "testQualifiedOhMyPiDeniedAuthorizationFailsBeforeBootstrap"
        })
        XCTAssertTrue(qualifiedSelection[assertionIndex].contains("may construct the provider and controller"))
        XCTAssertTrue(qualifiedSelection[assertionIndex].contains("before controller.bootstrap()"))
        XCTAssertTrue(qualifiedSelection[assertionIndex].contains("never creates a provider process"))
        XCTAssertTrue(qualifiedSelection[notesIndex].contains("local synthetic qualification transaction"))
        XCTAssertTrue(qualifiedSelection[notesIndex].contains("injects denial"))
        XCTAssertTrue(qualifiedSelection[notesIndex].contains("suite teardown resets shared process state"))
        XCTAssertTrue(qualifiedSelection[notesIndex].contains("No provider process is created"))

        let deadline = try XCTUnwrap(lines.dropFirst().first {
            $0.indices.contains(methodIndex)
                && $0[methodIndex] == "testOMPQualificationAuthorizationUsesSingleAbsoluteDeadline"
        })
        XCTAssertTrue(
            deadline[sharedStateIndex].split(separator: ";").contains(
                "AgentRunMCPToolService.ompQualificationAuthorizationDeadlineNanosecondsOverride"
            )
        )

        let lifecycleSource = try String(
            contentsOf: RepoRoot.url().appendingPathComponent(
                "Tests/RepoPromptTests/AgentMode/AgentModeRunServiceLifecycleTests.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(lifecycleSource.contains("override func setUp() async throws"))
        XCTAssertTrue(lifecycleSource.contains("OMPQualificationSharedGateTestIsolation.shared.acquire()"))
        XCTAssertTrue(lifecycleSource.contains("override func tearDown() async throws"))
        XCTAssertTrue(lifecycleSource.contains("OhMyPiAgentModeSmokeGate.shared.resetForTesting()"))
        XCTAssertTrue(lifecycleSource.contains("OMPQualificationSharedGateTestIsolation.shared.release()"))
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "List Agents \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentManageListAgentsTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeService(window: WindowState) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "list-agents-shape-tests",
                    windowID: window.windowID,
                    actorRoutedRunTab: nil
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            restrictDiscoveryToRoleLabels: { _ in false }
        )
    }
}
