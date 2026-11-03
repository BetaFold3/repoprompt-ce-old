import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class HistorySessionScannerTests: XCTestCase {
    // MARK: - Test Infrastructure

    private var tempDir: URL!
    private var workspacesRoot: URL!
    private var scanner: HistorySessionScanner!
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistorySessionScannerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        workspacesRoot = tempDir.appendingPathComponent("Workspaces", isDirectory: true)
        scanner = HistorySessionScanner(workspacesRoot: workspacesRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Workspace Discovery

    func testScanAllWorkspaces_noWorkspacesDir_returnsEmpty() async throws {
        let results = try await scanner.scanAllWorkspaces()
        XCTAssertTrue(results.isEmpty)
    }

    func testScanAllWorkspaces_emptyWorkspacesDir_returnsEmpty() async throws {
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        let results = try await scanner.scanAllWorkspaces()
        XCTAssertTrue(results.isEmpty)
    }

    func testScanAllWorkspaces_skipsHiddenDirectories() async throws {
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        let hiddenDir = workspacesRoot.appendingPathComponent(".hiddenWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertTrue(results.isEmpty)
    }

    func testScanAllWorkspaces_discoversSingleWorkspace() async throws {
        let wsDir = try createWorkspaceDir(name: "MyProject", uuid: UUID())
        try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord()])

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].workspaceName, "MyProject")
        XCTAssertEqual(results[0].records.count, 1)
        XCTAssertFalse(results[0].indexReadFailed)
    }

    func testScanAllWorkspaces_discoversMultipleWorkspaces() async throws {
        let ws1 = try createWorkspaceDir(name: "ProjectA", uuid: UUID())
        let ws2 = try createWorkspaceDir(name: "ProjectB", uuid: UUID())
        try createAgentSessionsIndex(in: ws1, records: [makeMinimalRecord(name: "Session1")])
        try createAgentSessionsIndex(in: ws2, records: [makeMinimalRecord(name: "Session2"), makeMinimalRecord(name: "Session3")])

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 2)

        let totalRecords = results.reduce(0) { $0 + $1.records.count }
        XCTAssertEqual(totalRecords, 3)
    }

    func testScanAllWorkspaces_cacheInvalidatesChangedIndexAfterTTL() async throws {
        scanner = HistorySessionScanner(workspacesRoot: workspacesRoot, scanCacheTTL: 0)
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let first = makeMinimalRecord(name: "First")
        try createAgentSessionsIndex(in: wsDir, records: [first])

        var results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.records.map(\.name), ["First"])

        let second = makeMinimalRecord(name: "Second")
        try createAgentSessionsIndex(in: wsDir, records: [first, second])
        let indexFile = wsDir
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("AgentSessionIndex.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: indexFile.path
        )

        results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.records.map(\.name), ["First", "Second"])
    }

    func testScanAllWorkspaces_workspaceWithoutAgentSessionsDir() async throws {
        _ = try createWorkspaceDir(name: "EmptyProject", uuid: UUID())
        // No AgentSessions directory created

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].records.isEmpty)
        XCTAssertFalse(results[0].indexReadFailed)
    }

    func testScanAllWorkspaces_workspaceWithoutIndexFile() async throws {
        let wsDir = try createWorkspaceDir(name: "NoIndex", uuid: UUID())
        let agentSessions = wsDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)
        // No AgentSessionIndex.json created

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].records.isEmpty)
        XCTAssertFalse(results[0].indexReadFailed)
    }

    func testScanAllWorkspaces_corruptIndexFile_reportsReadFailed() async throws {
        let wsDir = try createWorkspaceDir(name: "Corrupt", uuid: UUID())
        let agentSessions = wsDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)
        let indexFile = agentSessions.appendingPathComponent("AgentSessionIndex.json")
        try Data("{ invalid json".utf8).write(to: indexFile)

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].records.isEmpty)
        XCTAssertTrue(results[0].indexReadFailed)
    }

    // MARK: - Workspace Name Resolution

    func testWorkspaceNameResolution_fromWorkspaceJSON() async throws {
        let wsUUID = UUID()
        let wsDir = try createWorkspaceDir(name: "MyProject", uuid: wsUUID)
        try writeWorkspaceJSON(in: wsDir, name: "Canonical Name", id: wsUUID)
        try createAgentSessionsIndex(in: wsDir, records: [])

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].workspaceName, "Canonical Name")
        XCTAssertEqual(results[0].workspaceID, wsUUID)
    }

    func testWorkspaceNameResolution_fromDirNameWithoutJSON() async throws {
        let wsUUID = UUID()
        let wsDir = try createWorkspaceDir(name: "MyProject", uuid: wsUUID)
        // No workspace.json — name parsed from directory name
        try createAgentSessionsIndex(in: wsDir, records: [])

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].workspaceName, "MyProject")
        XCTAssertEqual(results[0].workspaceID, wsUUID)
    }

    func testWorkspaceNameResolution_dirNameWithoutUUID() async throws {
        let wsDir = try XCTUnwrap(workspacesRoot?.appendingPathComponent("Workspace-SimpleName", isDirectory: true))
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        try createAgentSessionsIndex(in: wsDir, records: [])

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].workspaceName, "SimpleName")
        XCTAssertNil(results[0].workspaceID)
    }

    func testWorkspaceNameResolution_nonStandardDirName() async throws {
        let wsDir = try XCTUnwrap(workspacesRoot?.appendingPathComponent("CustomDirectoryName", isDirectory: true))
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        try createAgentSessionsIndex(in: wsDir, records: [])

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].workspaceName, "CustomDirectoryName")
        XCTAssertNil(results[0].workspaceID)
    }

    // MARK: - Metadata Filtering

    func testSessionsMatchingFilters_noFilters_returnsAll() async throws {
        let ws1 = try createWorkspaceDir(name: "ProjectA", uuid: UUID())
        let ws2 = try createWorkspaceDir(name: "ProjectB", uuid: UUID())
        let r1 = makeMinimalRecord(name: "Session1", agentKindRaw: "claudeCode")
        let r2 = makeMinimalRecord(name: "Session2", agentKindRaw: "codexExec")
        let r3 = makeMinimalRecord(name: "Session3", agentKindRaw: "claudeCode")
        try createAgentSessionsIndex(in: ws1, records: [r1, r2])
        try createAgentSessionsIndex(in: ws2, records: [r3])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = try scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: nil, filePath: nil, from: nil, to: nil)

        XCTAssertEqual(filtered.count, 3)
    }

    func testSessionsMatchingFilters_byWorkspaceName() async throws {
        let ws1 = try createWorkspaceDir(name: "ProjectA", uuid: UUID())
        let ws2 = try createWorkspaceDir(name: "ProjectB", uuid: UUID())
        let r1 = makeMinimalRecord(name: "Session1")
        let r2 = makeMinimalRecord(name: "Session2")
        try createAgentSessionsIndex(in: ws1, records: [r1])
        try createAgentSessionsIndex(in: ws2, records: [r2])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = try scanner.sessionsMatchingFilters(scanResults, workspace: "projecta", agentKind: nil, model: nil, filePath: nil, from: nil, to: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r1.id)
    }

    func testSessionsMatchingFilters_byWorkspaceStorageDirectoryName() async throws {
        let wsUUID = UUID()
        let ws1 = try createWorkspaceDir(name: "RepoPromptCE", uuid: wsUUID)
        let ws2 = try createWorkspaceDir(name: "OtherProject", uuid: UUID())
        let r1 = makeMinimalRecord(name: "Session1")
        let r2 = makeMinimalRecord(name: "Session2")
        try createAgentSessionsIndex(in: ws1, records: [r1])
        try createAgentSessionsIndex(in: ws2, records: [r2])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = try scanner.sessionsMatchingFilters(
            scanResults,
            workspace: "Workspace-RepoPromptCE-",
            agentKind: nil,
            model: nil,
            filePath: nil,
            from: nil,
            to: nil
        )

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r1.id)
    }

    func testSessionsMatchingFilters_byWorkspaceUUID() async throws {
        let wsUUID = UUID()
        let ws1 = try createWorkspaceDir(name: "ProjectA", uuid: wsUUID)
        let ws2 = try createWorkspaceDir(name: "ProjectB", uuid: UUID())
        let r1 = makeMinimalRecord(name: "Session1")
        let r2 = makeMinimalRecord(name: "Session2")
        try createAgentSessionsIndex(in: ws1, records: [r1])
        try createAgentSessionsIndex(in: ws2, records: [r2])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = try scanner.sessionsMatchingFilters(scanResults, workspace: wsUUID.uuidString, agentKind: nil, model: nil, filePath: nil, from: nil, to: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r1.id)
    }

    func testSessionsMatchingFilters_byAgentKind() async throws {
        let ws = try createWorkspaceDir(name: "Project", uuid: UUID())
        let r1 = makeMinimalRecord(name: "Session1", agentKindRaw: "claudeCode")
        let r2 = makeMinimalRecord(name: "Session2", agentKindRaw: "codexExec")
        let r3 = makeMinimalRecord(name: "Session3", agentKindRaw: nil)
        try createAgentSessionsIndex(in: ws, records: [r1, r2, r3])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = try scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: "claude", model: nil, filePath: nil, from: nil, to: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r1.id)
    }

    func testSessionsMatchingFilters_byModel() async throws {
        let ws = try createWorkspaceDir(name: "Project", uuid: UUID())
        let r1 = makeMinimalRecord(name: "S1", agentModelRaw: "claude-sonnet-4-20250514")
        let r2 = makeMinimalRecord(name: "S2", agentModelRaw: "claude-opus-4-20250116")
        let r3 = makeMinimalRecord(name: "S3", agentModelRaw: nil)
        try createAgentSessionsIndex(in: ws, records: [r1, r2, r3])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = try scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: "opus", filePath: nil, from: nil, to: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r2.id)
    }

    func testSessionsMatchingFilters_byFilePath() async throws {
        let ws = try createWorkspaceDir(name: "Project", uuid: UUID())
        let r1 = makeMinimalRecord(name: "S1", keyPaths: ["src/main.swift", "lib/utils.swift"])
        let r2 = makeMinimalRecord(name: "S2", keyPaths: ["docs/README.md"])
        let r3 = makeMinimalRecord(name: "S3", keyPaths: [])
        try createAgentSessionsIndex(in: ws, records: [r1, r2, r3])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = try scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: nil, filePath: "main.swift", from: nil, to: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r1.id)
    }

    func testSessionsMatchingFilters_filePathCaseInsensitive() async throws {
        let ws = try createWorkspaceDir(name: "Project", uuid: UUID())
        let r1 = makeMinimalRecord(name: "S1", keyPaths: ["Sources/Main.swift"])
        try createAgentSessionsIndex(in: ws, records: [r1])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = try scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: nil, filePath: "main.SWIFT", from: nil, to: nil)

        XCTAssertEqual(filtered.count, 1)
    }

    func testSessionsMatchingFilters_byDateRange() async throws {
        let ws = try createWorkspaceDir(name: "Project", uuid: UUID())
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let r1 = makeMinimalRecord(name: "S1", savedAt: epoch)
        let r2 = makeMinimalRecord(name: "S2", savedAt: epoch.addingTimeInterval(3600))
        let r3 = makeMinimalRecord(name: "S3", savedAt: epoch.addingTimeInterval(7200))
        try createAgentSessionsIndex(in: ws, records: [r1, r2, r3])

        let scanResults = try await scanner.scanAllWorkspaces()
        let from = epoch.addingTimeInterval(1800) // 30min in
        let to = epoch.addingTimeInterval(5400) // 90min in

        let filtered = try scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: nil, filePath: nil, from: from, to: to)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r2.id)
    }

    func testSessionsMatchingFilters_dateRangeUsesTranscriptBoundsNotSidebarDate() async throws {
        // firstActivityAt/lastActivityAt (transcript bounds) differ from activityDate
        // (lastUserMessageAt ?? savedAt). The filter must use the transcript bounds so it
        // agrees with the response's first_activity_at / last_activity_at fields.
        let ws = try createWorkspaceDir(name: "Project", uuid: UUID())
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let record = AgentSessionMetadataRecord(
            id: UUID(),
            filename: "AgentSession-bounds.json",
            workspaceID: nil,
            composeTabID: nil,
            name: "S1",
            savedAt: savedAt,
            lastUserMessageAt: nil, // → activityDate == savedAt
            itemCount: 1,
            transcriptProjectionCounts: nil,
            hasUnknownConversationContent: false,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            lastRunStateRaw: nil,
            autoEditEnabled: true,
            parentSessionID: nil,
            isMCPOriginated: false,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: nil,
            lastIndexedAt: savedAt,
            firstActivityAt: savedAt.addingTimeInterval(-300), // 5 min before savedAt
            lastActivityAt: savedAt.addingTimeInterval(-60), // 1 min before savedAt
            keyPaths: [],
            coveredTurnDurationSeconds: 0,
            toolCallCount: 0
        )
        try createAgentSessionsIndex(in: ws, records: [record])
        let scanResults = try await scanner.scanAllWorkspaces()

        // Window brackets the transcript activity bounds but excludes savedAt (the old
        // activityDate-based filter would drop this session).
        let from = try XCTUnwrap(record.firstActivityAt?.addingTimeInterval(-10))
        let to = try XCTUnwrap(record.lastActivityAt?.addingTimeInterval(10))
        let filtered = try scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: nil, filePath: nil, from: from, to: to)

        XCTAssertEqual(filtered.count, 1, "filter should use transcript activity bounds, not the sidebar date")
        XCTAssertEqual(filtered.first?.sessionID, record.id)
    }

    func testSessionsMatchingFilters_combinedFilters() async throws {
        let ws = try createWorkspaceDir(name: "Project", uuid: UUID())
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let r1 = makeMinimalRecord(name: "S1", agentKindRaw: "claudeCode", keyPaths: ["src/main.swift"], savedAt: epoch)
        let r2 = makeMinimalRecord(name: "S2", agentKindRaw: "claudeCode", keyPaths: ["docs/readme.md"], savedAt: epoch)
        let r3 = makeMinimalRecord(name: "S3", agentKindRaw: "codexExec", keyPaths: ["src/main.swift"], savedAt: epoch)
        try createAgentSessionsIndex(in: ws, records: [r1, r2, r3])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = try scanner.sessionsMatchingFilters(
            scanResults,
            workspace: nil,
            agentKind: "claudeCode",
            model: nil,
            filePath: "main.swift",
            from: nil,
            to: nil
        )

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r1.id)
    }

    func testSessionsMatchingFilters_emptyScanResults() throws {
        let filtered = try scanner.sessionsMatchingFilters(
            [],
            workspace: "anything",
            agentKind: nil,
            model: nil,
            filePath: nil,
            from: nil,
            to: nil
        )
        XCTAssertTrue(filtered.isEmpty)
    }

    // MARK: - Transcript Loading

    func testLoadTranscriptForSearch_validSession() async throws {
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionID = UUID()

        let turn = AgentTranscriptTurn(
            id: UUID(),
            summary: AgentTranscriptTurnSummary(
                requestText: "Fix the bug",
                conclusionText: nil,
                compactConclusionText: "Fixed the bug in main.swift",
                middleSummaryText: nil,
                toolCount: 2,
                notableToolNames: ["apply_edits"],
                keyPaths: ["src/main.swift"],
                compactedActivityCount: 0,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 200)
        )
        let transcript = AgentTranscript(turns: [turn])
        let session = AgentSession(
            id: sessionID,
            name: "Test Session",
            transcript: transcript,
            itemCount: 1
        )
        try writeSessionFile(session, in: wsDir)

        let loaded = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
        XCTAssertEqual(loaded.turns.count, 1)
        XCTAssertEqual(loaded.turns[0].summary?.keyPaths, ["src/main.swift"])
    }

    func testLoadTranscriptForSearch_missingFile_throwsError() async throws {
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionID = UUID()

        do {
            _ = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
            XCTFail("Expected error to be thrown")
        } catch let error as HistorySessionScannerError {
            if case .sessionFileNotFound = error {
                // Expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testLoadTranscriptForSearch_corruptFile_throwsError() async throws {
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionID = UUID()
        let agentSessions = wsDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)
        let file = agentSessions.appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
        try Data("{ bad".utf8).write(to: file)

        do {
            _ = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
            XCTFail("Expected error to be thrown")
        } catch let error as HistorySessionScannerError {
            if case .transcriptDecodingFailed = error {
                // Expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLoadTranscriptForSearch_sessionWithoutTranscript_returnsEmpty() async throws {
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionID = UUID()
        let session = AgentSession(
            id: sessionID,
            name: "Empty Session",
            transcript: nil,
            itemCount: 0
        )
        try writeSessionFile(session, in: wsDir)

        let loaded = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
        XCTAssertTrue(loaded.turns.isEmpty)
    }

    func testLoadTranscriptForSearch_cachesTranscriptAcrossCalls() async throws {
        // F5: a transcript decoded once is reused on the next load when the session
        // file is unchanged — the decode counter must not increment on the cache hit.
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionID = UUID()
        let session = AgentSession(
            id: sessionID,
            name: "S",
            transcript: AgentTranscript(turns: [AgentTranscriptTurn(startedAt: Date(timeIntervalSince1970: 1000))]),
            itemCount: 1
        )
        try writeSessionFile(session, in: wsDir)

        let first = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
        XCTAssertEqual(first.turns.count, 1)
        let decodedAfterFirst = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodedAfterFirst, 1)

        // Second load, file unchanged → served from the signature cache; no re-decode.
        let cached = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
        XCTAssertEqual(cached.turns.count, 1)
        let decodedAfterSecond = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodedAfterSecond, 1, "Unchanged file must hit the cache (no re-decode)")
    }

    func testLoadTranscriptForSearch_invalidatesCacheWhenSessionFileChanges() async throws {
        // F5: modifying the session file (size+mtime change) must invalidate the cache
        // and re-decode on the next load.
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionID = UUID()
        func writeTranscript(_ turnCount: Int) throws {
            let turns = (0 ..< turnCount).map { AgentTranscriptTurn(startedAt: Date(timeIntervalSince1970: 1000).addingTimeInterval(TimeInterval($0))) }
            try writeSessionFile(AgentSession(id: sessionID, name: "S", transcript: AgentTranscript(turns: turns), itemCount: turnCount), in: wsDir)
        }
        try writeTranscript(1)
        let first = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
        XCTAssertEqual(first.turns.count, 1)
        let decodedAfterFirst = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodedAfterFirst, 1)

        // Rewrite with more turns → different size+mtime → signature changes → re-decode.
        try writeTranscript(3)
        let refreshed = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
        XCTAssertEqual(refreshed.turns.count, 3, "Changed file must re-decode (cache invalidated)")
        let decodedAfterRefresh = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodedAfterRefresh, 2)
    }

    func testScanAllWorkspacesRefreshing_bypassesTTLCacheAndRepopulates() async throws {
        // F6 mechanism: `refreshWorkspacesContainingSession` re-reads the workspace that
        // holds a freshly-saved session, ignoring the TTL cache, while the cached scan
        // still hides it; the refresh splices it into the cache so later cached scans see
        // it too — all without a second full inventory scan.
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionA = UUID()
        try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord(id: sessionA, name: "A")])

        let cachedScanner = HistorySessionScanner(workspacesRoot: workspacesRoot, scanCacheTTL: 3600)
        _ = try await cachedScanner.scanAllWorkspaces() // warm the cache with [A]

        // App saves B: writes its file + updates the index.
        let sessionB = UUID()
        try writeSessionFile(AgentSession(id: sessionB, name: "B", transcript: nil, itemCount: 0), in: wsDir)
        try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord(id: sessionA, name: "A"), makeMinimalRecord(id: sessionB, name: "B")])

        let cachedIDs = try await Set(cachedScanner.scanAllWorkspaces().flatMap(\.records).map(\.id))
        XCTAssertFalse(cachedIDs.contains(sessionB), "Cached scan within TTL hides the freshly-saved session")

        let refreshedIDs = try await Set(cachedScanner.refreshWorkspacesContainingSession(sessionB).flatMap(\.records).map(\.id))
        XCTAssertTrue(refreshedIDs.contains(sessionB), "Refreshing scan bypasses the TTL and sees the freshly-saved session")

        let postRefreshCachedIDs = try await Set(cachedScanner.scanAllWorkspaces().flatMap(\.records).map(\.id))
        XCTAssertTrue(postRefreshCachedIDs.contains(sessionB), "Refreshing repopulates the cache so later cached scans see B")
        let inventoryScans = await cachedScanner.inventoryScanCountForTesting
        XCTAssertEqual(inventoryScans, 1, "Targeted refresh must not run another full inventory scan")
    }

    // MARK: - Cancellation

    func testAlreadyCancelledCalls_throwCancellationEvenWithWarmCaches() async throws {
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionID = UUID()
        try writeSessionFile(AgentSession(id: sessionID, name: "S", transcript: AgentTranscript(turns: []), itemCount: 0), in: wsDir)
        try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord(id: sessionID, name: "S")])
        let warmScanner = HistorySessionScanner(workspacesRoot: workspacesRoot, scanCacheTTL: 3600)
        let scanResults = try await warmScanner.scanAllWorkspaces()
        _ = try await warmScanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)

        let outcomes = await Task { () -> [String: Bool] in
            withUnsafeCurrentTask { $0?.cancel() }
            var threwCancellation: [String: Bool] = [:]
            do {
                _ = try await warmScanner.scanAllWorkspaces()
                threwCancellation["scanAllWorkspaces"] = false
            } catch { threwCancellation["scanAllWorkspaces"] = error is CancellationError }
            do {
                _ = try await warmScanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
                threwCancellation["loadTranscriptForSearch"] = false
            } catch { threwCancellation["loadTranscriptForSearch"] = error is CancellationError }
            do {
                _ = try warmScanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: nil, filePath: nil, from: nil, to: nil)
                threwCancellation["sessionsMatchingFilters"] = false
            } catch { threwCancellation["sessionsMatchingFilters"] = error is CancellationError }
            do {
                _ = try await warmScanner.refreshWorkspacesContainingSession(sessionID)
                threwCancellation["refreshWorkspacesContainingSession"] = false
            } catch { threwCancellation["refreshWorkspacesContainingSession"] = error is CancellationError }
            return threwCancellation
        }.value

        XCTAssertEqual(outcomes, [
            "scanAllWorkspaces": true,
            "loadTranscriptForSearch": true,
            "sessionsMatchingFilters": true,
            "refreshWorkspacesContainingSession": true
        ])
    }

    func testInventoryCancelledMidScan_publishesNothingAndDoesNotPrune() async throws {
        for index in 0 ..< 4 {
            let wsDir = try createWorkspaceDir(name: "P\(index)", uuid: UUID())
            try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord(name: "S\(index)")])
        }
        let clock = HistoryTestClock(Date(timeIntervalSince1970: 0))
        let cancelHook = HistoryInventoryCancelHook()
        let scanner = HistorySessionScanner(
            workspacesRoot: workspacesRoot,
            scanCacheTTL: 90,
            now: { clock.now },
            inventoryWorkspaceHookForTesting: { cancelHook.visit($0) }
        )
        let first = HistoryExecutionDiagnostics()
        _ = try await scanner.scanAllWorkspaces(diagnostics: first)
        XCTAssertEqual(first.snapshot().counters.indexDecodes, 4)

        clock.now = Date(timeIntervalSince1970: 100) // TTL expired
        cancelHook.cancelAtVisit = 2
        let cancelled = await Task { () -> Bool in
            do {
                _ = try await scanner.scanAllWorkspaces()
                return false
            } catch { return error is CancellationError }
        }.value
        XCTAssertTrue(cancelled, "Mid-scan cancellation must throw CancellationError")

        // Same instant: a partial inventory published by the cancelled scan would be
        // served from the TTL cache; pruning against its partial seen-set would have
        // evicted the two unvisited index entries.
        let after = HistoryExecutionDiagnostics()
        let results = try await scanner.scanAllWorkspaces(diagnostics: after)
        XCTAssertEqual(results.count, 4, "Cancelled scan must not publish a partial inventory")
        XCTAssertFalse(after.snapshot().counters.inventoryFromTTLCache)
        XCTAssertEqual(after.snapshot().counters.indexCacheHits, 4, "Cancelled scan must not prune live index entries")
        XCTAssertEqual(after.snapshot().counters.indexDecodes, 0)
    }

    func testInventoryCancelledMidScan_keepsDecodedIndexEntriesSoNextScanDecodesFewer() async throws {
        var workspaceDirs: [URL] = []
        for index in 0 ..< 4 {
            let wsDir = try createWorkspaceDir(name: "P\(index)", uuid: UUID())
            try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord(name: "S\(index)")])
            workspaceDirs.append(wsDir)
        }
        let cancelHook = HistoryInventoryCancelHook()
        let scanner = HistorySessionScanner(
            workspacesRoot: workspacesRoot,
            scanCacheTTL: 0,
            inventoryWorkspaceHookForTesting: { cancelHook.visit($0) }
        )
        _ = try await scanner.scanAllWorkspaces()

        // Every index changes, so each needs a fresh decode.
        for (index, wsDir) in workspaceDirs.enumerated() {
            try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord(name: "S\(index)"), makeMinimalRecord(name: "T\(index)")])
        }
        cancelHook.cancelAtVisit = 2
        let cancelledScan = HistoryExecutionDiagnostics()
        let cancelled = await Task { () -> Bool in
            do {
                _ = try await scanner.scanAllWorkspaces(diagnostics: cancelledScan)
                return false
            } catch { return error is CancellationError }
        }.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(cancelledScan.snapshot().counters.indexDecodes, 2)

        let next = HistoryExecutionDiagnostics()
        let results = try await scanner.scanAllWorkspaces(diagnostics: next)
        XCTAssertEqual(results.flatMap(\.records).count, 8)
        XCTAssertEqual(next.snapshot().counters.indexDecodes, 2, "Entries decoded before cancellation are reused")
        XCTAssertEqual(next.snapshot().counters.indexCacheHits, 2)
    }

    func testInventoryTTL_startsWhenScanCompletes() async throws {
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord(name: "S")])
        let clock = HistoryTestClock(Date(timeIntervalSince1970: 0))
        let scanner = HistorySessionScanner(
            workspacesRoot: workspacesRoot,
            scanCacheTTL: 90,
            now: { clock.now },
            // The scan takes 100s: it starts at t=0 and completes at t=100.
            inventoryWorkspaceHookForTesting: { _ in clock.now = Date(timeIntervalSince1970: 100) }
        )
        _ = try await scanner.scanAllWorkspaces()

        clock.now = Date(timeIntervalSince1970: 150) // 50s after completion, 150s after start
        let diagnostics = HistoryExecutionDiagnostics()
        _ = try await scanner.scanAllWorkspaces(diagnostics: diagnostics)
        XCTAssertTrue(diagnostics.snapshot().counters.inventoryFromTTLCache, "TTL is measured from scan completion")
        let inventoryScans = await scanner.inventoryScanCountForTesting
        XCTAssertEqual(inventoryScans, 1)
    }

    func testInventoryCancelledDuringEnumeration_throwsBeforeAnyIndexIsScanned() async throws {
        for index in 0 ..< 3 {
            let wsDir = try createWorkspaceDir(name: "E\(index)", uuid: UUID())
            try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord(name: "S\(index)")])
        }
        let scanner = HistorySessionScanner(workspacesRoot: workspacesRoot, scanCacheTTL: 90)
        let observer = HistoryPhaseCancelObserver(cancelOn: .inventoryEnumeration)
        let diagnostics = HistoryExecutionDiagnostics { observer.observe($0, $1) }
        let cancelled = await Task { () -> Bool in
            do {
                _ = try await scanner.scanAllWorkspaces(diagnostics: diagnostics)
                return false
            } catch { return error is CancellationError }
        }.value

        XCTAssertTrue(cancelled, "Cancellation during the listing must throw CancellationError")
        // The workspace listing itself observes cancellation, so the index scan never begins.
        XCTAssertFalse(observer.startedPhases.contains(.inventoryIndexScan))
        XCTAssertEqual(diagnostics.snapshot().counters.workspaceDirsVisited, 0)

        let next = HistoryExecutionDiagnostics()
        let results = try await scanner.scanAllWorkspaces(diagnostics: next)
        XCTAssertEqual(results.count, 3)
        XCTAssertFalse(next.snapshot().counters.inventoryFromTTLCache, "A scan cancelled while listing publishes nothing")
    }

    func testRefreshCancelledDuringEnumeration_throwsWithoutProbingOrSplicing() async throws {
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord(name: "Existing")])
        let scanner = HistorySessionScanner(workspacesRoot: workspacesRoot, scanCacheTTL: 3600)
        _ = try await scanner.scanAllWorkspaces()

        // A session saved after the inventory was cached.
        let fresh = makeMinimalRecord(name: "Fresh")
        try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord(name: "Existing"), fresh])
        try writeSessionFile(AgentSession(id: fresh.id, name: "Fresh", transcript: .empty, itemCount: 1), in: wsDir)

        let observer = HistoryPhaseCancelObserver(cancelOn: .inventoryEnumeration)
        let diagnostics = HistoryExecutionDiagnostics { observer.observe($0, $1) }
        let cancelled = await Task { () -> Bool in
            do {
                _ = try await scanner.refreshWorkspacesContainingSession(fresh.id, diagnostics: diagnostics)
                return false
            } catch { return error is CancellationError }
        }.value

        XCTAssertTrue(cancelled)
        XCTAssertFalse(observer.startedPhases.contains(.inventoryIndexScan))
        XCTAssertEqual(diagnostics.snapshot().counters.workspaceDirsVisited, 0, "No session-file probe after cancellation")
        let cached = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(cached.flatMap(\.records).count, 1, "A cancelled refresh must not splice into the cached inventory")
    }

    func testTranscriptDecodedAsCancellationArrives_isCachedButNotReturned() async throws {
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionID = UUID()
        try writeSessionFile(
            AgentSession(
                id: sessionID,
                name: "S",
                transcript: AgentTranscript(turns: [AgentTranscriptTurn(startedAt: Date(timeIntervalSince1970: 1000))]),
                itemCount: 1
            ),
            in: wsDir
        )
        let decoder = CancelAfterSessionDecodeDecoder()
        let scanner = HistorySessionScanner(decoder: decoder, workspacesRoot: workspacesRoot)

        decoder.armed = true
        let cancelled = await Task { () -> Bool in
            do {
                _ = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
                return false
            } catch { return error is CancellationError }
        }.value
        XCTAssertTrue(cancelled, "A cancelled caller never receives the transcript")
        let decodedWhileCancelled = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodedWhileCancelled, 1)

        // The completed decode was cached, so the next (uncancelled) load reuses it.
        let transcript = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
        XCTAssertEqual(transcript.turns.count, 1)
        let decodedAfterRetry = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodedAfterRetry, 1, "Repeated cancelled searches make progress: no re-decode")
    }

    // MARK: - Cross-Workspace Unification

    func testScanAllWorkspaces_recordsIncludeWorkspaceContext() async throws {
        let wsUUID1 = UUID()
        let wsUUID2 = UUID()
        let ws1 = try createWorkspaceDir(name: "Alpha", uuid: wsUUID1)
        let ws2 = try createWorkspaceDir(name: "Beta", uuid: wsUUID2)
        let r1 = makeMinimalRecord(name: "S1")
        let r2 = makeMinimalRecord(name: "S2")
        try createAgentSessionsIndex(in: ws1, records: [r1])
        try createAgentSessionsIndex(in: ws2, records: [r2])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = try scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: nil, filePath: nil, from: nil, to: nil)

        XCTAssertEqual(filtered.count, 2, "Expected 2 filtered records, got \(filtered.count)")
        let scanNames = scanResults.map(\.workspaceName)
        XCTAssertEqual(scanNames.sorted(), ["Alpha", "Beta"], "Scan result workspace names")

        let names = Set(filtered.map(\.workspaceName))
        XCTAssertEqual(names, Set(["Alpha", "Beta"]), "Filtered workspace names")

        let dirs = Set(filtered.map(\.workspaceDir.standardizedFileURL))
        XCTAssertTrue(dirs.contains(ws1.standardizedFileURL))
        XCTAssertTrue(dirs.contains(ws2.standardizedFileURL))
    }

    // MARK: - Stale Schema

    func testScanAllWorkspaces_staleSchemaVersion_returnsEmptyRecordsForWorkspace() async throws {
        let wsDir = try createWorkspaceDir(name: "StaleProject", uuid: UUID())
        let record = makeMinimalRecord(name: "OldSession")

        // Write an index with schemaVersion 3 (current is 5).
        let agentSessions = wsDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)
        let staleIndex = AgentSessionMetadataIndex(
            schemaVersion: 3,
            entries: [record]
        )
        let data = try encoder.encode(staleIndex)
        let indexFile = agentSessions.appendingPathComponent("AgentSessionIndex.json")
        try data.write(to: indexFile, options: .atomic)

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].records.isEmpty, "Stale-schema workspace should have empty records")
        XCTAssertFalse(results[0].indexReadFailed)
        XCTAssertEqual(results[0].indexSchemaVersion, 3)
    }

    func testSessionsMatchingFilters_skipsStaleSchemaWorkspace() async throws {
        // Current-schema workspace with a session.
        let currentWS = try createWorkspaceDir(name: "CurrentProject", uuid: UUID())
        let currentRecord = makeMinimalRecord(name: "CurrentSession")
        try createAgentSessionsIndex(in: currentWS, records: [currentRecord])

        // Stale-schema workspace with a session (should be excluded from filtering).
        let staleWS = try createWorkspaceDir(name: "StaleProject", uuid: UUID())
        let staleRecord = makeMinimalRecord(name: "StaleSession")
        let staleAgentSessions = staleWS.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: staleAgentSessions, withIntermediateDirectories: true)
        let staleIndex = AgentSessionMetadataIndex(schemaVersion: 3, entries: [staleRecord])
        try encoder.encode(staleIndex).write(
            to: staleAgentSessions.appendingPathComponent("AgentSessionIndex.json"),
            options: .atomic
        )

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = try scanner.sessionsMatchingFilters(
            scanResults,
            workspace: nil,
            agentKind: nil,
            model: nil,
            filePath: nil,
            from: nil,
            to: nil
        )

        // Only the current-schema workspace's session should appear.
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, currentRecord.id)
        XCTAssertEqual(filtered[0].workspaceName, "CurrentProject")
    }

    // MARK: - Helpers

    private func createWorkspaceDir(name: String, uuid: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        let dirName = "Workspace-\(name)-\(uuid.uuidString)"
        let wsDir = workspacesRoot.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        return wsDir
    }

    private func createAgentSessionsIndex(
        in workspaceDir: URL,
        records: [AgentSessionMetadataRecord]
    ) throws {
        let agentSessions = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)

        let index = AgentSessionMetadataIndex(
            schemaVersion: AgentSessionMetadataIndex.currentSchemaVersion,
            entries: records
        )
        let data = try encoder.encode(index)
        let indexFile = agentSessions.appendingPathComponent("AgentSessionIndex.json")
        try data.write(to: indexFile, options: .atomic)
    }

    private func writeWorkspaceJSON(in workspaceDir: URL, name: String, id: UUID) throws {
        let json: [String: Any] = ["name": name, "id": id.uuidString]
        let data = try JSONSerialization.data(withJSONObject: json)
        let file = workspaceDir.appendingPathComponent("workspace.json")
        try data.write(to: file, options: .atomic)
    }

    private func writeSessionFile(_ session: AgentSession, in workspaceDir: URL) throws {
        let agentSessions = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)
        let filename = "AgentSession-\(session.id.uuidString).json"
        let fileURL = agentSessions.appendingPathComponent(filename)
        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: .atomic)
    }

    private func makeMinimalRecord(
        id: UUID = UUID(),
        name: String = "Test Session",
        agentKindRaw: String? = nil,
        agentModelRaw: String? = nil,
        keyPaths: Set<String> = [],
        activeDurationSeconds: Int = 0,
        savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> AgentSessionMetadataRecord {
        AgentSessionMetadataRecord(
            id: id,
            filename: "AgentSession-\(id.uuidString).json",
            workspaceID: nil,
            composeTabID: nil,
            name: name,
            savedAt: savedAt,
            lastUserMessageAt: nil,
            itemCount: 1,
            transcriptProjectionCounts: nil,
            hasUnknownConversationContent: false,
            agentKindRaw: agentKindRaw,
            agentModelRaw: agentModelRaw,
            agentReasoningEffortRaw: nil,
            lastRunStateRaw: nil,
            autoEditEnabled: true,
            parentSessionID: nil,
            isMCPOriginated: false,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: nil,
            lastIndexedAt: savedAt,
            keyPaths: keyPaths,
            coveredTurnDurationSeconds: activeDurationSeconds
        )
    }
}

/// Settable test clock for the scanner's `now` seam.
private final class HistoryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Phase observer that records started phases and cancels the executing task the first
/// time a given phase starts (the observer runs synchronously on that task).
private final class HistoryPhaseCancelObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelOn: HistoryExecutionDiagnostics.Phase
    private var started: [HistoryExecutionDiagnostics.Phase] = []
    private var fired = false

    init(cancelOn: HistoryExecutionDiagnostics.Phase) {
        self.cancelOn = cancelOn
    }

    var startedPhases: [HistoryExecutionDiagnostics.Phase] {
        lock.withLock { started }
    }

    func observe(_ phase: HistoryExecutionDiagnostics.Phase, _ transition: HistoryExecutionDiagnostics.PhaseTransition) {
        guard transition == .started else { return }
        let shouldCancel = lock.withLock {
            started.append(phase)
            guard phase == cancelOn, !fired else { return false }
            fired = true
            return true
        }
        if shouldCancel {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
}

/// Decoder that cancels the calling task right after it finishes decoding an
/// `AgentSession` (models cancellation arriving as a transcript decode completes).
private final class CancelAfterSessionDecodeDecoder: JSONDecoder, @unchecked Sendable {
    private let lock = NSLock()
    private var isArmed = false

    var armed: Bool {
        get { lock.withLock { isArmed } }
        set { lock.withLock { isArmed = newValue } }
    }

    override func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let value = try super.decode(type, from: data)
        if type == AgentSession.self {
            let shouldCancel = lock.withLock {
                defer { isArmed = false }
                return isArmed
            }
            if shouldCancel {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        return value
    }
}

/// Inventory hook that cancels the scanning task when it reaches a given workspace
/// index, then disarms (deterministic mid-scan cancellation without sleeps).
private final class HistoryInventoryCancelHook: @unchecked Sendable {
    private let lock = NSLock()
    private var armedAt: Int?

    var cancelAtVisit: Int? {
        get { lock.withLock { armedAt } }
        set { lock.withLock { armedAt = newValue } }
    }

    func visit(_ visited: Int) {
        let shouldCancel = lock.withLock {
            guard armedAt == visited else { return false }
            armedAt = nil
            return true
        }
        if shouldCancel {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
}
