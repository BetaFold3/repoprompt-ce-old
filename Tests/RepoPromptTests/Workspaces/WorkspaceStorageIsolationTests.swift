@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

#if DEBUG
    /// Workspace storage isolation: the shared `Workspaces` root resolver keeps test processes off the
    /// live store, and Agent session metadata reads never create storage for a workspace that has
    /// never saved a session. Every check of the live store is read-only and tolerates its absence.
    final class WorkspaceStorageIsolationTests: XCTestCase {
        private struct StorageReference: AgentWorkspaceStorageReference {
            let id: UUID
            let name: String
            let customStoragePath: URL?
        }

        private var scratchRoot: URL!

        override func setUpWithError() throws {
            try super.setUpWithError()
            scratchRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceStorageIsolationTests-\(UUID().uuidString)", isDirectory: true)
        }

        override func tearDownWithError() throws {
            if let scratchRoot {
                try? FileManager.default.removeItem(at: scratchRoot)
            }
            try super.tearDownWithError()
        }

        // MARK: - Resolver

        func testResolverAppliesInjectedThenOverrideThenXCTestThenProductionPrecedence() {
            let injected = URL(fileURLWithPath: "/tmp/injected-root", isDirectory: true)
            let xctest = URL(fileURLWithPath: "/tmp/xctest-root", isDirectory: true)
            let production = URL(fileURLWithPath: "/tmp/production-root", isDirectory: true)
            let override = ["RPCE_WORKSPACES_ROOT_OVERRIDE": "/tmp/override-root"]
            let relativeOverride = ["RPCE_WORKSPACES_ROOT_OVERRIDE": "relative/root"]

            let cases: [(label: String, injected: URL?, env: [String: String], allowed: Bool, xctestProcess: Bool, expected: WorkspaceStorageRoot.Source, path: String)] = [
                ("injected beats every other source", injected, override, true, true, .injected, "/tmp/injected-root"),
                ("override honored when allowed", nil, override, true, false, .environmentOverride, "/tmp/override-root"),
                ("override honored under XCTest even when not allowed", nil, override, false, true, .environmentOverride, "/tmp/override-root"),
                ("override ignored in a release app", nil, override, false, false, .production, "/tmp/production-root"),
                ("relative override ignored", nil, relativeOverride, true, true, .xctestTemporary, "/tmp/xctest-root"),
                ("XCTest without override uses the temporary root", nil, [:], true, true, .xctestTemporary, "/tmp/xctest-root"),
                ("app without override uses production", nil, [:], true, false, .production, "/tmp/production-root")
            ]
            for testCase in cases {
                let resolution = WorkspaceStorageRoot.resolve(
                    injected: testCase.injected,
                    environment: testCase.env,
                    environmentOverrideAllowed: testCase.allowed,
                    isRunningUnderXCTest: testCase.xctestProcess,
                    xctestTemporaryRoot: xctest,
                    productionRoot: production
                )
                XCTAssertEqual(resolution.source, testCase.expected, testCase.label)
                XCTAssertEqual(resolution.url.path, testCase.path, testCase.label)
            }
        }

        func testDefaultRootUnderXCTestIsOneStableRootOffTheLiveStore() {
            let first = WorkspaceStorageRoot.resolve()
            let second = WorkspaceStorageRoot.resolve()
            XCTAssertEqual(first, second)
            XCTAssertEqual(WorkspaceStorageRoot.defaultRootURL, first.url)
            XCTAssertEqual(WorkspaceStoragePaths.defaultRoot, first.url)
            if ProcessInfo.processInfo.environment[WorkspaceStorageRoot.environmentOverrideKey] == nil {
                XCTAssertEqual(first.source, .xctestTemporary)
                XCTAssertEqual(first.url, WorkspaceStorageRoot.xctestTemporaryRootURL)
            }
            XCTAssertFalse(
                isInside(first.url, WorkspaceStorageRoot.productionRootURL()),
                "Test-process workspace storage must never resolve into the live store: \(first.url.path)"
            )
        }

        // MARK: - Global custom storage location

        func testGlobalCustomLocationSourceIsProcessLocalUnderXCTestAndPersistedInTheApp() {
            func resolve(xctest: Bool, processLocal: String?, persisted: String?) -> String? {
                WorkspaceGlobalCustomStorageLocation.resolve(
                    isRunningUnderXCTest: xctest,
                    processLocalPath: processLocal,
                    persistedPath: persisted
                )?.path
            }
            let real = "/Users/someone/RealCustomStore"
            XCTAssertNil(
                resolve(xctest: true, processLocal: nil, persisted: real),
                "Under XCTest a persisted (user or leaked) location must never be read"
            )
            XCTAssertEqual(resolve(xctest: true, processLocal: "/tmp/test-chosen", persisted: real), "/tmp/test-chosen")
            XCTAssertEqual(resolve(xctest: false, processLocal: "/tmp/test-chosen", persisted: real), real)
            XCTAssertNil(resolve(xctest: false, processLocal: nil, persisted: nil))
        }

        /// Canary: a global custom location persisted in this process's user defaults (a real user
        /// setting, or one leaked by an interrupted test into the shared xctest domain) must not
        /// redirect a test-built workspace manager, and a test-chosen location must not persist.
        @MainActor
        func testWorkspaceManagerIgnoresPersistedGlobalCustomLocationUnderXCTest() async throws {
            let defaults = UserDefaults.standard
            let key = WorkspaceGlobalCustomStorageLocation.defaultsKey
            let previousPersisted = defaults.object(forKey: key)
            let previousProcessLocal = WorkspaceGlobalCustomStorageLocation.load()
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            let foreign = scratchRoot.appendingPathComponent("ForeignCustomStore", isDirectory: true)
            defaults.set(foreign.path, forKey: key)
            WorkspaceGlobalCustomStorageLocation.store(nil)
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer {
                if let previousPersisted {
                    defaults.set(previousPersisted, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
                WorkspaceGlobalCustomStorageLocation.store(previousProcessLocal)
                GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            }

            let composition = WindowStateCompositionFactory.make(
                windowID: -1290,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                workspaceFileContextStore: WorkspaceFileContextStore()
            )
            let manager = composition.workspaceManager
            try await manager.awaitInitialized(timeout: .seconds(60))

            XCTAssertNil(manager.globalCustomStorageURL)
            XCTAssertEqual(WorkspaceManagerViewModel.recoveryInventoryBaseRoot(), WorkspaceStoragePaths.defaultRoot)

            let chosen = scratchRoot.appendingPathComponent("TestChosenStore", isDirectory: true)
            manager.globalCustomStorageURL = chosen
            // The location round-trips as a path (as it always has through user defaults).
            XCTAssertEqual(WorkspaceGlobalCustomStorageLocation.load()?.path, chosen.path)
            XCTAssertEqual(WorkspaceManagerViewModel.recoveryInventoryBaseRoot().path, chosen.path)
            manager.globalCustomStorageURL = nil
            XCTAssertNil(WorkspaceGlobalCustomStorageLocation.load())
            XCTAssertEqual(defaults.string(forKey: key), foreign.path, "A test-chosen location must not reach user defaults")
            XCTAssertFalse(FileManager.default.fileExists(atPath: foreign.path))
        }

        func testStaleXCTestRootSweepRemovesOnlyOldRootsOfDeadProcesses() throws {
            let fm = FileManager.default
            let container = scratchRoot.appendingPathComponent("RepoPromptCE-XCTest", isDirectory: true)
            try fm.createDirectory(at: container, withIntermediateDirectories: true)
            let now = Date()
            let old = now.addingTimeInterval(-(WorkspaceStorageRoot.staleXCTestRootAge + 3600))
            let deadPID: Int32 = 900_001
            let livePID: Int32 = 900_002
            func makeEntry(_ name: String, modified: Date, isDirectory: Bool = true) throws -> URL {
                let url = container.appendingPathComponent(name, isDirectory: isDirectory)
                if isDirectory {
                    try fm.createDirectory(at: url.appendingPathComponent("Workspace-x"), withIntermediateDirectories: true)
                } else {
                    try Data("x".utf8).write(to: url)
                }
                try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
                return url
            }
            let staleDead = try makeEntry("Workspaces-\(deadPID)-\(UUID().uuidString)", modified: old)
            let staleLive = try makeEntry("Workspaces-\(livePID)-\(UUID().uuidString)", modified: old)
            let recentDead = try makeEntry("Workspaces-\(deadPID)-\(UUID().uuidString)", modified: now)
            let otherFixture = try makeEntry("AgentRecovery-\(UUID().uuidString)", modified: old)
            let malformed = try makeEntry("Workspaces-\(deadPID)-not-a-uuid", modified: old)
            let staleFile = try makeEntry("Workspaces-\(deadPID)-\(UUID().uuidString)", modified: old, isDirectory: false)
            let isAlive: (Int32) -> Bool = { $0 == livePID }

            let removed = WorkspaceStorageRoot.removeStaleXCTestRoots(in: container, now: now, isProcessAlive: isAlive)

            XCTAssertEqual(removed.map(\.lastPathComponent), [staleDead.lastPathComponent])
            XCTAssertFalse(fm.fileExists(atPath: staleDead.path))
            for kept in [staleLive, recentDead, otherFixture, malformed, staleFile] {
                XCTAssertTrue(fm.fileExists(atPath: kept.path), kept.lastPathComponent)
            }

            // Any container not named RepoPromptCE-XCTest is never swept.
            let foreign = scratchRoot.appendingPathComponent("Elsewhere", isDirectory: true)
            try fm.createDirectory(at: foreign, withIntermediateDirectories: true)
            let foreignRoot = foreign.appendingPathComponent("Workspaces-\(deadPID)-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: foreignRoot.path)
            XCTAssertTrue(WorkspaceStorageRoot.removeStaleXCTestRoots(in: foreign, now: now, isProcessAlive: isAlive).isEmpty)
            XCTAssertTrue(fm.fileExists(atPath: foreignRoot.path))

            XCTAssertTrue(WorkspaceStorageRoot.isProcessAlive(ProcessInfo.processInfo.processIdentifier))
        }

        // MARK: - Agent session metadata reads

        func testMetadataReadsForNeverWrittenWorkspaceCreateNoStorage() async throws {
            let workspacesRoot = scratchRoot.appendingPathComponent("Workspaces", isDirectory: true)
            let service = makeService(workspacesRoot: workspacesRoot)
            let workspace = StorageReference(id: UUID(), name: "Never Written", customStoragePath: nil)

            let meta = try await service.listAgentSessionsMeta(for: workspace)
            let limitedMeta = try await service.listAgentSessionsMeta(for: workspace, limit: 5)
            let recent = try await service.recentSessions(for: workspace)
            let indexed = try await service.indexedAgentSessionMetadataRecords(for: workspace)
            let sidebar = try await service.sidebarStreamMetadataRecords(for: workspace)
            let fast = try await service.fastMetadataRecordsIfAvailable(for: workspace)
            let files = try await service.listAgentSessions(for: workspace)
            let loaded = try await service.loadAgentSession(id: UUID(), for: workspace)
            let record = try await service.metadataRecordForSessionID(UUID(), for: workspace)
            let candidates = try await service.deletionCandidates(forComposeTabID: UUID(), for: workspace)
            try await service.deleteAgentSessions(forComposeTabID: UUID(), for: workspace)

            XCTAssertTrue(meta.isEmpty)
            XCTAssertTrue(limitedMeta.isEmpty)
            XCTAssertTrue(recent.isEmpty)
            XCTAssertTrue(indexed.isEmpty)
            XCTAssertTrue(sidebar.isEmpty)
            XCTAssertNil(fast)
            XCTAssertTrue(files.isEmpty)
            XCTAssertNil(loaded)
            XCTAssertNil(record)
            XCTAssertTrue(candidates.isEmpty)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: workspacesRoot.path),
                "Reads must not create the workspaces root, the workspace folder, or an index"
            )
            let sessionsFolder = workspacesRoot
                .appendingPathComponent(WorkspaceDirectoryName.directoryName(name: workspace.name, id: workspace.id))
                .appendingPathComponent("AgentSessions")
            let scheduled = await service.test_isMetadataIndexReconciliationScheduled(forAgentSessionsFolder: sessionsFolder)
            XCTAssertFalse(scheduled)
        }

        func testRebuildOfExistingEmptyFolderWritesNoIndexUntilASessionIsSaved() async throws {
            let workspacesRoot = scratchRoot.appendingPathComponent("Workspaces", isDirectory: true)
            let service = makeService(workspacesRoot: workspacesRoot)
            let workspace = StorageReference(id: UUID(), name: "Empty Folder", customStoragePath: nil)
            let sessionsFolder = workspacesRoot
                .appendingPathComponent(WorkspaceDirectoryName.directoryName(name: workspace.name, id: workspace.id))
                .appendingPathComponent("AgentSessions")
            try FileManager.default.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
            let indexURL = sessionsFolder.appendingPathComponent("AgentSessionIndex.json")

            let before = try await service.listAgentSessionsMeta(for: workspace)
            XCTAssertTrue(before.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path), "An empty index describes nothing")

            let sessionID = UUID()
            _ = try await service.prepareInitialAgentSessionPersistence(
                initialSession: AgentSession(id: sessionID, workspaceID: workspace.id, name: "Saved"),
                for: workspace
            )
            let after = try await service.listAgentSessionsMeta(for: workspace)
            XCTAssertEqual(after.map(\.id), [sessionID])
        }

        func testSessionWriterCreatesWorkspaceStorageUnderTheResolvedRoot() async throws {
            let workspacesRoot = scratchRoot.appendingPathComponent("Workspaces", isDirectory: true)
            let service = makeService(workspacesRoot: workspacesRoot)
            let workspace = StorageReference(id: UUID(), name: "Writer", customStoragePath: nil)
            let sessionID = UUID()

            _ = try await service.prepareInitialAgentSessionPersistence(
                initialSession: AgentSession(id: sessionID, workspaceID: workspace.id, name: "Written"),
                for: workspace
            )

            let expectedFile = workspacesRoot
                .appendingPathComponent(WorkspaceDirectoryName.directoryName(name: workspace.name, id: workspace.id))
                .appendingPathComponent("AgentSessions")
                .appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
            let listed = try await service.listAgentSessionsMeta(for: workspace)
            XCTAssertEqual(listed.map(\.id), [sessionID])
        }

        /// Reintroduction canary: a default-constructed service (as the leaking suites use) reads and
        /// writes a default-path workspace without creating its directory in the live store.
        func testDefaultServiceNeverCreatesWorkspaceDirectoriesInTheLiveStore() async throws {
            let service = AgentSessionDataService()
            let workspace = StorageReference(id: UUID(), name: "Leak Canary", customStoragePath: nil)
            let directoryName = WorkspaceDirectoryName.directoryName(name: workspace.name, id: workspace.id)
            let isolatedWorkspaceFolder = WorkspaceStorageRoot.defaultRootURL.appendingPathComponent(directoryName)
            defer { try? FileManager.default.removeItem(at: isolatedWorkspaceFolder) }

            _ = try await service.listAgentSessionsMeta(for: workspace)
            _ = try await service.sidebarStreamMetadataRecords(for: workspace)
            let sessionID = UUID()
            _ = try await service.prepareInitialAgentSessionPersistence(
                initialSession: AgentSession(id: sessionID, workspaceID: workspace.id, name: "Canary"),
                for: workspace
            )

            let files = try await service.listAgentSessions(for: workspace)
            XCTAssertEqual(files.map(\.lastPathComponent), ["AgentSession-\(sessionID.uuidString).json"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: isolatedWorkspaceFolder.path))
            let liveWorkspaceFolder = WorkspaceStorageRoot.productionRootURL().appendingPathComponent(directoryName)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: liveWorkspaceFolder.path),
                "A test process created \(liveWorkspaceFolder.path) in the live store"
            )
        }

        // MARK: - Helpers

        private func makeService(workspacesRoot: URL) -> AgentSessionDataService {
            AgentSessionDataService(
                tombstoneRoot: scratchRoot.appendingPathComponent("AgentRecovery/v1/tombstones", isDirectory: true),
                workspacesRoot: workspacesRoot
            )
        }

        private func isInside(_ url: URL, _ root: URL) -> Bool {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }
#endif
