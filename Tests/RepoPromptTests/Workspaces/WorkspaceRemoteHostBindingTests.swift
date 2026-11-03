import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

@MainActor
final class WorkspaceRemoteHostBindingTests: XCTestCase {
    func testWorkspaceModelRemoteHostBindingRoundTripLegacyAndEquality() throws {
        let hostID = "host-workspace-default"
        let workspace = try WorkspaceModel(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000901")),
            name: "Remote Workspace",
            repoPaths: ["/tmp/repo"],
            defaultRemoteHostID: hostID
        )

        let encoded = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(WorkspaceModel.self, from: encoded)
        XCTAssertEqual(decoded.defaultRemoteHostID, hostID)
        XCTAssertEqual(decoded, workspace)

        var changedBinding = workspace
        changedBinding.defaultRemoteHostID = "host-other"
        XCTAssertNotEqual(changedBinding, workspace)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "defaultRemoteHostID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(WorkspaceModel.self, from: legacyData)
        XCTAssertNil(legacy.defaultRemoteHostID)
    }

    func testCreationDraftPropagatesRemoteHostBindingAndEditPersists() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRemoteHostBindingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let manager = makeComposition(storageRoot: storageRoot).workspaceManager
        await manager.awaitInitialized()
        manager.creationDraft.name = "Remote Bound Workspace"
        manager.creationDraft.selectedRepoPaths = ["/tmp/remote-bound"]
        manager.creationDraft.defaultRemoteHostID = "host-draft"

        let created = try XCTUnwrap(manager.createWorkspaceFromDraft())
        XCTAssertEqual(created.defaultRemoteHostID, "host-draft")
        XCTAssertNil(manager.creationDraft.defaultRemoteHostID)

        let workspaceFile = manager.workspaceDirectory(for: created)
            .appendingPathComponent("workspace.json")
        try await waitUntil {
            self.decodeWorkspace(at: workspaceFile)?.defaultRemoteHostID == "host-draft"
        }

        manager.setWorkspaceDefaultRemoteHost(created, hostID: "host-edited")
        XCTAssertEqual(
            manager.workspaces.first(where: { $0.id == created.id })?.defaultRemoteHostID,
            "host-edited"
        )
        try await waitUntil {
            self.decodeWorkspace(at: workspaceFile)?.defaultRemoteHostID == "host-edited"
        }
    }

    private func makeComposition(storageRoot: URL) -> WindowStateComposition {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        let previousStorageRoot = WorkspaceGlobalCustomStorageLocation.load()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        WorkspaceGlobalCustomStorageLocation.store(storageRoot)
        defer {
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            WorkspaceGlobalCustomStorageLocation.store(previousStorageRoot)
        }
        return WindowStateCompositionFactory.make(
            windowID: -1200 - Int.random(in: 1 ... 99),
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
    }

    private func decodeWorkspace(at url: URL) -> WorkspaceModel? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WorkspaceModel.self, from: data)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for workspace persistence", file: file, line: line)
    }
}
