import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptWorkspace
@_spi(TestSupport) @testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
import XCTest

@MainActor
final class AgentManageMCPToolServiceForkTests: XCTestCase {
    func testForkSessionReturnsListSessionsDescriptorAndStagesFirstSteerPayload() async throws {
        try await withFixture { fixture in
            let foregroundTabID = try XCTUnwrap(fixture.viewModel.currentTabID)
            let value = try await fixture.service.execute(args: forkArgs(fixture: fixture))

            let object = try XCTUnwrap(value.objectValue)
            XCTAssertEqual(object["status"]?.stringValue, "forked")
            let descriptor = try XCTUnwrap(object["session"]?.objectValue)
            let destinationSessionIDRaw = try XCTUnwrap(descriptor["session_id"]?.stringValue)
            let destinationSessionID = try XCTUnwrap(UUID(uuidString: destinationSessionIDRaw))
            XCTAssertEqual(descriptor["is_live"]?.boolValue, true)
            XCTAssertEqual(descriptor["agent"]?.objectValue?["id"]?.stringValue, fixture.destination.agentRaw)

            XCTAssertEqual(fixture.viewModel.currentTabID, foregroundTabID)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, foregroundTabID)
            let destinationSession = try XCTUnwrap(
                fixture.viewModel.sessions.values.first { $0.activeAgentSessionID == destinationSessionID }
            )
            XCTAssertEqual(destinationSession.items.map(\.text), fixture.sourceTexts)
            XCTAssertNil(destinationSession.pendingHandoff.sourceItemID)

            let pendingPayload = try XCTUnwrap(destinationSession.pendingHandoff.payload)
            let composedSteer = fixture.viewModel.prependPendingHandoffIfNeeded(
                "next remote steer",
                session: destinationSession
            )
            XCTAssertEqual(
                composedSteer,
                pendingPayload.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\nnext remote steer"
            )
            XCTAssertTrue(composedSteer.hasPrefix("<forked_session"))

            let listed = try await fixture.service.execute(args: [
                "op": .string("list_sessions"),
                "limit": .int(100)
            ])
            let listedDescriptor = try XCTUnwrap(
                listed.objectValue?["sessions"]?.arrayValue?
                    .compactMap(\.objectValue)
                    .first { $0["session_id"]?.stringValue == destinationSessionID.uuidString }
            )
            XCTAssertEqual(descriptor, listedDescriptor)
        }
    }

    func testForkSessionCutoffMigratesOnlyRequestedPrefix() async throws {
        try await withFixture { fixture in
            let cutoffID = try XCTUnwrap(fixture.sourceSession.items.dropFirst().first?.id)
            let value = try await fixture.service.execute(args: forkArgs(
                fixture: fixture,
                upToItemID: cutoffID
            ))
            let destinationSession = try destinationSession(from: value, fixture: fixture)

            XCTAssertEqual(destinationSession.items.map(\.text), Array(fixture.sourceTexts.prefix(2)))
            XCTAssertEqual(destinationSession.pendingHandoff.sourceItemID, cutoffID)
        }
    }

    func testForkSessionRejectsUnknownAndPersistedOnlySessions() async throws {
        try await withFixture { fixture in
            var unknownArgs = forkArgs(fixture: fixture)
            unknownArgs["session_id"] = .string(UUID().uuidString)
            await assertInvalidParams(contains: "was not found") {
                _ = try await fixture.service.execute(args: unknownArgs)
            }

            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let persistedID = UUID()
            let transcript = AgentTranscriptIO.buildTranscript(
                from: [.user("persisted only", sequenceIndex: 0)],
                terminalState: .completed,
                compact: false
            )
            let persisted = AgentSession(
                id: persistedID,
                workspaceID: workspace.id,
                name: "Persisted Fork Source",
                savedAt: Date(),
                transcript: transcript,
                itemCount: 1,
                lastRunState: AgentSessionRunState.completed.rawValue,
                autoEditEnabled: true
            )
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                persisted,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 1
            )
            var persistedArgs = forkArgs(fixture: fixture)
            persistedArgs["session_id"] = .string(persistedID.uuidString)
            await assertInvalidParams(contains: "persisted-only") {
                _ = try await fixture.service.execute(args: persistedArgs)
            }
        }
    }

    func testForkSessionRejectsInvalidDestinationAndCutoffWithoutCreatingTab() async throws {
        try await withFixture { fixture in
            let initialTabIDs = Set(fixture.viewModel.sessions.keys)

            var invalidAgentArgs = forkArgs(fixture: fixture)
            invalidAgentArgs["destination_agent"] = .string("not-a-provider")
            await assertInvalidParams(contains: "destination_agent") {
                _ = try await fixture.service.execute(args: invalidAgentArgs)
            }

            var invalidModelArgs = forkArgs(fixture: fixture)
            invalidModelArgs["destination_model_id"] = .string("\(fixture.destination.agentRaw):not-a-host-model")
            await assertInvalidParams(contains: "destination_model_id") {
                _ = try await fixture.service.execute(args: invalidModelArgs)
            }

            var invalidEffortArgs = forkArgs(fixture: fixture)
            invalidEffortArgs["destination_effort"] = .string("not-an-effort")
            await assertInvalidParams(contains: "destination_effort") {
                _ = try await fixture.service.execute(args: invalidEffortArgs)
            }

            var invalidCutoffArgs = forkArgs(fixture: fixture)
            invalidCutoffArgs["up_to_item_id"] = .string(UUID().uuidString)
            await assertInvalidParams(contains: "up_to_item_id was not found") {
                _ = try await fixture.service.execute(args: invalidCutoffArgs)
            }

            XCTAssertEqual(Set(fixture.viewModel.sessions.keys), initialTabIDs)
        }
    }

    private func forkArgs(
        fixture: Fixture,
        upToItemID: UUID? = nil
    ) -> [String: Value] {
        var args: [String: Value] = [
            "op": .string("fork_session"),
            "session_id": .string(fixture.sourceSessionID.uuidString),
            "destination_agent": .string(fixture.destination.agentRaw),
            "destination_model_id": .string(fixture.destination.modelID)
        ]
        if let effort = fixture.destination.effort {
            args["destination_effort"] = .string(effort)
        }
        if let upToItemID {
            args["up_to_item_id"] = .string(upToItemID.uuidString)
        }
        return args
    }

    private func destinationSession(
        from value: Value,
        fixture: Fixture
    ) throws -> AgentTabSession {
        let sessionIDRaw = try XCTUnwrap(value.objectValue?["session"]?.objectValue?["session_id"]?.stringValue)
        let sessionID = try XCTUnwrap(UUID(uuidString: sessionIDRaw))
        return try XCTUnwrap(fixture.viewModel.sessions.values.first { $0.activeAgentSessionID == sessionID })
    }

    private func assertInvalidParams(
        contains expectedMessage: String,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected invalid params containing '\(expectedMessage)'")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(expectedMessage),
                "Expected error containing '\(expectedMessage)', got: \(error)"
            )
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await makeFixture()
        do {
            try await body(fixture)
        } catch {
            await cleanup(fixture)
            throw error
        }
        await cleanup(fixture)
    }

    private func makeFixture() async throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentManageForkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Fork Session \(UUID().uuidString.prefix(8))",
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "agentManageForkSessionTests"
            )

            let sourceTabID = UUID()
            let foregroundTabID = UUID()
            let sourceSessionID = UUID()
            let foregroundSessionID = UUID()
            let sourceTab = ComposeTabState(
                id: sourceTabID,
                name: "Fork Source",
                activeAgentSessionID: sourceSessionID
            )
            let foregroundTab = ComposeTabState(
                id: foregroundTabID,
                name: "Foreground",
                activeAgentSessionID: foregroundSessionID
            )
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id })
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [sourceTab, foregroundTab]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = foregroundTabID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex],
                syncPromptText: true
            )

            let viewModel = window.agentModeViewModel
            let sourceSession = try XCTUnwrap(viewModel.session(for: sourceTabID, createIfNeeded: true))
            sourceSession.hasLoadedPersistedState = true
            let sourceTexts = ["first request", "first reply", "second request", "second reply"]
            sourceSession.setItemsSilently(
                [
                    .user(sourceTexts[0], sequenceIndex: 0),
                    .assistant(sourceTexts[1], sequenceIndex: 1),
                    .user(sourceTexts[2], sequenceIndex: 2),
                    .assistant(sourceTexts[3], sequenceIndex: 3)
                ],
                reason: .testOverride
            )
            viewModel.refreshDerivedTranscriptState(for: sourceSession)

            let foregroundSession = try XCTUnwrap(viewModel.session(for: foregroundTabID, createIfNeeded: true))
            foregroundSession.hasLoadedPersistedState = true
            foregroundSession.setItemsSilently(
                [.user("foreground", sequenceIndex: 0)],
                reason: .testOverride
            )
            viewModel.refreshDerivedTranscriptState(for: foregroundSession)
            viewModel.setAgentModeActive(true)

            window.apiSettingsViewModel.isClaudeCodeConnected = true
            window.apiSettingsViewModel.isCodexConnected = true
            window.apiSettingsViewModel.isOpenCodeConnected = true
            let service = makeService(window: window)
            let destination = try await firstAvailableDestination(service: service)

            return Fixture(
                window: window,
                rootURL: rootURL,
                viewModel: viewModel,
                service: service,
                sourceSessionID: sourceSessionID,
                sourceSession: sourceSession,
                sourceTexts: sourceTexts,
                destination: destination
            )
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    private func firstAvailableDestination(
        service: AgentManageMCPToolService
    ) async throws -> Destination {
        let value = try await service.execute(args: ["op": .string("list_agents")])
        let agents = try XCTUnwrap(value.objectValue?["agents"]?.arrayValue)
        var fallback: Destination?
        for agentValue in agents {
            guard let agent = agentValue.objectValue,
                  agent["available"]?.boolValue == true
            else { continue }
            for modelValue in agent["models"]?.arrayValue ?? [] {
                guard let model = modelValue.objectValue,
                      let agentRaw = model["agent_id"]?.stringValue,
                      let modelID = model["model_id"]?.stringValue
                else { continue }
                let destination = Destination(
                    agentRaw: agentRaw,
                    modelID: modelID,
                    effort: model["effort"]?.stringValue
                )
                if destination.effort != nil {
                    return destination
                }
                fallback = fallback ?? destination
            }
        }
        if let fallback {
            return fallback
        }
        throw XCTSkip("No available structured host destination model")
    }

    private func makeService(window: WindowState) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "fork-session-tests",
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

    private func cleanup(_ fixture: Fixture) async {
        fixture.window.beginClose()
        await fixture.window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(fixture.window)
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }

    private struct Destination {
        let agentRaw: String
        let modelID: String
        let effort: String?
    }

    private struct Fixture {
        let window: WindowState
        let rootURL: URL
        let viewModel: AgentModeViewModel
        let service: AgentManageMCPToolService
        let sourceSessionID: UUID
        let sourceSession: AgentTabSession
        let sourceTexts: [String]
        let destination: Destination
    }
}
