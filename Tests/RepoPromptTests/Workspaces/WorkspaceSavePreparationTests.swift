@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceSavePreparationTests: XCTestCase {
        private var originalMCPAutoStart = false

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        }

        override func tearDown() async throws {
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            try await super.tearDown()
        }

        func testSaveKeepsCapturedWorkspaceIdentityAndURLAcrossReorderAfterPreparation() async throws {
            let storageRoot = try temporaryDirectory(named: "IdentityURL")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let composition = makeComposition(windowID: -981)
            let manager = composition.workspaceManager
            try await manager.awaitInitialized(timeout: .seconds(60))
            let workspaceA = makeWorkspace(name: "A", storage: storageRoot.appendingPathComponent("A"))
            let workspaceB = makeWorkspace(name: "B", storage: storageRoot.appendingPathComponent("B"))
            manager.workspaces.append(contentsOf: [workspaceA, workspaceB])
            let switchResult = await manager.switchWorkspace(to: workspaceA, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            manager.markWorkspaceDirty()

            let gate = WorkspaceSavePreparationGate()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, fileURL, _ in
                await gate.arriveAndWait(workspaceID: workspaceID, fileURL: fileURL)
            }
            let saveTask = Task { @MainActor in
                await manager.pollAndSaveStateAsync()
            }
            let arrival = await gate.waitUntilArrived()
            XCTAssertEqual(arrival.workspaceID, workspaceA.id)
            XCTAssertEqual(arrival.fileURL, manager.workspaceFileURL(for: workspaceA))
            try manager.workspaces.swapAt(
                XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceA.id }),
                XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceB.id })
            )
            await gate.release()
            await saveTask.value
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            let savedA = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: arrival.fileURL)
            XCTAssertEqual(savedA.id, workspaceA.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: manager.workspaceFileURL(for: workspaceB).path))
        }

        func testSaveBailsWithoutEnqueueOrAcknowledgementWhenWorkspaceRemovedAfterPreparation() async throws {
            let storageRoot = try temporaryDirectory(named: "Removal")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let composition = makeComposition(windowID: -982)
            let manager = composition.workspaceManager
            try await manager.awaitInitialized(timeout: .seconds(60))
            let workspace = makeWorkspace(name: "Removed", storage: storageRoot.appendingPathComponent("Removed"))
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            manager.markWorkspaceDirty()
            let expectedURL = manager.workspaceFileURL(for: workspace)

            let gate = WorkspaceSavePreparationGate()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, fileURL, _ in
                await gate.arriveAndWait(workspaceID: workspaceID, fileURL: fileURL)
            }
            let saveTask = Task { @MainActor in
                await manager.pollAndSaveStateAsync()
            }
            _ = await gate.waitUntilArrived()
            manager.workspaces.removeAll { $0.id == workspace.id }
            await gate.release()
            await saveTask.value
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            XCTAssertFalse(FileManager.default.fileExists(atPath: expectedURL.path))
            XCTAssertNil(manager.debugLastSavedVersionForWorkspace(workspace.id))
        }

        func testSaveRetriesSameIdentityOnceWhenStateChangesAfterPreparation() async throws {
            let storageRoot = try temporaryDirectory(named: "Retry")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let composition = makeComposition(windowID: -983)
            let manager = composition.workspaceManager
            try await manager.awaitInitialized(timeout: .seconds(60))
            let workspace = makeWorkspace(name: "Retry", storage: storageRoot.appendingPathComponent("Retry"))
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            manager.markWorkspaceDirty()
            manager.resetWorkspaceSaveDiagnosticsForTesting()

            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, _, remainingRetryCount in
                guard remainingRetryCount == 1 else { return }
                await MainActor.run {
                    guard let index = manager.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
                    manager.workspaces[index].currentPromptText = "newer state"
                    manager.markWorkspaceDirty()
                }
            }
            await manager.pollAndSaveStateAsync()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)

            let diagnostics = manager.workspaceSaveDiagnosticsForTesting(workspaceID: workspace.id)
            XCTAssertEqual(diagnostics.attemptCount, 2)
            let saved = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: manager.workspaceFileURL(for: workspace)
            )
            XCTAssertEqual(saved.currentPromptText, "newer state")
            XCTAssertEqual(
                manager.debugLastSavedVersionForWorkspace(workspace.id),
                manager.debugStateVersionForWorkspace(workspace.id)
            )
        }

        func testPreparationFailureDoesNotAdvanceLastSavedVersion() async throws {
            let storageRoot = try temporaryDirectory(named: "Failure")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let blockingFile = storageRoot.appendingPathComponent("not-a-directory")
            try Data("block".utf8).write(to: blockingFile)
            let composition = makeComposition(windowID: -984)
            let manager = composition.workspaceManager
            try await manager.awaitInitialized(timeout: .seconds(60))
            let workspace = makeWorkspace(name: "Failure", storage: blockingFile)
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            manager.markWorkspaceDirty()

            await manager.pollAndSaveStateAsync()

            XCTAssertGreaterThan(manager.debugStateVersionForWorkspace(workspace.id), 0)
            XCTAssertNil(manager.debugLastSavedVersionForWorkspace(workspace.id))
        }

        func testQuiescentCapturePublishesWorkspaceOnceWithoutReloadingComposeTabs() async throws {
            let storageRoot = try temporaryDirectory(named: "Publication")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let composition = makeComposition(windowID: -985)
            let manager = composition.workspaceManager
            try await manager.awaitInitialized(timeout: .seconds(60))
            let workspace = makeWorkspace(name: "Publication", storage: storageRoot.appendingPathComponent("Publication"))
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            manager.markWorkspaceDirty()
            manager.resetWorkspaceSaveDiagnosticsForTesting()

            await manager.pollAndSaveStateAsync()

            let diagnostics = manager.workspaceSaveDiagnosticsForTesting(workspaceID: workspace.id)
            XCTAssertEqual(diagnostics.capturePublicationCount, 1)
            XCTAssertEqual(diagnostics.composeTabReloadCount, 0)
        }

        // MARK: - Ephemeral workspaces

        /// `isEphemeral` stops automatic workspace-document persistence on the poll and mutation save paths.
        func testEphemeralWorkspaceAutoAndDirectSavesWriteNoWorkspaceDocument() async throws {
            let storageRoot = try temporaryDirectory(named: "Ephemeral")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let composition = makeComposition(windowID: -986)
            let manager = composition.workspaceManager
            try await manager.awaitInitialized(timeout: .seconds(60))
            let workspaceStorage = storageRoot.appendingPathComponent("Ephemeral")
            var workspace = makeWorkspace(name: "Ephemeral", storage: workspaceStorage)
            workspace.isEphemeral = true
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            manager.markWorkspaceDirty()

            await manager.pollAndSaveStateAsync()
            let directURL = try await manager.saveWorkspaceToFileAsync(workspace, source: .directUnknown)
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: directURL)

            XCTAssertEqual(directURL, manager.workspaceFileURL(for: workspace))
            let contents = (try? FileManager.default.subpathsOfDirectory(atPath: workspaceStorage.path)) ?? []
            XCTAssertFalse(FileManager.default.fileExists(atPath: directURL.path), "contents: \(contents)")
            XCTAssertNil(manager.debugLastSavedVersionForWorkspace(workspace.id))
        }

        /// Switching away from an unpersisted ephemeral workspace still captures its live state into the
        /// in-memory model, and switching back restores that model (there is no document to reload from).
        func testSwitchingAwayFromEphemeralWorkspaceAndBackKeepsInMemoryState() async throws {
            let storageRoot = try temporaryDirectory(named: "EphemeralSwitch")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let composition = makeComposition(windowID: -990)
            let manager = composition.workspaceManager
            try await manager.awaitInitialized(timeout: .seconds(60))
            var ephemeral = makeWorkspace(name: "EphemeralSwitch", storage: storageRoot.appendingPathComponent("Ephemeral"))
            ephemeral.isEphemeral = true
            let other = makeWorkspace(name: "Other", storage: storageRoot.appendingPathComponent("Other"))
            manager.workspaces.append(contentsOf: [ephemeral, other])
            let ephemeralURL = manager.workspaceFileURL(for: ephemeral)

            let toEphemeral = await manager.switchWorkspace(to: ephemeral, saveState: false)
            XCTAssertTrue(toEphemeral.didSwitch)
            manager.promptViewModel.promptText = "ephemeral draft"
            manager.markWorkspaceDirty()

            let toOther = await manager.switchWorkspace(to: other, saveState: true)
            XCTAssertTrue(toOther.didSwitch)
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: ephemeralURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ephemeralURL.path))
            XCTAssertEqual(manager.workspaces.first { $0.id == ephemeral.id }?.currentPromptText, "ephemeral draft")

            let backToEphemeral = await manager.switchWorkspace(to: ephemeral, saveState: true)
            XCTAssertTrue(backToEphemeral.didSwitch)
            XCTAssertEqual(manager.activeWorkspaceID, ephemeral.id)
            XCTAssertEqual(manager.activeWorkspace?.isEphemeral, true)
            XCTAssertEqual(manager.activeWorkspace?.currentPromptText, "ephemeral draft")
            XCTAssertEqual(manager.promptViewModel.promptText, "ephemeral draft")
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: ephemeralURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ephemeralURL.path))
        }

        /// A workspace marked ephemeral while a save is in flight is rechecked before commit.
        func testSaveSkipsCommitWhenWorkspaceBecomesEphemeralAfterPreparation() async throws {
            let storageRoot = try temporaryDirectory(named: "BecomesEphemeral")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let composition = makeComposition(windowID: -987)
            let manager = composition.workspaceManager
            try await manager.awaitInitialized(timeout: .seconds(60))
            let workspace = makeWorkspace(name: "BecomesEphemeral", storage: storageRoot.appendingPathComponent("BecomesEphemeral"))
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            manager.markWorkspaceDirty()
            let expectedURL = manager.workspaceFileURL(for: workspace)

            let gate = WorkspaceSavePreparationGate()
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { workspaceID, fileURL, _ in
                await gate.arriveAndWait(workspaceID: workspaceID, fileURL: fileURL)
            }
            let saveTask = Task { @MainActor in
                await manager.pollAndSaveStateAsync()
            }
            _ = await gate.waitUntilArrived()
            let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspace.id })
            manager.workspaces[index].isEphemeral = true
            await gate.release()
            await saveTask.value
            manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: expectedURL)

            XCTAssertFalse(FileManager.default.fileExists(atPath: expectedURL.path))
            XCTAssertNil(manager.debugLastSavedVersionForWorkspace(workspace.id))
        }

        /// The URL command can flag an existing, already-persisted workspace ephemeral; that workspace
        /// keeps saving so pending and later edits are not dropped.
        func testPersistedWorkspaceFlaggedEphemeralKeepsSaving() async throws {
            let storageRoot = try temporaryDirectory(named: "PersistedThenEphemeral")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let composition = makeComposition(windowID: -989)
            let manager = composition.workspaceManager
            try await manager.awaitInitialized(timeout: .seconds(60))
            let workspace = makeWorkspace(name: "PersistedThenEphemeral", storage: storageRoot.appendingPathComponent("Persisted"))
            manager.workspaces.append(workspace)
            let switchResult = await manager.switchWorkspace(to: workspace, saveState: false)
            XCTAssertTrue(switchResult.didSwitch)
            manager.markWorkspaceDirty()
            await manager.pollAndSaveStateAsync()
            let fileURL = manager.workspaceFileURL(for: workspace)
            XCTAssertFalse(try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: fileURL).isEphemeral)

            let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspace.id })
            manager.workspaces[index].isEphemeral = true
            manager.markWorkspaceDirty()
            await manager.pollAndSaveStateAsync()

            // The second save committed: the document now carries the post-flag state.
            let saved = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: fileURL)
            XCTAssertTrue(saved.isEphemeral)
            XCTAssertEqual(
                manager.debugLastSavedVersionForWorkspace(workspace.id),
                manager.debugStateVersionForWorkspace(workspace.id)
            )
        }

        /// Promotion clears the flag and then persists the workspace document normally.
        func testPromotingEphemeralWorkspacePersistsItsDocument() async throws {
            let storageRoot = try temporaryDirectory(named: "Promotion")
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let composition = makeComposition(windowID: -988)
            let manager = composition.workspaceManager
            try await manager.awaitInitialized(timeout: .seconds(60))
            let workspace = manager.createEphemeralWorkspace(name: "Promoted", repoPaths: [])
            let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspace.id })
            manager.workspaces[index].customStoragePath = storageRoot.appendingPathComponent("Promoted")
            let fileURL = manager.workspaceFileURL(for: manager.workspaces[index])
            XCTAssertTrue(manager.workspaces[index].isEphemeral)

            await manager.setWorkspaceEphemeral(workspace.id, false)

            let saved = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: fileURL)
            XCTAssertEqual(saved.id, workspace.id)
            XCTAssertFalse(saved.isEphemeral)
            XCTAssertEqual(manager.workspaces.first { $0.id == workspace.id }?.isEphemeral, false)
        }

        private func makeComposition(windowID: Int) -> WindowStateComposition {
            WindowStateCompositionFactory.make(
                windowID: windowID,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                workspaceFileContextStore: WorkspaceFileContextStore()
            )
        }

        private func makeWorkspace(name: String, storage: URL) -> WorkspaceModel {
            let tab = ComposeTabState(name: name)
            return WorkspaceModel(
                name: name,
                repoPaths: [],
                customStoragePath: storage,
                composeTabs: [tab],
                activeComposeTabID: tab.id
            )
        }

        private func temporaryDirectory(named name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceSavePreparationTests-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    private actor WorkspaceSavePreparationGate {
        struct Arrival {
            let workspaceID: UUID
            let fileURL: URL
        }

        private var arrival: Arrival?
        private var arrivalWaiters: [CheckedContinuation<Arrival, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func arriveAndWait(workspaceID: UUID, fileURL: URL) async {
            let value = Arrival(workspaceID: workspaceID, fileURL: fileURL)
            arrival = value
            arrivalWaiters.forEach { $0.resume(returning: value) }
            arrivalWaiters.removeAll()
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilArrived() async -> Arrival {
            if let arrival { return arrival }
            return await withCheckedContinuation { continuation in
                arrivalWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

#endif
