import CryptoKit
import Darwin
import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import RepoPromptShared
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

private extension ToolResultDTOs.CodeStructureReplyDTO {
    var fileCount: Int {
        summary.returnedFiles
    }

    var content: String {
        files.map(\.content).joined(separator: "\n")
    }

    var pendingPaths: [String]? {
        issuePaths { $0.retryable }
    }

    var unmappedPaths: [String]? {
        issuePaths { issue in
            guard !issue.retryable else { return false }
            switch issue.code {
            case "path_not_found", "outside_root_scope", "unsupported_file",
                 "artifact_unavailable", "git_root_unavailable":
                return true
            default:
                return false
            }
        }
    }

    private func issuePaths(
        matching predicate: (ToolResultDTOs.CodeStructureReplyDTO.IssueDTO) -> Bool
    ) -> [String]? {
        let paths = issues.compactMap { issue -> String? in
            guard predicate(issue) else { return nil }
            return issue.path
        }
        return paths.isEmpty ? nil : paths
    }
}

@MainActor
final class MCPCodeStructureWorktreeTests: XCTestCase {
    func testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logical = try repositories.makeRepository(
            named: "logical",
            files: ["Sources/App.swift": SwiftFixtureSource.emptyStruct("CanonicalOnly")]
        )
        let physical = try repositories.makeRepository(
            named: "physical-secret",
            files: [
                "Sources/App.swift": "protocol AppProtocol { func run() }\nstruct WorktreeApp: AppProtocol { func run() {} }\n"
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: logical)
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logical.path
        )
        let setupPhysicalRoot = try await store.loadRoot(path: physical.path, kind: .sessionWorktree)
        let setupFile = try await fileRecord(
            at: physical.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: .allLoaded
        )
        let setupTicket = try await readyTicket(
            store: store,
            fileID: setupFile.id,
            timeout: .seconds(30)
        )
        var setupTicketCancelled = false
        do {
            _ = try await settledCodemapPresentationOperationCounts(
                store: store,
                rootEpoch: setupTicket.rootEpoch,
                reason: "after setup physical worktree codemap readiness"
            )
            _ = await store.cancelCodemapArtifactDemand(setupTicket)
            setupTicketCancelled = true
            _ = try await settledCodemapPresentationOperationCounts(
                store: store,
                rootEpoch: setupTicket.rootEpoch,
                reason: "after setup physical worktree codemap cancellation"
            )
        } catch {
            if !setupTicketCancelled {
                _ = await store.cancelCodemapArtifactDemand(setupTicket)
            }
            throw error
        }
        await store.unloadRoot(id: setupPhysicalRoot.id)

        let physicalRoot = try await store.loadRoot(path: physical.path, kind: .sessionWorktree)
        let projection = makeProjection(
            logicalRoot: logicalRoot,
            physicalRoot: physicalRoot,
            worktreeID: "logical-result"
        )
        let context = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        )
        let file = try await fileRecord(
            at: physical.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projection.lookupRootScope
        )
        let ticket = try await readyTicket(store: store, fileID: file.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let structureRequest = request()
        let firstDTO = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: structureRequest,
            includePathNotFoundIssue: true,
            lookupContext: context
        )
        let secondDTO = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: structureRequest,
            includePathNotFoundIssue: true,
            lookupContext: context
        )

        for dto in [firstDTO, secondDTO] {
            XCTAssertEqual(dto.status, "ready")
            XCTAssertEqual(dto.files.count, 1)
            let renderedFile = try XCTUnwrap(dto.files.first)
            XCTAssertEqual(renderedFile.path, "\(logicalRoot.name)/Sources/App.swift")
            XCTAssertEqual(renderedFile.role, "seed")
            XCTAssertEqual(renderedFile.depth, 0)
            XCTAssertTrue(renderedFile.content.contains("WorktreeApp"), renderedFile.content)
            XCTAssertFalse(renderedFile.content.contains("CanonicalOnly"), renderedFile.content)
            XCTAssertFalse(renderedFile.content.contains(physical.standardizedFileURL.path), renderedFile.content)
            XCTAssertEqual(dto.summary.codemapContentTokens, renderedFile.tokens)
            let mapping = try XCTUnwrap(dto.worktreeScope?.rootMappings.first)
            XCTAssertEqual(mapping.logicalRootPath, logicalRoot.name)
            XCTAssertEqual(mapping.effectiveRootPath, "session-bound")
            XCTAssertEqual(mapping.worktreeID, "logical-result")
            XCTAssertFalse(mapping.logicalRootPath.contains(physical.standardizedFileURL.path))
        }

        let rootLifetimeID = try await store.rootLifetimeIDForTesting(rootID: physicalRoot.id)
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: physicalRoot.id,
            rootLifetimeID: rootLifetimeID
        )
        let storeWorkBeforeTree = try await settledCodemapPresentationOperationCounts(
            store: store,
            rootEpoch: rootEpoch,
            reason: "before passive current-snapshot tree render"
        )
        let recoveryStateBeforeTree = await store.codemapGraphPublicationRecoveryStateForTesting(
            rootEpoch: rootEpoch
        )
        let markerBeforeTreeValue = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: rootEpoch
        )
        let markerBeforeTree = try XCTUnwrap(markerBeforeTreeValue)
        XCTAssertEqual(markerBeforeTree.changes.map(\.fileID), [file.id])
        XCTAssertEqual(markerBeforeTree.changes.map(\.state), [.ready])
        let engineWorkBeforeTreeValue = await store.codemapBindingEngineAccountingForTesting(
            rootID: physicalRoot.id
        )
        let engineWorkBeforeTree = try XCTUnwrap(engineWorkBeforeTreeValue)

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: true,
                rootScope: projection.lookupRootScope
            ),
            lookupContext: context,
            profile: .mcpRead
        )

        XCTAssertTrue(tree.content.contains("App.swift +"), tree.content)
        XCTAssertTrue(tree.content.contains("(+ denotes code-map available)"), tree.content)
        XCTAssertTrue(tree.content.contains(logicalRoot.name), tree.content)
        XCTAssertFalse(tree.content.contains(physical.standardizedFileURL.path), tree.content)
        XCTAssertFalse(tree.content.contains("physical-secret"), tree.content)
        let markerAfterTree = await store.codemapMarkerReadinessSnapshotForTesting(rootEpoch: rootEpoch)
        XCTAssertEqual(markerAfterTree?.revision, markerBeforeTree.revision)
        XCTAssertEqual(markerAfterTree?.changes, markerBeforeTree.changes)
        let recoveryStateAfterTree = await store.codemapGraphPublicationRecoveryStateForTesting(
            rootEpoch: rootEpoch
        )
        let storeWorkAfterTree = await store.codemapPresentationOperationCountsForTesting()
        let passiveTreeWorkDiagnostic = """
        Passive current-snapshot tree rendering must not create codemap/projection work.
        beforeCounts: \(storeWorkBeforeTree)
        afterCounts: \(storeWorkAfterTree)
        beforeRecoveryState: \(recoveryStateBeforeTree)
        afterRecoveryState: \(recoveryStateAfterTree)
        """
        XCTAssertEqual(
            storeWorkAfterTree.structureSeedAdmissionRequests,
            storeWorkBeforeTree.structureSeedAdmissionRequests,
            passiveTreeWorkDiagnostic
        )
        XCTAssertEqual(
            storeWorkAfterTree.selectedMetadataResolutionRequests,
            storeWorkBeforeTree.selectedMetadataResolutionRequests,
            passiveTreeWorkDiagnostic
        )
        // `presentationCandidateRequests` is a store-global counter for
        // codemapOperationPresentationCandidates(...), not an attributable passive-tree render
        // counter. The full before/after value stays in the diagnostic while direct passive-tree
        // work counters remain strict below.
        XCTAssertEqual(
            storeWorkAfterTree.artifactDemandRequests,
            storeWorkBeforeTree.artifactDemandRequests,
            passiveTreeWorkDiagnostic
        )
        XCTAssertEqual(
            storeWorkAfterTree.presentationFreezeRequests,
            storeWorkBeforeTree.presentationFreezeRequests,
            passiveTreeWorkDiagnostic
        )
        XCTAssertEqual(
            storeWorkAfterTree.setupTasksCreated,
            storeWorkBeforeTree.setupTasksCreated,
            passiveTreeWorkDiagnostic
        )
        XCTAssertEqual(
            storeWorkAfterTree.demandTasksCreated,
            storeWorkBeforeTree.demandTasksCreated,
            passiveTreeWorkDiagnostic
        )
        XCTAssertEqual(
            storeWorkAfterTree.targetedReadyFreezes,
            storeWorkBeforeTree.targetedReadyFreezes,
            passiveTreeWorkDiagnostic
        )
        XCTAssertEqual(
            storeWorkAfterTree.graphBatchSignals,
            storeWorkBeforeTree.graphBatchSignals,
            passiveTreeWorkDiagnostic
        )
        XCTAssertEqual(
            storeWorkAfterTree.projectionRecoveryObserversStarted,
            storeWorkBeforeTree.projectionRecoveryObserversStarted,
            passiveTreeWorkDiagnostic
        )
        XCTAssertEqual(
            storeWorkAfterTree.projectionRecoveryObserverRearms,
            storeWorkBeforeTree.projectionRecoveryObserverRearms,
            passiveTreeWorkDiagnostic
        )
        let graphDrainDeltas = [
            storeWorkAfterTree.fullRootGraphFreezes - storeWorkBeforeTree.fullRootGraphFreezes,
            storeWorkAfterTree.graphBatchFlushes - storeWorkBeforeTree.graphBatchFlushes,
            storeWorkAfterTree.graphWorkerStarts - storeWorkBeforeTree.graphWorkerStarts
        ]
        XCTAssertEqual(
            graphDrainDeltas,
            [0, 0, 0],
            "Unexpected graph-worker drain deltas: \(graphDrainDeltas)\n\(passiveTreeWorkDiagnostic)"
        )
        let engineWorkAfterTree = await store.codemapBindingEngineAccountingForTesting(
            rootID: physicalRoot.id
        )
        XCTAssertEqual(engineWorkAfterTree, engineWorkBeforeTree)
    }

    func testNonGitRootReturnsTypedUnavailableWithoutLegacySnapshotBuild() async throws {
        let root = try makeTemporaryRoot(name: "NonGit")
        let fileURL = root.appendingPathComponent("Sources/App.swift")
        try write(SwiftFixtureSource.emptyStruct("PlainFile"), to: fileURL)
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        _ = try await fileRecord(at: fileURL, store: store, rootScope: .visibleWorkspace)

        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "code-structure-zero-git",
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let tools = await window.mcpServer.windowMCPTools
        let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.getCodeStructure })
        let requestIdentity = MCPRequestTimelineIdentity(
            jsonRPCRequestID: .number(8001),
            connectionID: connectionID.uuidString,
            connectionGeneration: 1,
            appInvocationID: UUID().uuidString,
            requestOrdinal: 1
        )
        MCPToolWorkCountDiagnostics.resetForTesting()

        let value = try await MCPRequestTimelineContext.$current.withValue(requestIdentity) {
            try await ServerNetworkManager.withConnectionID(connectionID) {
                try await tool([
                    "scope": .string("paths"),
                    "paths": .array([.string(fileURL.path)])
                ])
            }
        }

        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, "unavailable")
        XCTAssertTrue(object["files"]?.arrayValue?.isEmpty == true)
        let issueCodes = object["issues"]?.arrayValue?.compactMap {
            $0.objectValue?["code"]?.stringValue
        }
        XCTAssertTrue(issueCodes?.contains("git_root_unavailable") == true)
        let issue = try XCTUnwrap(object["issues"]?.arrayValue?.first {
            $0.objectValue?["code"]?.stringValue == "git_root_unavailable"
        }?.objectValue)
        XCTAssertEqual(issue["detail"]?.stringValue, "git_terminal.non_git")
        XCTAssertEqual(issue["retryable"]?.boolValue, false)
        XCTAssertNil(object["retry"])
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 0)
        let invocations = MCPToolWorkCountDiagnostics.debugSnapshots().git
        XCTAssertEqual(invocations.count, 1)
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(invocation.operation, MCPWindowToolName.getCodeStructure)
        assertNonGitEligibilityDiagnosticShape(invocation)
        XCTAssertEqual(invocation.outcome, "success")
        XCTAssertEqual(invocation.requestIdentity, requestIdentity)

        let repeatedRequestIdentity = MCPRequestTimelineIdentity(
            jsonRPCRequestID: .number(8002),
            connectionID: connectionID.uuidString,
            connectionGeneration: 1,
            appInvocationID: UUID().uuidString,
            requestOrdinal: 2
        )
        let repeatedValue = try await MCPRequestTimelineContext.$current.withValue(repeatedRequestIdentity) {
            try await ServerNetworkManager.withConnectionID(connectionID) {
                try await tool([
                    "scope": .string("paths"),
                    "paths": .array([.string(fileURL.path)])
                ])
            }
        }
        let repeatedObject = try XCTUnwrap(repeatedValue.objectValue)
        XCTAssertEqual(repeatedObject["status"]?.stringValue, "unavailable")
        XCTAssertTrue(repeatedObject["issues"]?.arrayValue?.contains {
            $0.objectValue?["code"]?.stringValue == "git_root_unavailable"
        } == true)
        let repeatedInvocations = MCPToolWorkCountDiagnostics.debugSnapshots().git
        XCTAssertEqual(repeatedInvocations.count, 2)
        for invocation in repeatedInvocations {
            assertNonGitEligibilityDiagnosticShape(invocation)
        }
        XCTAssertEqual(repeatedInvocations.map(\.requestIdentity), [requestIdentity, repeatedRequestIdentity])
    }

    func testWaitMillisecondsParameterIsNotExposedAndIsRejected() async throws {
        let root = try makeTemporaryRoot(name: "WaitPolicy")
        let fileURL = root.appendingPathComponent("Sources/App.swift")
        try write(SwiftFixtureSource.emptyStruct("PlainFile"), to: fileURL)
        let window = try await makeWindow(root: root)
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "code-structure-wait-policy",
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let tools = await window.mcpServer.windowMCPTools
        let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.getCodeStructure })
        let schema = try XCTUnwrap(Value(tool.inputSchema).objectValue)
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        let limitsSchema = try XCTUnwrap(properties["limits"]?.objectValue)
        let limitProperties = try XCTUnwrap(limitsSchema["properties"]?.objectValue)
        XCTAssertNil(limitProperties["wait_ms"])
        let invoke: ([String: Value]?) async throws -> Value = { submittedLimits in
            var arguments: [String: Value] = [
                "scope": .string("paths"),
                "paths": .array([.string(fileURL.path)])
            ]
            if let submittedLimits {
                arguments["limits"] = .object(submittedLimits)
            }
            return try await ServerNetworkManager.withConnectionID(connectionID) {
                try await tool(arguments)
            }
        }

        window.mcpServer.resetLastCodeStructureRequestForTesting()
        _ = try await invoke(nil)
        XCTAssertEqual(window.mcpServer.capturedCodeStructureRequestForTesting(), request())

        window.mcpServer.resetLastCodeStructureRequestForTesting()
        do {
            _ = try await invoke(["wait_ms": .int(10000)])
            XCTFail("Expected wait_ms to be rejected as an unknown limits parameter")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("unknown limits parameter"),
                "Unexpected error: \(error)"
            )
        }
        XCTAssertNil(window.mcpServer.capturedCodeStructureRequestForTesting())

        do {
            _ = try await tool([:])
            XCTFail("Expected required scope to be rejected")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("scope must be 'paths' or 'selected'"),
                "Unexpected error: \(error)"
            )
        }
    }

    func testRecoverableRootRejectionResetsOnceAndBecomesReadyInSameRequest() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: ["Sources/App.swift": "protocol Service { func run() }\nstruct App: Service { func run() {} }\n"]
        )
        defer { repositories.cleanup() }
        let counter = CodeStructureDemandHookCounter(persistent: false)
        let window = try await makeWindow(root: root) { _, result in
            await counter.transform(result)
        }
        let store = window.workspaceFileContextStore
        let file = try await fileRecord(
            at: root.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true
        )
        XCTAssertEqual(dto.status, "ready")
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1)
    }

    func testPersistentRecoverableRootRejectionResetsOnceAndReturnsExactSubtype() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: ["Sources/App.swift": "protocol Service { func run() }\nstruct App: Service { func run() {} }\n"]
        )
        defer { repositories.cleanup() }
        let counter = CodeStructureDemandHookCounter(persistent: true)
        let window = try await makeWindow(root: root) { _, result in
            await counter.transform(result)
        }
        let store = window.workspaceFileContextStore
        let file = try await fileRecord(
            at: root.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true
        )
        XCTAssertEqual(dto.status, "unavailable")
        XCTAssertEqual(dto.issues.first?.detail, "binding_rejected.capability_unavailable")
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1)
    }

    func testPersistentCurrentnessRejectionRetriesOnceThenPreservesExactSubtype() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: ["Sources/App.swift": "struct App { let value = 1 }\n"]
        )
        defer { repositories.cleanup() }
        let window = try await makeWindow(root: root) { _, _ in
            .rejected(.rootEpochMismatch)
        }
        let store = window.workspaceFileContextStore
        let file = try await fileRecord(
            at: root.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true
        )

        XCTAssertEqual(dto.status, "unavailable")
        XCTAssertEqual(dto.issues.first?.detail, "binding_rejected.root_epoch_mismatch")
        XCTAssertEqual(dto.issues.first?.retryable, true)
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 0)
    }

    func testRootSessionRepairWithJoinedRetainersInvalidatesPeerAndReacquires() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: ["Sources/App.swift": "struct App { let value = 1 }\n"]
        )
        defer { repositories.cleanup() }
        let window = try await makeWindow(root: root) { _, _ in
            .rejected(.capabilityUnavailable)
        }
        let store = window.workspaceFileContextStore
        let file = try await fileRecord(
            at: root.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let first = await store.requestCodemapArtifactWithOwnership(forFileID: file.id)
        let second = await store.requestCodemapArtifactWithOwnership(forFileID: file.id)
        guard case let .pending(firstTicket) = first.result,
              case let .pending(secondTicket) = second.result
        else {
            return XCTFail("Expected joined pending demands.")
        }
        let rejected = await waitForDemandResult(store: store, ticket: firstTicket) {
            if case .unavailable(.rejected(.capabilityUnavailable)) = $0 { return true }
            return false
        }
        XCTAssertTrue(rejected)
        let retainCount = await store.codemapArtifactDemandRetainCountForTesting(firstTicket)
        XCTAssertEqual(retainCount, 2)

        let repaired = await store.prepareCodemapRootSessionRetry(
            firstTicket,
            rejection: .capabilityUnavailable,
            priority: .demand,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )

        XCTAssertNotNil(repaired)
        let peerStatus = await store.codemapArtifactDemandStatus(secondTicket)
        guard case .unavailable(.staleCurrentness) = peerStatus else {
            return XCTFail("Expected the joined peer ticket to become stale.")
        }
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1)
        if let repaired, let ticket = demandTicket(from: repaired.result) {
            _ = await store.cancelCodemapArtifactDemand(ticket)
        }
    }

    func testFreshDemandRetryWithJoinedRetainersInvalidatesPeerAndReacquires() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: ["Sources/App.swift": "struct App { let value = 1 }\n"]
        )
        defer { repositories.cleanup() }
        let window = try await makeWindow(root: root) { _, _ in
            .rejected(.sourceAuthorityUnavailable)
        }
        let store = window.workspaceFileContextStore
        let file = try await fileRecord(
            at: root.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let first = await store.requestCodemapArtifactWithOwnership(forFileID: file.id)
        let second = await store.requestCodemapArtifactWithOwnership(forFileID: file.id)
        guard case let .pending(firstTicket) = first.result,
              case let .pending(secondTicket) = second.result
        else {
            return XCTFail("Expected joined pending demands.")
        }
        let rejected = await waitForDemandResult(store: store, ticket: firstTicket) {
            if case .unavailable(.rejected(.sourceAuthorityUnavailable)) = $0 { return true }
            return false
        }
        XCTAssertTrue(rejected)
        let retainCount = await store.codemapArtifactDemandRetainCountForTesting(firstTicket)
        XCTAssertEqual(retainCount, 2)

        let repaired = await store.retryRejectedCodemapArtifactDemand(
            firstTicket,
            rejection: .sourceAuthorityUnavailable,
            priority: .demand
        )

        XCTAssertNotNil(repaired)
        let peerStatus = await store.codemapArtifactDemandStatus(secondTicket)
        guard case .unavailable(.staleCurrentness) = peerStatus else {
            return XCTFail("Expected the joined peer ticket to become stale.")
        }
        if let repaired, let ticket = demandTicket(from: repaired.result) {
            _ = await store.cancelCodemapArtifactDemand(ticket)
        }
    }

    func testSharedCodemapCleanupWaitHonorsDeadlineAndCancellation() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: ["Sources/App.swift": "struct App {}\n"]
        )
        defer { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let sharedTask = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(5))
        }

        let expired = await store.waitForCodemapSharedTaskForTesting(
            sharedTask,
            deadline: ContinuousClock.now
        )
        XCTAssertFalse(expired)

        let waiter = Task {
            await store.waitForCodemapSharedTaskForTesting(
                sharedTask,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        }
        await Task.yield()
        waiter.cancel()
        let cancelled = await waiter.value
        XCTAssertFalse(cancelled)
        sharedTask.cancel()
        await sharedTask.value
    }

    func testRootSessionResetReissuesEverySameRootSeedOnce() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/App.swift": "struct App { let value = 1 }\n",
                "Sources/Service.swift": "protocol Service { func run() }\n"
            ]
        )
        defer { repositories.cleanup() }
        let counter = CodeStructurePersistentDemandBarrier(expectedInitialFileCount: 2)
        let window = try await makeWindow(root: root) { ticket, result in
            await counter.transform(ticket: ticket, result: result)
        }
        let store = window.workspaceFileContextStore
        let appFile = try await fileRecord(
            at: root.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let serviceFile = try await fileRecord(
            at: root.appendingPathComponent("Sources/Service.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let files = [appFile, serviceFile]

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: files,
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true
        )

        XCTAssertEqual(dto.status, "unavailable")
        XCTAssertEqual(
            Set(dto.issues.compactMap(\.detail)),
            ["binding_rejected.capability_unavailable"]
        )
        let invocationCounts = await counter.invocationCounts()
        XCTAssertEqual(Set(invocationCounts.keys), Set(files.map(\.id)))
        XCTAssertTrue(invocationCounts.values.allSatisfy { $0 == 2 })
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1)
    }

    func testTraversalTargetRootResetRestartsAttemptBeforeReusingSeedTickets() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target { func run() {} }\n"
            ]
        )
        defer { repositories.cleanup() }
        let rejection = CodeStructureTargetDemandRejection()
        let window = try await makeWindow(root: root) { ticket, result in
            await rejection.transform(ticket: ticket, result: result)
        }
        let store = window.workspaceFileContextStore
        let source = try await fileRecord(
            at: root.appendingPathComponent("Sources/Source.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let target = try await fileRecord(
            at: root.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        await rejection.configure(targetFileID: target.id)

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [source],
            request: request(
                direction: .referencedDefinitions,
                maximumDepth: 1,
                maximumFiles: 10
            ),
            includePathNotFoundIssue: true
        )

        XCTAssertEqual(dto.status, "ready")
        XCTAssertEqual(Set(dto.files.map(\.path)), [
            "repository/Sources/Source.swift",
            "repository/Sources/Target.swift"
        ])
        let rejectionCount = await rejection.rejectionCount()
        XCTAssertEqual(rejectionCount, 1)
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1)
    }

    func testBindingAndOverlayRejectionDTOsPreserveStableSubtypeAndRetryability() throws {
        let bindingCases: [(WorkspaceCodemapBindingDemandRejection, String)] = [
            (.rootNotRegistered, "binding_rejected.root_not_registered"),
            (.capabilityUnavailable, "binding_rejected.capability_unavailable"),
            (.rootEpochMismatch, "binding_rejected.root_epoch_mismatch"),
            (.rootPathMismatch, "binding_rejected.root_path_mismatch"),
            (.invalidIdentity, "binding_rejected.invalid_identity"),
            (.catalogGenerationMismatch, "binding_rejected.catalog_generation_mismatch"),
            (.requestGenerationInvalid, "binding_rejected.request_generation_invalid"),
            (.stalePathGeneration, "binding_rejected.stale_path_generation"),
            (.staleIngressGeneration, "binding_rejected.stale_ingress_generation"),
            (.languageMismatch, "binding_rejected.language_mismatch"),
            (.classificationMismatch, "binding_rejected.classification_mismatch"),
            (.sourceAuthorityUnavailable, "binding_rejected.source_authority_unavailable"),
            (.repositoryAuthorityChanged, "binding_rejected.repository_authority_changed"),
            (.staleCompletion, "binding_rejected.stale_completion")
        ]
        let overlayCases: [(WorkspaceCodemapLiveDemandRejection, String)] = [
            (.rootNotRegistered, "root_not_registered"),
            (.rootAuthorityInvalid, "root_authority_invalid"),
            (.rootEpochMismatch, "root_epoch_mismatch"),
            (.catalogGenerationMismatch, "catalog_generation_mismatch"),
            (.repositoryAuthorityMismatch, "repository_authority_mismatch"),
            (.invalidToken, "invalid_token"),
            (.pathOutsideRoot, "path_outside_root"),
            (.staleRequestGeneration, "stale_request_generation"),
            (.requestGenerationConflict, "request_generation_conflict"),
            (.admissionReservationInvalid, "admission_reservation_invalid")
        ]
        let cases = bindingCases + overlayCases.map {
            (.overlayRejected($0.0), "overlay_rejected.\($0.1)")
        }

        for (rejection, detail) in cases {
            let fileID = UUID()
            let dto = MCPServerViewModel.codeStructureReplyDTO(
                presentation: WorkspaceCodemapStructurePresentation(
                    outcome: .unavailable,
                    entries: [],
                    issues: [.artifactUnavailable(fileID: fileID, reason: .rejected(rejection))],
                    requestedSeedCount: 1,
                    resolvedSeedCount: 0,
                    examinedEdgeCount: 0,
                    codemapTokenCount: 0
                ),
                logicalPathsByFileID: [fileID: "Sources/App.swift"],
                worktreeScope: nil
            )
            let issue = try XCTUnwrap(dto.issues.first)
            XCTAssertEqual(issue.code, "artifact_unavailable")
            XCTAssertEqual(issue.detail, detail)
            let expectedMessage = rejection == .repositoryAuthorityChanged
                ? "Repository authority changed; retry the request. (reason=\(detail))"
                : "A codemap artifact is unavailable. (reason=\(detail))"
            XCTAssertEqual(issue.message, expectedMessage)
            XCTAssertFalse(
                issue.message.localizedCaseInsensitiveContains("reset"),
                "A rejection observes drift; it cannot claim a completed reset."
            )
            XCTAssertEqual(
                issue.retryable,
                WorkspaceCodemapArtifactDemandRecovery(rejection).isRetryable
            )
            XCTAssertEqual(dto.retry != nil, issue.retryable)
            if rejection == .repositoryAuthorityChanged {
                XCTAssertEqual(WorkspaceCodemapArtifactDemandRecovery(rejection), .resetRootSession)
                XCTAssertTrue(issue.retryable)
            }
        }
    }

    func testGitTerminalDTOsPreserveStableSubtypeAndReleasedEpochRetryability() throws {
        let cases: [(WorkspaceCodemapGitTerminalUnavailableReason, String)] = [
            (.nonGit, "non_git"),
            (.bareRepository, "bare_repository"),
            (.unsupportedObjectFormat, "unsupported_object_format"),
            (.unsupportedGit, "unsupported_git"),
            (.invalidLayout, "invalid_layout"),
            (.invalidLoadedRootContainment, "invalid_loaded_root_containment"),
            (.namespaceUnavailable, "namespace_unavailable"),
            (.rootEpochBindingMismatch, "root_epoch_binding_mismatch"),
            (.releasedRootEpoch, "released_root_epoch")
        ]
        for (reason, subtype) in cases {
            let fileID = UUID()
            let detail = "git_terminal.\(subtype)"
            let dto = MCPServerViewModel.codeStructureReplyDTO(
                presentation: WorkspaceCodemapStructurePresentation(
                    outcome: .unavailable,
                    entries: [],
                    issues: [.artifactUnavailable(fileID: fileID, reason: .gitTerminal(reason))],
                    requestedSeedCount: 1,
                    resolvedSeedCount: 0,
                    examinedEdgeCount: 0,
                    codemapTokenCount: 0
                ),
                logicalPathsByFileID: [fileID: "Sources/App.swift"],
                worktreeScope: nil
            )
            let issue = try XCTUnwrap(dto.issues.first)
            XCTAssertEqual(issue.detail, detail)
            XCTAssertEqual(
                issue.message,
                "The Git root is unavailable for codemap generation. (reason=\(detail))"
            )
            XCTAssertEqual(issue.retryable, reason == .releasedRootEpoch)
            XCTAssertEqual(dto.retry != nil, reason == .releasedRootEpoch)
        }
    }

    func testParkedRuntimeFailureDTOIsTerminalWithStableReasonToken() throws {
        let fileID = UUID()
        let path = "Sources/Parked.swift"
        let presentation = WorkspaceCodemapStructurePresentation(
            outcome: .unavailable,
            entries: [],
            issues: [.artifactUnavailable(fileID: fileID, reason: .runtimeFailureParked)],
            requestedSeedCount: 1,
            resolvedSeedCount: 1,
            examinedEdgeCount: 0,
            codemapTokenCount: 0
        )

        let dto = MCPServerViewModel.codeStructureReplyDTO(
            presentation: presentation,
            logicalPathsByFileID: [fileID: path],
            worktreeScope: nil
        )

        XCTAssertEqual(dto.status, "unavailable")
        let issue = try XCTUnwrap(dto.issues.first)
        XCTAssertEqual(issue.code, "artifact_unavailable")
        XCTAssertEqual(issue.path, path)
        XCTAssertFalse(issue.retryable)
        XCTAssertNil(issue.retryAfterMilliseconds)
        XCTAssertEqual(issue.detail, "runtime_failure_parked")
        XCTAssertEqual(
            issue.message,
            "A codemap artifact is unavailable. (reason=runtime_failure_parked)"
        )
        XCTAssertNil(dto.retry)
    }

    func testReadinessPressureDTOsAreTypedEmptyAndRetryConsistent() throws {
        let rendered = try renderedStructureEntry()
        let cases: [(
            outcome: WorkspaceCodemapStructureOutcome,
            issue: WorkspaceCodemapStructureIssue,
            status: String,
            code: String,
            retryAfterMilliseconds: Int?
        )] = [
            (.busy, .busy(retryAfterMilliseconds: 1), "busy", "codemap_busy", 25),
            (
                .timeout,
                .readinessTimeout(
                    elapsedMilliseconds: 9876,
                    limitMilliseconds: 10000,
                    retryAfterMilliseconds: 5000
                ),
                "timeout",
                "readiness_timeout",
                1000
            ),
            (
                .unavailable,
                .projectionUnavailable(reason: .generationMismatch, retryAfterMilliseconds: 75),
                "unavailable",
                "projection_unavailable",
                75
            ),
            (
                .unavailable,
                .projectionUnavailable(reason: .capabilityUnavailable, retryAfterMilliseconds: nil),
                "unavailable",
                "projection_unavailable",
                nil
            )
        ]

        for item in cases {
            let presentation = WorkspaceCodemapStructurePresentation(
                outcome: item.outcome,
                entries: [rendered],
                issues: [item.issue],
                requestedSeedCount: 1,
                resolvedSeedCount: 1,
                examinedEdgeCount: 9,
                codemapTokenCount: 7
            )
            let dto = MCPServerViewModel.codeStructureReplyDTO(
                presentation: presentation,
                logicalPathsByFileID: [rendered.entry.fileID: rendered.entry.logicalPath.displayPath],
                worktreeScope: nil
            )

            XCTAssertEqual(dto.status, item.status)
            XCTAssertTrue(dto.files.isEmpty)
            XCTAssertEqual(dto.summary.returnedFiles, 0)
            XCTAssertEqual(dto.summary.codemapContentTokens, 0)
            XCTAssertEqual(dto.summary.examinedEdges, 0)
            let issue = try XCTUnwrap(dto.issues.first { $0.code == item.code })
            XCTAssertEqual(issue.retryable, item.retryAfterMilliseconds != nil)
            XCTAssertEqual(issue.retryAfterMilliseconds, item.retryAfterMilliseconds)
            XCTAssertEqual(dto.retry?.retryAfterMilliseconds, item.retryAfterMilliseconds)
            XCTAssertEqual(dto.retry?.retryable, item.retryAfterMilliseconds == nil ? nil : true)
            if item.code == "readiness_timeout" {
                XCTAssertEqual(issue.attempted, 9876)
                XCTAssertEqual(issue.limit, 10000)
            }
        }

        for legacyOutcome in [WorkspaceCodemapStructureOutcome.partial, .pending] {
            let dto = MCPServerViewModel.codeStructureReplyDTO(
                presentation: WorkspaceCodemapStructurePresentation(
                    outcome: legacyOutcome,
                    entries: [rendered],
                    issues: [],
                    requestedSeedCount: 1,
                    resolvedSeedCount: 1,
                    examinedEdgeCount: 9,
                    codemapTokenCount: 7
                ),
                logicalPathsByFileID: [rendered.entry.fileID: rendered.entry.logicalPath.displayPath],
                worktreeScope: nil
            )
            XCTAssertEqual(dto.status, "timeout")
            XCTAssertTrue(dto.files.isEmpty)
            XCTAssertEqual(dto.issues.map(\.code), ["readiness_timeout"])
            XCTAssertEqual(dto.issues.first?.attempted, 10000)
            XCTAssertEqual(dto.issues.first?.limit, 10000)
            XCTAssertNotNil(dto.retry?.retryAfterMilliseconds)
        }

        let projectionBudget = WorkspaceCodemapProjectionBudget(
            dimension: .retainedProjectionBytes,
            attempted: 2049,
            limit: 2048
        )
        let budgetDTO = MCPServerViewModel.codeStructureReplyDTO(
            presentation: WorkspaceCodemapStructurePresentation(
                outcome: .budget,
                entries: [],
                issues: [.projectionBudget(projectionBudget)],
                requestedSeedCount: 1,
                resolvedSeedCount: 0,
                examinedEdgeCount: 0,
                codemapTokenCount: 0
            ),
            logicalPathsByFileID: [:],
            worktreeScope: nil
        )
        XCTAssertEqual(budgetDTO.status, "budget")
        XCTAssertEqual(budgetDTO.issues.map(\.code), ["projection_budget"])
        XCTAssertEqual(budgetDTO.issues.first?.attempted, 2049)
        XCTAssertEqual(budgetDTO.issues.first?.limit, 2048)
        XCTAssertNil(budgetDTO.retry)
    }

    func testStrictTokenBudgetNeverAdmitsOversizedFirstEntry() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Large.swift": (0 ..< 80).map {
                    "struct Type\($0) { func method\($0)() -> String { \"\($0)\" } }"
                }.joined(separator: "\n")
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let file = try await fileRecord(
            at: root.appendingPathComponent("Sources/Large.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let ticket = try await readyTicket(store: store, fileID: file.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let primed = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumCodemapTokens: 6000),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        XCTAssertEqual(primed.status, "ready")
        XCTAssertTrue(primed.content.contains("Type0"), primed.content)

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumCodemapTokens: 1),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )

        XCTAssertEqual(dto.status, "budget")
        XCTAssertTrue(dto.files.isEmpty)
        XCTAssertEqual(dto.summary.codemapContentTokens, 0)
        XCTAssertTrue(dto.issues.contains { $0.code == "token_limit" })
    }

    func testBoundedDirectoryExpansionRejectsAtLimitPlusOneBeforeDownstreamWork() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/One.swift": SwiftFixtureSource.emptyStruct("One"),
                "Sources/Nested/Two.swift": SwiftFixtureSource.emptyStruct("Two"),
                "Sources/Three.swift": SwiftFixtureSource.emptyStruct("Three")
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "bounded-code-structure",
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let tools = await window.mcpServer.windowMCPTools
        let tool = try XCTUnwrap(tools.first {
            $0.name == MCPWindowToolName.getCodeStructure
        })
        window.mcpServer.resetCodeStructureAdmissionWorkCountsForTesting()

        let value = try await ServerNetworkManager.withConnectionID(connectionID) {
            try await tool([
                "scope": .string("paths"),
                "paths": .array([.string(root.appendingPathComponent("Sources").path)]),
                "limits": .object(["max_files": .int(1)])
            ])
        }

        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, "budget")
        XCTAssertTrue(object["files"]?.arrayValue?.isEmpty == true)
        let issue = try XCTUnwrap(object["issues"]?.arrayValue?.compactMap(\.objectValue).first {
            $0["phase"]?.stringValue == "seed_demand"
        })
        XCTAssertEqual(issue["code"]?.stringValue, "hard_budget_exceeded")
        XCTAssertEqual(issue["attempted"]?.intValue, 2)
        XCTAssertEqual(issue["limit"]?.intValue, 1)

        let admission = window.mcpServer.codeStructureAdmissionWorkCountsForTesting()
        XCTAssertEqual(admission.uniqueSeedCandidatesVisited, 2)
        XCTAssertEqual(admission.logicalPathComputations, 0)
        XCTAssertEqual(admission.coordinatorInvocations, 0)
    }

    func testSelectedScopeRejectsAtLimitPlusOneWithoutContentOrCodemapWork() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/One.swift": SwiftFixtureSource.emptyStruct("One"),
                "Sources/Two.swift": SwiftFixtureSource.emptyStruct("Two"),
                "Sources/Three.swift": SwiftFixtureSource.emptyStruct("Three")
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let rootRefs = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(rootRefs.first)
        let files = await store.files(inRoot: loadedRoot.id).sorted {
            $0.standardizedFullPath < $1.standardizedFullPath
        }
        XCTAssertEqual(files.count, 3)
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        var composeTab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
        composeTab.selection = StoredSelection(selectedPaths: files.map(\.standardizedFullPath))
        window.workspaceManager.updateComposeTab(composeTab, markDirty: false)
        try await AsyncTestWait.waitUntil("selected code structure candidates are cataloged", timeout: 5) {
            let resolution = await store.resolveSelectedCodeStructureFiles(
                atPaths: files.map(\.standardizedFullPath),
                rootScope: .visibleWorkspace,
                maximumUniqueFileCount: 1
            )
            return resolution.didExceedLimit && resolution.visitedUniqueFileCount == 2
        }

        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "bounded-selected-code-structure",
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let tools = await window.mcpServer.windowMCPTools
        let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.getCodeStructure })
        let contentReads = CodeStructureContentReadCounter()
        let fileSystemServiceCandidate = await store.fileSystemServiceForTesting(rootID: loadedRoot.id)
        let fileSystemService = try XCTUnwrap(fileSystemServiceCandidate)
        await fileSystemService.setContentReadChunkHandlerForTesting { _ in
            await contentReads.increment()
        }
        window.mcpServer.resetCodeStructureAdmissionWorkCountsForTesting()

        let value = try await ServerNetworkManager.withConnectionID(connectionID) {
            try await tool([
                "scope": .string("selected"),
                "limits": .object(["max_files": .int(1)])
            ])
        }
        await fileSystemService.setContentReadChunkHandlerForTesting(nil)

        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, "budget")
        let issue = try XCTUnwrap(object["issues"]?.arrayValue?.compactMap(\.objectValue).first {
            $0["phase"]?.stringValue == "seed_demand"
        })
        XCTAssertEqual(issue["code"]?.stringValue, "hard_budget_exceeded")
        XCTAssertEqual(issue["attempted"]?.intValue, 2)
        XCTAssertEqual(issue["limit"]?.intValue, 1)
        let contentReadCount = await contentReads.value
        XCTAssertEqual(contentReadCount, 0)

        let admission = window.mcpServer.codeStructureAdmissionWorkCountsForTesting()
        XCTAssertEqual(admission.uniqueSeedCandidatesVisited, 2)
        XCTAssertEqual(admission.logicalPathComputations, 0)
        XCTAssertEqual(admission.coordinatorInvocations, 0)
    }

    func testSelectedScopeStaleFolderIsIgnoredWhileExactRootAliasResolves() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "CurrentParent/SelectedFolder/Only.swift": SwiftFixtureSource.emptyStruct("Only")
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let rootRefs = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(rootRefs.first)
        let staleFolderPath = "StaleParent/SelectedFolder"

        let staleResolution = await store.resolveSelectedCodeStructureFiles(
            atPaths: [staleFolderPath],
            rootScope: .visibleWorkspace,
            maximumUniqueFileCount: 10
        )
        XCTAssertFalse(staleResolution.didExceedLimit)
        XCTAssertTrue(staleResolution.files.isEmpty)
        XCTAssertEqual(staleResolution.visitedUniqueFileCount, 0)

        let exactAliasResolution = await store.resolveSelectedCodeStructureFiles(
            atPaths: ["\(loadedRoot.name)/CurrentParent/SelectedFolder"],
            rootScope: .visibleWorkspace,
            maximumUniqueFileCount: 10
        )
        XCTAssertFalse(exactAliasResolution.didExceedLimit)
        XCTAssertEqual(
            exactAliasResolution.files.map(\.standardizedRelativePath),
            ["CurrentParent/SelectedFolder/Only.swift"]
        )
    }

    func testPhysicalPathDedupAvoidsFalseOverflowAcrossOverlappingRoots() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: ["Sources/Shared.swift": SwiftFixtureSource.emptyStruct("Shared")]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let outerRoot = try XCTUnwrap(roots.first { $0.standardizedFullPath == root.standardizedFileURL.path })
        let nestedRoot = try await store.loadRoot(path: root.appendingPathComponent("Sources").path)
        let outerFiles = await store.files(inRoot: outerRoot.id)
        let nestedFiles = await store.files(inRoot: nestedRoot.id)
        let outerFile = try XCTUnwrap(outerFiles.first)
        let nestedFile = try XCTUnwrap(nestedFiles.first)
        XCTAssertNotEqual(outerFile.id, nestedFile.id)
        XCTAssertEqual(outerFile.standardizedFullPath, nestedFile.standardizedFullPath)

        let boundedExpansion = await store.expandFolderInputToFiles(
            root.appendingPathComponent("Sources").path,
            rootScope: .allLoaded,
            profile: .mcpSelection,
            excludingStandardizedFullPaths: [nestedFile.standardizedFullPath],
            maximumUniqueFileCount: 0
        )
        XCTAssertTrue(boundedExpansion.handled)
        XCTAssertFalse(boundedExpansion.didExceedLimit)
        XCTAssertTrue(boundedExpansion.files.isEmpty)
        XCTAssertEqual(boundedExpansion.visitedUniqueFileCount, 0)

        window.mcpServer.resetCodeStructureAdmissionWorkCountsForTesting()
        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [outerFile, nestedFile],
            request: request(maximumFiles: 1, maximumCodemapTokens: 0),
            includePathNotFoundIssue: true,
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        )

        XCTAssertFalse(dto.issues.contains { $0.code == "hard_budget_exceeded" })
        XCTAssertTrue(dto.issues.contains { $0.code == "token_limit" })
        let admission = window.mcpServer.codeStructureAdmissionWorkCountsForTesting()
        XCTAssertEqual(admission.logicalPathComputations, 1)
        XCTAssertEqual(admission.coordinatorInvocations, 1)
    }

    func testSeedDemandBudgetRejectsExpandedSeedsBeforeDemand() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/One.swift": SwiftFixtureSource.emptyStruct("One"),
                "Sources/Two.swift": SwiftFixtureSource.emptyStruct("Two")
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(roots.first)
        let files = await store.files(inRoot: loadedRoot.id)
        XCTAssertEqual(files.count, 2)

        window.mcpServer.resetCodeStructureAdmissionWorkCountsForTesting()
        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: files,
            request: request(maximumFiles: 1),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )

        XCTAssertEqual(dto.status, "budget")
        XCTAssertTrue(dto.files.isEmpty)
        XCTAssertEqual(dto.summary.resolvedSeeds, 0)
        let issue = try XCTUnwrap(dto.issues.first { $0.phase == "seed_demand" })
        XCTAssertEqual(issue.code, "hard_budget_exceeded")
        XCTAssertEqual(issue.attempted, 2)
        XCTAssertEqual(issue.limit, 1)
        let admission = window.mcpServer.codeStructureAdmissionWorkCountsForTesting()
        XCTAssertEqual(admission.logicalPathComputations, 0)
        XCTAssertEqual(admission.coordinatorInvocations, 0)
    }

    func testSeedOrderingAndOutputAreDeterministic() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Zeta.swift": "struct Zeta { func zeta() {} }\n",
                "Sources/Alpha.swift": "struct Alpha { func alpha() {} }\n"
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(roots.first)
        let files = await store.files(inRoot: loadedRoot.id)
        XCTAssertEqual(files.count, 2)
        let tickets = try await files.asyncMap { try await readyTicket(store: store, fileID: $0.id) }
        defer {
            Task {
                for ticket in tickets {
                    _ = await store.cancelCodemapArtifactDemand(ticket)
                }
            }
        }

        let first = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: Array(files.reversed()),
            request: request(),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        let second = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: files,
            request: request(),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.status, "ready")
        XCTAssertEqual(first.files.count, 2)
        XCTAssertTrue(first.files[0].path.hasSuffix("Sources/Alpha.swift"), first.files[0].path)
        XCTAssertTrue(first.files[1].path.hasSuffix("Sources/Zeta.swift"), first.files[1].path)
    }

    func testResidentForwardAndReverseExpansionUseRootLocalBoundedTraversal() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": """
                struct Source {
                    let target: Target
                }
                """,
                "Sources/Target.swift": "struct Target { func targetMethod() {} }\n"
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(roots.first)
        let files = await store.files(inRoot: loadedRoot.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let sourceTicket = try await readyTicket(store: store, fileID: source.id)
        let targetTicket = try await readyTicket(store: store, fileID: target.id)
        addTeardownBlock {
            _ = await store.cancelCodemapArtifactDemand(sourceTicket)
            _ = await store.cancelCodemapArtifactDemand(targetTicket)
        }
        let graphClock = ContinuousClock()
        let graphReady = await store.waitForCodemapGraphPublication(
            rootEpoch: sourceTicket.rootEpoch,
            deadline: graphClock.now.advanced(by: .seconds(8))
        )
        XCTAssertTrue(graphReady, "Timed out waiting for root-local codemap graph publication")

        let forward = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [source],
            request: request(direction: .referencedDefinitions, maximumDepth: 2),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        XCTAssertEqual(forward.status, "ready")
        XCTAssertTrue(forward.issues.isEmpty)
        XCTAssertEqual(forward.files.count, 2)
        XCTAssertEqual(forward.files.map(\.path), [
            "repository/Sources/Source.swift",
            "repository/Sources/Target.swift"
        ])
        XCTAssertEqual(forward.files.map(\.role), ["seed", "related"])
        XCTAssertEqual(forward.files.map(\.depth), [0, 1])
        let forwardRelated = try XCTUnwrap(forward.files.first { $0.role == "related" })
        XCTAssertEqual(forwardRelated.reachedBy, ["referenced_definitions"])

        let reverse = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [target],
            request: request(direction: .referrers, maximumDepth: 2),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        XCTAssertEqual(reverse.status, "ready")
        XCTAssertTrue(reverse.issues.isEmpty)
        XCTAssertEqual(reverse.files.count, 2)
        XCTAssertEqual(reverse.files.map(\.path), [
            "repository/Sources/Target.swift",
            "repository/Sources/Source.swift"
        ])
        XCTAssertEqual(reverse.files.map(\.role), ["seed", "related"])
        XCTAssertEqual(reverse.files.map(\.depth), [0, 1])
        let reverseRelated = try XCTUnwrap(reverse.files.first { $0.role == "related" })
        XCTAssertEqual(reverseRelated.reachedBy, ["referrers"])
    }

    func testCodeStructureSucceedsAfterGitDirectoryChurn() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First { func first() {} }\n",
                "Sources/Second.swift": "struct Second { func second() {} }\n",
                "Sources/Third.swift": "struct Third { func third() {} }\n"
            ]
        )
        defer { repositories.cleanup() }
        try repositories.settleIndex(at: root)
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let initial = try await codeStructureDTO(window: window, root: root, path: "Sources/First.swift")
        XCTAssertEqual(initial.status, "ready", "\(initial.issues)")

        for _ in 0 ..< 3 {
            try repositories.churnRepositoryDirectoryTimestamps(at: root, includeWorktreeRoot: false)
            _ = try repositories.runGit(["status", "--porcelain"], at: root)
        }

        for path in ["Sources/Second.swift", "Sources/Third.swift"] {
            let dto = try await codeStructureDTO(window: window, root: root, path: path)
            XCTAssertEqual(dto.status, "ready", "\(path): \(dto.issues)")
            XCTAssertTrue(dto.issues.isEmpty, "\(path): \(dto.issues)")
        }
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 0)
        let counters = try await engineCounters(store: store)
        XCTAssertEqual(counters.repositoryAuthorityChanges, 0)
    }

    func testCodeStructureRecoversOnceAfterIndexAdvance() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First { func first() {} }\n",
                "Sources/Second.swift": "struct Second { func second() {} }\n",
                "Sources/Third.swift": "struct Third { func third() {} }\n",
                "Notes.txt": "notes\n"
            ]
        )
        defer { repositories.cleanup() }
        try repositories.write("notes changed\n", to: "Notes.txt", at: root)
        try repositories.settleIndex(at: root)
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let initial = try await codeStructureDTO(window: window, root: root, path: "Sources/First.swift")
        XCTAssertEqual(initial.status, "ready", "\(initial.issues)")

        try repositories.stage("Notes.txt", at: root)
        let clock = ContinuousClock()
        let started = clock.now
        let recovered = try await codeStructureDTO(window: window, root: root, path: "Sources/Second.swift")
        let elapsed = clock.now - started

        XCTAssertEqual(recovered.status, "ready", "\(recovered.issues)")
        XCTAssertTrue(recovered.issues.isEmpty, "\(recovered.issues)")
        XCTAssertLessThan(elapsed, .seconds(10))
        let repairCountAfterRecovery = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterRecovery, 1)

        let following = try await codeStructureDTO(window: window, root: root, path: "Sources/Third.swift")
        XCTAssertEqual(following.status, "ready", "\(following.issues)")
        let repairCountAfterFollowing = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterFollowing, 1)
        let counters = try await engineCounters(store: store)
        XCTAssertEqual(counters.repositoryAuthorityChanges, 1)
    }

    func testConcurrentAuthorityRepairReissuesAllSiblingSeeds() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        var files = ["Notes.txt": "notes\n"]
        for name in ["Held", "Alpha", "Beta", "Gamma", "Delta"] {
            files["Sources/\(name).swift"] = "struct \(name) { func run() {} }\n"
        }
        let root = try repositories.makeRepository(named: "repository", files: files)
        defer { repositories.cleanup() }
        try repositories.write("notes changed\n", to: "Notes.txt", at: root)
        try repositories.settleIndex(at: root)
        let barrier = CodeStructureDistinctDemandBarrier(expectedFileCount: 4)
        let window = try await makeWindow(
            root: root,
            codemapDemandResultHook: { ticket, result in
                await barrier.passThrough(ticket: ticket, result: result)
            }
        )
        let store = window.workspaceFileContextStore
        let records = try await ["Held", "Alpha", "Beta", "Gamma", "Delta"].asyncMap { name in
            try await fileRecord(
                at: root.appendingPathComponent("Sources/\(name).swift"),
                store: store,
                rootScope: .visibleWorkspace
            )
        }
        await barrier.ignore(fileID: records[0].id)
        let heldTicket = try await readyTicket(store: store, fileID: records[0].id)
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(heldTicket) }

        try repositories.stage("Notes.txt", at: root)
        let mcpServer = window.mcpServer
        let firstRecords = Array(records[1 ... 3])
        let secondRecords = Array(records[2 ... 4])
        async let first = mcpServer.buildCodeStructureDTO(
            fromRecords: firstRecords,
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true
        )
        async let second = mcpServer.buildCodeStructureDTO(
            fromRecords: secondRecords,
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true
        )
        let (firstDTO, secondDTO) = try await (first, second)

        let overlapped = await barrier.didReleaseByArrival()
        XCTAssertTrue(overlapped, "Both operations must overlap at the rejection.")
        XCTAssertEqual(firstDTO.status, "ready", "\(firstDTO.issues)")
        XCTAssertEqual(secondDTO.status, "ready", "\(secondDTO.issues)")
        XCTAssertEqual(firstDTO.files.count, 3)
        XCTAssertEqual(secondDTO.files.count, 3)
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1)
        let heldStatus = await store.codemapArtifactDemandStatus(heldTicket)
        guard case .unavailable(.staleCurrentness) = heldStatus else {
            return XCTFail("The pre-reset ticket must be stale after the root session reset: \(heldStatus)")
        }
    }

    /// A root session repair replaces the session that held an idle (released, warm) ready record:
    /// the old token stays stale and the next request for that file is a fresh demand in the
    /// replacement session instead of joining old cached state.
    func testSessionRepairRejectsIdleReadyRecordFromReplacedSession() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First { func first() {} }\n",
                "Sources/Second.swift": "struct Second { func second() {} }\n",
                "Notes.txt": "notes\n"
            ]
        )
        defer { repositories.cleanup() }
        try repositories.write("notes changed\n", to: "Notes.txt", at: root)
        try repositories.settleIndex(at: root)
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let first = try await fileRecord(
            at: root.appendingPathComponent("Sources/First.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let second = try await fileRecord(
            at: root.appendingPathComponent("Sources/Second.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let idleTicket = try await readyTicket(store: store, fileID: first.id)
        let released = await store.cancelCodemapArtifactDemand(idleTicket)
        XCTAssertTrue(released)
        let idleBeforeRepair = await store.codemapIdleReadyDemandFileIDsForTesting(rootEpoch: idleTicket.rootEpoch)
        XCTAssertEqual(idleBeforeRepair, [first.id])

        try repositories.stage("Notes.txt", at: root)
        let requested = await store.requestCodemapArtifactWithOwnership(forFileID: second.id)
        guard case let .pending(driftTicket) = requested.result else {
            return XCTFail("Expected a pending demand, got \(requested.result)")
        }
        let rejected = await waitForDemandResult(store: store, ticket: driftTicket) {
            if case .unavailable(.rejected(.repositoryAuthorityChanged)) = $0 { return true }
            return false
        }
        XCTAssertTrue(rejected)
        let repaired = await store.prepareCodemapRootSessionRetry(
            driftTicket,
            rejection: .repositoryAuthorityChanged,
            priority: .demand,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        let replacement = try XCTUnwrap(repaired)
        let replacementTicket = try XCTUnwrap(demandTicket(from: replacement.result))
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(replacementTicket) }
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1)

        let oldStatus = await store.codemapArtifactDemandStatus(idleTicket)
        guard case .unavailable(.staleCurrentness) = oldStatus else {
            return XCTFail("The released pre-repair token must stay stale: \(oldStatus)")
        }
        let idleAfterRepair = await store.codemapIdleReadyDemandFileIDsForTesting(rootEpoch: idleTicket.rootEpoch)
        XCTAssertTrue(idleAfterRepair.isEmpty)
        let fresh = await store.requestCodemapArtifactWithOwnership(forFileID: first.id)
        guard case let .created(freshTicket) = fresh.ownership else {
            return XCTFail("The replacement session must create a fresh demand: \(fresh.ownership)")
        }
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(freshTicket) }
        XCTAssertNotEqual(freshTicket.requestID, idleTicket.requestID)
        let freshReady = await waitForDemandResult(store: store, ticket: freshTicket) {
            if case .ready = $0 { return true }
            return false
        }
        XCTAssertTrue(freshReady)
    }

    func testOldTicketCannotResetReplacementSession() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First { func first() {} }\n",
                "Sources/Second.swift": "struct Second { func second() {} }\n",
                "Notes.txt": "notes\n"
            ]
        )
        defer { repositories.cleanup() }
        try repositories.write("notes changed\n", to: "Notes.txt", at: root)
        try repositories.settleIndex(at: root)
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let initial = try await codeStructureDTO(window: window, root: root, path: "Sources/First.swift")
        XCTAssertEqual(initial.status, "ready", "\(initial.issues)")

        try repositories.stage("Notes.txt", at: root)
        let second = try await fileRecord(
            at: root.appendingPathComponent("Sources/Second.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let requested = await store.requestCodemapArtifactWithOwnership(forFileID: second.id)
        guard case let .pending(oldTicket) = requested.result else {
            return XCTFail("Expected a pending demand, got \(requested.result)")
        }
        let rejected = await waitForDemandResult(store: store, ticket: oldTicket) {
            if case .unavailable(.rejected(.repositoryAuthorityChanged)) = $0 { return true }
            return false
        }
        XCTAssertTrue(rejected)

        let repaired = await store.prepareCodemapRootSessionRetry(
            oldTicket,
            rejection: .repositoryAuthorityChanged,
            priority: .demand,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        let replacement = try XCTUnwrap(repaired)
        let replacementTicket = try XCTUnwrap(demandTicket(from: replacement.result))
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(replacementTicket) }
        let replacementReady = await waitForDemandResult(store: store, ticket: replacementTicket) {
            if case .ready = $0 { return true }
            return false
        }
        XCTAssertTrue(replacementReady)
        let repairCountAfterReset = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterReset, 1)

        let replay = await store.prepareCodemapRootSessionRetry(
            oldTicket,
            rejection: .repositoryAuthorityChanged,
            priority: .demand,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        XCTAssertNil(replay)
        let repairCountAfterReplay = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterReplay, 1)
        let replacementStatus = await store.codemapArtifactDemandStatus(replacementTicket)
        guard case .ready = replacementStatus else {
            return XCTFail("The old ticket must not disturb the replacement session: \(replacementStatus)")
        }
    }

    func testContinuedAuthorityChangesExhaustOneRootRepair() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/First.swift": "struct First { func first() {} }\n",
                "Sources/Second.swift": "struct Second { func second() {} }\n",
                "Sources/Third.swift": "struct Third { func third() {} }\n",
                "Notes.txt": "notes\n",
                "Extra.txt": "extra\n"
            ]
        )
        defer { repositories.cleanup() }
        try repositories.write("notes changed\n", to: "Notes.txt", at: root)
        try repositories.write("extra changed\n", to: "Extra.txt", at: root)
        try repositories.settleIndex(at: root)
        let advance = CodeStructureAuthorityAdvanceAfterReset(
            repositories: repositories,
            root: root,
            relativePath: "Extra.txt"
        )
        let window = try await makeWindow(
            root: root,
            capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterSourcePathFingerprintCapture: { advance.observeIssuance() }
            )
        )
        let store = window.workspaceFileContextStore
        let initial = try await codeStructureDTO(window: window, root: root, path: "Sources/First.swift")
        XCTAssertEqual(initial.status, "ready", "\(initial.issues)")

        try repositories.stage("Notes.txt", at: root)
        advance.arm()
        let clock = ContinuousClock()
        let started = clock.now
        let exhausted = try await codeStructureDTO(window: window, root: root, path: "Sources/Second.swift")
        let elapsed = clock.now - started

        XCTAssertTrue(advance.didAdvance(), "The second authority change must land after the replacement registration.")
        XCTAssertEqual(exhausted.status, "unavailable", "\(exhausted.issues)")
        let issue = try XCTUnwrap(exhausted.issues.first)
        XCTAssertEqual(issue.detail, "binding_rejected.repository_authority_changed")
        XCTAssertTrue(issue.retryable)
        XCTAssertLessThan(elapsed, .seconds(10))
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1, "One operation may spend at most one root-session reset.")

        let retried = try await codeStructureDTO(window: window, root: root, path: "Sources/Third.swift")
        XCTAssertEqual(retried.status, "ready", "\(retried.issues)")
        let repairCountAfterRetry = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterRetry, 2)
    }

    func testCodeStructureToolSurvivesIndexAdvanceAndInterleavedStatus() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        var files = ["Notes.txt": "notes\n"]
        for index in 0 ... 5 {
            files["Sources/File\(index).swift"] = "struct File\(index) { func method\(index)() {} }\n"
        }
        let root = try repositories.makeRepository(named: "repository", files: files)
        defer { repositories.cleanup() }
        try repositories.write("notes changed\n", to: "Notes.txt", at: root)
        try repositories.settleIndex(at: root)
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let invoke = try await codeStructureToolInvoker(window: window)

        let initial = try await invoke(root.appendingPathComponent("Sources/File0.swift").path)
        XCTAssertEqual(initial.status, "ready", "\(initial.issues)")

        try repositories.stage("Notes.txt", at: root)
        for index in 1 ... 5 {
            _ = try repositories.runGit(["status", "--porcelain"], at: root)
            let reply = try await invoke(root.appendingPathComponent("Sources/File\(index).swift").path)
            XCTAssertEqual(reply.status, "ready", "File\(index): \(reply.issues)")
            XCTAssertFalse(
                reply.issues.contains { $0.code == "artifact_unavailable" },
                "File\(index): \(reply.issues)"
            )
            XCTAssertTrue(reply.issues.isEmpty, "File\(index): \(reply.issues)")
        }
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1)
    }

    func testRetainedProjectionPreloadStopsAfterIndexAdvanceAndForegroundRecoversOnce() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        var files = ["Notes.txt": "notes\n"]
        for index in 0 ..< 20 {
            files["Sources/File\(index).swift"] = "struct File\(index) { func method\(index)() {} }\n"
        }
        let root = try repositories.makeRepository(named: "repository", files: files)
        defer { repositories.cleanup() }
        try repositories.write("notes changed\n", to: "Notes.txt", at: root)
        try repositories.settleIndex(at: root)
        let stage = CodeStructureOneShotGitStage(repositories: repositories, root: root, relativePath: "Notes.txt")
        let window = try await makeWindow(
            root: root,
            projectionPreloadLaunchPolicy: .enabled,
            prepareStore: { store in
                await store.setCodemapProjectionCatalogBuildHandlerForTesting { _ in
                    stage.stageOnce()
                }
            }
        )
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let rootID = try XCTUnwrap(roots.first?.id)

        let clock = ContinuousClock()
        let settleDeadline = clock.now.advanced(by: .seconds(8))
        var settledCounters: WorkspaceCodemapBindingEngineCounters?
        while clock.now < settleDeadline {
            if stage.snapshot().didStage,
               let counters = await store.codemapBindingEngineAccountingForTesting(rootID: rootID)?.counters,
               counters.projectionRetries > 0
               || counters.projectionCoveragesCancelled > 0
               || counters.projectionCoveragesCompleted > 0
            {
                settledCounters = counters
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(stage.snapshot().error)
        let before = try XCTUnwrap(settledCounters, "Projection preload never observed the staged index change.")
        XCTAssertLessThanOrEqual(before.repositoryAuthorityChanges, 1)
        let latchedStore = try await storePreloadState(store: store, rootID: rootID)
        XCTAssertEqual(
            latchedStore.launchPhase,
            .handedOff,
            "The handed-off launch stays current, so store triggers cannot relaunch it."
        )
        assertNoStorePreloadRetry(latchedStore)

        try await Task.sleep(for: storePreloadRetryHorizon)
        let idleStore = try await storePreloadState(store: store, rootID: rootID)
        XCTAssertEqual(
            idleStore,
            latchedStore,
            "No store event, relaunch, or timer retry may follow the latch within the maximum store backoff."
        )
        let afterIdleAccounting = await store.codemapBindingEngineAccountingForTesting(rootID: rootID)
        let afterIdle = try XCTUnwrap(afterIdleAccounting?.counters)
        XCTAssertEqual(afterIdle.capabilityResolutions, before.capabilityResolutions)
        XCTAssertEqual(afterIdle.repositoryAuthorityChanges, before.repositoryAuthorityChanges)
        XCTAssertEqual(
            afterIdle.projectionRetries,
            before.projectionRetries,
            "A root-wide authority change must not keep the projection job in a timer retry loop."
        )
        XCTAssertEqual(
            afterIdle.projectionPreloadsScheduled,
            before.projectionPreloadsScheduled,
            "A latched authority failure must not reschedule projection preload."
        )
        XCTAssertEqual(afterIdle.projectionPreloadsStarted, before.projectionPreloadsStarted)
        XCTAssertEqual(afterIdle.manifestLoads, before.manifestLoads)
        XCTAssertEqual(afterIdleAccounting?.projectionJobCount, 0)
        let repairCountBeforeForeground = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountBeforeForeground, 0, "Background detection must not reset the root session.")

        let foreground = try await codeStructureDTO(window: window, root: root, path: "Sources/File7.swift")
        XCTAssertEqual(foreground.status, "ready", "\(foreground.issues)")
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1)
    }

    func testReferrersExpansionFromRetainedSeedUsesColdProjection() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source {\n    let target: Target\n}\n",
                "Sources/Target.swift": "struct Target { func targetMethod() {} }\n"
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        try repositories.settleIndex(at: root)
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let target = try await fileRecord(
            at: root.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let targetTicket = try await readyTicket(store: store, fileID: target.id)
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(targetTicket) }

        let reverse = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [target],
            request: request(direction: .referrers, maximumDepth: 1),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )

        XCTAssertEqual(reverse.status, "ready", "\(reverse.issues)")
        XCTAssertEqual(reverse.files.map(\.path), [
            "repository/Sources/Target.swift",
            "repository/Sources/Source.swift"
        ])
    }

    func testReferrersExpansionFromRetainedSeedRecoversAfterIndexAdvance() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source {\n    let target: Target\n}\n",
                "Sources/Target.swift": "struct Target { func targetMethod() {} }\n",
                "Notes.txt": "notes\n"
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        try repositories.write("notes changed\n", to: "Notes.txt", at: root)
        try repositories.settleIndex(at: root)
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let target = try await fileRecord(
            at: root.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let targetTicket = try await readyTicket(store: store, fileID: target.id)
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(targetTicket) }

        try repositories.stage("Notes.txt", at: root)
        let clock = ContinuousClock()
        let started = clock.now
        let reverse = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [target],
            request: request(direction: .referrers, maximumDepth: 1),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        let elapsed = clock.now - started
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        let targetStatus = await store.codemapArtifactDemandStatus(targetTicket)

        XCTAssertEqual(reverse.status, "ready", "\(reverse.issues) repairs=\(repairCount)")
        XCTAssertEqual(reverse.files.map(\.path), [
            "repository/Sources/Target.swift",
            "repository/Sources/Source.swift"
        ])
        XCTAssertLessThan(elapsed, .seconds(10))
        XCTAssertEqual(repairCount, 1, "The projection authority failure must spend exactly one root reset.")
        guard case .unavailable(.staleCurrentness) = targetStatus else {
            return XCTFail("The retained pre-reset seed ticket must be stale: \(targetStatus)")
        }

        let repeated = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [target],
            request: request(direction: .referrers, maximumDepth: 1),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        XCTAssertEqual(repeated.status, "ready", "\(repeated.issues)")
        XCTAssertEqual(repeated.files.map(\.path), [
            "repository/Sources/Target.swift",
            "repository/Sources/Source.swift"
        ])
        let repairCountAfterRepeat = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterRepeat, 1, "A later expansion on the replacement must not reset again.")
    }

    func testReferrersExpansionAfterCompletedBaselineRecoversFromIndexOnlyStage() async throws {
        try await assertReferrersExpansionRecoversAfterRepositoryMutation(.stageExistingNonSource)
    }

    func testReferrersExpansionAfterCompletedBaselineRecoversFromEmptyCommit() async throws {
        try await assertReferrersExpansionRecoversAfterRepositoryMutation(.emptyCommit)
    }

    func testReferrersExpansionAfterCompletedBaselineRecoversFromOverlappedCreateAndStage() async throws {
        try await assertReferrersExpansionRecoversAfterRepositoryMutation(.createAndStage)
    }

    func testReferrersExpansionAfterCompletedBaselineIncludesUnstagedStoreCreateWithoutRepair() async throws {
        try await assertReferrersExpansionRecoversAfterRepositoryMutation(.createUnstaged)
    }

    /// Production path: nothing evicts the idle ready seeds after a Git mutation, so the recovery
    /// request joins them warm. Every mutation must still answer ready with the expected files;
    /// the root-session repair counts are the ones production actually produces.
    func testReferrersExpansionWithoutIdleEvictionStaysReadyAfterRepositoryMutations() async throws {
        for mutation in [
            ReferrersRecoveryMutation.stageExistingNonSource,
            .emptyCommit,
            .createAndStage,
            .createUnstaged
        ] {
            try await assertReferrersExpansionRecoversAfterRepositoryMutation(
                mutation,
                evictIdleSeedsBeforeRecovery: false
            )
        }
    }

    /// Live catalog-only lane counterpart: MCP `apply_edits` creates a third top-level source and, as
    /// in production, selects it, so the window's automatic codemap consumer works the same root while
    /// the next MCP referrers expansion publishes. That expansion and an unchanged repeat must return
    /// all three files ready within 10 seconds, with no root reset and no Git drift.
    func testReferrersExpansionAfterCompletedBaselineIncludesApplyEditsCreatedSelectedSource() async throws {
        let fixture = try await makeControlReferrersFixtureAfterReadyBaseline(
            name: "referrers-apply-edits-create-select"
        )
        let window = fixture.window
        let store = window.workspaceFileContextStore

        let addedURL = fixture.root.appendingPathComponent(Self.controlAddedFileName)
        let edit = try await applyEditsCreateControlSource(fixture.invoke, at: addedURL)
        XCTAssertEqual(try String(contentsOf: addedURL, encoding: .utf8), Self.controlAddedSource, "\(edit)")
        XCTAssertTrue(
            activeSelectionContainsControlAddedSource(window),
            "The production apply_edits create must select the new source: \(edit)"
        )

        let countsBefore = await store.codemapPresentationOperationCountsForTesting()
        let clock = ContinuousClock()
        let started = clock.now
        let recovered = try await controlPayloadReferrers(fixture.invoke)
        let elapsed = clock.now - started
        let repairs = await store.codemapRootSessionRepairCountForTesting()
        let countsAfter = await store.codemapPresentationOperationCountsForTesting()
        let diagnostics = "status=\(recovered.status) elapsed=\(elapsed) repairs=\(repairs) " +
            "issues=\(recovered.issues) \(automaticConsumerSummary(window)) " +
            "artifactDemandRequests+=\(countsAfter.artifactDemandRequests - countsBefore.artifactDemandRequests) " +
            "candidateRequests+=\(countsAfter.presentationCandidateRequests - countsBefore.presentationCandidateRequests) " +
            "graphWorkerStarts+=\(countsAfter.graphWorkerStarts - countsBefore.graphWorkerStarts)"
        XCTAssertEqual(recovered.status, "ready", diagnostics)
        XCTAssertEqual(Set(recovered.files.map(\.path)), Self.controlExpandedPaths, diagnostics)
        XCTAssertLessThan(elapsed, .seconds(10), diagnostics)
        XCTAssertEqual(repairs, 0, "Root resets: \(diagnostics)")

        try await assertControlUnchangedRepeatReadyWithoutGitDrift(fixture, context: "apply_edits create")

        // Fixture faithfulness: the window's production automatic codemap consumer received the
        // selected new source, so the expansions above ran beside it rather than in isolation.
        let consumerSummary = automaticConsumerSummary(window)
        XCTAssertTrue(window.workspaceFilesViewModel.codemapAutoEnabled, consumerSummary)
        XCTAssertTrue(
            window.workspaceFilesViewModel.selectedFiles.contains {
                $0.standardizedFullPath.hasSuffix("/\(Self.controlAddedFileName)")
            },
            "The automatic consumer must observe the created selection: \(consumerSummary)"
        )
    }

    /// Coordinator-level pair for the live catalog-only lane. The same third source is created either
    /// through MCP `apply_edits` (which selects it and engages the automatic codemap consumer) or through
    /// the store without selection; the next referrers structure publication must be ready with all
    /// three files in both cases. Timing-only hooks record each attempt and the final typed reason.
    func testReferrersStructureAfterSourceCreatePublishesWithAndWithoutCreatedSelection() async throws {
        for create in [ControlReferrersCreate.applyEditsCreateAndSelect, .storeCreateWithoutSelection] {
            try await assertControlReferrersStructurePublishes(after: create)
        }
    }

    /// Cancelling the structure task after its first attempt begins still emits one record: the
    /// attempt's completed checkpoints, ownership cleanup, and a `cancelled` terminal. The caller
    /// still receives `CancellationError`, and the next MCP query is ready without root resets.
    func testStructureDiagnosticsRecordCancelledAttemptCleanupAndRethrowCancellation() async throws {
        let fixture = try await makeControlReferrersFixtureAfterReadyBaseline(
            name: "referrers-diagnostics-cancellation"
        )
        let store = fixture.window.workspaceFileContextStore
        let payload = try await fileRecord(
            at: fixture.root.appendingPathComponent("ControlPayload.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let diagnosticRecords = CodemapLockedValues<WorkspaceCodemapStructureDiagnosticRecord>()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            structureAttemptDidBegin: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            },
            structureDiagnosticSink: { diagnosticRecords.append($0) }
        )
        let task = Task {
            try await coordinator.structurePresentation(
                seedFileIDs: [payload.id],
                direction: .referrers,
                traversalLimits: WorkspaceCodemapStructureTraversalLimits(
                    maximumDepth: 1,
                    maximumNodeCount: 10,
                    maximumEdgeCount: 500,
                    maximumByteCount: 8 * 1024 * 1024
                ),
                outputLimits: WorkspaceCodemapStructureOutputLimits(
                    maximumFileCount: 10,
                    maximumCodemapTokenCount: 6000
                ),
                rootScope: .visibleWorkspace
            )
        }
        do {
            let presentation = try await task.value
            XCTFail("Cancelled structure presentation must throw, got \(presentation.outcome)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        let records = diagnosticRecords.values
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        let logLines = record.logLines(emissionSequence: 1)
        XCTAssertEqual(record.terminal.disposition, .cancelled, "\(logLines)")
        XCTAssertTrue(record.terminal.cancelled, "\(logLines)")
        XCTAssertNil(record.terminal.outcome, "\(logLines)")
        XCTAssertNil(record.terminal.staleReason, "\(logLines)")
        XCTAssertEqual(record.terminal.attemptsStarted, 1, "\(logLines)")
        XCTAssertEqual(record.terminal.finalAttempt, 0, "\(logLines)")
        XCTAssertEqual(record.terminal.finalPhase, .cleanup, "\(logLines)")
        XCTAssertEqual(record.droppedCheckpointCount, 0, "\(logLines)")
        // Seed admission and candidate collection complete; artifact demand observes cancellation
        // before requesting anything, and the attempt's ownership is still released.
        XCTAssertEqual(
            record.checkpoints.map(\.phase),
            [.attemptBegin, .seedAdmission, .seedCandidates, .cleanup],
            "\(logLines)"
        )
        XCTAssertTrue(
            record.tokens.contains("terminal=cancelled") && record.tokens.contains("cancelled=true"),
            "\(logLines)"
        )
        assertControlDiagnosticLogLinesPrivacySafe(logLines, context: "cancellation")

        let followUp = try await controlPayloadReferrers(fixture.invoke)
        let repairs = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(followUp.status, "ready", "\(followUp.issues)")
        XCTAssertEqual(Set(followUp.files.map(\.path)), Self.controlBaselinePaths, "\(followUp.issues)")
        XCTAssertEqual(repairs, 0)
    }

    func testRootAttributedCodemapCountersIsolateRootsAndSurviveSessionRepair() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let files = [
            "Sources/Source.swift": "struct Source {\n    let target: Target\n}\n",
            "Sources/Target.swift": "struct Target { func targetMethod() {} }\n",
            "Notes.txt": "notes\n"
        ]
        let rootA = try repositories.makeRepository(named: "alpha", files: files)
        let rootB = try repositories.makeRepository(named: "beta", files: files)
        addTeardownBlock { repositories.cleanup() }
        for root in [rootA, rootB] {
            try repositories.write("notes changed\n", to: "Notes.txt", at: root)
            try repositories.settleIndex(at: root)
        }
        let window = try await makeWindow(
            root: rootA,
            additionalRoots: [rootB],
            projectionPreloadLaunchPolicy: .enabled
        )
        let store = window.workspaceFileContextStore
        let targetA = try await fileRecord(
            at: rootA.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let targetB = try await fileRecord(
            at: rootB.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        XCTAssertNotEqual(targetA.rootID, targetB.rootID)
        for target in [targetA, targetB] {
            let baseline = try await referrersDTO(window: window, record: target)
            XCTAssertEqual(baseline.status, "ready", "baseline \(baseline.issues)")
        }
        let baselineAttributionA = await store.debugCodemapRootAttribution(rootID: targetA.rootID)
        let baselineA = try XCTUnwrap(baselineAttributionA)
        let baselineAttributionB = await store.debugCodemapRootAttribution(rootID: targetB.rootID)
        let baselineB = try XCTUnwrap(baselineAttributionB)
        XCTAssertNotEqual(baselineA.rootEpoch, baselineB.rootEpoch)
        for baseline in [baselineA, baselineB] {
            XCTAssertEqual(baseline.storeSessionRepairs, 0)
            XCTAssertEqual(baseline.repositoryAuthorityChanges, 0)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(baseline.capabilityResolutions), 1)
        }

        // An authority change and session repair on B leave A's attribution untouched. Evicting B's
        // idle ready records makes the next request take the cold path that observes the drift.
        try repositories.stage("Notes.txt", at: rootB)
        _ = try await evictIdleCodemapDemands(store: store, rootID: targetB.rootID)
        let repairedB = try await referrersDTO(window: window, record: targetB)
        XCTAssertEqual(repairedB.status, "ready", "B repair \(repairedB.issues)")
        let afterBAttributionA = await store.debugCodemapRootAttribution(rootID: targetA.rootID)
        XCTAssertEqual(afterBAttributionA, baselineA)
        let afterBAttributionB = await store.debugCodemapRootAttribution(rootID: targetB.rootID)
        let afterB = try XCTUnwrap(afterBAttributionB)
        XCTAssertEqual(afterB.rootEpoch, baselineB.rootEpoch)
        XCTAssertEqual(afterB.storeSessionRepairs, 1)
        XCTAssertEqual(afterB.capabilityResolutions, baselineB.capabilityResolutions.map { $0 + 1 })
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(afterB.repositoryAuthorityChanges), 1)

        // A's replacement session keeps A's cumulative counts and still leaves B untouched.
        try repositories.stage("Notes.txt", at: rootA)
        _ = try await evictIdleCodemapDemands(store: store, rootID: targetA.rootID)
        let repairedA = try await referrersDTO(window: window, record: targetA)
        XCTAssertEqual(repairedA.status, "ready", "A repair \(repairedA.issues)")
        let afterAAttributionB = await store.debugCodemapRootAttribution(rootID: targetB.rootID)
        XCTAssertEqual(afterAAttributionB, afterB)
        let afterAAttributionA = await store.debugCodemapRootAttribution(rootID: targetA.rootID)
        let afterA = try XCTUnwrap(afterAAttributionA)
        XCTAssertEqual(afterA.rootEpoch, baselineA.rootEpoch)
        XCTAssertEqual(afterA.storeSessionRepairs, 1)
        XCTAssertEqual(afterA.capabilityResolutions, baselineA.capabilityResolutions.map { $0 + 1 })
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(afterA.repositoryAuthorityChanges), 1)
        let storeWideRepairs = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(storeWideRepairs, 2)
    }

    func testProjectionAuthorityFailurePersistsAcrossPollingAndResetsOnceByTicket() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeReferrersRepository(repositories)
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let target = try await fileRecord(
            at: root.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let targetTicket = try await readyTicket(store: store, fileID: target.id)
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(targetTicket) }

        try repositories.stage("Notes.txt", at: root)
        let acquisition = await store.acquireCodemapProjectionDemand(
            sourceTickets: [targetTicket],
            deadlineUptimeNanoseconds: codeStructureProjectionDeadline(after: .seconds(60))
        )
        guard case let .acquired(projectionTicket, _) = acquisition else {
            return XCTFail("Expected a retained projection ticket: \(acquisition)")
        }
        addTeardownBlock { _ = await store.releaseCodemapProjectionDemand(projectionTicket) }
        let failed = await waitForProjectionStatus(store: store, ticket: projectionTicket) {
            self.isProjectionAuthorityFailure($0)
        }
        XCTAssertTrue(isProjectionAuthorityFailure(failed), "\(failed)")
        guard isProjectionAuthorityFailure(failed) else { return }

        let latched = try await engineAccounting(store: store)
        XCTAssertEqual(latched.projectionJobCount, 0, "The latched failure must end the projection job.")
        XCTAssertEqual(latched.counters.repositoryAuthorityChanges, 1)
        let latchedActivity = CodeStructureProjectionActivity(latched.counters)
        for _ in 0 ..< 20 {
            let status = await store.codemapProjectionDemandStatus(projectionTicket)
            XCTAssertTrue(isProjectionAuthorityFailure(status), "Polling must preserve the failure: \(status)")
            try await Task.sleep(for: .milliseconds(25))
        }
        let reacquired = await store.acquireCodemapProjectionDemand(
            sourceTickets: [targetTicket],
            deadlineUptimeNanoseconds: codeStructureProjectionDeadline(after: .seconds(60))
        )
        guard case let .acquired(siblingTicket, siblingStatus) = reacquired else {
            return XCTFail("A demand on the latched session must still carry a ticket: \(reacquired)")
        }
        addTeardownBlock { _ = await store.releaseCodemapProjectionDemand(siblingTicket) }
        XCTAssertTrue(isProjectionAuthorityFailure(siblingStatus), "\(siblingStatus)")
        let siblingPolled = await store.codemapProjectionDemandStatus(siblingTicket)
        XCTAssertTrue(isProjectionAuthorityFailure(siblingPolled), "\(siblingPolled)")
        let afterPolling = try await engineAccounting(store: store)
        XCTAssertEqual(afterPolling.projectionJobCount, 0)
        XCTAssertEqual(
            CodeStructureProjectionActivity(afterPolling.counters),
            latchedActivity,
            "Polling and reacquisition must not schedule, reload, or recapture against the latched session."
        )
        let repairCountAfterPolling = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterPolling, 0)

        let wrongReason = await store.prepareCodemapProjectionRootSessionRetry(
            projectionTicket,
            reason: .capabilityUnavailable,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        XCTAssertEqual(wrongReason, .stale)
        let notRecoverable = await store.prepareCodemapProjectionRootSessionRetry(
            projectionTicket,
            reason: .generationMismatch,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        XCTAssertEqual(notRecoverable, .stale)
        let expired = await store.prepareCodemapProjectionRootSessionRetry(
            projectionTicket,
            reason: .repositoryAuthorityChanged,
            deadline: ContinuousClock.now.advanced(by: .milliseconds(-1))
        )
        XCTAssertEqual(expired, .deadlineReached)
        let cancelledCall = Task {
            try? await Task.sleep(for: .seconds(30))
            return await store.prepareCodemapProjectionRootSessionRetry(
                projectionTicket,
                reason: .repositoryAuthorityChanged,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        }
        cancelledCall.cancel()
        let cancelled = await cancelledCall.value
        XCTAssertEqual(cancelled, .cancelled)
        let repairCountAfterRefusals = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterRefusals, 0, "Refused preparations must not detach.")

        let prepared = await store.prepareCodemapProjectionRootSessionRetry(
            projectionTicket,
            reason: .repositoryAuthorityChanged,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        XCTAssertEqual(prepared, .prepared)
        let replay = await store.prepareCodemapProjectionRootSessionRetry(
            projectionTicket,
            reason: .repositoryAuthorityChanged,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        XCTAssertEqual(replay, .stale)
        let siblingReset = await store.prepareCodemapProjectionRootSessionRetry(
            siblingTicket,
            reason: .repositoryAuthorityChanged,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        XCTAssertEqual(siblingReset, .stale, "Detachment removes every projection record for the root.")
        let repairCountAfterReset = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterReset, 1)
        let oldProjectionStatus = await store.codemapProjectionDemandStatus(projectionTicket)
        XCTAssertEqual(oldProjectionStatus, .stale)
        let targetStatus = await store.codemapArtifactDemandStatus(targetTicket)
        guard case .unavailable(.staleCurrentness) = targetStatus else {
            return XCTFail("The pre-reset seed ticket must be stale: \(targetStatus)")
        }

        let reverse = try await referrersDTO(window: window, record: target)
        XCTAssertEqual(reverse.status, "ready", "\(reverse.issues)")
        XCTAssertEqual(reverse.files.map(\.path), referrerPaths)
        let repairCountAfterExpansion = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterExpansion, 1)
    }

    func testBackgroundProjectionDriftStaysIdleUntilForegroundAcquisitionRepairsOnce() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeReferrersRepository(repositories)
        addTeardownBlock { repositories.cleanup() }
        // Hold the background preload launch until the retained seed is ready and the index moved.
        let launchGate = CodeStructureOpenGate()
        addTeardownBlock { launchGate.open() }
        let window = try await makeWindow(
            root: root,
            projectionPreloadLaunchPolicy: .enabled,
            prepareStore: { store in
                await store.setCodemapProjectionPreloadStartHandlerForTesting { _ in
                    await launchGate.waitUntilOpened()
                }
            }
        )
        let store = window.workspaceFileContextStore
        let target = try await fileRecord(
            at: root.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let targetTicket = try await readyTicket(store: store, fileID: target.id)
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(targetTicket) }

        try repositories.stage("Notes.txt", at: root)
        launchGate.open()
        let detected = try await waitForEngineAccounting(store: store) {
            $0.counters.repositoryAuthorityChanges >= 1 && $0.projectionJobCount == 0
        }
        XCTAssertTrue(launchGate.didHoldCaller(), "The background preload launch must start behind the gate.")
        XCTAssertEqual(detected.counters.repositoryAuthorityChanges, 1, "Preload must detect the drift once.")
        XCTAssertEqual(detected.projectionJobCount, 0)
        XCTAssertGreaterThanOrEqual(detected.counters.projectionCoveragesCancelled, 1)
        let detectedActivity = CodeStructureProjectionActivity(detected.counters)
        let rootID = targetTicket.rootEpoch.rootID
        let detectedStore = try await storePreloadState(store: store, rootID: rootID)
        XCTAssertEqual(detectedStore.launchPhase, .handedOff)
        assertNoStorePreloadRetry(detectedStore)

        try await Task.sleep(for: storePreloadRetryHorizon)
        let idleStore = try await storePreloadState(store: store, rootID: rootID)
        XCTAssertEqual(
            idleStore,
            detectedStore,
            "No store event, relaunch, or timer retry may follow the latch within the maximum store backoff."
        )
        let idle = try await engineAccounting(store: store)
        XCTAssertEqual(idle.projectionJobCount, 0)
        XCTAssertEqual(
            CodeStructureProjectionActivity(idle.counters),
            detectedActivity,
            "A latched background failure must stay idle without rescheduling."
        )
        let repairCountWhileIdle = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountWhileIdle, 0, "Background detection must not reset the root session.")
        let retainedSeed = await store.codemapArtifactDemandStatus(targetTicket)
        guard case .ready = retainedSeed else {
            return XCTFail("No autonomous reset may disturb the retained seed: \(retainedSeed)")
        }

        let acquisition = await store.acquireCodemapProjectionDemand(
            sourceTickets: [targetTicket],
            deadlineUptimeNanoseconds: codeStructureProjectionDeadline(after: .seconds(60))
        )
        guard case let .acquired(projectionTicket, status) = acquisition else {
            return XCTFail("Acquisition after drift must return a ticket-bearing failure: \(acquisition)")
        }
        XCTAssertTrue(isProjectionAuthorityFailure(status), "\(status)")
        _ = await store.releaseCodemapProjectionDemand(projectionTicket)
        let afterAcquisition = try await engineAccounting(store: store)
        XCTAssertEqual(CodeStructureProjectionActivity(afterAcquisition.counters), detectedActivity)

        let reverse = try await referrersDTO(window: window, record: target)
        XCTAssertEqual(reverse.status, "ready", "\(reverse.issues)")
        XCTAssertEqual(reverse.files.map(\.path), referrerPaths)
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1, "The foreground expansion must spend exactly one reset.")
        let targetStatus = await store.codemapArtifactDemandStatus(targetTicket)
        guard case .unavailable(.staleCurrentness) = targetStatus else {
            return XCTFail("The retained pre-reset seed ticket must be stale: \(targetStatus)")
        }
    }

    /// A store preload launch that reaches an already-latched session receives the engine's
    /// `.cancelled` disposition. The store must finish the launch as cancelled and schedule no retry.
    func testStorePreloadLaunchOnLatchedSessionFinishesCancelledWithoutRetry() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeReferrersRepository(repositories)
        addTeardownBlock { repositories.cleanup() }
        // Hold the background launch before eligibility until a foreground demand latched the session.
        let launchGate = CodeStructureOpenGate()
        addTeardownBlock { launchGate.open() }
        let window = try await makeWindow(
            root: root,
            projectionPreloadLaunchPolicy: .enabled,
            prepareStore: { store in
                await store.setCodemapProjectionPreloadStartHandlerForTesting { _ in
                    await launchGate.waitUntilOpened()
                }
            }
        )
        let store = window.workspaceFileContextStore
        let target = try await fileRecord(
            at: root.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let targetTicket = try await readyTicket(store: store, fileID: target.id)
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(targetTicket) }
        let rootEpoch = targetTicket.rootEpoch

        try repositories.stage("Notes.txt", at: root)
        let acquisition = await store.acquireCodemapProjectionDemand(
            sourceTickets: [targetTicket],
            deadlineUptimeNanoseconds: codeStructureProjectionDeadline(after: .seconds(60))
        )
        guard case let .acquired(projectionTicket, _) = acquisition else {
            return XCTFail("Expected a retained projection ticket: \(acquisition)")
        }
        addTeardownBlock { _ = await store.releaseCodemapProjectionDemand(projectionTicket) }
        let failed = await waitForProjectionStatus(store: store, ticket: projectionTicket) {
            self.isProjectionAuthorityFailure($0)
        }
        XCTAssertTrue(isProjectionAuthorityFailure(failed), "\(failed)")
        guard isProjectionAuthorityFailure(failed) else { return }
        let latched = try await engineAccounting(store: store)
        XCTAssertEqual(latched.projectionJobCount, 0)
        let heldPhase = await store.codemapProjectionPreloadLaunchPhaseForTesting(rootEpoch: rootEpoch)
        XCTAssertEqual(heldPhase, .eligibilityQueued, "The background launch must still be held.")

        launchGate.open()
        let finishedPhase = await waitForPreloadLaunchPhase(store: store, rootEpoch: rootEpoch) {
            $0 == .cancelled
        }

        XCTAssertTrue(launchGate.didHoldCaller())
        XCTAssertEqual(finishedPhase, .cancelled, "The latched engine must refuse the launch.")
        let cancelledStore = try await storePreloadState(store: store, rootID: rootEpoch.rootID)
        XCTAssertEqual(
            Array(cancelledStore.events.map(\.kind).suffix(2)),
            [.engineScheduling, .cancelled],
            "The launch reached engine scheduling and finished cancelled."
        )
        assertNoStorePreloadRetry(cancelledStore)
        let afterCancelled = try await engineAccounting(store: store)
        XCTAssertEqual(afterCancelled.projectionJobCount, 0)
        XCTAssertEqual(
            CodeStructureProjectionActivity(afterCancelled.counters),
            CodeStructureProjectionActivity(latched.counters),
            "The refused launch must not schedule, reload, or recapture."
        )

        try await Task.sleep(for: storePreloadRetryHorizon)
        let idleStore = try await storePreloadState(store: store, rootID: rootEpoch.rootID)
        XCTAssertEqual(
            idleStore,
            cancelledStore,
            "A cancelled launch must not relaunch or retry within the maximum store backoff."
        )
        let idle = try await engineAccounting(store: store)
        XCTAssertEqual(
            CodeStructureProjectionActivity(idle.counters),
            CodeStructureProjectionActivity(latched.counters)
        )
        let repairCountWhileIdle = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountWhileIdle, 0, "A cancelled background launch must not reset the root session.")

        let reverse = try await referrersDTO(window: window, record: target)
        XCTAssertEqual(reverse.status, "ready", "\(reverse.issues)")
        XCTAssertEqual(reverse.files.map(\.path), referrerPaths)
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1, "The foreground expansion must spend exactly one reset.")
    }

    func testSeedRepairThenProjectionFailureShareOneRootResetBudget() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeReferrersRepository(
            repositories,
            extraFiles: ["Sources/First.swift": "struct First { func first() {} }\n"],
            modifiedFiles: ["Notes.txt", "Extra.txt"]
        )
        addTeardownBlock { repositories.cleanup() }
        // Armed issuances: #1 seed on the original session (rejected), #2 seed on the replacement
        // (accepted), #3 the replacement's first cold-projection candidate (observes Extra.txt).
        let advance = CodeStructureAuthorityAdvanceAfterReset(
            repositories: repositories,
            root: root,
            relativePath: "Extra.txt",
            onIssuance: 3
        )
        let window = try await makeWindow(
            root: root,
            capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterSourcePathFingerprintCapture: { advance.observeIssuance() }
            )
        )
        let store = window.workspaceFileContextStore
        let initial = try await codeStructureDTO(window: window, root: root, path: "Sources/First.swift")
        XCTAssertEqual(initial.status, "ready", "\(initial.issues)")
        let target = try await fileRecord(
            at: root.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )

        try repositories.stage("Notes.txt", at: root)
        advance.arm()
        let clock = ContinuousClock()
        let started = clock.now
        let exhausted = try await referrersDTO(window: window, record: target)
        let elapsed = clock.now - started

        XCTAssertTrue(advance.didAdvance(), "The second change must land on the replacement's projection.")
        XCTAssertEqual(exhausted.status, "unavailable", "\(exhausted.issues)")
        let issue = try XCTUnwrap(exhausted.issues.first)
        XCTAssertEqual(issue.code, "projection_unavailable", "\(exhausted.issues)")
        XCTAssertTrue(issue.retryable)
        XCTAssertLessThan(elapsed, .seconds(10))
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1, "Seed and projection recovery share one reset per root per operation.")

        let retried = try await referrersDTO(window: window, record: target)
        XCTAssertEqual(retried.status, "ready", "\(retried.issues)")
        XCTAssertEqual(retried.files.map(\.path), referrerPaths)
        let repairCountAfterRetry = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterRetry, 2)
    }

    func testProjectionRepairThenSeedRejectionShareOneRootResetBudget() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeReferrersRepository(repositories, modifiedFiles: ["Notes.txt", "Extra.txt"])
        addTeardownBlock { repositories.cleanup() }
        // Armed issuances: #1 the original session's projection candidate (rejected, projection
        // reset), #2 the restarted attempt's seed on the replacement (observes Extra.txt).
        let advance = CodeStructureAuthorityAdvanceAfterReset(
            repositories: repositories,
            root: root,
            relativePath: "Extra.txt"
        )
        let window = try await makeWindow(
            root: root,
            capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterSourcePathFingerprintCapture: { advance.observeIssuance() }
            )
        )
        let store = window.workspaceFileContextStore
        let target = try await fileRecord(
            at: root.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let targetTicket = try await readyTicket(store: store, fileID: target.id)
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(targetTicket) }
        let before = try await engineCounters(store: store)

        try repositories.stage("Notes.txt", at: root)
        advance.arm()
        let clock = ContinuousClock()
        let started = clock.now
        let exhausted = try await referrersDTO(window: window, record: target)
        let elapsed = clock.now - started

        XCTAssertTrue(advance.didAdvance(), "The second change must land on the replacement's seed.")
        XCTAssertEqual(exhausted.status, "unavailable", "\(exhausted.issues)")
        let issue = try XCTUnwrap(exhausted.issues.first)
        XCTAssertEqual(issue.detail, "binding_rejected.repository_authority_changed", "\(exhausted.issues)")
        XCTAssertTrue(issue.retryable)
        XCTAssertLessThan(elapsed, .seconds(10))
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1, "Projection and seed recovery share one reset per root per operation.")
        let after = try await engineCounters(store: store)
        XCTAssertGreaterThan(
            after.projectionCoveragesCancelled,
            before.projectionCoveragesCancelled,
            "The original session's projection must observe the first change before the seed path."
        )

        let retried = try await referrersDTO(window: window, record: target)
        XCTAssertEqual(retried.status, "ready", "\(retried.issues)")
        XCTAssertEqual(retried.files.map(\.path), referrerPaths)
        let repairCountAfterRetry = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterRetry, 2)
    }

    /// A projection reset spent on the operation's last publication attempt cannot restart, so the
    /// result must keep the typed projection cause and retry guidance, not a borrowed stale reason.
    func testProjectionResetOnFinalPublicationAttemptKeepsTypedUnavailable() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeReferrersRepository(repositories)
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let target = try await fileRecord(
            at: root.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let targetTicket = try await readyTicket(store: store, fileID: target.id)
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(targetTicket) }
        let before = try await engineCounters(store: store)

        try repositories.stage("Notes.txt", at: root)
        let structureAttempts = CodemapLockedValues<Int>()
        let diagnosticRecords = CodemapLockedValues<WorkspaceCodemapStructureDiagnosticRecord>()
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(maximumStructurePublicationAttempts: 1),
            structureAttemptDidBegin: { structureAttempts.append($0) },
            structureDiagnosticSink: { diagnosticRecords.append($0) }
        )
        let exhausted = try await coordinator.structurePresentation(
            seedFileIDs: [target.id],
            direction: .referrers,
            traversalLimits: WorkspaceCodemapStructureTraversalLimits(
                maximumDepth: 1,
                maximumNodeCount: 10,
                maximumEdgeCount: 500,
                maximumByteCount: 8 * 1024 * 1024
            ),
            outputLimits: WorkspaceCodemapStructureOutputLimits(
                maximumFileCount: 10,
                maximumCodemapTokenCount: 6000
            ),
            rootScope: .visibleWorkspace
        )

        XCTAssertEqual(structureAttempts.values, [0], "The cap leaves no attempt for the restart.")
        XCTAssertEqual(exhausted.outcome, .unavailable, "\(exhausted.issues)")
        XCTAssertEqual(
            exhausted.issues,
            [.projectionUnavailable(reason: .repositoryAuthorityChanged, retryAfterMilliseconds: 100)],
            "The spent projection reset must surface its typed cause, not publication staleness."
        )
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1, "The final attempt still spends exactly one root reset.")
        assertUnrestartableProjectionResetDiagnosticRecord(diagnosticRecords.values)

        let dto = MCPServerViewModel.codeStructureReplyDTO(
            presentation: exhausted,
            logicalPathsByFileID: [target.id: "repository/Sources/Target.swift"],
            worktreeScope: nil
        )
        XCTAssertEqual(dto.status, "unavailable")
        XCTAssertEqual(dto.issues.map(\.code), ["projection_unavailable"])
        let issue = try XCTUnwrap(dto.issues.first)
        XCTAssertTrue(issue.retryable)
        XCTAssertEqual(issue.retryAfterMilliseconds, 100)
        XCTAssertNotNil(dto.retry)
        XCTAssertEqual(
            issue.message,
            "Repository authority changed during codemap projection; retry the request."
        )

        let retried = try await referrersDTO(window: window, record: target)
        XCTAssertEqual(retried.status, "ready", "\(retried.issues)")
        XCTAssertEqual(retried.files.map(\.path), referrerPaths)
        let repairCountAfterRetry = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterRetry, 1, "Following the retry guidance must not reset again.")
        // The reset detaches the session, so engine counters are read once the retry replaced it.
        let after = try await engineCounters(store: store)
        XCTAssertGreaterThan(
            after.projectionCoveragesCancelled,
            before.projectionCoveragesCancelled,
            "The original session's projection, not the seed path, must observe the change."
        )
    }

    func testConcurrentExpansionsObservingOneProjectionFailureDetachOnce() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeReferrersRepository(repositories)
        addTeardownBlock { repositories.cleanup() }
        let pause = CodeStructureOneShotIssuancePause()
        addTeardownBlock { pause.release() }
        let window = try await makeWindow(
            root: root,
            capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterSourcePathFingerprintCapture: { await pause.observeIssuance() }
            )
        )
        let store = window.workspaceFileContextStore
        let target = try await fileRecord(
            at: root.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let targetTicket = try await readyTicket(store: store, fileID: target.id)
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(targetTicket) }

        try repositories.stage("Notes.txt", at: root)
        pause.arm()
        let mcpServer = window.mcpServer
        let referrersRequest = request(direction: .referrers, maximumDepth: 1)
        async let first = mcpServer.buildCodeStructureDTO(
            fromRecords: [target],
            request: referrersRequest,
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        async let second = mcpServer.buildCodeStructureDTO(
            fromRecords: [target],
            request: referrersRequest,
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        let parked = await pause.waitUntilParked()
        let joined = try await waitForEngineAccounting(store: store) {
            $0.retainedProjectionDemandCount >= 2
        }
        XCTAssertTrue(parked, "The shared projection worker must park at its authority capture.")
        XCTAssertEqual(
            joined.retainedProjectionDemandCount,
            2,
            "Both operations must hold projection tickets on the same session before it fails."
        )
        pause.release()
        let (firstDTO, secondDTO) = try await (first, second)

        XCTAssertEqual(firstDTO.status, "ready", "\(firstDTO.issues)")
        XCTAssertEqual(secondDTO.status, "ready", "\(secondDTO.issues)")
        XCTAssertEqual(firstDTO.files.map(\.path), referrerPaths)
        XCTAssertEqual(secondDTO.files.map(\.path), referrerPaths)
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1, "Only one operation may detach; the other's ticket is stale.")
        let targetStatus = await store.codemapArtifactDemandStatus(targetTicket)
        guard case .unavailable(.staleCurrentness) = targetStatus else {
            return XCTFail("The retained pre-reset seed ticket must be stale: \(targetStatus)")
        }
    }

    func testOldProjectionWorkerAndTicketCannotDisturbReplacementSession() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeReferrersRepository(
            repositories,
            extraFiles: ["Sources/Second.swift": "struct Second { func second() {} }\n"]
        )
        addTeardownBlock { repositories.cleanup() }
        let pause = CodeStructureOneShotIssuancePause()
        addTeardownBlock { pause.release() }
        let window = try await makeWindow(
            root: root,
            capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterSourcePathFingerprintCapture: { await pause.observeIssuance() }
            )
        )
        let store = window.workspaceFileContextStore
        let target = try await fileRecord(
            at: root.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let second = try await fileRecord(
            at: root.appendingPathComponent("Sources/Second.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let targetTicket = try await readyTicket(store: store, fileID: target.id)
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(targetTicket) }

        pause.arm()
        let acquisition = await store.acquireCodemapProjectionDemand(
            sourceTickets: [targetTicket],
            deadlineUptimeNanoseconds: codeStructureProjectionDeadline(after: .seconds(60))
        )
        guard case let .acquired(oldProjectionTicket, _) = acquisition else {
            return XCTFail("Expected a retained projection ticket: \(acquisition)")
        }
        addTeardownBlock { _ = await store.releaseCodemapProjectionDemand(oldProjectionTicket) }
        let parked = await pause.waitUntilParked()
        XCTAssertTrue(parked, "The original session's projection worker must park at its authority capture.")
        guard parked else { return }

        try repositories.stage("Notes.txt", at: root)
        let requested = await store.requestCodemapArtifactWithOwnership(forFileID: second.id)
        guard case let .pending(oldSecondTicket) = requested.result else {
            return XCTFail("Expected a pending demand, got \(requested.result)")
        }
        let rejected = await waitForDemandResult(store: store, ticket: oldSecondTicket) {
            if case .unavailable(.rejected(.repositoryAuthorityChanged)) = $0 { return true }
            return false
        }
        XCTAssertTrue(rejected)
        let repaired = await store.prepareCodemapRootSessionRetry(
            oldSecondTicket,
            rejection: .repositoryAuthorityChanged,
            priority: .demand,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        let replacement = try XCTUnwrap(repaired)
        let replacementSecondTicket = try XCTUnwrap(demandTicket(from: replacement.result))
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(replacementSecondTicket) }
        let replacementSecondReady = await waitForDemandResult(store: store, ticket: replacementSecondTicket) {
            if case .ready = $0 { return true }
            return false
        }
        XCTAssertTrue(replacementSecondReady)
        let repairCountAfterReset = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterReset, 1)
        let oldProjectionStatus = await store.codemapProjectionDemandStatus(oldProjectionTicket)
        XCTAssertEqual(oldProjectionStatus, .stale)
        let beforeRelease = try await engineCounters(store: store)

        pause.release()
        let replacementTargetTicket = try await readyTicket(store: store, fileID: target.id)
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(replacementTargetTicket) }
        let replacementAcquisition = await store.acquireCodemapProjectionDemand(
            sourceTickets: [replacementTargetTicket],
            deadlineUptimeNanoseconds: codeStructureProjectionDeadline(after: .seconds(60))
        )
        guard case let .acquired(replacementProjectionTicket, _) = replacementAcquisition else {
            return XCTFail("Expected a replacement projection ticket: \(replacementAcquisition)")
        }
        addTeardownBlock { _ = await store.releaseCodemapProjectionDemand(replacementProjectionTicket) }
        let replacementStatus = await waitForProjectionStatus(store: store, ticket: replacementProjectionTicket) {
            if case .ready = $0 { return true }
            return false
        }
        guard case .ready = replacementStatus else {
            return XCTFail("The released old worker must neither latch nor cancel the replacement: \(replacementStatus)")
        }
        let drained = try await waitForEngineAccounting(store: store) { $0.drainingProjectionTaskCount == 0 }
        XCTAssertEqual(drained.drainingProjectionTaskCount, 0)
        XCTAssertEqual(
            drained.counters.repositoryAuthorityChanges,
            beforeRelease.repositoryAuthorityChanges,
            "The old worker's capture result must be fenced before it is recorded."
        )

        let staleReset = await store.prepareCodemapProjectionRootSessionRetry(
            oldProjectionTicket,
            reason: .repositoryAuthorityChanged,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        XCTAssertEqual(staleReset, .stale)
        let repairCountAfterStaleReset = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterStaleReset, 1)
        let replacementAfterStaleReset = await store.codemapProjectionDemandStatus(replacementProjectionTicket)
        guard case .ready = replacementAfterStaleReset else {
            return XCTFail("An old ticket must not disturb the replacement: \(replacementAfterStaleReset)")
        }
    }

    func testProjectionRootSessionResetHonorsDeadlineWhileSharedCleanupIsPaused() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeReferrersRepository(
            repositories,
            extraFiles: ["Sources/Other.swift": "struct Other { func other() {} }\n"]
        )
        addTeardownBlock { repositories.cleanup() }
        let pause = CodeStructureDemandResultPause()
        addTeardownBlock { pause.release() }
        let window = try await makeWindow(
            root: root,
            codemapDemandResultHook: { ticket, result in
                await pause.transform(ticket: ticket, result: result)
            }
        )
        let store = window.workspaceFileContextStore
        let target = try await fileRecord(
            at: root.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let other = try await fileRecord(
            at: root.appendingPathComponent("Sources/Other.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let targetTicket = try await readyTicket(store: store, fileID: target.id)
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(targetTicket) }

        try repositories.stage("Notes.txt", at: root)
        let acquisition = await store.acquireCodemapProjectionDemand(
            sourceTickets: [targetTicket],
            deadlineUptimeNanoseconds: codeStructureProjectionDeadline(after: .seconds(60))
        )
        guard case let .acquired(projectionTicket, _) = acquisition else {
            return XCTFail("Expected a retained projection ticket: \(acquisition)")
        }
        addTeardownBlock { _ = await store.releaseCodemapProjectionDemand(projectionTicket) }
        let failed = await waitForProjectionStatus(store: store, ticket: projectionTicket) {
            self.isProjectionAuthorityFailure($0)
        }
        XCTAssertTrue(isProjectionAuthorityFailure(failed), "\(failed)")
        guard isProjectionAuthorityFailure(failed) else { return }

        // A demand task parked in its result hook keeps the shared detach cleanup in flight.
        pause.pause(fileID: other.id)
        let requested = await store.requestCodemapArtifactWithOwnership(forFileID: other.id)
        guard case let .pending(otherTicket) = requested.result else {
            return XCTFail("Expected a pending demand, got \(requested.result)")
        }
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(otherTicket) }
        let parked = await pause.waitUntilParked()
        XCTAssertTrue(parked)
        guard parked else { return }

        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await store.prepareCodemapProjectionRootSessionRetry(
            projectionTicket,
            reason: .repositoryAuthorityChanged,
            deadline: clock.now.advanced(by: .milliseconds(300))
        )
        let elapsed = clock.now - started
        XCTAssertEqual(outcome, .deadlineReached)
        XCTAssertLessThan(elapsed, .seconds(3), "The caller's deadline must bound the shared cleanup wait.")
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1)
        let replay = await store.prepareCodemapProjectionRootSessionRetry(
            projectionTicket,
            reason: .repositoryAuthorityChanged,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        XCTAssertEqual(replay, .stale)

        pause.release()
        let reverse = try await referrersDTO(window: window, record: target)
        XCTAssertEqual(reverse.status, "ready", "\(reverse.issues)")
        XCTAssertEqual(reverse.files.map(\.path), referrerPaths)
        let repairCountAfterExpansion = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCountAfterExpansion, 1, "Completed shared cleanup must not need another reset.")
        let accounting = try await engineAccounting(store: store)
        XCTAssertEqual(accounting.retainedProjectionDemandCount, 0)
    }

    func testCancelledExpansionStopsWaitingWhileSharedCleanupContinues() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeReferrersRepository(
            repositories,
            extraFiles: ["Sources/Other.swift": "struct Other { func other() {} }\n"]
        )
        addTeardownBlock { repositories.cleanup() }
        let pause = CodeStructureDemandResultPause()
        addTeardownBlock { pause.release() }
        let window = try await makeWindow(
            root: root,
            codemapDemandResultHook: { ticket, result in
                await pause.transform(ticket: ticket, result: result)
            }
        )
        let store = window.workspaceFileContextStore
        let target = try await fileRecord(
            at: root.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let other = try await fileRecord(
            at: root.appendingPathComponent("Sources/Other.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let targetTicket = try await readyTicket(store: store, fileID: target.id)
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(targetTicket) }

        try repositories.stage("Notes.txt", at: root)
        pause.pause(fileID: other.id)
        let requested = await store.requestCodemapArtifactWithOwnership(forFileID: other.id)
        guard case let .pending(otherTicket) = requested.result else {
            return XCTFail("Expected a pending demand, got \(requested.result)")
        }
        addTeardownBlock { _ = await store.cancelCodemapArtifactDemand(otherTicket) }
        let parked = await pause.waitUntilParked()
        XCTAssertTrue(parked)
        guard parked else { return }

        let mcpServer = window.mcpServer
        let referrersRequest = request(direction: .referrers, maximumDepth: 1)
        let operation = Task {
            try await mcpServer.buildCodeStructureDTO(
                fromRecords: [target],
                request: referrersRequest,
                includePathNotFoundIssue: true,
                lookupContext: .visibleWorkspace
            )
        }
        let spentReset = await waitForRepairCount(store: store, 1)
        XCTAssertTrue(spentReset, "The expansion must spend its reset and wait on the shared cleanup.")
        guard spentReset else {
            operation.cancel()
            return
        }
        let clock = ContinuousClock()
        let started = clock.now
        operation.cancel()
        let result = await operation.result
        let elapsed = clock.now - started
        XCTAssertLessThan(elapsed, .seconds(3), "Cancellation must end the caller's wait, not the shared cleanup.")
        if case let .success(dto) = result {
            XCTAssertNotEqual(dto.status, "ready", "A cancelled expansion cannot finish behind paused cleanup.")
        }

        pause.release()
        let followUp = try await referrersDTO(window: window, record: target)
        XCTAssertEqual(followUp.status, "ready", "\(followUp.issues)")
        XCTAssertEqual(followUp.files.map(\.path), referrerPaths)
        let repairCount = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairCount, 1, "The cancelled caller's cleanup must still complete for the next request.")
        let accounting = try await engineAccounting(store: store)
        XCTAssertEqual(accounting.retainedProjectionDemandCount, 0, "Cancelled operation resources must be released.")
    }

    func testStoreCanScanSessionWorktreeRoot() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let worktreeRootURL = try repositories.makeRepository(
            named: "direct-scan-worktree",
            files: [
                "App.swift": "struct DirectSessionWorktreeType {\n    func directMethod() {}\n}\n"
            ]
        )
        defer { repositories.cleanup() }

        let codemapFixture = try MCPCodeStructureCodemapRuntimeFixture(name: #function)
        addTeardownBlock {
            await codemapFixture.shutdown()
        }
        let store = codemapFixture.makeStore()
        let root = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let content = try await store.readContent(rootID: root.id, relativePath: "App.swift", workloadClass: .codemap)
        XCTAssertTrue(content?.contains("DirectSessionWorktreeType") == true)
        let loadedFile = await store.file(rootID: root.id, relativePath: "App.swift")
        let file = try XCTUnwrap(loadedFile)
        let ticket = try await readyTicket(store: store, fileID: file.id, timeout: .seconds(30))
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let presentation = try await WorkspaceCodemapPresentationCoordinator(store: store)
            .presentation(
                for: .exact(fileIDs: [file.id], completeRootSet: false),
                rootScope: .allLoaded
            )
        XCTAssertEqual(presentation.coverage, .complete)
        let rendered = try XCTUnwrap(presentation.orderedEntries.first)
        XCTAssertTrue(rendered.text.contains("DirectSessionWorktreeType"), rendered.text)
    }

    func testMissingWorktreeSnapshotReturnsPendingThenRendersRefreshedLogicalPath() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logicalRootURL = try repositories.makeRepository(
            named: "logical",
            files: [
                "Sources/App.swift": "struct CanonicalOnlyType {\n    func canonicalMethod() {}\n}\n"
            ]
        )
        let worktreeRootURL = try repositories.makeRepository(
            named: "worktree",
            files: [
                "Sources/App.swift": "struct WorktreeOnlyType {\n    func worktreeMethod() {}\n}\n"
            ]
        )
        defer { repositories.cleanup() }

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let worktreeRoot = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let projection = makeProjection(logicalRoot: logicalRoot, physicalRoot: worktreeRoot, worktreeID: "worktree")
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let file = try await fileRecord(
            at: worktreeRootURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projection.lookupRootScope
        )

        let pendingDTO = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: lookupContext
        )
        if pendingDTO.status == "pending" {
            XCTAssertEqual(pendingDTO.fileCount, 0)
            XCTAssertEqual(pendingDTO.pendingPaths, ["Sources/App.swift"])
            XCTAssertNil(pendingDTO.unmappedPaths)
        } else {
            XCTAssertEqual(pendingDTO.status, "ready")
        }
        let ticket = try await readyTicket(store: store, fileID: file.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let refreshedDTO = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: lookupContext
        )
        XCTAssertEqual(refreshedDTO.status, "ready")
        XCTAssertEqual(refreshedDTO.fileCount, 1)
        XCTAssertTrue(refreshedDTO.content.contains("WorktreeOnlyType"), refreshedDTO.content)
        XCTAssertFalse(refreshedDTO.content.contains("CanonicalOnlyType"), refreshedDTO.content)
        XCTAssertTrue(refreshedDTO.content.contains("Sources/App.swift"), refreshedDTO.content)
        XCTAssertFalse(refreshedDTO.content.contains(worktreeRoot.standardizedFullPath), refreshedDTO.content)
        XCTAssertNil(refreshedDTO.pendingPaths)
        let mapping = try XCTUnwrap(refreshedDTO.worktreeScope?.rootMappings.first)
        XCTAssertEqual(mapping.effectiveRootPath, "session-bound")
    }

    func testSwitchingCodeStructureScopeFromWorktreeAToBDoesNotReuseA() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logicalRootURL = try repositories.makeRepository(
            named: "logical",
            files: ["Sources/App.swift": SwiftFixtureSource.emptyStruct("CanonicalSwitchType")]
        )
        let worktreeAURL = try repositories.makeRepository(
            named: "switch-a",
            files: ["Sources/App.swift": "struct WorktreeAType {\n    func branchAMethod() {}\n}\n"]
        )
        let worktreeBURL = try repositories.makeRepository(
            named: "switch-b",
            files: ["Sources/App.swift": "struct WorktreeBType {\n    func branchBMethod() {}\n}\n"]
        )
        defer { repositories.cleanup() }

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let logicalRef = WorkspaceRootRef(
            id: logicalRoot.id,
            name: logicalRoot.name,
            fullPath: logicalRoot.standardizedFullPath
        )
        let sessionID = UUID()
        let materializedA = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: [makeBinding(
                logicalRoot: logicalRef,
                physicalRoot: WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: worktreeAURL.path),
                worktreeID: "A"
            )]
        )
        let projectionA = try XCTUnwrap(materializedA)
        let fileA = try await fileRecord(
            at: worktreeAURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projectionA.lookupRootScope
        )
        let ticketA = try await readyTicket(store: store, fileID: fileA.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticketA) } }
        let dtoA = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [fileA],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: WorkspaceLookupContext(rootScope: projectionA.lookupRootScope, bindingProjection: projectionA)
        )
        XCTAssertEqual(dtoA.status, "ready")
        XCTAssertTrue(dtoA.content.contains("WorktreeAType"), dtoA.content)

        let materializedB = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: [makeBinding(
                logicalRoot: logicalRef,
                physicalRoot: WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: worktreeBURL.path),
                worktreeID: "B"
            )]
        )
        let projectionB = try XCTUnwrap(materializedB)
        let fileB = try await fileRecord(
            at: worktreeBURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projectionB.lookupRootScope
        )
        let ticketB = try await readyTicket(store: store, fileID: fileB.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticketB) } }
        let dtoB = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [fileA, fileB],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: WorkspaceLookupContext(rootScope: projectionB.lookupRootScope, bindingProjection: projectionB)
        )

        XCTAssertEqual(dtoB.status, "ready")
        XCTAssertEqual(dtoB.fileCount, 1)
        XCTAssertTrue(dtoB.content.contains("WorktreeBType"), dtoB.content)
        XCTAssertFalse(dtoB.content.contains("WorktreeAType"), dtoB.content)
        XCTAssertFalse(dtoB.content.contains("CanonicalSwitchType"), dtoB.content)
        XCTAssertEqual(dtoB.worktreeScope?.rootMappings.first?.worktreeID, "B")
    }

    func testDeletedMaterializedWorktreeFailsClosedInsteadOfReturningCachedStructure() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logicalRootURL = try repositories.makeRepository(
            named: "logical",
            files: [
                "Sources/App.swift": "struct CanonicalDeletedType {\n    func canonicalMethod() {}\n}\n"
            ]
        )
        let worktreeRootURL = try repositories.makeRepository(
            named: "deleted-worktree",
            files: [
                "Sources/App.swift": "struct CachedDeletedWorktreeType {\n    func cachedMethod() {}\n}\n"
            ]
        )
        defer { repositories.cleanup() }

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let worktreeRoot = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let projection = makeProjection(logicalRoot: logicalRoot, physicalRoot: worktreeRoot, worktreeID: "deleted")
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let file = try await fileRecord(
            at: worktreeRootURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projection.lookupRootScope
        )
        let ticket = try await readyTicket(store: store, fileID: file.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let primed = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: lookupContext
        )
        XCTAssertEqual(primed.status, "ready")
        XCTAssertTrue(primed.content.contains("CachedDeletedWorktreeType"), primed.content)
        try FileManager.default.removeItem(at: worktreeRootURL)

        let unavailable = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: lookupContext
        )
        XCTAssertEqual(unavailable.status, "unavailable")
        XCTAssertTrue(unavailable.files.isEmpty)
        XCTAssertTrue(unavailable.issues.contains { $0.code == "git_root_unavailable" })
        XCTAssertFalse(unavailable.issues.contains { $0.message.contains(worktreeRootURL.standardizedFileURL.path) })

        let availability = await store.rootScopeAvailability(projection.lookupRootScope)
        XCTAssertEqual(
            availability,
            .sessionWorktreeUnavailable(missingPhysicalRootPaths: [worktreeRootURL.standardizedFileURL.path])
        )
    }

    func testTargetedSelfHealingIsBoundedByMaxResults() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: Dictionary(uniqueKeysWithValues: (1 ... 3).map { index in
                (
                    "Sources/File\(index).swift",
                    "struct BoundedType\(index) {\n    func boundedMethod\(index)() {}\n}\n"
                )
            })
        )
        defer { repositories.cleanup() }

        let window = try await makeWindow(root: root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(roots.first)
        let files = await store.files(inRoot: loadedRoot.id)
        XCTAssertEqual(files.count, 3)

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: files,
            request: request(maximumFiles: 1),
            includePathNotFoundIssue: false,
            lookupContext: .visibleWorkspace
        )

        XCTAssertEqual(dto.status, "budget")
        XCTAssertEqual(dto.fileCount, 0)
        XCTAssertNil(dto.pendingPaths)
        XCTAssertNil(dto.unmappedPaths)
        // Seed admission reports the bounded overflow sentinel (limit + 1), not the full input count.
        XCTAssertEqual(dto.summary.requestedSeeds, 2)
        XCTAssertEqual(dto.summary.resolvedSeeds, 0)
        let issue = try XCTUnwrap(dto.issues.first { $0.phase == "seed_demand" })
        XCTAssertEqual(issue.code, "hard_budget_exceeded")
        XCTAssertEqual(issue.attempted, 2)
        XCTAssertEqual(issue.limit, 1)
    }

    func testUnavailableWorktreeReturnsTypedIssueBeforeCanonicalRead() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logicalRootURL = try repositories.makeRepository(
            named: "logical",
            files: ["Sources/App.swift": SwiftFixtureSource.emptyStruct("CanonicalUnavailableType")]
        )
        defer { repositories.cleanup() }
        let missingWorktreeURL = logicalRootURL.deletingLastPathComponent()
            .appendingPathComponent("Missing-\(UUID().uuidString)", isDirectory: true)

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let logicalRef = WorkspaceRootRef(id: logicalRoot.id, name: logicalRoot.name, fullPath: logicalRoot.standardizedFullPath)
        let missingRef = WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: missingWorktreeURL.path)
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRef,
                    physicalRoot: missingRef,
                    binding: makeBinding(logicalRoot: logicalRef, physicalRoot: missingRef, worktreeID: "missing")
                )
            ],
            visibleLogicalRoots: [logicalRef]
        )

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        )
        XCTAssertEqual(dto.status, "unavailable")
        XCTAssertTrue(dto.files.isEmpty)
        XCTAssertEqual(dto.issues.map(\.code), ["git_root_unavailable"])
        XCTAssertFalse(dto.issues.contains { $0.message.contains(logicalRootURL.standardizedFileURL.path) })
        XCTAssertFalse(dto.issues.contains { $0.message.contains(missingWorktreeURL.standardizedFileURL.path) })

        let availability = await store.rootScopeAvailability(projection.lookupRootScope)
        XCTAssertEqual(
            availability,
            .sessionWorktreeUnavailable(missingPhysicalRootPaths: [missingWorktreeURL.standardizedFileURL.path])
        )
    }

    private func assertNonGitEligibilityDiagnosticShape(
        _ invocation: MCPToolWorkCountDiagnostics.GitInvocationSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let commands = invocation.commands
        if invocation.commandCount == 0, commands.isEmpty {
            return
        }

        // This accepted three-command shape is non-git eligibility probing after
        // proof invalidation, not legacy snapshot-build work.
        let expectedFallbackCommands = [
            "rev-parse --show-toplevel",
            "rev-parse --show-toplevel",
            "rev-parse --is-bare-repository"
        ]
        if invocation.commandCount == expectedFallbackCommands.count,
           commands == expectedFallbackCommands
        {
            return
        }

        XCTFail(
            "Expected no git commands or exact non-git eligibility fallback commands; " +
                "got count \(invocation.commandCount):\n\(commands.joined(separator: "\n"))",
            file: file,
            line: line
        )
    }

    private func request(
        direction: WorkspaceCodemapStructureTraversalDirection? = nil,
        maximumDepth: Int = 0,
        maximumFiles: Int = 10,
        maximumCodemapTokens: Int = 6000
    ) -> MCPServerViewModel.CodeStructureRequest {
        .init(
            direction: direction,
            maximumDepth: maximumDepth,
            maximumFiles: maximumFiles,
            maximumEdges: 500,
            maximumCodemapTokens: maximumCodemapTokens
        )
    }

    private func codeStructureDTO(
        window: WindowState,
        root: URL,
        path: String
    ) async throws -> ToolResultDTOs.CodeStructureReplyDTO {
        let record = try await fileRecord(
            at: root.appendingPathComponent(path),
            store: window.workspaceFileContextStore,
            rootScope: .visibleWorkspace
        )
        return try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [record],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true
        )
    }

    private func engineCounters(
        store: WorkspaceFileContextStore
    ) async throws -> WorkspaceCodemapBindingEngineCounters {
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let rootID = try XCTUnwrap(roots.first?.id)
        let accounting = await store.codemapBindingEngineAccountingForTesting(rootID: rootID)
        return try XCTUnwrap(accounting?.counters)
    }

    private func engineAccounting(
        store: WorkspaceFileContextStore
    ) async throws -> WorkspaceCodemapBindingEngineAccounting {
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let rootID = try XCTUnwrap(roots.first?.id)
        let accounting = await store.codemapBindingEngineAccountingForTesting(rootID: rootID)
        return try XCTUnwrap(accounting)
    }

    /// Polls engine accounting until `condition` holds or the timeout passes; returns the last value.
    private func waitForEngineAccounting(
        store: WorkspaceFileContextStore,
        timeout: Duration = .seconds(10),
        _ condition: (WorkspaceCodemapBindingEngineAccounting) -> Bool
    ) async throws -> WorkspaceCodemapBindingEngineAccounting {
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let rootID = try XCTUnwrap(roots.first?.id)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var last = await store.codemapBindingEngineAccountingForTesting(rootID: rootID)
        while clock.now < deadline {
            if let last, condition(last) { return last }
            try await Task.sleep(for: .milliseconds(20))
            last = await store.codemapBindingEngineAccountingForTesting(rootID: rootID)
        }
        return try XCTUnwrap(last)
    }

    private func waitForRepairCount(
        store: WorkspaceFileContextStore,
        _ expected: Int,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await store.codemapRootSessionRepairCountForTesting() >= expected { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await store.codemapRootSessionRepairCountForTesting() >= expected
    }

    private func codeStructureProjectionDeadline(after duration: Duration) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(duration.components.seconds) * 1_000_000_000
    }

    private func isProjectionAuthorityFailure(_ status: WorkspaceCodemapProjectionDemandStatus) -> Bool {
        if case .unavailable(reason: .repositoryAuthorityChanged, retryAfterMilliseconds: nil) = status {
            return true
        }
        return false
    }

    private func waitForProjectionStatus(
        store: WorkspaceFileContextStore,
        ticket: WorkspaceCodemapProjectionDemandTicket,
        timeout: Duration = .seconds(10),
        matches: (WorkspaceCodemapProjectionDemandStatus) -> Bool
    ) async -> WorkspaceCodemapProjectionDemandStatus {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var status = await store.codemapProjectionDemandStatus(ticket)
        while !matches(status), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            status = await store.codemapProjectionDemandStatus(ticket)
        }
        return status
    }

    private func waitForPreloadLaunchPhase(
        store: WorkspaceFileContextStore,
        rootEpoch: WorkspaceCodemapRootEpoch,
        timeout: Duration = .seconds(10),
        matches: (WorkspaceCodemapProjectionPreloadLaunchPhase?) -> Bool
    ) async -> WorkspaceCodemapProjectionPreloadLaunchPhase? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var phase = await store.codemapProjectionPreloadLaunchPhaseForTesting(rootEpoch: rootEpoch)
        while !matches(phase), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            phase = await store.codemapProjectionPreloadLaunchPhaseForTesting(rootEpoch: rootEpoch)
        }
        return phase
    }

    /// Bounds any timer-driven store relaunch: the longer of the production policy's largest single
    /// backoff and its cumulative backoff across every permitted retry, plus scheduling margin.
    private var storePreloadRetryHorizon: Duration {
        let policy = WorkspaceFileContextStore.CodemapProjectionPreloadRetryPolicy.production
        let cumulative = (1 ... policy.maximumRetryCount).reduce(UInt64(0)) {
            $0 + policy.backoffNanoseconds(forAttempt: $1)
        }
        let bound = max(cumulative, policy.maximumBackoffNanoseconds)
        return .nanoseconds(Int64(bound)) + .milliseconds(500)
    }

    /// Store-side preload evidence for the root's current epoch: event log, launch phase, and retry.
    private func storePreloadState(
        store: WorkspaceFileContextStore,
        rootID: UUID
    ) async throws -> CodeStructureStorePreloadState {
        let events = await store.codemapProjectionPreloadStoreEventsForTesting(rootID: rootID)
        let rootEpoch = try XCTUnwrap(events.last?.rootEpoch, "The root must have preload store events.")
        let launchPhase = await store.codemapProjectionPreloadLaunchPhaseForTesting(rootEpoch: rootEpoch)
        let retry = await store.codemapProjectionPreloadRetrySnapshotForTesting(rootEpoch: rootEpoch)
        return CodeStructureStorePreloadState(
            events: events,
            launchPhase: launchPhase,
            retryAttempt: retry?.attempt
        )
    }

    private func assertNoStorePreloadRetry(
        _ state: CodeStructureStorePreloadState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(state.retryAttempt, "No store retry may be pending.", file: file, line: line)
        XCTAssertFalse(
            state.events.contains { $0.kind == .retryScheduled || $0.kind == .retryStarted },
            "The store must never schedule a timer retry for this root: \(state.events.map(\.kind))",
            file: file,
            line: line
        )
    }

    /// Real Git repository where `Source` references `Target`; listed text files carry unstaged edits
    /// that tests stage later to advance repository authority.
    private func makeReferrersRepository(
        _ repositories: ReviewGitRepositoryFixture,
        extraFiles: [String: String] = [:],
        modifiedFiles: [String] = ["Notes.txt"]
    ) throws -> URL {
        var files = [
            "Sources/Source.swift": "struct Source {\n    let target: Target\n}\n",
            "Sources/Target.swift": "struct Target { func targetMethod() {} }\n"
        ]
        for path in modifiedFiles {
            files[path] = "\(path) original\n"
        }
        files.merge(extraFiles) { _, extra in extra }
        let root = try repositories.makeRepository(named: "repository", files: files)
        for path in modifiedFiles {
            try repositories.write("\(path) changed\n", to: path, at: root)
        }
        try repositories.settleIndex(at: root)
        return root
    }

    private var referrerPaths: [String] {
        ["repository/Sources/Target.swift", "repository/Sources/Source.swift"]
    }

    private func referrersDTO(
        window: WindowState,
        record: WorkspaceFileRecord
    ) async throws -> ToolResultDTOs.CodeStructureReplyDTO {
        try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [record],
            request: request(direction: .referrers, maximumDepth: 1),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
    }

    /// A completed baseline referrers expansion leaves complete projection coverage on the original
    /// engine session; a real repository mutation then spends exactly one root-session repair, and the
    /// replacement session must reach ready coverage without inheriting the retired session's overlay
    /// contribution watermark.
    private func assertReferrersExpansionRecoversAfterRepositoryMutation(
        _ mutation: ReferrersRecoveryMutation,
        evictIdleSeedsBeforeRecovery: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let repositories = try ReviewGitRepositoryFixture(
            name: "referrers-recovery-\(mutation.rawValue)\(evictIdleSeedsBeforeRecovery ? "" : "-warm")"
        )
        var files = [
            "Sources/Source.swift": "struct Source {\n    let target: Target\n}\n",
            "Sources/Target.swift": "struct Target { func targetMethod() {} }\n"
        ]
        if mutation == .stageExistingNonSource {
            files["Notes.txt"] = "notes\n"
        }
        let root = try repositories.makeRepository(named: "repository", files: files)
        addTeardownBlock { repositories.cleanup() }
        if mutation == .stageExistingNonSource {
            // Only the index advances after the baseline.
            try repositories.write("notes changed\n", to: "Notes.txt", at: root)
            try repositories.settleIndex(at: root)
        }
        let window = try await makeWindow(root: root, projectionPreloadLaunchPolicy: .enabled)
        let store = window.workspaceFileContextStore
        let target = try await fileRecord(
            at: root.appendingPathComponent("Sources/Target.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )

        let baseline = try await referrersDTO(window: window, record: target)
        XCTAssertEqual(baseline.status, "ready", "baseline \(baseline.issues)", file: file, line: line)
        XCTAssertEqual(baseline.files.map(\.path), referrerPaths, file: file, line: line)
        let baselineRepairs = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(baselineRepairs, 0, "The baseline must not reset.", file: file, line: line)
        // Cold seeds (idle records evicted) detect every Git authority mutation except the unstaged
        // create and repair once. Warm seeds join without probing Git, so only the staged create
        // repairs: its new referrer is a cold demand that observes the advanced index.
        let expectedRepairs = if evictIdleSeedsBeforeRecovery {
            mutation == .createUnstaged ? 0 : 1
        } else {
            mutation == .createAndStage ? 1 : 0
        }
        let gitStateBefore = try mutation == .createUnstaged
            ? referrersGitState(repositories, root: root)
            : nil

        var expected = Set(referrerPaths)
        switch mutation {
        case .stageExistingNonSource:
            try repositories.stage("Notes.txt", at: root)
        case .emptyCommit:
            _ = try repositories.runGit(["commit", "--allow-empty", "-m", "Empty"], at: root)
        case .createAndStage:
            let addedPath = "Sources/Added.swift"
            try await store.createFile(
                rootID: target.rootID,
                relativePath: addedPath,
                content: "struct Added {\n    let target: Target\n    func addedLabel() { target.targetMethod() }\n}\n",
                validating: .visibleWorkspace
            )
            try repositories.stage(addedPath, at: root)
            expected.insert("repository/\(addedPath)")
        case .createUnstaged:
            let addedPath = "Sources/Added.swift"
            try await store.createFile(
                rootID: target.rootID,
                relativePath: addedPath,
                content: "struct Added {\n    let target: Target\n    func addedLabel() { target.targetMethod() }\n}\n",
                validating: .visibleWorkspace
            )
            expected.insert("repository/\(addedPath)")
        }

        if mutation == .stageExistingNonSource || mutation == .emptyCommit {
            // Released ready seeds and the published graph stay warm, so an unchanged-content
            // repeat is ready without probing Git and without a reset.
            let warm = try await referrersDTO(window: window, record: target)
            let warmRepairs = await store.codemapRootSessionRepairCountForTesting()
            let warmDiagnostics = "mutation=\(mutation.rawValue) warm status=\(warm.status) " +
                "repairs=\(warmRepairs) issues=\(warm.issues)"
            XCTAssertEqual(warm.status, "ready", warmDiagnostics, file: file, line: line)
            XCTAssertEqual(Set(warm.files.map(\.path)), expected, warmDiagnostics, file: file, line: line)
            XCTAssertEqual(warmRepairs, 0, "Warm repeat must not reset: \(warmDiagnostics)", file: file, line: line)
        }
        if evictIdleSeedsBeforeRecovery {
            // Evicting the idle ready records forces the cold seed path, which must detect the drift.
            _ = try await evictIdleCodemapDemands(store: store, rootID: target.rootID)
        }

        let clock = ContinuousClock()
        let started = clock.now
        let recovered = try await referrersDTO(window: window, record: target)
        let elapsed = clock.now - started
        let repairs = await store.codemapRootSessionRepairCountForTesting()
        let diagnostics = "mutation=\(mutation.rawValue) status=\(recovered.status) elapsed=\(elapsed) " +
            "repairs=\(repairs) issues=\(recovered.issues)"
        XCTAssertEqual(recovered.status, "ready", diagnostics, file: file, line: line)
        XCTAssertEqual(Set(recovered.files.map(\.path)), expected, diagnostics, file: file, line: line)
        XCTAssertLessThan(elapsed, .seconds(10), diagnostics, file: file, line: line)
        XCTAssertEqual(repairs, expectedRepairs, "Root resets: \(diagnostics)", file: file, line: line)

        let repeated = try await referrersDTO(window: window, record: target)
        let repeatedRepairs = await store.codemapRootSessionRepairCountForTesting()
        let repeatedDiagnostics = "repeat status=\(repeated.status) repairs=\(repeatedRepairs) " +
            "issues=\(repeated.issues)"
        XCTAssertEqual(repeated.status, "ready", repeatedDiagnostics, file: file, line: line)
        XCTAssertEqual(Set(repeated.files.map(\.path)), expected, repeatedDiagnostics, file: file, line: line)
        XCTAssertEqual(repeatedRepairs, expectedRepairs, "The repeat must not reset again.", file: file, line: line)
        if let gitStateBefore {
            let gitStateAfter = try referrersGitState(repositories, root: root)
            XCTAssertEqual(
                gitStateAfter,
                gitStateBefore,
                "An unstaged store create must leave HEAD, tree, and index bytes/stat unchanged.",
                file: file,
                line: line
            )
        }
    }

    /// Evicts every idle ready codemap demand for the root's current epoch, awaiting cleanup.
    @discardableResult
    private func evictIdleCodemapDemands(store: WorkspaceFileContextStore, rootID: UUID) async throws -> Int {
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: rootID,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: rootID)
        )
        return await store.evictIdleReadyCodemapDemandsForTesting(rootEpoch: rootEpoch)
    }

    /// HEAD, HEAD tree, index SHA-256, and index lstat identity (size, inode, mtime, ctime).
    private func referrersGitState(
        _ repositories: ReviewGitRepositoryFixture,
        root: URL
    ) throws -> [String] {
        let index = try repositories.gitPath("index", at: root)
        var status = stat()
        guard lstat(index.path, &status) == 0 else {
            throw NSError(domain: "MCPCodeStructureWorktreeTests", code: 6)
        }
        let digest = try SHA256.hash(data: Data(contentsOf: index))
            .map { String(format: "%02x", $0) }
            .joined()
        return try [
            repositories.head(at: root),
            repositories.runGit(["rev-parse", "HEAD^{tree}"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            digest,
            "\(status.st_size)",
            "\(status.st_ino)",
            "\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)",
            "\(status.st_ctimespec.tv_sec).\(status.st_ctimespec.tv_nsec)"
        ]
    }

    private func codeStructureToolInvoker(
        window: WindowState
    ) async throws -> (String) async throws -> ToolResultDTOs.CodeStructureReplyDTO {
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "code-structure-authority-recovery",
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let tools = await window.mcpServer.windowMCPTools
        let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.getCodeStructure })
        return { path in
            let value = try await ServerNetworkManager.withConnectionID(connectionID) {
                try await tool([
                    "scope": .string("paths"),
                    "paths": .array([.string(path)])
                ])
            }
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(ToolResultDTOs.CodeStructureReplyDTO.self, from: data)
        }
    }

    // Live catalog-only lane fixture: two committed top-level sources with a builtin method-call
    // relationship plus a tracked non-source file; the lane creates a third referrer.
    private static let controlAddedFileName = "ControlAuthorityAdded.swift"
    private static let controlAddedSource = "struct ControlAuthorityAdded {\n    let payload: ControlPayload\n" +
        "    func authorityAddedLabel() -> String { payload.controlLabel() }\n}\n"
    private static let controlReferrersFiles = [
        "ControlPayload.swift": "struct ControlPayload {\n    let identifier: Int\n" +
            "    func controlLabel() -> String { \"payload-\\(identifier)\" }\n}\n",
        "ControlConsumer.swift": "struct ControlConsumer {\n    let payload: ControlPayload\n" +
            "    func consumeControl(_ value: ControlPayload) -> String { value.controlLabel() }\n}\n",
        "Notes.txt": "tracked baseline\n"
    ]
    private static let controlBaselinePaths: Set<String> = [
        "repository/ControlPayload.swift",
        "repository/ControlConsumer.swift"
    ]
    private static let controlExpandedPaths = controlBaselinePaths.union(["repository/ControlAuthorityAdded.swift"])

    private typealias WindowToolInvoker = (String, [String: Value]) async throws -> Value

    /// Invokes real window MCP tools through one tab-bound connection, as the live harness does.
    private func boundWindowToolInvoker(
        window: WindowState,
        clientName: String
    ) async throws -> WindowToolInvoker {
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: clientName,
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let tools = await window.mcpServer.windowMCPTools
        return { name, arguments in
            let tool = try XCTUnwrap(tools.first { $0.name == name }, "Missing window MCP tool \(name)")
            return try await ServerNetworkManager.withConnectionID(connectionID) {
                try await tool(arguments)
            }
        }
    }

    /// The live harness request: top-level seed, default output limits, depth-1 referrers.
    private func controlPayloadReferrers(
        _ invoke: WindowToolInvoker
    ) async throws -> ToolResultDTOs.CodeStructureReplyDTO {
        let value = try await invoke(MCPWindowToolName.getCodeStructure, [
            "scope": .string("paths"),
            "paths": .array([.string("ControlPayload.swift")]),
            "limits": .object(["max_files": .int(10), "max_codemap_tokens": .int(6000)]),
            "expand": .object(["direction": .string("referrers"), "max_depth": .int(1)])
        ])
        return try JSONDecoder().decode(
            ToolResultDTOs.CodeStructureReplyDTO.self,
            from: JSONEncoder().encode(value)
        )
    }

    private func applyEditsCreateControlSource(
        _ invoke: WindowToolInvoker,
        at url: URL
    ) async throws -> Value {
        try await invoke(MCPWindowToolName.applyEdits, [
            "path": .string(url.path),
            "rewrite": .string(Self.controlAddedSource),
            "on_missing": .string("create")
        ])
    }

    private func activeSelectionContainsControlAddedSource(_ window: WindowState) -> Bool {
        window.selectionCoordinator.activeSelectionSnapshot(flushPendingUI: false).selection.selectedPaths
            .contains { $0.hasSuffix("/\(Self.controlAddedFileName)") }
    }

    private func automaticConsumerSummary(_ window: WindowState) -> String {
        let viewModel = window.workspaceFilesViewModel
        let selected = viewModel.selectedFiles.map { ($0.standardizedFullPath as NSString).lastPathComponent }
        let automatic = viewModel.autoCodemapFiles.map { ($0.standardizedFullPath as NSString).lastPathComponent }
        return "autoEnabled=\(viewModel.codemapAutoEnabled) selected=\(selected.sorted()) " +
            "autoCodemaps=\(automatic.sorted()) " +
            "autoRetryPending=\(viewModel.automaticCodemapReadinessRetryPendingForTesting)"
    }

    private struct ControlReferrersFixture {
        let repositories: ReviewGitRepositoryFixture
        let root: URL
        let window: WindowState
        let invoke: WindowToolInvoker
        let gitStateBefore: [String]
    }

    /// Builds the live-lane fixture with production preload and returns it after a ready MCP referrers
    /// baseline with zero root resets, capturing the Git state the scenario must leave unchanged.
    private func makeControlReferrersFixtureAfterReadyBaseline(
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ControlReferrersFixture {
        let repositories = try ReviewGitRepositoryFixture(name: name)
        let root = try repositories.makeRepository(named: "repository", files: Self.controlReferrersFiles)
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root, projectionPreloadLaunchPolicy: .enabled)
        let invoke = try await boundWindowToolInvoker(window: window, clientName: "code-structure-\(name)")
        let baseline = try await controlPayloadReferrers(invoke)
        XCTAssertEqual(baseline.status, "ready", "\(name) baseline \(baseline.issues)", file: file, line: line)
        XCTAssertEqual(Set(baseline.files.map(\.path)), Self.controlBaselinePaths, file: file, line: line)
        let baselineRepairs = await window.workspaceFileContextStore.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(baselineRepairs, 0, "\(name) baseline must not reset.", file: file, line: line)
        return try ControlReferrersFixture(
            repositories: repositories,
            root: root,
            window: window,
            invoke: invoke,
            gitStateBefore: referrersGitState(repositories, root: root)
        )
    }

    /// An unchanged MCP repeat stays ready with all three files and zero resets, and the created
    /// untracked source leaves HEAD, tree, and index bytes/stat unchanged.
    private func assertControlUnchangedRepeatReadyWithoutGitDrift(
        _ fixture: ControlReferrersFixture,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let repeated = try await controlPayloadReferrers(fixture.invoke)
        let repairs = await fixture.window.workspaceFileContextStore.codemapRootSessionRepairCountForTesting()
        let diagnostics = "\(context) repeat status=\(repeated.status) repairs=\(repairs) " +
            "issues=\(repeated.issues) \(automaticConsumerSummary(fixture.window))"
        XCTAssertEqual(repeated.status, "ready", diagnostics, file: file, line: line)
        XCTAssertEqual(Set(repeated.files.map(\.path)), Self.controlExpandedPaths, diagnostics, file: file, line: line)
        XCTAssertEqual(repairs, 0, "The repeat must not reset: \(diagnostics)", file: file, line: line)
        let gitStateAfter = try referrersGitState(fixture.repositories, root: fixture.root)
        XCTAssertEqual(
            gitStateAfter,
            fixture.gitStateBefore,
            "\(context) must leave HEAD, tree, and index bytes/stat unchanged.",
            file: file,
            line: line
        )
    }

    private func assertControlReferrersStructurePublishes(
        after create: ControlReferrersCreate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try await makeControlReferrersFixtureAfterReadyBaseline(
            name: "referrers-control-\(create.rawValue)",
            file: file,
            line: line
        )
        let root = fixture.root
        let window = fixture.window
        let store = window.workspaceFileContextStore
        let payload = try await fileRecord(
            at: root.appendingPathComponent("ControlPayload.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let consumer = try await fileRecord(
            at: root.appendingPathComponent("ControlConsumer.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: payload.rootID,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: payload.rootID)
        )

        let addedURL = root.appendingPathComponent(Self.controlAddedFileName)
        switch create {
        case .applyEditsCreateAndSelect:
            _ = try await applyEditsCreateControlSource(fixture.invoke, at: addedURL)
        case .storeCreateWithoutSelection:
            try await store.createFile(
                rootID: payload.rootID,
                relativePath: Self.controlAddedFileName,
                content: Self.controlAddedSource,
                validating: .visibleWorkspace
            )
        }
        XCTAssertEqual(
            activeSelectionContainsControlAddedSource(window),
            create == .applyEditsCreateAndSelect,
            "\(create) must differ from its pair only in selecting the created source",
            file: file,
            line: line
        )
        let added = try await fileRecord(at: addedURL, store: store, rootScope: .visibleWorkspace)
        let names = [payload.id: "payload", consumer.id: "consumer", added.id: "added"]
        let countsBefore = await store.codemapPresentationOperationCountsForTesting()
        let engineBefore = try await engineCounters(store: store)

        // Timing-only observation: each hook records and returns; none rejects or delays publication
        // beyond the store reads it performs. The diagnostic sink only captures the terminal record.
        let events = CodemapLockedValues<String>()
        let diagnosticRecords = CodemapLockedValues<WorkspaceCodemapStructureDiagnosticRecord>()
        let clock = ContinuousClock()
        let started = clock.now
        let coordinator = WorkspaceCodemapPresentationCoordinator(
            store: store,
            beforePublicationRevalidation: { receipt in
                var tickets: [String] = []
                for ticket in receipt.demandTickets {
                    let retains = await store.codemapArtifactDemandRetainCountForTesting(ticket)
                    tickets.append(
                        "\(names[ticket.fileID] ?? "other"):gen=\(ticket.requestGeneration)" +
                            ":catalog=\(ticket.catalogGeneration):retains=\(retains)"
                    )
                }
                let graph = await store.codemapGraphPublicationRecoveryStateForTesting(rootEpoch: rootEpoch)
                events.append(
                    "revalidate@\(clock.now - started) tickets=\(tickets.sorted()) " +
                        "flight=\(graph.flightActive) observer=\(graph.observerActive)"
                )
            },
            structureAttemptDidBegin: { attempt in
                events.append("attempt\(attempt)@\(clock.now - started)")
            },
            structureDiagnosticSink: { diagnosticRecords.append($0) }
        )
        let presentation = try await coordinator.structurePresentation(
            seedFileIDs: [payload.id],
            direction: .referrers,
            traversalLimits: WorkspaceCodemapStructureTraversalLimits(
                maximumDepth: 1,
                maximumNodeCount: 10,
                maximumEdgeCount: 500,
                maximumByteCount: 8 * 1024 * 1024
            ),
            outputLimits: WorkspaceCodemapStructureOutputLimits(
                maximumFileCount: 10,
                maximumCodemapTokenCount: 6000
            ),
            rootScope: .visibleWorkspace
        )
        let elapsed = clock.now - started
        let repairs = await store.codemapRootSessionRepairCountForTesting()
        let countsAfter = await store.codemapPresentationOperationCountsForTesting()
        let engineAfter = try await engineCounters(store: store)
        let diagnostics = "\(create) outcome=\(presentation.outcome) elapsed=\(elapsed) repairs=\(repairs) " +
            "issues=\(presentation.issues) events=\(events.values) " +
            "graphWorkerStarts+=\(countsAfter.graphWorkerStarts - countsBefore.graphWorkerStarts) " +
            "artifactDemandRequests+=\(countsAfter.artifactDemandRequests - countsBefore.artifactDemandRequests) " +
            "demandTasks+=\(countsAfter.demandTasksCreated - countsBefore.demandTasksCreated) " +
            "fullRootGraphFreezes+=\(countsAfter.fullRootGraphFreezes - countsBefore.fullRootGraphFreezes) " +
            "observers+=\(countsAfter.projectionRecoveryObserversStarted - countsBefore.projectionRecoveryObserversStarted) " +
            "coveragesCompleted\(counterDelta(engineBefore, engineAfter, \.projectionCoveragesCompleted)) " +
            "coveragesSuperseded\(counterDelta(engineBefore, engineAfter, \.projectionCoveragesSuperseded)) " +
            "coveragesCancelled\(counterDelta(engineBefore, engineAfter, \.projectionCoveragesCancelled)) " +
            "catalogPages\(counterDelta(engineBefore, engineAfter, \.projectionCatalogPages)) " +
            automaticConsumerSummary(window)
        XCTAssertEqual(presentation.outcome, .ready, diagnostics, file: file, line: line)
        XCTAssertEqual(
            Set(presentation.entries.map(\.entry.fileID)),
            [payload.id, consumer.id, added.id],
            diagnostics,
            file: file,
            line: line
        )
        XCTAssertLessThan(elapsed, .seconds(10), diagnostics, file: file, line: line)
        XCTAssertEqual(repairs, 0, "Root resets: \(diagnostics)", file: file, line: line)
        assertControlDiagnosticRecordRevalidatedCurrent(
            diagnosticRecords.values,
            attemptsBegun: events.values.count { $0.hasPrefix("attempt") },
            context: diagnostics,
            file: file,
            line: line
        )
        try await assertControlUnchangedRepeatReadyWithoutGitDrift(
            fixture,
            context: create.rawValue,
            file: file,
            line: line
        )
    }

    /// The coordinator-emitted record for a projection reset spent on the only allowed attempt names
    /// the typed projection cause, the prepared root-session retry, and the unrestartable terminal.
    private func assertUnrestartableProjectionResetDiagnosticRecord(
        _ records: [WorkspaceCodemapStructureDiagnosticRecord],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(records.count, 1, file: file, line: line)
        guard let record = records.first else { return }
        let logLines = record.logLines(emissionSequence: 1)
        let context = "record=\(logLines)"
        XCTAssertEqual(record.terminal.disposition, .unrestartableAfterAttempt, context, file: file, line: line)
        XCTAssertEqual(record.terminal.outcome?.rawValue, "unavailable", context, file: file, line: line)
        XCTAssertNil(record.terminal.staleReason, context, file: file, line: line)
        XCTAssertEqual(
            record.terminal.issueCodes.map(\.rawValue),
            ["projection_unavailable.repository_authority_changed"],
            context,
            file: file,
            line: line
        )
        XCTAssertEqual(record.terminal.attemptsStarted, 1, context, file: file, line: line)
        XCTAssertFalse(record.terminal.cancelled, context, file: file, line: line)
        XCTAssertEqual(
            record.checkpoints.map(\.phase),
            [
                .attemptBegin, .seedAdmission, .seedCandidates, .seedDemand, .projection,
                .projectionRootSessionRetry, .attemptResult, .cleanup
            ],
            context,
            file: file,
            line: line
        )
        XCTAssertEqual(
            record.checkpoints.first { $0.phase == .projection }?.code?.rawValue,
            "unavailable.repository_authority_changed",
            context,
            file: file,
            line: line
        )
        XCTAssertEqual(
            record.checkpoints.first { $0.phase == .projectionRootSessionRetry }?.code?.rawValue,
            "prepared",
            context,
            file: file,
            line: line
        )
        let attemptResult = record.checkpoints.first { $0.phase == .attemptResult }
        XCTAssertTrue(
            attemptResult?.code?.rawValue.hasPrefix("publication.") == true,
            "The restart-needing attempt reports its typed stale leaf: \(context)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            attemptResult?.details.contains(.flag(.unrestartable, true)),
            true,
            context,
            file: file,
            line: line
        )
        assertControlDiagnosticLogLinesPrivacySafe(logLines, context: context, file: file, line: line)
    }

    /// The enabled diagnostic sink receives exactly one record that matches the published result:
    /// a current revalidation after the full final-attempt phase sequence, nothing dropped, and log
    /// lines carrying only fixed codes, numbers, and booleans (no fixture names, paths, or UUIDs).
    private func assertControlDiagnosticRecordRevalidatedCurrent(
        _ records: [WorkspaceCodemapStructureDiagnosticRecord],
        attemptsBegun: Int,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(records.count, 1, "One terminal record per invocation: \(context)", file: file, line: line)
        guard let record = records.first else { return }
        let logLines = record.logLines(emissionSequence: 1)
        let recordContext = "\(context) record=\(logLines)"
        XCTAssertEqual(record.terminal.disposition, .revalidatedCurrent, recordContext, file: file, line: line)
        XCTAssertEqual(record.terminal.outcome?.rawValue, "ready", recordContext, file: file, line: line)
        XCTAssertNil(record.terminal.staleReason, recordContext, file: file, line: line)
        XCTAssertEqual(record.terminal.issueCodes, [], recordContext, file: file, line: line)
        XCTAssertFalse(record.terminal.cancelled, recordContext, file: file, line: line)
        XCTAssertFalse(record.terminal.deadlinePassed, recordContext, file: file, line: line)
        XCTAssertEqual(record.terminal.attemptsStarted, attemptsBegun, recordContext, file: file, line: line)
        XCTAssertEqual(record.terminal.finalAttempt, attemptsBegun - 1, recordContext, file: file, line: line)
        XCTAssertEqual(record.terminal.finalPhase, .cleanup, recordContext, file: file, line: line)
        XCTAssertEqual(record.direction.rawValue, "referrers", recordContext, file: file, line: line)
        XCTAssertEqual(record.requestedSeedCount, 1, recordContext, file: file, line: line)
        XCTAssertEqual(record.droppedCheckpointCount, 0, recordContext, file: file, line: line)

        let finalAttempt = record.checkpoints.filter { $0.attempt == record.terminal.finalAttempt }
        XCTAssertEqual(
            finalAttempt.map(\.phase),
            [
                .attemptBegin, .seedAdmission, .seedCandidates, .seedDemand, .projection,
                .initialTraversal, .targetDemand, .targetTraversal, .presentationCandidates,
                .freezeRender, .attemptResult, .publicationHook, .revalidation, .cleanup
            ],
            recordContext,
            file: file,
            line: line
        )
        XCTAssertEqual(
            finalAttempt.first { $0.phase == .attemptResult }?.code?.rawValue,
            "ready",
            recordContext,
            file: file,
            line: line
        )
        XCTAssertEqual(
            finalAttempt.first { $0.phase == .revalidation }?.code?.rawValue,
            "current",
            recordContext,
            file: file,
            line: line
        )
        XCTAssertEqual(
            finalAttempt.first { $0.phase == .targetDemand }?.details.first,
            .count(.targets, 2),
            recordContext,
            file: file,
            line: line
        )
        assertControlDiagnosticLogLinesPrivacySafe(logLines, context: recordContext, file: file, line: line)
    }

    private func assertControlDiagnosticLogLinesPrivacySafe(
        _ logLines: [String],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(logLines.isEmpty, context, file: file, line: line)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_.=@;:,{} ")
        // The charset already excludes path separators and UUID hyphens; also reject fixture names.
        let forbidden = ["controlpayload", "controlconsumer", "controlauthorityadded", "swift"]
        for logLine in logLines {
            XCTAssertTrue(logLine.hasPrefix("code_structure_diagnostics schema=1 rec=1 part="), logLine, file: file, line: line)
            XCTAssertLessThanOrEqual(
                logLine.utf8.count,
                WorkspaceCodemapStructureDiagnosticRecord.defaultMaximumLineBytes,
                logLine,
                file: file,
                line: line
            )
            XCTAssertTrue(
                logLine.allSatisfy { allowed.contains($0) },
                "Unexpected character in diagnostic line \(logLine): \(context)",
                file: file,
                line: line
            )
            for fragment in forbidden {
                XCTAssertFalse(
                    logLine.lowercased().contains(fragment),
                    "Diagnostic line leaked \(fragment): \(logLine)",
                    file: file,
                    line: line
                )
            }
        }
    }

    /// Signed engine-counter delta for diagnostics; never traps if a counter source is replaced.
    private func counterDelta(
        _ before: WorkspaceCodemapBindingEngineCounters,
        _ after: WorkspaceCodemapBindingEngineCounters,
        _ counter: KeyPath<WorkspaceCodemapBindingEngineCounters, UInt64>
    ) -> String {
        let old = before[keyPath: counter]
        let new = after[keyPath: counter]
        return new >= old ? "+=\(new - old)" : "-=\(old - new)"
    }

    private func demandTicket(
        from result: WorkspaceCodemapArtifactDemandResult
    ) -> WorkspaceCodemapArtifactDemandTicket? {
        switch result {
        case let .pending(ticket):
            ticket
        case let .ready(ready):
            ready.ticket
        case .unavailable:
            nil
        }
    }

    private func waitForDemandResult(
        store: WorkspaceFileContextStore,
        ticket: WorkspaceCodemapArtifactDemandTicket,
        matches: (WorkspaceCodemapArtifactDemandResult) -> Bool
    ) async -> Bool {
        for _ in 0 ..< 200 {
            let result = await store.codemapArtifactDemandStatus(ticket)
            if matches(result) { return true }
            if case .pending = result {
                try? await Task.sleep(for: .milliseconds(10))
                continue
            }
            return false
        }
        return false
    }

    private func readyTicket(
        store: WorkspaceFileContextStore,
        fileID: UUID,
        timeout: Duration = .seconds(8)
    ) async throws -> WorkspaceCodemapArtifactDemandTicket {
        var activeTicket: WorkspaceCodemapArtifactDemandTicket?
        let clock = ContinuousClock()

        do {
            var result = await store.requestCodemapArtifact(forFileID: fileID)
            var lastResultDescription = String(describing: result)
            let timeoutDescription = String(describing: timeout)
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                try Task.checkCancellation()
                lastResultDescription = String(describing: result)
                switch result {
                case let .ready(ready):
                    return ready.ticket
                case let .pending(ticket):
                    activeTicket = ticket
                    try await Task.sleep(for: .milliseconds(25))
                    result = await store.codemapArtifactDemandStatus(ticket)
                case let .unavailable(.busy(retryAfterMilliseconds)):
                    let delayMilliseconds = min(max(retryAfterMilliseconds ?? 100, 25), 1000)
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                    if let activeTicket {
                        result = await store.retryBusyCodemapArtifactDemand(activeTicket, priority: .demand)
                    } else {
                        result = await store.requestCodemapArtifact(forFileID: fileID)
                    }
                    switch result {
                    case let .ready(ready):
                        return ready.ticket
                    case let .pending(ticket):
                        activeTicket = ticket
                    case .unavailable:
                        break
                    }
                case let .unavailable(reason):
                    XCTFail("Expected ready codemap demand, got \(reason)")
                    throw NSError(domain: "MCPCodeStructureWorktreeTests", code: 2)
                }
            }
            XCTFail(
                "Timed out waiting for ready codemap demand after \(timeoutDescription); last result: \(lastResultDescription)"
            )
            throw NSError(domain: "MCPCodeStructureWorktreeTests", code: 3)
        } catch {
            if let ticket = activeTicket {
                activeTicket = nil
                _ = await store.cancelCodemapArtifactDemand(
                    ticket,
                    deadline: clock.now.advanced(by: .seconds(5))
                )
            }
            throw error
        }
    }

    private func settledCodemapPresentationOperationCounts(
        store: WorkspaceFileContextStore,
        rootEpoch: WorkspaceCodemapRootEpoch,
        timeout: Duration = .seconds(8),
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> WorkspaceFileContextStore.CodemapPresentationOperationCounts {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var previousCounts: WorkspaceFileContextStore.CodemapPresentationOperationCounts?
        var stablePassCount = 0
        var lastState: WorkspaceFileContextStore.CodemapGraphPublicationRecoveryStateForTesting?
        var lastCounts: WorkspaceFileContextStore.CodemapPresentationOperationCounts?

        while clock.now < deadline {
            try Task.checkCancellation()
            let graphReady = await store.waitForCodemapGraphPublication(
                rootEpoch: rootEpoch,
                deadline: deadline
            )
            guard graphReady else {
                XCTFail(
                    "Timed out waiting for codemap graph publication while settling \(reason); " +
                        "lastState: \(String(describing: lastState)); " +
                        "lastCounts: \(String(describing: lastCounts))",
                    file: file,
                    line: line
                )
                throw NSError(domain: "MCPCodeStructureWorktreeTests", code: 4)
            }

            let state = await store.codemapGraphPublicationRecoveryStateForTesting(rootEpoch: rootEpoch)
            let counts = await store.codemapPresentationOperationCountsForTesting()
            lastState = state
            lastCounts = counts

            guard !state.flightActive, !state.observerActive else {
                previousCounts = nil
                stablePassCount = 0
                await Task.yield()
                continue
            }

            if counts == previousCounts {
                stablePassCount += 1
            } else {
                previousCounts = counts
                stablePassCount = 1
            }

            if stablePassCount >= 2 {
                return counts
            }

            await Task.yield()
        }

        XCTFail(
            "Timed out waiting for stable codemap presentation counters while settling \(reason); " +
                "lastState: \(String(describing: lastState)); " +
                "lastCounts: \(String(describing: lastCounts)); timeout: \(timeout)",
            file: file,
            line: line
        )
        throw NSError(domain: "MCPCodeStructureWorktreeTests", code: 5)
    }

    private func makeWindow(
        root: URL,
        additionalRoots: [URL] = [],
        projectionPreloadLaunchPolicy: WorkspaceFileContextStore.CodemapProjectionPreloadLaunchPolicyForTesting = .disabled,
        capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks = .none,
        prepareStore: (WorkspaceFileContextStore) async -> Void = { _ in },
        codemapDemandResultHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket,
            WorkspaceCodemapBindingDemandResult
        ) async -> WorkspaceCodemapBindingDemandResult = { _, result in result }
    ) async throws -> WindowState {
        let codemapFixture = try MCPCodeStructureCodemapRuntimeFixture(
            name: "MCPCodeStructureWorktreeTests",
            projectionPreloadLaunchPolicy: projectionPreloadLaunchPolicy,
            capabilityHooks: capabilityHooks,
            codemapDemandResultHook: codemapDemandResultHook
        )
        addTeardownBlock {
            await codemapFixture.shutdown()
        }
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let store = codemapFixture.makeStore()
        await prepareStore(store)
        let window = WindowState(workspaceFileContextStore: store)
        WindowStatesManager.shared.registerWindowState(window)
        addTeardownBlock { @MainActor in
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Code Structure Worktree \(UUID().uuidString.prefix(8))",
            repoPaths: ([root] + additionalRoots).map(\.path),
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "mcpCodeStructureWorktreeTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        for loadedRoot in [root] + additionalRoots {
            _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: loadedRoot.path
            )
        }
        return window
    }

    private func makeProjection(
        logicalRoot: WorkspaceRootRecord,
        physicalRoot: WorkspaceRootRecord,
        worktreeID: String
    ) -> WorkspaceRootBindingProjection {
        let logicalRef = WorkspaceRootRef(
            id: logicalRoot.id,
            name: logicalRoot.name,
            fullPath: logicalRoot.standardizedFullPath
        )
        let physicalRef = WorkspaceRootRef(
            id: physicalRoot.id,
            name: logicalRoot.name,
            fullPath: physicalRoot.standardizedFullPath
        )
        return WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRef,
                    physicalRoot: physicalRef,
                    binding: makeBinding(logicalRoot: logicalRef, physicalRoot: physicalRef, worktreeID: worktreeID)
                )
            ],
            visibleLogicalRoots: [logicalRef]
        )
    }

    private func makeBinding(
        logicalRoot: WorkspaceRootRef,
        physicalRoot: WorkspaceRootRef,
        worktreeID: String
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-\(worktreeID)",
            repositoryID: "repo-\(worktreeID)",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.standardizedFullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: worktreeID,
            worktreeRootPath: physicalRoot.standardizedFullPath,
            worktreeName: URL(fileURLWithPath: physicalRoot.standardizedFullPath).lastPathComponent,
            branch: "feature/\(worktreeID)",
            source: "test"
        )
    }

    private func renderedStructureEntry() throws -> WorkspaceCodemapStructureRenderedEntry {
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "LogicalRoot",
            standardizedRelativePath: "Sources/App.swift"
        ))
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        return WorkspaceCodemapStructureRenderedEntry(
            entry: WorkspaceCodemapOperationRenderedEntry(
                bundleID: WorkspaceCodemapFrozenPresentationBundleID(),
                fileID: UUID(),
                rootEpoch: rootEpoch,
                artifactKey: CodeMapArtifactKey(
                    rawSHA256: CodeMapRawSourceDigest(bytes: Data(repeating: 1, count: 32)),
                    rawByteCount: 16,
                    pipelineIdentity: pipeline
                ),
                logicalPath: logicalPath,
                text: SwiftFixtureSource.emptyStruct("App", trailingNewline: false),
                tokenCount: 7
            ),
            isSeed: true,
            depth: 0,
            reachedBy: []
        )
    }

    private func fileRecord(
        at url: URL,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope
    ) async throws -> WorkspaceFileRecord {
        let result = await store.lookupPath(url.path, profile: .mcpRead, rootScope: rootScope)
        return try XCTUnwrap(result?.file)
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPCodeStructureWorktreeTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.standardizedFileURL
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

#if DEBUG
    private actor AsyncGate {
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }

            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
#endif

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(underestimatedCount)
        for element in self {
            try await values.append(transform(element))
        }
        return values
    }
}

private actor CodeStructureDemandHookCounter {
    private let persistent: Bool
    private var count = 0

    init(persistent: Bool) {
        self.persistent = persistent
    }

    func transform(
        _ result: WorkspaceCodemapBindingDemandResult
    ) -> WorkspaceCodemapBindingDemandResult {
        count += 1
        if persistent || count == 1 {
            return .rejected(.capabilityUnavailable)
        }
        return result
    }
}

private actor CodeStructureTargetDemandRejection {
    private var targetFileID: UUID?
    private var didReject = false

    func configure(targetFileID: UUID) {
        self.targetFileID = targetFileID
    }

    func transform(
        ticket: WorkspaceCodemapArtifactDemandTicket,
        result: WorkspaceCodemapBindingDemandResult
    ) -> WorkspaceCodemapBindingDemandResult {
        guard ticket.fileID == targetFileID, !didReject else { return result }
        didReject = true
        return .rejected(.rootNotRegistered)
    }

    func rejectionCount() -> Int {
        didReject ? 1 : 0
    }
}

private actor CodeStructurePersistentDemandBarrier {
    private let expectedInitialFileCount: Int
    private var firstInvocationFileIDs: Set<UUID> = []
    private var countsByFileID: [UUID: Int] = [:]
    private var initialBarrierReleased = false
    private var initialWaiters: [CheckedContinuation<Void, Never>] = []

    init(expectedInitialFileCount: Int) {
        self.expectedInitialFileCount = expectedInitialFileCount
    }

    func transform(
        ticket: WorkspaceCodemapArtifactDemandTicket,
        result _: WorkspaceCodemapBindingDemandResult
    ) async -> WorkspaceCodemapBindingDemandResult {
        countsByFileID[ticket.fileID, default: 0] += 1
        if firstInvocationFileIDs.insert(ticket.fileID).inserted {
            if firstInvocationFileIDs.count == expectedInitialFileCount {
                initialBarrierReleased = true
                let waiters = initialWaiters
                initialWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            } else if !initialBarrierReleased {
                await withCheckedContinuation { continuation in
                    initialWaiters.append(continuation)
                }
            }
        }
        return .rejected(.capabilityUnavailable)
    }

    func invocationCounts() -> [UUID: Int] {
        countsByFileID
    }
}

/// Passes real demand results through unchanged; only holds first results until the expected
/// number of distinct files has a result, so concurrent operations overlap at recovery.
private actor CodeStructureDistinctDemandBarrier {
    private let expectedFileCount: Int
    private var ignoredFileIDs: Set<UUID> = []
    private var arrivedFileIDs: Set<UUID> = []
    private var released = false
    private var releasedByArrival = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expectedFileCount: Int) {
        self.expectedFileCount = expectedFileCount
    }

    func ignore(fileID: UUID) {
        ignoredFileIDs.insert(fileID)
    }

    func passThrough(
        ticket: WorkspaceCodemapArtifactDemandTicket,
        result: WorkspaceCodemapBindingDemandResult
    ) async -> WorkspaceCodemapBindingDemandResult {
        guard !released, !ignoredFileIDs.contains(ticket.fileID) else { return result }
        guard arrivedFileIDs.insert(ticket.fileID).inserted else { return result }
        if arrivedFileIDs.count >= expectedFileCount {
            releasedByArrival = true
            release()
            return result
        }
        if waiters.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await self?.release()
            }
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        return result
    }

    func didReleaseByArrival() -> Bool {
        releasedByArrival
    }

    private func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Stages a second unrelated edit with real Git on the `onIssuance`-th armed source-authority
/// issuance. The default (second) follows the replacement registration of the first root-session
/// reset; the hook runs before the authority capture, so that issuance observes the edit.
private final class CodeStructureAuthorityAdvanceAfterReset: @unchecked Sendable {
    private let lock = NSLock()
    private let repositories: ReviewGitRepositoryFixture
    private let root: URL
    private let relativePath: String
    private let onIssuance: Int
    private var armed = false
    private var issuanceCount = 0
    private var advanced = false

    init(repositories: ReviewGitRepositoryFixture, root: URL, relativePath: String, onIssuance: Int = 2) {
        self.repositories = repositories
        self.root = root
        self.relativePath = relativePath
        self.onIssuance = onIssuance
    }

    func arm() {
        lock.lock()
        defer { lock.unlock() }
        armed = true
    }

    func observeIssuance() {
        lock.lock()
        defer { lock.unlock() }
        guard armed, !advanced else { return }
        issuanceCount += 1
        guard issuanceCount == onIssuance else { return }
        advanced = (try? repositories.stage(relativePath, at: root)) != nil
    }

    func didAdvance() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return advanced
    }
}

private final class CodeStructureOneShotGitStage: @unchecked Sendable {
    struct Snapshot {
        let didStage: Bool
        let error: String?
    }

    private let lock = NSLock()
    private let repositories: ReviewGitRepositoryFixture
    private let root: URL
    private let relativePath: String
    private var didStage = false
    private var error: String?

    init(repositories: ReviewGitRepositoryFixture, root: URL, relativePath: String) {
        self.repositories = repositories
        self.root = root
        self.relativePath = relativePath
    }

    func stageOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !didStage else { return }
        didStage = true
        do {
            try repositories.stage(relativePath, at: root)
        } catch {
            self.error = String(describing: error)
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(didStage: didStage, error: error)
    }
}

/// Holds callers (bounded) until the test opens it; records whether any caller waited.
private final class CodeStructureOpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waited = false

    func open() {
        lock.withLock { opened = true }
    }

    func waitUntilOpened() async {
        lock.withLock { waited = true }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline, !lock.withLock({ opened }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func didHoldCaller() -> Bool {
        lock.withLock { waited }
    }
}

/// Parks the first armed source-authority issuance until released; later issuances pass.
private final class CodeStructureOneShotIssuancePause: @unchecked Sendable {
    private let lock = NSLock()
    private let fence = TestReleaseFence(name: "code structure issuance pause")
    private var armed = false
    private var claimed = false

    func arm() {
        lock.withLock { armed = true }
    }

    func observeIssuance() async {
        let shouldPark = lock.withLock { () -> Bool in
            guard armed, !claimed else { return false }
            claimed = true
            return true
        }
        guard shouldPark else { return }
        await fence.enterAndWaitIgnoringCancellationUntilRelease(timeout: 30)
    }

    func waitUntilParked() async -> Bool {
        await fence.waitUntilEntered(timeout: .seconds(10))
    }

    func release() {
        fence.release()
    }
}

/// Parks the first real demand result for one configured file until released, ignoring the
/// detach cancellation, so the root's shared cleanup flight stays in progress.
private final class CodeStructureDemandResultPause: @unchecked Sendable {
    private let lock = NSLock()
    private let fence = TestReleaseFence(name: "code structure demand result pause")
    private var pausedFileID: UUID?
    private var claimed = false

    func pause(fileID: UUID) {
        lock.withLock { pausedFileID = fileID }
    }

    func transform(
        ticket: WorkspaceCodemapArtifactDemandTicket,
        result: WorkspaceCodemapBindingDemandResult
    ) async -> WorkspaceCodemapBindingDemandResult {
        let shouldPark = lock.withLock { () -> Bool in
            guard ticket.fileID == pausedFileID, !claimed else { return false }
            claimed = true
            return true
        }
        if shouldPark {
            await fence.enterAndWaitIgnoringCancellationUntilRelease(timeout: 30)
        }
        return result
    }

    func waitUntilParked() async -> Bool {
        await fence.waitUntilEntered(timeout: .seconds(10))
    }

    func release() {
        fence.release()
    }
}

private enum ReferrersRecoveryMutation: String {
    case stageExistingNonSource
    case emptyCommit
    case createAndStage
    case createUnstaged
}

/// How the live catalog-only lane's third source is created: through the production MCP edit path,
/// which also selects it, or directly through the store without touching selection.
private enum ControlReferrersCreate: String {
    case applyEditsCreateAndSelect
    case storeCreateWithoutSelection
}

/// Engine counters that must stay flat while a session's projection authority failure is latched.
private struct CodeStructureStorePreloadState: Equatable {
    let events: [WorkspaceFileContextStore.CodemapProjectionPreloadStoreEvent]
    let launchPhase: WorkspaceCodemapProjectionPreloadLaunchPhase?
    let retryAttempt: Int?
}

private struct CodeStructureProjectionActivity: Equatable {
    let capabilityResolutions: UInt64
    let repositoryAuthorityChanges: UInt64
    let manifestLoads: UInt64
    let projectionPreloadsScheduled: UInt64
    let projectionPreloadsStarted: UInt64
    let projectionCatalogPages: UInt64
    let projectionBatchesStarted: UInt64
    let projectionRetries: UInt64

    init(_ counters: WorkspaceCodemapBindingEngineCounters) {
        capabilityResolutions = counters.capabilityResolutions
        repositoryAuthorityChanges = counters.repositoryAuthorityChanges
        manifestLoads = counters.manifestLoads
        projectionPreloadsScheduled = counters.projectionPreloadsScheduled
        projectionPreloadsStarted = counters.projectionPreloadsStarted
        projectionCatalogPages = counters.projectionCatalogPages
        projectionBatchesStarted = counters.projectionBatchesStarted
        projectionRetries = counters.projectionRetries
    }
}

private actor CodeStructureContentReadCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class MCPCodeStructureCodemapRuntimeFixture: @unchecked Sendable {
    private let sandbox: URL
    private let provider: CodeMapArtifactRuntimeProvider
    private let projectionPreloadLaunchPolicy: WorkspaceFileContextStore.CodemapProjectionPreloadLaunchPolicyForTesting
    private let codemapDemandResultHook: @Sendable (
        WorkspaceCodemapArtifactDemandTicket,
        WorkspaceCodemapBindingDemandResult
    ) async -> WorkspaceCodemapBindingDemandResult

    init(
        name: String,
        projectionPreloadLaunchPolicy: WorkspaceFileContextStore.CodemapProjectionPreloadLaunchPolicyForTesting = .disabled,
        capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks = .none,
        codemapDemandResultHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket,
            WorkspaceCodemapBindingDemandResult
        ) async -> WorkspaceCodemapBindingDemandResult = { _, result in result }
    ) throws {
        self.projectionPreloadLaunchPolicy = projectionPreloadLaunchPolicy
        self.codemapDemandResultHook = codemapDemandResultHook
        let sandbox = try Self.makeSecureDirectory(name: name)
        do {
            let artifactRoot = try Self.makeSecureDirectory(in: sandbox, named: "artifacts")
            let registry = WorkspaceCodemapBindingIntegrationRegistry()
            self.sandbox = sandbox
            provider = CodeMapArtifactRuntimeProvider {
                try CodeMapArtifactRuntime(
                    rootURL: artifactRoot,
                    bindingIntegrationRegistry: registry,
                    bindingEngineFactory: { runtime in
                        WorkspaceCodemapBindingEngine(
                            runtime: runtime,
                            capabilityService: WorkspaceCodemapGitCapabilityService(
                                namespaceSalt: Data(
                                    repeating: 0x4D,
                                    count: GitBlobRepositoryNamespace.saltByteCount
                                ),
                                hooks: capabilityHooks
                            ),
                            sourceReader: registry.makeValidatedSourceReaderClient(),
                            catalogClient: registry.makeBindingCatalogClient()
                        )
                    }
                )
            }
            _ = try provider.runtime()
        } catch {
            try? FileManager.default.removeItem(at: sandbox)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func makeStore() -> WorkspaceFileContextStore {
        let provider = provider
        return WorkspaceFileContextStore(
            enableCatalogShardShadowValidation: false,
            codemapRuntimeProvider: {
                try provider.runtime()
            },
            codemapProjectionPreloadLaunchPolicyForTesting: projectionPreloadLaunchPolicy,
            codemapDemandResultHook: codemapDemandResultHook
        )
    }

    func shutdown() async {
        if let runtime = try? provider.runtime(),
           let engine = try? runtime.bindingEngine()
        {
            await engine.shutdown()
        }
        try? FileManager.default.removeItem(at: sandbox)
    }

    private static func makeSecureDirectory(name: String) throws -> URL {
        let sanitized = name.replacingOccurrences(of: "/", with: "-")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(sanitized)-codemap-runtime-\(UUID().uuidString)",
                isDirectory: true
            )
        return try createSecureDirectory(directory, withIntermediateDirectories: true)
    }

    private static func makeSecureDirectory(in parent: URL, named name: String) throws -> URL {
        try createSecureDirectory(
            parent.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: false
        )
    }

    private static func createSecureDirectory(
        _ directory: URL,
        withIntermediateDirectories: Bool
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: withIntermediateDirectories,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let resolvedPath = try directory.path.withCString { pointer -> String in
            guard let resolved = realpath(pointer, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }
}
