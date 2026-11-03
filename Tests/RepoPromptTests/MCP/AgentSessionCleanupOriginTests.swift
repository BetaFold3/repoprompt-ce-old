import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptWorkspace
@_spi(TestSupport) @testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
import XCTest

/// Plan §6.4: `agent_manage.cleanup_sessions` eligibility is provenance-scoped —
/// `.remote(deviceID:)` sessions are cleanup-eligible, `.user` sessions never are.
@MainActor
final class AgentSessionCleanupOriginTests: XCTestCase {
    func testUserOriginSessionIsNeverCleanupEligible() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = try await installSession(on: window, origin: .user)
        let service = makeService(window: window)

        let value = try await service.execute(args: [
            "op": .string("cleanup_sessions"),
            "session_ids": .array([.string(sessionID.uuidString)])
        ])

        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["deleted_count"]?.intValue, 0)
        let skipped = try XCTUnwrap(object["skipped_sessions"]?.arrayValue)
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(skipped[0].objectValue?["session_id"]?.stringValue, sessionID.uuidString)
        XCTAssertEqual(skipped[0].objectValue?["reason"]?.stringValue, "not_mcp_originated")
    }

    func testRemoteOriginSessionIsCleanupEligible() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = try await installSession(on: window, origin: .remote(deviceID: "aaaa1111"))
        let service = makeService(window: window)

        let value = try await service.execute(args: [
            "op": .string("cleanup_sessions"),
            "session_ids": .array([.string(sessionID.uuidString)])
        ])

        let object = try XCTUnwrap(value.objectValue)
        let skipped = object["skipped_sessions"]?.arrayValue ?? []
        XCTAssertFalse(
            skipped.contains { $0.objectValue?["reason"]?.stringValue == "not_mcp_originated" },
            "Remote-origin sessions must pass the provenance guard: \(skipped)"
        )
        let deleted = try XCTUnwrap(object["deleted_sessions"]?.arrayValue)
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted[0].objectValue?["session_id"]?.stringValue, sessionID.uuidString)
    }

    func testMCPOriginSessionRemainsCleanupEligible() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let sessionID = try await installSession(on: window, origin: .mcp(clientID: "claude-code"))
        let service = makeService(window: window)

        let value = try await service.execute(args: [
            "op": .string("cleanup_sessions"),
            "session_ids": .array([.string(sessionID.uuidString)])
        ])

        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["deleted_count"]?.intValue, 1)
    }

    private func installSession(
        on window: WindowState,
        origin: AgentSessionOrigin
    ) async throws -> UUID {
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.origin = origin
        session.runState = .completed
        return sessionID
    }

    private func makeRegisteredSession(
        in window: WindowState
    ) async throws -> AgentTabSession {
        await window.promptManager.createBlankComposeTab(createAgentSession: false)
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        return try await window.agentModeViewModel.ensureSessionReady(tabID: tabID)
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Cleanup Origin \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentSessionCleanupOriginTests"
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
                    clientName: "cleanup-origin-tests",
                    windowID: window.windowID,
                    actorRoutedRunTab: nil
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in }
        )
    }
}
