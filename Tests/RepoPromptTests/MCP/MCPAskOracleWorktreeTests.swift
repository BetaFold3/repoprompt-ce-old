import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

#if DEBUG
    @MainActor
    final class MCPAskOracleWorktreeTests: XCTestCase {
        override func tearDown() async throws {
            await ServerNetworkManager.shared.debugSetBeforeToolResultFormattingForTesting(nil)
            await ServerNetworkManager.shared.debugSetResolvedToolOperationOverride(
                toolName: MCPWindowToolName.readFile,
                operation: nil
            )
            try await super.tearDown()
        }

        func testExplicitWindowProvenanceEndsBeforePostProviderHooks() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                try await activateWorkspace(fixture.contextA)
                fixture.contextA.window.mcpServer.windowToolsEnabled = true
                WindowStatesManager.shared.registerWindowState(fixture.contextA.window)
                let manager = fixture.networkManager
                let capture = ExplicitWindowRoutingHintCapture()
                let endpoint = try fixture.endpointA()
                let endpointConnectionID = endpoint.connectionID
                try await configureAgentModeEndpoint(
                    endpoint,
                    context: makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(
                            selectedPaths: [fixture.contextA.fileURL.path],
                            codemapAutoEnabled: false
                        ),
                        bindings: []
                    ),
                    fixture: fixture
                )
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                    .object(["ok": .bool(true)])
                }
                await manager.debugSetBeforeToolResultFormattingForTesting { connectionID, toolName in
                    guard connectionID == endpointConnectionID,
                          toolName == MCPWindowToolName.readFile
                    else { return }
                    await capture.record(ServerNetworkManager.currentExplicitWindowRoutingHint)
                }

                do {
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: [
                            "path": fixture.contextA.fileURL.path,
                            "context_id": fixture.contextA.tabID.uuidString,
                            "_windowID": fixture.contextA.window.windowID
                        ],
                        timeoutSeconds: 30
                    )

                    let hints = await capture.snapshot()
                    XCTAssertEqual(hints.count, 1)
                    XCTAssertNil(hints.first.flatMap(\.self))

                    await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.readFile,
                        operation: nil
                    )
                    WindowStatesManager.shared.unregisterWindowState(fixture.contextA.window)
                    await fixture.cleanup()
                } catch {
                    await manager.debugSetBeforeToolResultFormattingForTesting(nil)
                    await manager.debugSetResolvedToolOperationOverride(
                        toolName: MCPWindowToolName.readFile,
                        operation: nil
                    )
                    WindowStatesManager.shared.unregisterWindowState(fixture.contextA.window)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testOracleSendContextKeepsConversationOwnerSeparateFromDelegatedPackagingSource() throws {
            let childTabID = UUID()
            let childWorkspaceID = UUID()
            let childSessionID = UUID()
            let childRunID = UUID()
            let sourceTabID = UUID()
            let sourceSessionID = UUID()
            let sourceRunID = UUID()
            let delegationID = UUID()
            let sourceSelection = StoredSelection(
                selectedPaths: ["/tmp/source/Sources/Feature.swift"],
                codemapAutoEnabled: false
            )
            let sourceCapability = SelectedGitArtifactCapability(
                workspaceID: childWorkspaceID,
                workspaceDirectoryPath: "/tmp/workspace",
                gitDataRoot: WorkspaceRootRef(
                    id: UUID(),
                    name: "_git_data",
                    fullPath: "/tmp/workspace/_git_data"
                ),
                creatorTabID: sourceTabID,
                sessionID: sourceSessionID,
                boundCheckouts: [],
                canonicalWorkspaceRootPaths: ["/tmp/source"]
            )
            let sourceReviewContext = FrozenPromptGitReviewContext(
                artifactCapability: sourceCapability,
                compareIntent: .uncommittedHEAD,
                displayContext: ReviewGitDisplayContext(roots: [])
            )
            let capturedSource = AgentRunOracleReviewSource.Captured(
                delegationID: delegationID,
                sourceTabID: sourceTabID,
                workspaceID: childWorkspaceID,
                sourceSelectionRevision: 42,
                promptText: "source prompt",
                selection: sourceSelection,
                lookupContext: .visibleWorkspace,
                reviewGitContext: sourceReviewContext,
                sourceAgentSessionID: sourceSessionID,
                sourceAgentRunID: sourceRunID,
                sourceWorktreeBindings: []
            )
            let delegated = DelegatedAgentRunOracleReviewContext(
                source: .captured(capturedSource),
                target: AgentRunOracleReviewTargetSnapshot(
                    tabID: childTabID,
                    workspaceID: childWorkspaceID,
                    agentSessionID: childSessionID,
                    activationID: UUID(),
                    expectedParentSessionID: sourceSessionID,
                    worktreeBindings: [],
                    validationFailure: nil
                ),
                targetRunID: childRunID
            )
            let packaging = try OracleViewModel.OracleSendPackagingContext(delegated: delegated)
            let context = OracleViewModel.OracleSendTabContext(
                tabID: childTabID,
                workspaceID: childWorkspaceID,
                origin: .askOracle,
                agentModeSessionID: childSessionID,
                agentModeRunID: childRunID,
                packaging: packaging
            )

            XCTAssertEqual(context.tabID, childTabID)
            XCTAssertEqual(context.agentModeSessionID, childSessionID)
            XCTAssertEqual(context.agentModeRunID, childRunID)
            XCTAssertEqual(context.packaging.sourceTabID, sourceTabID)
            XCTAssertEqual(context.packaging.sourceAgentSessionID, sourceSessionID)
            XCTAssertEqual(context.packaging.sourceAgentRunID, sourceRunID)
            XCTAssertEqual(context.packaging.selection, sourceSelection)
            XCTAssertEqual(
                context.packaging.provenance,
                .delegated(delegationID: delegationID)
            )
            guard case let .delegated(artifactDelegation) = try XCTUnwrap(
                context.packaging.reviewGitContext.artifactCapability
            ).access else {
                return XCTFail("Expected delegated artifact capability")
            }
            XCTAssertEqual(artifactDelegation.sourceTabID, sourceTabID)
            XCTAssertEqual(artifactDelegation.targetTabID, childTabID)
            XCTAssertEqual(artifactDelegation.targetAgentSessionID, childSessionID)
            XCTAssertEqual(artifactDelegation.targetAgentRunID, childRunID)
            XCTAssertEqual(
                context.packaging.reviewGitContext.artifactDelegationConsumer,
                SelectedGitArtifactDelegationConsumer(
                    workspaceID: childWorkspaceID,
                    tabID: childTabID,
                    agentSessionID: childSessionID,
                    agentRunID: childRunID,
                    boundCheckouts: []
                )
            )
        }

        func testExplicitOracleContinuationUsesSessionDominantOwnership() {
            let tabID = UUID()
            let sessionID = UUID()
            let runID = UUID()
            let owned = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: runID
            )
            let missingRunStamp = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID
            )
            let runOwned = ChatSession(
                composeTabID: tabID,
                agentModeRunID: runID
            )
            let unownedLegacy = ChatSession(composeTabID: tabID)

            // Session-owned lanes: the durable Agent Mode session decides. The run stamp is
            // ephemeral per-process metadata, so a rotated run (app relaunch or controller
            // recreation) must not orphan the session's own lane.
            XCTAssertTrue(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
            XCTAssertTrue(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: UUID()
                )
            )
            XCTAssertTrue(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: nil
                )
            )
            XCTAssertTrue(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    missingRunStamp,
                    agentModeSessionID: sessionID,
                    agentModeRunID: UUID()
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: UUID(),
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: nil,
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: nil,
                    agentModeRunID: nil
                )
            )

            // Run-owned headless lanes die with their exact run; a session-having caller
            // must not adopt them even when the ephemeral run UUID happens to match.
            XCTAssertTrue(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    runOwned,
                    agentModeSessionID: nil,
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    runOwned,
                    agentModeSessionID: nil,
                    agentModeRunID: UUID()
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    runOwned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )

            // Unowned legacy chats never match owned callers on the strict path.
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    unownedLegacy,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
            XCTAssertTrue(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    unownedLegacy,
                    agentModeSessionID: nil,
                    agentModeRunID: nil
                )
            )

            // Rejection messages keep the load-bearing phrase and discriminate causes.
            let sessionMismatch = OracleViewModel.oracleOwnerContinuationRejection(
                owned,
                chatID: "lane-a",
                agentModeSessionID: UUID(),
                agentModeRunID: runID
            )
            XCTAssertTrue(sessionMismatch?.contains("different Agent Mode owner") == true)
            XCTAssertTrue(sessionMismatch?.contains("different Agent Mode session") == true)
            let headlessLaneMismatch = OracleViewModel.oracleOwnerContinuationRejection(
                runOwned,
                chatID: "lane-b",
                agentModeSessionID: sessionID,
                agentModeRunID: runID
            )
            XCTAssertTrue(headlessLaneMismatch?.contains("different Agent Mode owner") == true)
            XCTAssertTrue(headlessLaneMismatch?.contains("run-scoped headless lane") == true)
            XCTAssertNil(
                OracleViewModel.oracleOwnerContinuationRejection(
                    owned,
                    chatID: "lane-c",
                    agentModeSessionID: sessionID,
                    agentModeRunID: UUID()
                )
            )
        }

        func testOracleLogLookupPrefersExactRunThenStaleSameSessionNeverLegacy() {
            let tabID = UUID()
            let sessionID = UUID()
            let runID = UUID()
            let exact = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: runID,
                savedAt: Date(timeIntervalSince1970: 1)
            )
            let newerStaleRun = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: UUID(),
                savedAt: Date(timeIntervalSince1970: 3)
            )
            let newestLegacy = ChatSession(
                composeTabID: tabID,
                savedAt: Date(timeIntervalSince1970: 4)
            )
            let otherSession = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: UUID(),
                agentModeRunID: runID,
                savedAt: Date(timeIntervalSince1970: 5)
            )

            // Exact-run lane wins over a newer stale-run lane of the same session.
            XCTAssertEqual(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [newestLegacy, newerStaleRun, exact],
                    activeSessionID: newestLegacy.id,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )?.id,
                exact.id
            )
            // Post-rotation recovery: without an exact-run lane, the caller's own session
            // recovers its stale-run lane; the legacy chat is still never adopted.
            XCTAssertEqual(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [newestLegacy, newerStaleRun],
                    activeSessionID: newestLegacy.id,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )?.id,
                newerStaleRun.id
            )
            // Legacy and other-session lanes remain invisible to an owned caller.
            XCTAssertNil(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [newestLegacy, otherSession],
                    activeSessionID: newestLegacy.id,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
        }

        func testOwnerlessOracleLogLookupSeesOnlyUnownedChats() {
            let tabID = UUID()
            let sessionID = UUID()
            let runID = UUID()
            let ownedActive = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: runID,
                savedAt: Date(timeIntervalSince1970: 5),
                messageCount: 3
            )
            let runOwned = ChatSession(
                composeTabID: tabID,
                agentModeRunID: runID,
                savedAt: Date(timeIntervalSince1970: 4),
                messageCount: 2
            )
            let unownedLegacy = ChatSession(
                composeTabID: tabID,
                savedAt: Date(timeIntervalSince1970: 1),
                messageCount: 1
            )

            // An ownerless Agent Mode caller must not read agent-owned lanes — even the
            // tab-active one — only genuinely unowned chats.
            XCTAssertEqual(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [ownedActive, runOwned, unownedLegacy],
                    activeSessionID: ownedActive.id,
                    agentModeSessionID: nil,
                    agentModeRunID: nil
                )?.id,
                unownedLegacy.id
            )
            XCTAssertNil(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [ownedActive, runOwned],
                    activeSessionID: ownedActive.id,
                    agentModeSessionID: nil,
                    agentModeRunID: nil
                )
            )
        }

        func testOracleLogRecoveryPrefersNonEmptyStaleLaneOverEmptyExactRunLane() {
            let tabID = UUID()
            let sessionID = UUID()
            let runID = UUID()
            let staleWithMessages = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: UUID(),
                savedAt: Date(timeIntervalSince1970: 1),
                messageCount: 4
            )
            let emptyExact = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: runID,
                savedAt: Date(timeIntervalSince1970: 2)
            )

            // Log recovery is about reading a conversation: a non-empty stale lane from the
            // same session beats an empty exact-run lane instead of dead-ending on it.
            XCTAssertEqual(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [emptyExact, staleWithMessages],
                    activeSessionID: nil,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )?.id,
                staleWithMessages.id
            )
            // With both lanes non-empty, the exact-run lane still wins.
            let exactWithMessages = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: runID,
                savedAt: Date(timeIntervalSince1970: 2),
                messageCount: 2
            )
            XCTAssertEqual(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [exactWithMessages, staleWithMessages],
                    activeSessionID: nil,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )?.id,
                exactWithMessages.id
            )
        }

        func testAskOracleWaitsForReadAutoSelectionAndPackagesWorktreeContent() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let gate = OracleWorktreeGate()
                let capture = OracleWorktreeCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let logicalFile = fixture.contextA.fileURL
                    let worktreeRoot = try makeTemporaryRoot(name: "OracleDrainWorktree")
                    let worktreeFile = worktreeRoot
                        .appendingPathComponent("Sources", isDirectory: true)
                        .appendingPathComponent(logicalFile.lastPathComponent)
                    let canonicalSentinel = "canonical_oracle_drain_content"
                    let worktreeSentinel = "worktree_oracle_drain_content"
                    try write("let value = \"\(canonicalSentinel)\"\n", to: logicalFile)
                    try write("let value = \"\(worktreeSentinel)\"\n", to: worktreeFile)

                    let binding = makeBinding(
                        logicalRoot: fixture.contextA.rootURL,
                        worktreeRoot: worktreeRoot,
                        suffix: "drain"
                    )
                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(),
                        bindings: [binding]
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: context,
                        fixture: fixture,
                        sessionProfile: .knowledge
                    )
                    let deniedResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "get"]
                    )
                    XCTAssertTrue(
                        deniedResponse.rawJSON.contains("not available in this Knowledge session"),
                        deniedResponse.rawJSON
                    )

                    installOracleCapture(capture, on: fixture.contextA.window)
                    fixture.contextA.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting {
                        await gate.markStartedAndWaitForRelease()
                    }

                    let readTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": logicalFile.path],
                            timeoutSeconds: 5
                        )
                    }
                    guard await gate.waitUntilStarted() else {
                        readTask.cancel()
                        let diagnostic: String
                        do {
                            diagnostic = try await readTask.value.rawJSON
                        } catch {
                            diagnostic = String(describing: error)
                        }
                        throw OracleWorktreeTestError.autoSelectionDidNotStart(readDiagnostic: diagnostic)
                    }
                    let readResponse = try await readTask.value
                    XCTAssertTrue(try toolResultText(readResponse).contains(worktreeSentinel))

                    let askTask = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.askOracle,
                            arguments: ["message": "Explain the selected implementation."],
                            timeoutSeconds: 30
                        )
                    }
                    let drainWaiterRegistered = await waitUntil {
                        fixture.contextA.window.mcpServer
                            .readFileAutoSelectionDiagnosticsSnapshot().canonicalWaiterCount == 1
                    }
                    XCTAssertTrue(drainWaiterRegistered)
                    XCTAssertFalse(capture.wasInvoked)

                    await gate.release()
                    let askResponse = try await askTask.value
                    XCTAssertTrue(try toolResultText(askResponse).contains("captured oracle response"))
                    XCTAssertTrue(capture.wasInvoked)
                    let tabContext = try XCTUnwrap(capture.tabContext)
                    XCTAssertEqual(tabContext.packaging.selection.selectedPaths, [logicalFile.path])
                    let packaged = capture.fileBlocks.joined(separator: "\n")
                    XCTAssertTrue(packaged.contains(worktreeSentinel), packaged)
                    XCTAssertFalse(packaged.contains(canonicalSentinel), packaged)
                    XCTAssertFalse(packaged.contains(worktreeRoot.path), packaged)
                    XCTAssertFalse(capture.fileTree.contains(worktreeRoot.path), capture.fileTree)

                    fixture.contextA.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    await gate.release()
                    fixture.contextA.window.mcpServer.setReadFileAutoSelectionCanonicalApplyGateForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOraclePackagesMultipleBoundRootsWithoutCanonicalLeak() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleWorktreeCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let gitFixture = try ReviewGitRepositoryFixture(name: "OracleMultiRoot")
                    let logicalRootA = try gitFixture.makeRepository(
                        named: "logical-a",
                        files: ["Sources/First.swift": "let value = \"initial_a\"\n"]
                    )
                    let logicalRootB = try gitFixture.makeRepository(
                        named: "logical-b",
                        files: ["Sources/Second.swift": "let value = \"initial_b\"\n"]
                    )
                    let logicalFileA = logicalRootA.appendingPathComponent("Sources/First.swift")
                    let logicalFileB = logicalRootB.appendingPathComponent("Sources/Second.swift")
                    let worktreeRootA = try gitFixture.makeLinkedWorktree(
                        from: logicalRootA,
                        named: "worktree-a",
                        branch: "feature/oracle-a"
                    )
                    let worktreeRootB = try gitFixture.makeLinkedWorktree(
                        from: logicalRootB,
                        named: "worktree-b",
                        branch: "feature/oracle-b"
                    )
                    let worktreeFileA = worktreeRootA.appendingPathComponent("Sources/First.swift")
                    let worktreeFileB = worktreeRootB.appendingPathComponent("Sources/Second.swift")

                    try write("let value = \"canonical_oracle_a\"\n", to: logicalFileA)
                    try write("let value = \"canonical_oracle_b\"\n", to: logicalFileB)
                    try write("let value = \"worktree_oracle_a\"\n", to: worktreeFileA)
                    try write("let value = \"worktree_oracle_b\"\n", to: worktreeFileB)
                    _ = try await fixture.contextA.window.workspaceFileContextStore.loadRoot(path: logicalRootA.path)
                    _ = try await fixture.contextA.window.workspaceFileContextStore.loadRoot(path: logicalRootB.path)

                    let bindings = [
                        makeBinding(logicalRoot: logicalRootA, worktreeRoot: worktreeRootA, suffix: "multi-a"),
                        makeBinding(logicalRoot: logicalRootB, worktreeRoot: worktreeRootB, suffix: "multi-b")
                    ]
                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(
                            selectedPaths: [logicalFileA.path, logicalFileB.path],
                            codemapAutoEnabled: false
                        ),
                        bindings: bindings
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)
                    installOracleCapture(capture, on: fixture.contextA.window, gitInclusion: .selected)

                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: ["message": "Compare both selected roots.", "mode": "review"],
                        timeoutSeconds: 30
                    )
                    XCTAssertTrue(try toolResultText(response).contains("captured oracle response"))

                    let packaged = capture.fileBlocks.joined(separator: "\n")
                    XCTAssertTrue(packaged.contains("worktree_oracle_a"), packaged)
                    XCTAssertTrue(packaged.contains("worktree_oracle_b"), packaged)
                    XCTAssertFalse(packaged.contains("canonical_oracle_a"), packaged)
                    XCTAssertFalse(packaged.contains("canonical_oracle_b"), packaged)
                    XCTAssertFalse(packaged.contains(worktreeRootA.path), packaged)
                    XCTAssertFalse(packaged.contains(worktreeRootB.path), packaged)
                    XCTAssertEqual(capture.tabContext?.packaging.lookupContext?.bindingProjection?.boundRootsForMetadata.count, 2)
                    let gitDiff = try XCTUnwrap(capture.gitDiff)
                    XCTAssertTrue(gitDiff.contains("worktree_oracle_a"), gitDiff)
                    XCTAssertTrue(gitDiff.contains("worktree_oracle_b"), gitDiff)
                    XCTAssertFalse(gitDiff.contains("canonical_oracle_a"), gitDiff)
                    XCTAssertFalse(gitDiff.contains("canonical_oracle_b"), gitDiff)
                    XCTAssertFalse(gitDiff.contains(worktreeRootA.path), gitDiff)
                    XCTAssertFalse(gitDiff.contains(worktreeRootB.path), gitDiff)

                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testGitDiffArtifactsReturnWhenExplicitLinkedWorktreeAdvertisementIsUnauthorized() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let gitFixture = try ReviewGitRepositoryFixture(name: "ExplicitLinkedArtifactNoBinding")
                defer { gitFixture.cleanup() }
                do {
                    try await activateWorkspace(fixture.contextA)
                    let logicalRoot = try gitFixture.makeRepository(
                        named: "logical",
                        files: ["Sources/Feature.swift": "let value = \"initial\"\n"]
                    )
                    let worktreeRoot = try gitFixture.makeLinkedWorktree(
                        from: logicalRoot,
                        named: "worktree",
                        branch: "feature/explicit-artifact"
                    )
                    let logicalFile = logicalRoot.appendingPathComponent("Sources/Feature.swift")
                    let worktreeFile = worktreeRoot.appendingPathComponent("Sources/Feature.swift")
                    try write("let value = \"canonical_artifact_leak\"\n", to: logicalFile)
                    try write("let value = \"explicit_worktree_artifact_source\"\n", to: worktreeFile)
                    _ = try await fixture.contextA.window.workspaceFileContextStore.loadRoot(
                        path: logicalRoot.path,
                        kind: .primaryWorkspace
                    )

                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(),
                        bindings: []
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)

                    let gitResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.git,
                        arguments: [
                            "op": "diff",
                            "repo_root": worktreeRoot.path,
                            "scope": "all",
                            "artifacts": true,
                            "mode": "standard",
                            "inline": ["map": false]
                        ],
                        timeoutSeconds: 30
                    )

                    XCTAssertFalse(gitResponse.rawJSON.contains("\"isError\":true"), gitResponse.rawJSON)
                    let gitText = try toolResultText(gitResponse)
                    XCTAssertTrue(gitText.contains("MAP.txt"), gitText)
                    XCTAssertTrue(gitText.contains("all.patch"), gitText)
                    let patchAlias = try XCTUnwrap(
                        gitText.split(separator: "`").map(String.init).first { candidate in
                            candidate.hasPrefix("_git_data/") && candidate.hasSuffix("/diff/all.patch")
                        },
                        gitText
                    )
                    let workspaceDirectory = try fixture.contextA.window.workspaceManager.workspaceDirectory(
                        for: XCTUnwrap(fixture.contextA.window.workspaceManager.activeWorkspace)
                    )
                    let patchPath = workspaceDirectory
                        .appendingPathComponent("_git_data", isDirectory: true)
                        .appendingPathComponent(String(patchAlias.dropFirst("_git_data/".count)))
                        .path
                    let patchText = try String(contentsOfFile: patchPath, encoding: .utf8)
                    XCTAssertTrue(patchText.contains("explicit_worktree_artifact_source"), patchText)
                    XCTAssertFalse(patchText.contains("canonical_artifact_leak"), patchText)

                    let rejectedAliasSelection = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "add",
                            "paths": [patchAlias],
                            "strict": true
                        ],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(
                        rejectedAliasSelection.rawJSON.contains("\"isError\":true"),
                        rejectedAliasSelection.rawJSON
                    )

                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testGitDiffSelectedArtifactsAutoSelectPatchForBoundLinkedWorktreeWithoutSessionRootCatalog() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let gitFixture = try ReviewGitRepositoryFixture(name: "OracleSelectedArtifactNoCatalog")
                defer { gitFixture.cleanup() }
                do {
                    try await activateWorkspace(fixture.contextA)
                    let logicalRoot = try gitFixture.makeRepository(
                        named: "logical",
                        files: ["Sources/Feature.swift": "let value = \"initial\"\n"]
                    )
                    let worktreeRoot = try gitFixture.makeLinkedWorktree(
                        from: logicalRoot,
                        named: "worktree",
                        branch: "feature/artifact-no-catalog"
                    )
                    let logicalFile = logicalRoot.appendingPathComponent("Sources/Feature.swift")
                    let worktreeFile = worktreeRoot.appendingPathComponent("Sources/Feature.swift")
                    try write("let value = \"canonical_artifact_leak\"\n", to: logicalFile)
                    try write("let value = \"linked_artifact_source\"\n", to: worktreeFile)
                    _ = try await fixture.contextA.window.workspaceFileContextStore.loadRoot(
                        path: logicalRoot.path,
                        kind: .primaryWorkspace
                    )
                    let layout = try XCTUnwrap(
                        GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: worktreeRoot)
                    )
                    let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
                        commonGitDir: layout.commonDir,
                        mainWorktreeRoot: layout.knownMainWorktreeRoot
                    )
                    let worktreeID = GitWorktreeIdentity.worktreeID(
                        repositoryID: repositoryIdentity.repositoryID,
                        gitDir: layout.gitDir,
                        isMain: false,
                        path: layout.workTreeRoot
                    )
                    let binding = AgentSessionWorktreeBinding(
                        id: "binding-artifact-no-catalog",
                        repositoryID: repositoryIdentity.repositoryID,
                        repoKey: GitRepoDescriptor(rootURL: logicalRoot).repoKey,
                        logicalRootPath: logicalRoot.path,
                        logicalRootName: "ArtifactNoCatalogRepo",
                        worktreeID: worktreeID,
                        worktreeRootPath: worktreeRoot.path,
                        worktreeName: "worktree",
                        branch: "feature/artifact-no-catalog",
                        source: "test"
                    )

                    let sourceSelection = StoredSelection(
                        selectedPaths: [logicalFile.path],
                        codemapAutoEnabled: false
                    )
                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: sourceSelection,
                        bindings: [binding]
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)

                    let gitResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.git,
                        arguments: [
                            "op": "diff",
                            "repo_root": logicalRoot.path,
                            "scope": "selected",
                            "detail": "patches",
                            "artifacts": true,
                            "mode": "deep"
                        ],
                        timeoutSeconds: 30
                    )
                    XCTAssertFalse(gitResponse.rawJSON.contains("\"isError\":true"), gitResponse.rawJSON)
                    let gitText = try toolResultText(gitResponse)
                    let publishedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    ).selection
                    XCTAssertTrue(publishedSelection.selectedPaths.contains(logicalFile.path))
                    _ = try requireSelectedPath(
                        suffix: "/MAP.txt",
                        in: publishedSelection,
                        context: "selected linked-worktree artifact publication without session root catalog",
                        toolOutput: gitText
                    )
                    let patchPath = try requireSelectedPath(
                        suffix: "/diff/all.patch",
                        in: publishedSelection,
                        context: "selected linked-worktree artifact publication without session root catalog",
                        toolOutput: gitText
                    )
                    let patchText = try String(contentsOfFile: patchPath, encoding: .utf8)
                    XCTAssertTrue(patchText.contains("linked_artifact_source"), patchText)
                    XCTAssertFalse(patchText.contains("canonical_artifact_leak"), patchText)

                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        /// D2 wire evidence: a native-shell Agent Mode lease hides and denies `git`, while
        /// `git_review_snapshot` stays advertised, rejects arguments outside its fixed surface, and
        /// publishes selected artifacts through the shared auto-selection path.
        func testNativeShellLeaseHidesGitWhileReviewSnapshotPublishesAndAutoSelectsArtifacts() async throws {
            try await assertNativeShellReviewSnapshotScenario(structuredResults: .off)
        }

        /// D1 + D2: with `mcp.structured_results` on, only the snapshot (never `git`) advertises an
        /// `outputSchema`; a success carries `structuredContent` beside the formatted text and an
        /// argument rejection stays an `isError` text result without it.
        func testStructuredResultsAdvertiseAndDeliverTheReviewSnapshotShapeOnly() async throws {
            try await assertNativeShellReviewSnapshotScenario(structuredResults: .on)
        }

        /// D2 wire evidence for surfaces that never gain the snapshot, each installed from its
        /// production lease builder. Context Builder discovery restricts it, so `tools/list` hides it
        /// and `tools/call` is denied. The explore role hides it by advertisement only, the existing
        /// role contract for every role-hidden tool, so a call by name still reaches the tool's own
        /// argument check. Knowledge's closed allowlist lists and admits neither Git tool.
        func testDiscoveryExploreAndKnowledgeLeasesKeepTheReviewSnapshotOffTheirSurfaces() async throws {
            enum Surface: CaseIterable { case discovery, explore, knowledge }
            for surface in Surface.allCases {
                try await MCPSharedServerTestLease.shared.withLease { lease in
                    let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                    do {
                        try await activateWorkspace(fixture.contextA)
                        let context = makeFrozenContext(
                            fixture: fixture,
                            selection: StoredSelection(selectedPaths: [], codemapAutoEnabled: false),
                            bindings: []
                        )
                        let endpoint = try fixture.endpointA()
                        switch surface {
                        case .discovery:
                            try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture) { runID in
                                MCPBootstrapLeaseSpec.headless(
                                    runID: runID,
                                    gateID: runID,
                                    clientName: endpoint.clientName,
                                    windowID: context.windowID,
                                    restrictedTools: DiscoverMCPToolPolicy.restrictedTools,
                                    reason: "discover-run",
                                    ttl: 10,
                                    tabID: context.tabID,
                                    purpose: .discoverRun
                                )
                            }
                        case .explore:
                            try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture) { runID in
                                MCPBootstrapLeaseSpec.agentMode(
                                    tabID: context.tabID,
                                    runID: runID,
                                    gateID: UUID(),
                                    windowID: context.windowID,
                                    agent: .codexExec,
                                    taskLabelKind: .explore
                                )
                            }
                        case .knowledge:
                            try await configureAgentModeEndpoint(
                                endpoint,
                                context: context,
                                fixture: fixture,
                                sessionProfile: .knowledge
                            )
                        }

                        let label = "\(surface)"
                        let advertised = try await Set(endpoint.listToolNames())
                        XCTAssertFalse(advertised.contains(MCPWindowToolName.gitReviewSnapshot), "\(label): \(advertised.sorted())")
                        XCTAssertEqual(
                            advertised.contains(MCPWindowToolName.git),
                            surface != .knowledge,
                            "\(label): \(advertised.sorted())"
                        )

                        let call = try await endpoint.callTool(
                            name: MCPWindowToolName.gitReviewSnapshot,
                            arguments: ["op": "diff"]
                        )
                        switch surface {
                        case .discovery:
                            XCTAssertTrue(
                                call.rawJSON.contains("Tool 'git_review_snapshot' is disabled for this connection."),
                                "\(label): \(call.rawJSON)"
                            )
                        case .explore:
                            XCTAssertTrue(
                                call.rawJSON.contains("git_review_snapshot does not accept: op."),
                                "\(label): \(call.rawJSON)"
                            )
                            XCTAssertFalse(call.rawJSON.contains("disabled for this connection"), "\(label): \(call.rawJSON)")
                        case .knowledge:
                            let denial = try XCTUnwrap(
                                ServerNetworkManager.positiveToolCeilingDenialMessage(
                                    forCanonicalToolName: MCPWindowToolName.gitReviewSnapshot,
                                    allowedToolsOverride: AgentModeMCPToolPolicy.knowledgeAllowedTools
                                )
                            )
                            XCTAssertTrue(call.rawJSON.contains(denial), "\(label): \(call.rawJSON)")
                        }
                        XCTAssertTrue(call.rawJSON.contains("\"isError\":true"), "\(label): \(call.rawJSON)")

                        await fixture.cleanup()
                    } catch {
                        await fixture.cleanup()
                        throw error
                    }
                }
            }
        }

        private func assertNativeShellReviewSnapshotScenario(
            structuredResults: MCPStructuredResultsMode
        ) async throws {
            let settings = GlobalSettingsStore.shared
            let previousStructuredResults = settings.mcpStructuredResultsMode()
            // The mode is read when the connection registers its handlers, so set it first.
            settings.setMCPStructuredResultsMode(structuredResults, commit: false)
            defer { settings.setMCPStructuredResultsMode(previousStructuredResults, commit: false) }
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let gitFixture = try ReviewGitRepositoryFixture(name: "ReviewSnapshotNativeShell")
                defer { gitFixture.cleanup() }
                do {
                    try await activateWorkspace(fixture.contextA)
                    let root = try gitFixture.makeRepository(
                        named: "logical",
                        files: [
                            "Sources/Feature.swift": "let value = \"initial\"\n",
                            "Sources/Other.swift": "let other = \"initial\"\n"
                        ]
                    )
                    let file = root.appendingPathComponent("Sources/Feature.swift")
                    let otherFile = root.appendingPathComponent("Sources/Other.swift")
                    try write("let value = \"review_snapshot_source\"\n", to: file)
                    try write("let other = \"excluded_by_path_filter\"\n", to: otherFile)
                    _ = try await fixture.contextA.window.workspaceFileContextStore.loadRoot(
                        path: root.path,
                        kind: .primaryWorkspace
                    )
                    // Both changed files are selected; the snapshot's `paths` filter keeps only `file`.
                    let sourceSelection = StoredSelection(
                        selectedPaths: [file.path, otherFile.path],
                        codemapAutoEnabled: false
                    )
                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: sourceSelection,
                        bindings: []
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture) { runID in
                        // The production lease builder supplies the restrictions a native-shell run installs.
                        MCPBootstrapLeaseSpec.agentMode(
                            tabID: context.tabID,
                            runID: runID,
                            gateID: UUID(),
                            windowID: context.windowID,
                            agent: .codexExec,
                            runHasNativeShell: true
                        )
                    }

                    let structured = structuredResults == .on
                    let toolsList = try await endpoint.client.request(
                        method: "tools/list",
                        params: [:],
                        timeoutSeconds: 10
                    )
                    let listedTools = try XCTUnwrap(Self.resultObject(toolsList)["tools"] as? [[String: Any]])
                    let snapshotListing = try XCTUnwrap(
                        listedTools.first { $0["name"] as? String == MCPWindowToolName.gitReviewSnapshot }
                    )
                    if structured {
                        let outputSchema = try XCTUnwrap(snapshotListing["outputSchema"] as? [String: Any])
                        XCTAssertEqual(outputSchema["type"] as? String, "object")
                        let properties = try XCTUnwrap(outputSchema["properties"] as? [String: Any])
                        XCTAssertNotNil(properties["primary_artifacts"])
                    } else {
                        XCTAssertNil(snapshotListing["outputSchema"])
                    }

                    let advertised = try await Set(endpoint.listToolNames())
                    XCTAssertFalse(advertised.contains(MCPWindowToolName.git), "\(advertised.sorted())")
                    XCTAssertTrue(advertised.contains(MCPWindowToolName.gitReviewSnapshot), "\(advertised.sorted())")
                    XCTAssertTrue(advertised.contains(MCPWindowToolName.readFile), "\(advertised.sorted())")

                    let gitResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.git,
                        arguments: ["op": "status"]
                    )
                    XCTAssertTrue(
                        gitResponse.rawJSON.contains("Tool 'git' is disabled for this connection."),
                        gitResponse.rawJSON
                    )

                    let rejected = try await endpoint.callTool(
                        name: MCPWindowToolName.gitReviewSnapshot,
                        arguments: ["op": "status", "detail": "patches", "scope": "selected"]
                    )
                    XCTAssertTrue(
                        rejected.rawJSON.contains("git_review_snapshot does not accept: detail, op."),
                        rejected.rawJSON
                    )
                    let rejectedResult = try Self.resultObject(rejected)
                    XCTAssertEqual(rejectedResult["isError"] as? Bool, true)
                    XCTAssertNil(rejectedResult["structuredContent"], rejected.rawJSON)
                    let untouchedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    ).selection
                    XCTAssertEqual(Set(untouchedSelection.selectedPaths), [file.path, otherFile.path])

                    let snapshotResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.gitReviewSnapshot,
                        arguments: [
                            "repo_root": root.path,
                            "scope": "selected",
                            "paths": [file.path],
                            "mode": "deep"
                        ],
                        timeoutSeconds: 30
                    )
                    XCTAssertFalse(snapshotResponse.rawJSON.contains("\"isError\":true"), snapshotResponse.rawJSON)
                    let snapshotText = try toolResultText(snapshotResponse)
                    // The text is formatted from the reply DTO (op=diff with artifacts), not the
                    // caller's arguments, so it names the published snapshot and its MAP.
                    XCTAssertTrue(snapshotText.contains("_git_data/"), snapshotText)
                    XCTAssertTrue(snapshotText.contains("MAP.txt"), snapshotText)
                    let snapshotResult = try Self.resultObject(snapshotResponse)
                    if structured {
                        let structuredContent = try XCTUnwrap(snapshotResult["structuredContent"] as? [String: Any])
                        XCTAssertEqual(structuredContent["op"] as? String, "diff")
                        XCTAssertNotNil(structuredContent["primary_artifacts"] as? [String: Any], snapshotResponse.rawJSON)
                        XCTAssertNil(structuredContent[AgentDelegatedQuestionNoticeWire.resultKey])
                        XCTAssertFalse(snapshotText.hasPrefix("{"), "Text stays formatted, not JSON")
                        // The live payload stays inside the advertised top-level shape.
                        let schema = try XCTUnwrap(MCPToolOutputSchemas.gitReviewSnapshot.objectValue)
                        let declared = try Set(XCTUnwrap(schema["properties"]?.objectValue).keys)
                        let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
                        XCTAssertTrue(Set(structuredContent.keys).isSubset(of: declared), "\(structuredContent.keys.sorted())")
                        XCTAssertTrue(required.isSubset(of: Set(structuredContent.keys)), "\(structuredContent.keys.sorted())")
                    } else {
                        XCTAssertNil(snapshotResult["structuredContent"], snapshotResponse.rawJSON)
                    }
                    let publishedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    ).selection
                    XCTAssertTrue(publishedSelection.selectedPaths.contains(file.path))
                    _ = try requireSelectedPath(
                        suffix: "/MAP.txt",
                        in: publishedSelection,
                        context: "git_review_snapshot selected artifact publication",
                        toolOutput: snapshotText
                    )
                    let patchPath = try requireSelectedPath(
                        suffix: "/diff/all.patch",
                        in: publishedSelection,
                        context: "git_review_snapshot selected artifact publication",
                        toolOutput: snapshotText
                    )
                    let patchText = try String(contentsOfFile: patchPath, encoding: .utf8)
                    XCTAssertTrue(patchText.contains("review_snapshot_source"), patchText)
                    XCTAssertFalse(patchText.contains("excluded_by_path_filter"), patchText)

                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleReviewUsesAuthorizedSelectedArtifactAndKeepsMapAsContext() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleWorktreeCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let gitFixture = try ReviewGitRepositoryFixture(name: "OracleSelectedArtifact")
                    let logicalRoot = try gitFixture.makeRepository(
                        named: "logical",
                        files: ["Sources/Feature.swift": "let value = \"initial\"\n"]
                    )
                    let worktreeRoot = try gitFixture.makeLinkedWorktree(
                        from: logicalRoot,
                        named: "worktree",
                        branch: "feature/artifact"
                    )
                    let logicalFile = logicalRoot.appendingPathComponent("Sources/Feature.swift")
                    let worktreeFile = worktreeRoot.appendingPathComponent("Sources/Feature.swift")
                    try write("let value = \"canonical_artifact_leak\"\n", to: logicalFile)
                    try write("let value = \"worktree_artifact_source\"\n", to: worktreeFile)
                    _ = try await fixture.contextA.window.workspaceFileContextStore.loadRoot(path: logicalRoot.path)

                    let layout = try XCTUnwrap(
                        GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: worktreeRoot)
                    )
                    let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
                        commonGitDir: layout.commonDir,
                        mainWorktreeRoot: layout.knownMainWorktreeRoot
                    )
                    let worktreeID = GitWorktreeIdentity.worktreeID(
                        repositoryID: repositoryIdentity.repositoryID,
                        gitDir: layout.gitDir,
                        isMain: false,
                        path: layout.workTreeRoot
                    )
                    let binding = AgentSessionWorktreeBinding(
                        id: "binding-artifact",
                        repositoryID: repositoryIdentity.repositoryID,
                        repoKey: "artifact-repo",
                        logicalRootPath: logicalRoot.path,
                        logicalRootName: "ArtifactRepo",
                        worktreeID: worktreeID,
                        worktreeRootPath: worktreeRoot.path,
                        worktreeName: "artifact",
                        branch: "feature/artifact",
                        source: "test"
                    )

                    let sourceSelection = StoredSelection(
                        selectedPaths: [logicalFile.path],
                        codemapAutoEnabled: false
                    )
                    var composeTab = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    )
                    composeTab.selection = sourceSelection
                    fixture.contextA.window.workspaceManager.updateComposeTab(composeTab, markDirty: false)

                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: sourceSelection,
                        bindings: [binding]
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)

                    let gitResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.git,
                        arguments: [
                            "op": "diff",
                            "repo_root": logicalRoot.path,
                            "scope": "selected",
                            "detail": "patches",
                            "artifacts": true,
                            "mode": "deep"
                        ],
                        timeoutSeconds: 30
                    )
                    let gitText = try toolResultText(gitResponse)
                    XCTAssertTrue(gitText.contains("auto-selected"), gitText)

                    let publishedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    ).selection
                    let mapPath = try requireSelectedPath(
                        suffix: "/MAP.txt",
                        in: publishedSelection,
                        context: "selected-artifact publication",
                        toolOutput: gitText
                    )
                    let patchPath = try requireSelectedPath(
                        suffix: "/diff/all.patch",
                        in: publishedSelection,
                        context: "selected-artifact publication",
                        toolOutput: gitText
                    )
                    XCTAssertTrue(publishedSelection.selectedPaths.contains(logicalFile.path))
                    let patchText = try String(contentsOfFile: patchPath, encoding: .utf8)
                    let patchAlias = try XCTUnwrap(
                        patchPath.range(of: "/_git_data/").map {
                            "_git_data/" + patchPath[$0.upperBound...]
                        }
                    )
                    let mapAlias = try XCTUnwrap(
                        mapPath.range(of: "/_git_data/").map {
                            "_git_data/" + mapPath[$0.upperBound...]
                        }
                    )
                    let previewResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "preview",
                            "paths": [mapAlias, patchAlias],
                            "strict": true,
                            "view": "files"
                        ],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(previewResponse.rawJSON.contains("MAP.txt"))
                    XCTAssertTrue(previewResponse.rawJSON.contains("all.patch"))

                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "remove",
                            "paths": [mapAlias, patchAlias],
                            "strict": true,
                            "view": "files"
                        ],
                        timeoutSeconds: 20
                    )
                    let removedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(
                            with: fixture.contextA.tabID
                        )
                    ).selection
                    XCTAssertEqual(removedSelection.selectedPaths, [logicalFile.path])

                    let readdedResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "set",
                            "paths": [logicalFile.path, mapAlias, patchAlias],
                            "strict": true,
                            "view": "files"
                        ],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(readdedResponse.rawJSON.contains("MAP.txt"))
                    XCTAssertTrue(readdedResponse.rawJSON.contains("all.patch"))
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "add",
                            "paths": [patchAlias],
                            "strict": true
                        ],
                        timeoutSeconds: 20
                    )
                    let readdedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(
                            with: fixture.contextA.tabID
                        )
                    ).selection
                    XCTAssertEqual(
                        readdedSelection.selectedPaths.count { $0 == patchPath },
                        1
                    )
                    XCTAssertTrue(readdedSelection.selectedPaths.contains(logicalFile.path))
                    let manifestPath = String(
                        patchPath.dropLast("diff/all.patch".count)
                    ) + "manifest.json"
                    let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let manifest = try decoder.decode(
                        GitDiffSnapshotManifest.self,
                        from: manifestData
                    )
                    let perFileRelativePath = try XCTUnwrap(
                        manifest.files.compactMap(\.patchPath).first
                    )
                    let perFileAlias = String(
                        patchAlias.dropLast("diff/all.patch".count)
                    ) + perFileRelativePath
                    let perFileAbsolutePath = String(
                        patchPath.dropLast("diff/all.patch".count)
                    ) + perFileRelativePath
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "add",
                            "paths": [perFileAlias],
                            "strict": true
                        ],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(
                        try XCTUnwrap(
                            fixture.contextA.window.workspaceManager.composeTab(
                                with: fixture.contextA.tabID
                            )
                        ).selection.selectedPaths.contains(perFileAbsolutePath)
                    )
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "remove",
                            "paths": [perFileAlias],
                            "strict": true
                        ],
                        timeoutSeconds: 20
                    )
                    let lookupContext = try await AgentWorkspaceLookupContextResolver
                        .requiredLookupContext(
                            source: AgentWorkspaceLookupContextSource(
                                activeAgentSessionID: context.activeAgentSessionID,
                                worktreeBindings: [binding]
                            ),
                            store: fixture.contextA.window.workspaceFileContextStore
                        )
                    let reviewGitContext = await fixture.contextA.window.promptManager
                        .freezePromptGitReviewContext(
                            workspaceID: context.workspaceID,
                            tabID: context.tabID,
                            sessionID: context.activeAgentSessionID,
                            bindings: [binding],
                            base: "HEAD"
                        )
                    var replyContext = context
                    replyContext.selection = publishedSelection
                    let selectionReply = await fixture.contextA.window.mcpServer
                        .buildTabSelectionReply(
                            from: publishedSelection,
                            includeBlocks: true,
                            display: .full,
                            virtualContext: replyContext,
                            lookupContextOverride: lookupContext,
                            reviewGitContextOverride: reviewGitContext
                        )
                    XCTAssertTrue(selectionReply.files?.contains { $0.path == mapAlias } == true)
                    XCTAssertTrue(selectionReply.files?.contains { $0.path == patchAlias } == true)
                    XCTAssertNil(selectionReply.invalidPaths)
                    XCTAssertEqual(
                        selectionReply.blocks?.count(where: { $0.contains(mapAlias) }),
                        1
                    )
                    XCTAssertFalse(
                        selectionReply.blocks?.contains {
                            $0.contains("<path>\(patchAlias)</path>")
                        } ?? true
                    )

                    let readResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: ["path": patchAlias],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(try toolResultText(readResponse).contains("worktree_artifact_source"))

                    let manifestAlias = String(
                        patchAlias.dropLast("diff/all.patch".count)
                    ) + "manifest.json"
                    let rejectedMutation = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "add",
                            "paths": [manifestAlias],
                            "strict": true
                        ],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(rejectedMutation.rawJSON.contains("\"isError\":true"))
                    let rejectedRead = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: ["path": manifestAlias],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(rejectedRead.rawJSON.contains("\"isError\":true"))
                    XCTAssertTrue(
                        rejectedRead.rawJSON.contains("Cannot read")
                            || rejectedRead.rawJSON.contains("File not found"),
                        rejectedRead.rawJSON
                    )
                    let searchResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.search,
                        arguments: ["pattern": "all.patch", "mode": "path", "regex": false],
                        timeoutSeconds: 20
                    )
                    XCTAssertFalse(try toolResultText(searchResponse).contains(patchAlias))
                    let treeResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.getFileTree,
                        arguments: ["mode": "full"],
                        timeoutSeconds: 20
                    )
                    XCTAssertFalse(try toolResultText(treeResponse).contains("_git_data"))

                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting { _ in
                            AutomaticReviewGitDiffResult(
                                text: "AUTOMATIC_FALLBACK_INVOKED",
                                completeness: .complete,
                                outcomes: [],
                                pathIssues: []
                            )
                        }
                    installOracleCapture(capture, on: fixture.contextA.window, gitInclusion: .selected)

                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: ["message": "Review the selected artifact.", "mode": "review"],
                        timeoutSeconds: 30
                    )
                    XCTAssertTrue(try toolResultText(response).contains("captured oracle response"))
                    XCTAssertEqual(capture.gitDiff, patchText)
                    XCTAssertNotEqual(capture.gitDiff, "AUTOMATIC_FALLBACK_INVOKED")
                    let packaged = capture.fileBlocks.joined(separator: "\n")
                    XCTAssertTrue(packaged.contains("worktree_artifact_source"), packaged)
                    XCTAssertFalse(packaged.contains("canonical_artifact_leak"), packaged)
                    XCTAssertEqual(
                        capture.fileBlocks.count(where: { $0.contains(mapAlias) }),
                        1,
                        packaged
                    )
                    XCTAssertFalse(capture.fileBlocks.contains { $0.contains(patchAlias) }, packaged)

                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleReviewUsesPublishedCanonicalArtifactWithoutAutomaticFallback() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleWorktreeCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let repository = fixture.contextA.rootURL
                    let sourceFile = fixture.contextA.fileURL
                    let gitFixture = try ReviewGitRepositoryFixture(name: "OracleCanonicalArtifact")
                    defer { gitFixture.cleanup() }
                    _ = try gitFixture.runGit(["init"], at: repository)
                    _ = try gitFixture.runGit(["config", "user.name", "RepoPrompt Test"], at: repository)
                    _ = try gitFixture.runGit(["config", "user.email", "repoprompt@example.test"], at: repository)
                    _ = try gitFixture.runGit(["config", "commit.gpgSign", "false"], at: repository)
                    _ = try gitFixture.runGit(["add", "."], at: repository)
                    _ = try gitFixture.runGit(["commit", "-m", "Initial commit"], at: repository)
                    try write("let canonicalPublishedArtifact = true\n", to: sourceFile)

                    let sourceSelection = StoredSelection(
                        selectedPaths: [sourceFile.path],
                        codemapAutoEnabled: false
                    )
                    var composeTab = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    )
                    composeTab.selection = sourceSelection
                    fixture.contextA.window.workspaceManager.updateComposeTab(composeTab, markDirty: false)

                    let context = MCPServerViewModel.TabContextSnapshot(
                        tabID: fixture.contextA.tabID,
                        windowID: fixture.contextA.window.windowID,
                        workspaceID: fixture.contextA.workspaceID,
                        promptText: "Review canonical publication",
                        selection: sourceSelection,
                        selectedMetaPromptIDs: [],
                        tabName: "Canonical Oracle",
                        runID: UUID(),
                        activeAgentSessionID: nil,
                        worktreeBindingState: .notApplicable,
                        explicitlyBound: false
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)

                    let gitResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.git,
                        arguments: [
                            "op": "diff",
                            "repo_root": repository.path,
                            "scope": "selected",
                            "detail": "patches",
                            "artifacts": true,
                            "mode": "deep"
                        ],
                        timeoutSeconds: 30
                    )
                    let gitText = try toolResultText(gitResponse)

                    let publishedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    ).selection
                    let mapPath = try requireSelectedPath(
                        suffix: "/MAP.txt",
                        in: publishedSelection,
                        context: "canonical-artifact publication",
                        toolOutput: gitText
                    )
                    let patchPath = try requireSelectedPath(
                        suffix: "/diff/all.patch",
                        in: publishedSelection,
                        context: "canonical-artifact publication",
                        toolOutput: gitText
                    )
                    XCTAssertTrue(publishedSelection.selectedPaths.contains(sourceFile.path))
                    let patchText = try String(contentsOfFile: patchPath, encoding: .utf8)
                    let mapAlias = try XCTUnwrap(
                        mapPath.range(of: "/_git_data/").map {
                            "_git_data/" + mapPath[$0.upperBound...]
                        }
                    )
                    let patchAlias = try XCTUnwrap(
                        patchPath.range(of: "/_git_data/").map {
                            "_git_data/" + patchPath[$0.upperBound...]
                        }
                    )

                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "remove",
                            "paths": [mapAlias, patchAlias],
                            "strict": true
                        ],
                        timeoutSeconds: 20
                    )
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "add",
                            "paths": [mapAlias, patchAlias],
                            "strict": true
                        ],
                        timeoutSeconds: 20
                    )
                    let roundTrippedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(
                            with: fixture.contextA.tabID
                        )
                    ).selection
                    XCTAssertTrue(roundTrippedSelection.selectedPaths.contains(sourceFile.path))
                    XCTAssertEqual(roundTrippedSelection.selectedPaths.count { $0 == mapPath }, 1)
                    XCTAssertEqual(roundTrippedSelection.selectedPaths.count { $0 == patchPath }, 1)

                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting { _ in
                            AutomaticReviewGitDiffResult(
                                text: "AUTOMATIC_FALLBACK_INVOKED",
                                completeness: .complete,
                                outcomes: [],
                                pathIssues: []
                            )
                        }
                    installOracleCapture(capture, on: fixture.contextA.window, gitInclusion: .selected)

                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: ["message": "Review canonical artifacts.", "mode": "review"],
                        timeoutSeconds: 30
                    )
                    XCTAssertEqual(capture.gitDiff, patchText)
                    XCTAssertNotEqual(capture.gitDiff, "AUTOMATIC_FALLBACK_INVOKED")
                    XCTAssertTrue(capture.fileBlocks.joined().contains("canonicalPublishedArtifact"))
                    XCTAssertEqual(
                        capture.fileBlocks.count(where: { $0.contains(mapAlias) }),
                        1
                    )
                    XCTAssertFalse(
                        capture.fileBlocks.contains { $0.contains("<path>\(patchAlias)</path>") }
                    )

                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testOracleReviewTransportUsesPublishedCanonicalPatchForFreshAndContinuingChat() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(repositoryKind: .canonical)
        }

        func testOracleReviewTransportUsesPublishedLinkedWorktreePatchForFreshAndContinuingChat() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(repositoryKind: .linkedWorktree)
        }

        func testAgentRunCanonicalFreshAndContinuingOracleInheritsLaunchArtifact() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(
                repositoryKind: .canonical,
                delegateToChildRun: true
            )
        }

        func testAgentRunCanonicalSourceDelegatesArtifactToFreshAppManagedWorktreeChild() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(
                repositoryKind: .canonical,
                delegateToChildRun: true,
                childCreateWorktree: true
            )
        }

        func testAgentRunLinkedWorktreeFreshAndContinuingOracleInheritsLaunchArtifact() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(
                repositoryKind: .linkedWorktree,
                delegateToChildRun: true
            )
        }

        func testAgentRunLinkedWorktreeSourceDelegatesArtifactToExplicitlyUnboundChild() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(
                repositoryKind: .linkedWorktree,
                delegateToChildRun: true,
                childInheritWorktreeBindings: false
            )
        }

        func testVisibleLinkedWorktreeOracleUsesPublishedPatchForFreshAndContinuingChat() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(
                repositoryKind: .visibleLinkedWorktree
            )
        }

        func testAgentRunVisibleLinkedWorktreeFreshAndContinuingOracleInheritsLaunchArtifact() async throws {
            try await assertOracleReviewTransportUsesPublishedPatch(
                repositoryKind: .visibleLinkedWorktree,
                delegateToChildRun: true
            )
        }

        func testAgentRunWindowOnlyNoArtifactUsesAutomaticFallbackAcrossSelectedRepositories() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let gitFixture = try ReviewGitRepositoryFixture(name: "AgentRunAutomaticFallback")
                let capture = OracleWorktreeCapture()
                let automaticProviderCounter = OracleAutomaticProviderCounter()
                let window = fixture.contextA.window
                let apiSettings = try XCTUnwrap(window.promptManager.apiSettingsViewModel)
                let previousClaudeCodeConnected = apiSettings.isClaudeCodeConnected
                defer {
                    window.promptManager.setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    window.mcpServer.setAgentRunDispatchOverrideForTesting(nil)
                    window.mcpServer.setRequestMetadataOverrideForTesting(nil)
                    apiSettings.isClaudeCodeConnected = previousClaudeCodeConnected
                    gitFixture.cleanup()
                }

                do {
                    try await activateWorkspace(fixture.contextA)
                    let secondaryRoot = try gitFixture.makeRepository(
                        named: "secondary",
                        files: ["Sources/Secondary.swift": "let secondary = 1\n"]
                    )
                    let secondaryFile = secondaryRoot.appendingPathComponent("Sources/Secondary.swift")
                    try await window.workspaceManager.addFolder(
                        secondaryRoot,
                        to: XCTUnwrap(window.workspaceManager.activeWorkspace)
                    )
                    let sourceSelection = StoredSelection(
                        selectedPaths: [fixture.contextA.fileURL.path, secondaryFile.path],
                        codemapAutoEnabled: false
                    )
                    _ = await window.selectionCoordinator.persistActiveSelection(
                        sourceSelection,
                        source: .runtimeMutation,
                        mirrorToUI: true
                    )
                    let committedSource = try XCTUnwrap(
                        window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    )
                    XCTAssertTrue(
                        Set(committedSource.selection.selectedPaths).isSuperset(
                            of: sourceSelection.selectedPaths
                        )
                    )
                    XCTAssertFalse(committedSource.selection.selectedPaths.contains {
                        $0.contains("/_git_data/")
                    })

                    let startConnectionID = UUID()
                    window.mcpServer.setRequestMetadataOverrideForTesting(.init(
                        connectionID: startConnectionID,
                        clientName: "public-agent-run-automatic-fallback",
                        windowID: window.windowID,
                        runPurpose: .unknown,
                        explicitWindowRoutingHint: MCPExplicitWindowRoutingHint(
                            connectionID: startConnectionID,
                            toolName: "agent_run",
                            windowID: window.windowID,
                            windowStateIdentity: ObjectIdentifier(window),
                            serverViewModelIdentity: ObjectIdentifier(window.mcpServer),
                            provenance: .hiddenWindowArgument
                        ),
                        actorRoutedRunTab: nil
                    ))
                    XCTAssertEqual(
                        window.mcpServer.connectionBindingSnapshot(forConnection: startConnectionID).bindingKind,
                        .unbound
                    )
                    var targetRunID: UUID?
                    window.mcpServer.setAgentRunDispatchOverrideForTesting {
                        _, tabID, _, _, viewModel in
                        let runID = UUID()
                        targetRunID = runID
                        let session = viewModel.session(for: tabID)
                        session.runID = runID
                        session.runState = .running
                        guard viewModel.mcpBindPendingAgentRunOracleReviewContext(
                            tabID: tabID,
                            runID: runID
                        ) != nil else {
                            throw MCPError.internalError(
                                "Automatic fallback child did not promote its launch carrier."
                            )
                        }
                        return .startedRun
                    }
                    apiSettings.isClaudeCodeConnected = true
                    let startValue = try await window.mcpServer.executeAgentRunForTesting(args: [
                        "op": .string("start"),
                        "message": .string("Start automatic fallback child."),
                        "model_id": .string("claudeCode:sonnet"),
                        "detach": .bool(true),
                        "timeout": .int(0)
                    ])
                    let startObject = try XCTUnwrap(startValue.objectValue)
                    let startSession = try XCTUnwrap(startObject["session"]?.objectValue)
                    let targetSessionID = try XCTUnwrap(
                        startObject["session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                    )
                    let targetTabID = try XCTUnwrap(
                        startSession["context_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                    )
                    let resolvedTargetRunID = try XCTUnwrap(targetRunID)
                    XCTAssertNil(startSession["parent_session_id"])
                    XCTAssertTrue(
                        try XCTUnwrap(window.workspaceManager.composeTab(with: targetTabID))
                            .selection.selectedPaths.isEmpty
                    )

                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: MCPServerViewModel.TabContextSnapshot(
                            tabID: targetTabID,
                            windowID: window.windowID,
                            workspaceID: fixture.contextA.workspaceID,
                            promptText: "Blank child",
                            selection: StoredSelection(codemapAutoEnabled: false),
                            selectedMetaPromptIDs: [],
                            tabName: "Automatic fallback child",
                            runID: resolvedTargetRunID,
                            activeAgentSessionID: targetSessionID,
                            worktreeBindingState: .hydrated([]),
                            explicitlyBound: false
                        ),
                        fixture: fixture
                    )
                    window.promptManager.setAutomaticReviewGitDiffProviderOverrideForTesting { request in
                        await automaticProviderCounter.recordInvocation(request)
                        return AutomaticReviewGitDiffResult(
                            text: "AUTOMATIC_PRIMARY_REPO_MARKER\nAUTOMATIC_SECONDARY_REPO_MARKER",
                            completeness: .complete,
                            outcomes: [],
                            pathIssues: []
                        )
                    }
                    installOracleCapture(capture, on: window, gitInclusion: .selected)

                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: [
                            "message": "Review every selected repository.",
                            "mode": "review"
                        ],
                        timeoutSeconds: 30
                    )
                    XCTAssertTrue(try toolResultText(response).contains("captured oracle response"))
                    let automaticInvocationCount = await automaticProviderCounter.invocationCount()
                    XCTAssertEqual(automaticInvocationCount, 1)
                    let automaticSelectedPaths = await automaticProviderCounter.lastSelectedPaths()
                    XCTAssertEqual(
                        Set(automaticSelectedPaths),
                        Set(sourceSelection.selectedPaths)
                    )
                    XCTAssertTrue(capture.gitDiff?.contains("AUTOMATIC_PRIMARY_REPO_MARKER") == true)
                    XCTAssertTrue(capture.gitDiff?.contains("AUTOMATIC_SECONDARY_REPO_MARKER") == true)
                    XCTAssertFalse(capture.fileBlocks.isEmpty)

                    await window.agentModeViewModel.mcpDeactivateControlContext(
                        sessionID: targetSessionID,
                        cleanupSessionStore: true
                    )
                    XCTAssertFalse(
                        window.agentModeViewModel.mcpHasAgentRunOracleReviewContextExpectation(
                            tabID: targetTabID
                        )
                    )
                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAgentRunOracleReviewSourceCaptureAllowsEquivalentSelectionRevisionDriftButRejectsIdentityChange() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    contextASearchFileCount: 3
                )
                addTeardownBlock {
                    await fixture.cleanup()
                }
                let window = fixture.contextA.window
                defer {
                    window.mcpServer.setRequestMetadataOverrideForTesting(nil)
                }

                do {
                    try await activateWorkspace(fixture.contextA)
                    let sourceTabID = UUID()
                    guard let workspaceIndex = window.workspaceManager.workspaces.firstIndex(where: {
                        $0.id == fixture.contextA.workspaceID
                    }) else {
                        return XCTFail("Expected active fixture workspace")
                    }
                    window.workspaceManager.workspaces[workspaceIndex].composeTabs.append(
                        ComposeTabState(
                            id: sourceTabID,
                            name: "Oracle revision drift source",
                            selection: StoredSelection(),
                            promptText: "Frozen launch source"
                        )
                    )
                    let sourceIdentity = WorkspaceSelectionIdentity(
                        workspaceID: fixture.contextA.workspaceID,
                        tabID: sourceTabID
                    )
                    let searchPaths = Array(fixture.contextA.searchFileURLs.prefix(3).map(\.path))
                    XCTAssertEqual(searchPaths.count, 3)
                    let sourcePaths = Array(searchPaths.prefix(2))
                    let manualCodemapPath = searchPaths[2]
                    let sourceSelection = StoredSelection(
                        selectedPaths: sourcePaths,
                        codemapAutoEnabled: false
                    )
                    _ = await window.selectionCoordinator.persistSelection(
                        sourceSelection,
                        for: sourceIdentity,
                        source: .runtimeMutation,
                        mirrorToUIIfActive: false
                    )
                    let sourceRevision = window.workspaceManager.selectionRevisionForMCP(
                        workspaceID: fixture.contextA.workspaceID,
                        tabID: sourceTabID
                    )
                    let committedSource = try XCTUnwrap(
                        window.workspaceManager.composeTab(with: sourceTabID)
                    )
                    XCTAssertEqual(Set(committedSource.selection.selectedPaths), Set(sourcePaths))
                    let snapshot = AgentRunOracleReviewLaunchSnapshot(
                        route: .explicitTabContext,
                        windowID: window.windowID,
                        workspaceID: fixture.contextA.workspaceID,
                        tabID: sourceTabID,
                        selectionRevision: sourceRevision,
                        promptText: committedSource.promptText,
                        selection: committedSource.selection,
                        sourceAgentSessionID: nil,
                        routedRunID: nil
                    )

                    let equivalentSelection = StoredSelection(
                        selectedPaths: Array(sourcePaths.reversed()),
                        codemapAutoEnabled: false
                    )
                    _ = await window.selectionCoordinator.persistSelection(
                        equivalentSelection,
                        for: sourceIdentity,
                        source: .runtimeMutation,
                        mirrorToUIIfActive: false
                    )
                    XCTAssertNotEqual(
                        window.workspaceManager.selectionRevisionForMCP(
                            workspaceID: fixture.contextA.workspaceID,
                            tabID: sourceTabID
                        ),
                        sourceRevision
                    )
                    let equivalentCapture = await window.mcpServer.testCaptureAgentRunOracleReviewSource(
                        snapshot: snapshot,
                        targetWindow: window
                    )
                    let liveAfterEquivalentCapture = window.workspaceManager.composeTab(
                        with: sourceTabID
                    )?.selection
                    guard case let .captured(captured) = equivalentCapture else {
                        return XCTFail(
                            "Expected equivalent selection identity drift to preserve captured source, " +
                                "got \(equivalentCapture); " +
                                "liveSelection=\(String(describing: liveAfterEquivalentCapture))"
                        )
                    }
                    XCTAssertEqual(captured.sourceSelectionRevision, sourceRevision)
                    XCTAssertEqual(captured.selection, committedSource.selection)
                    XCTAssertEqual(
                        captured.exactSelectedIdentities,
                        AgentRunOracleReviewSelectionIdentity.normalizedSelectedArtifactIdentities(
                            snapshot.selection
                        )
                    )

                    let manualCodemapChangedSelection = StoredSelection(
                        selectedPaths: sourcePaths,
                        manualCodemapPaths: [manualCodemapPath],
                        codemapAutoEnabled: false
                    )
                    _ = await window.selectionCoordinator.persistSelection(
                        manualCodemapChangedSelection,
                        for: sourceIdentity,
                        source: .runtimeMutation,
                        mirrorToUIIfActive: false
                    )
                    let manualCodemapChangedCapture = await window.mcpServer.testCaptureAgentRunOracleReviewSource(
                        snapshot: snapshot,
                        targetWindow: window
                    )
                    guard case let .unavailable(manualCodemapUnavailable) = manualCodemapChangedCapture else {
                        return XCTFail("Expected manual codemap identity drift to fail closed")
                    }
                    guard case .sourceCaptureFailed = manualCodemapUnavailable.reason else {
                        return XCTFail(
                            "Expected manual codemap source capture failure, got \(manualCodemapUnavailable.reason)"
                        )
                    }

                    let changedSelection = StoredSelection(
                        selectedPaths: [sourcePaths[0]],
                        codemapAutoEnabled: false
                    )
                    _ = await window.selectionCoordinator.persistSelection(
                        changedSelection,
                        for: sourceIdentity,
                        source: .runtimeMutation,
                        mirrorToUIIfActive: false
                    )
                    let changedCapture = await window.mcpServer.testCaptureAgentRunOracleReviewSource(
                        snapshot: snapshot,
                        targetWindow: window
                    )
                    guard case let .unavailable(unavailable) = changedCapture else {
                        return XCTFail("Expected real selection identity drift to fail closed")
                    }
                    guard case let .sourceCaptureFailed(message) = unavailable.reason else {
                        return XCTFail("Expected source capture failure, got \(unavailable.reason)")
                    }
                    XCTAssertTrue(message.contains("selection") || message.contains("tab changed"))
                }
            }
        }

        func testAgentRunExplicitContextCapturesInactiveSourceInsteadOfActiveTab() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let window = fixture.contextA.window
                let apiSettings = try XCTUnwrap(window.promptManager.apiSettingsViewModel)
                let previousClaudeCodeConnected = apiSettings.isClaudeCodeConnected
                defer {
                    window.mcpServer.setAgentRunDispatchOverrideForTesting(nil)
                    window.mcpServer.setRequestMetadataOverrideForTesting(nil)
                    apiSettings.isClaudeCodeConnected = previousClaudeCodeConnected
                }

                do {
                    try await activateWorkspace(fixture.contextA)
                    let explicitTabID = UUID()
                    let explicitSelection = StoredSelection(
                        selectedPaths: [fixture.contextA.fileURL.path],
                        codemapAutoEnabled: false
                    )
                    guard let workspaceIndex = window.workspaceManager.workspaces.firstIndex(where: {
                        $0.id == fixture.contextA.workspaceID
                    }) else {
                        return XCTFail("Expected active fixture workspace")
                    }
                    window.workspaceManager.workspaces[workspaceIndex].composeTabs.append(
                        ComposeTabState(
                            id: explicitTabID,
                            name: "Explicit inactive launch source",
                            selection: explicitSelection,
                            promptText: "EXPLICIT_INACTIVE_PROMPT"
                        )
                    )
                    let connectionID = UUID()
                    try window.mcpServer.bindTabForConnection(
                        connectionID: connectionID,
                        clientName: "public-agent-run-explicit",
                        tabID: explicitTabID,
                        workspaceID: fixture.contextA.workspaceID,
                        windowID: window.windowID
                    )
                    window.mcpServer.setRequestMetadataOverrideForTesting(.init(
                        connectionID: connectionID,
                        clientName: "public-agent-run-explicit",
                        windowID: window.windowID,
                        runPurpose: .unknown,
                        actorRoutedRunTab: nil
                    ))
                    var targetRunID: UUID?
                    window.mcpServer.setAgentRunDispatchOverrideForTesting {
                        _, tabID, _, _, viewModel in
                        let runID = UUID()
                        targetRunID = runID
                        let session = viewModel.session(for: tabID)
                        session.runID = runID
                        session.runState = .running
                        guard viewModel.mcpBindPendingAgentRunOracleReviewContext(
                            tabID: tabID,
                            runID: runID
                        ) != nil else {
                            throw MCPError.internalError(
                                "Explicit launch child did not promote its carrier."
                            )
                        }
                        return .startedRun
                    }
                    apiSettings.isClaudeCodeConnected = true
                    let startValue = try await window.mcpServer.executeAgentRunForTesting(args: [
                        "op": .string("start"),
                        "message": .string("Start from the explicit inactive source."),
                        "model_id": .string("claudeCode:sonnet"),
                        "detach": .bool(true),
                        "timeout": .int(0)
                    ])
                    let startObject = try XCTUnwrap(startValue.objectValue)
                    let sessionObject = try XCTUnwrap(startObject["session"]?.objectValue)
                    let childSessionID = try XCTUnwrap(
                        startObject["session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                    )
                    let childTabID = try XCTUnwrap(
                        sessionObject["context_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                    )
                    XCTAssertNil(sessionObject["parent_session_id"])
                    let delegated = try XCTUnwrap(
                        try window.agentModeViewModel.mcpDelegatedAgentRunOracleReviewContext(
                            tabID: childTabID,
                            workspaceID: fixture.contextA.workspaceID,
                            sessionID: childSessionID,
                            runID: XCTUnwrap(targetRunID)
                        )
                    )
                    XCTAssertEqual(delegated.source.sourceTabID, explicitTabID)
                    guard case let .captured(captured) = delegated.source else {
                        return XCTFail("Expected captured explicit launch source")
                    }
                    XCTAssertEqual(captured.promptText, "EXPLICIT_INACTIVE_PROMPT")
                    XCTAssertEqual(captured.selection, explicitSelection)
                    XCTAssertNil(captured.sourceAgentSessionID)
                    XCTAssertNotEqual(explicitTabID, fixture.contextA.tabID)

                    await window.agentModeViewModel.mcpDeactivateControlContext(
                        sessionID: childSessionID,
                        cleanupSessionStore: true
                    )
                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private func assertOracleReviewTransportUsesPublishedPatch(
            repositoryKind: ProductionOracleRepositoryKind,
            delegateToChildRun: Bool = false,
            childInheritWorktreeBindings: Bool = true,
            childCreateWorktree: Bool = false
        ) async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let gitFixture = try ReviewGitRepositoryFixture(
                    name: "OracleTransport-" + repositoryKind.rawValue
                )
                let traceCapture = OracleReviewPackagingTraceCapture()
                let transportCapture = OracleReviewTransportCapture()
                let automaticProviderCounter = OracleAutomaticProviderCounter()
                let customOpenAIProvider = CustomOpenAIProvider(
                    baseURL: "https://example.invalid",
                    apiKey: "test-key",
                    defaultModel: "oracle-serialization-test"
                )
                let settings = GlobalSettingsStore.shared
                let previousShowPresets = settings.mcpShowModelPresets()
                let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
                let apiSettings = try XCTUnwrap(
                    fixture.contextA.window.promptManager.apiSettingsViewModel
                )
                let previousCustomProviderValidity = apiSettings.isCustomProviderValid
                let previousClaudeCodeConnected = apiSettings.isClaudeCodeConnected
                let previousPlanningModel = fixture.contextA.window.promptManager.planningModelName
                var syntheticSessionIDsToCleanup: [UUID] = []
                var syntheticRunIDsToCleanup: [UUID] = []
                var syntheticConnectionsToCleanup: [SyntheticMCPConnectionCleanup] = []
                var delegatedConversationSessionIDToDeactivate: UUID?

                func trackSyntheticSession(_ sessionID: UUID) {
                    guard !syntheticSessionIDsToCleanup.contains(sessionID) else { return }
                    syntheticSessionIDsToCleanup.append(sessionID)
                }

                func trackSyntheticRun(_ runID: UUID) {
                    guard !syntheticRunIDsToCleanup.contains(runID) else { return }
                    syntheticRunIDsToCleanup.append(runID)
                }

                func trackSyntheticConnection(
                    connectionID: UUID,
                    clientName: String,
                    runID: UUID?
                ) {
                    guard !syntheticConnectionsToCleanup.contains(where: {
                        $0.connectionID == connectionID
                    }) else { return }
                    syntheticConnectionsToCleanup.append(SyntheticMCPConnectionCleanup(
                        connectionID: connectionID,
                        clientName: clientName,
                        runID: runID
                    ))
                }

                defer {
                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer
                        .setOracleReviewPackagingTraceObserverForTesting(nil)
                    fixture.contextA.window.mcpServer
                        .setOraclePostPackagingTransportOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer
                        .setAgentRunDispatchOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer
                        .setRequestMetadataOverrideForTesting(nil)
                    apiSettings.isCustomProviderValid = previousCustomProviderValidity
                    apiSettings.isClaudeCodeConnected = previousClaudeCodeConnected
                    fixture.contextA.window.promptManager.planningModelName = previousPlanningModel
                    settings.setMCPShowModelPresets(previousShowPresets, commit: false)
                    settings.setMCPTemporarilyDisablePresets(
                        previousTemporaryDisable,
                        commit: false
                    )
                    gitFixture.cleanup()
                }

                do {
                    try await activateWorkspace(fixture.contextA)

                    let publicationRoot: URL
                    let sourceFile: URL
                    let bindings: [AgentSessionWorktreeBinding]
                    let frozenContext: MCPServerViewModel.TabContextSnapshot
                    let expectedMarker: String
                    let forbiddenMarker: String?
                    let physicalSourceFile: URL

                    switch repositoryKind {
                    case .canonical:
                        publicationRoot = fixture.contextA.rootURL
                        sourceFile = fixture.contextA.fileURL
                        _ = try gitFixture.runGit(["init"], at: publicationRoot)
                        _ = try gitFixture.runGit(
                            ["config", "user.name", "RepoPrompt Test"],
                            at: publicationRoot
                        )
                        _ = try gitFixture.runGit(
                            ["config", "user.email", "repoprompt@example.test"],
                            at: publicationRoot
                        )
                        _ = try gitFixture.runGit(
                            ["config", "commit.gpgSign", "false"],
                            at: publicationRoot
                        )
                        _ = try gitFixture.runGit(["add", "."], at: publicationRoot)
                        _ = try gitFixture.runGit(
                            ["commit", "-m", "Initial commit"],
                            at: publicationRoot
                        )
                        expectedMarker = "oracle_canonical_transport_marker"
                        forbiddenMarker = nil
                        try write(
                            "let oracleMarker = \"" + expectedMarker + "\"\n",
                            to: sourceFile
                        )
                        bindings = []
                        physicalSourceFile = sourceFile
                        frozenContext = MCPServerViewModel.TabContextSnapshot(
                            tabID: fixture.contextA.tabID,
                            windowID: fixture.contextA.window.windowID,
                            workspaceID: fixture.contextA.workspaceID,
                            promptText: "Review canonical transport",
                            selection: StoredSelection(
                                selectedPaths: [sourceFile.path],
                                codemapAutoEnabled: false
                            ),
                            selectedMetaPromptIDs: [],
                            tabName: "Canonical Oracle Transport",
                            runID: UUID(),
                            activeAgentSessionID: nil,
                            worktreeBindingState: .notApplicable,
                            explicitlyBound: false
                        )

                    case .linkedWorktree, .visibleLinkedWorktree:
                        let usesVisibleLinkedRoot = repositoryKind == .visibleLinkedWorktree
                        let logicalRoot = try gitFixture.makeRepository(
                            named: "logical",
                            files: ["Sources/Feature.swift": "let oracleMarker = \"initial\"\n"]
                        )
                        let worktreeRoot = try gitFixture.makeLinkedWorktree(
                            from: logicalRoot,
                            named: "linked",
                            branch: "feature/oracle-transport"
                        )
                        publicationRoot = usesVisibleLinkedRoot ? worktreeRoot : logicalRoot
                        let logicalSourceFile = logicalRoot
                            .appendingPathComponent("Sources/Feature.swift")
                        sourceFile = (usesVisibleLinkedRoot ? worktreeRoot : logicalRoot)
                            .appendingPathComponent("Sources/Feature.swift")
                        expectedMarker = usesVisibleLinkedRoot
                            ? "oracle_visible_worktree_transport_marker"
                            : "oracle_worktree_transport_marker"
                        forbiddenMarker = "oracle_canonical_transport_leak"
                        try write(
                            "let oracleMarker = \"" + forbiddenMarker! + "\"\n",
                            to: logicalSourceFile
                        )
                        try write(
                            "let oracleMarker = \"" + expectedMarker + "\"\n",
                            to: worktreeRoot.appendingPathComponent("Sources/Feature.swift")
                        )
                        _ = try await fixture.contextA.window.workspaceFileContextStore
                            .loadRoot(
                                path: usesVisibleLinkedRoot ? worktreeRoot.path : logicalRoot.path,
                                kind: .primaryWorkspace
                            )
                        let layout = try XCTUnwrap(
                            GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: worktreeRoot)
                        )
                        let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
                            commonGitDir: layout.commonDir,
                            mainWorktreeRoot: layout.knownMainWorktreeRoot
                        )
                        let worktreeID = GitWorktreeIdentity.worktreeID(
                            repositoryID: repositoryIdentity.repositoryID,
                            gitDir: layout.gitDir,
                            isMain: false,
                            path: layout.workTreeRoot
                        )
                        let binding = AgentSessionWorktreeBinding(
                            id: "binding-oracle-transport",
                            repositoryID: repositoryIdentity.repositoryID,
                            repoKey: GitRepoDescriptor(rootURL: logicalRoot).repoKey,
                            logicalRootPath: logicalRoot.path,
                            logicalRootName: "OracleTransportRepo",
                            worktreeID: worktreeID,
                            worktreeRootPath: worktreeRoot.path,
                            worktreeName: "linked",
                            branch: "feature/oracle-transport",
                            source: "test"
                        )
                        physicalSourceFile = worktreeRoot
                            .appendingPathComponent("Sources/Feature.swift")
                        if usesVisibleLinkedRoot {
                            let workspaceIndex = try XCTUnwrap(
                                fixture.contextA.window.workspaceManager.workspaces.firstIndex {
                                    $0.id == fixture.contextA.workspaceID
                                }
                            )
                            var workspace = fixture.contextA.window.workspaceManager
                                .workspaces[workspaceIndex]
                            workspace.repoPaths = [worktreeRoot.path]
                            fixture.contextA.window.workspaceManager.workspaces[workspaceIndex] = workspace
                            bindings = []
                            frozenContext = MCPServerViewModel.TabContextSnapshot(
                                tabID: fixture.contextA.tabID,
                                windowID: fixture.contextA.window.windowID,
                                workspaceID: fixture.contextA.workspaceID,
                                promptText: "Review visible linked transport",
                                selection: StoredSelection(
                                    selectedPaths: [sourceFile.path],
                                    codemapAutoEnabled: false
                                ),
                                selectedMetaPromptIDs: [],
                                tabName: "Visible Linked Oracle Transport",
                                runID: UUID(),
                                activeAgentSessionID: nil,
                                worktreeBindingState: .notApplicable,
                                explicitlyBound: false
                            )
                        } else {
                            bindings = [binding]
                            frozenContext = makeFrozenContext(
                                fixture: fixture,
                                selection: StoredSelection(
                                    selectedPaths: [sourceFile.path],
                                    codemapAutoEnabled: false
                                ),
                                bindings: bindings
                            )
                        }
                    }

                    if let activeAgentSessionID = frozenContext.activeAgentSessionID {
                        trackSyntheticSession(activeAgentSessionID)
                    }

                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: frozenContext,
                        fixture: fixture
                    )

                    let gitResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.git,
                        arguments: [
                            "op": "diff",
                            "repo_root": publicationRoot.path,
                            "scope": "selected",
                            "detail": "patches",
                            "artifacts": true,
                            "mode": "deep"
                        ],
                        timeoutSeconds: 30
                    )
                    let gitText = try toolResultText(gitResponse)

                    let publishedSelection = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(
                            with: fixture.contextA.tabID
                        )
                    ).selection
                    let diagnosticContext = "oracle transport publication "
                        + "repositoryKind=\(repositoryKind.rawValue) "
                        + "delegateToChildRun=\(delegateToChildRun) "
                        + "childInheritWorktreeBindings=\(childInheritWorktreeBindings) "
                        + "childCreateWorktree=\(childCreateWorktree)"
                    let mapPath = try requireSelectedPath(
                        suffix: "/MAP.txt",
                        in: publishedSelection,
                        context: diagnosticContext,
                        toolOutput: gitText
                    )
                    let patchPath = try requireSelectedPath(
                        suffix: "/diff/all.patch",
                        in: publishedSelection,
                        context: diagnosticContext,
                        toolOutput: gitText
                    )
                    let patchText = try String(contentsOfFile: patchPath, encoding: .utf8)
                    let mapAlias = try XCTUnwrap(
                        mapPath.range(of: "/_git_data/").map {
                            "_git_data/" + mapPath[$0.upperBound...]
                        }
                    )
                    let patchAlias = try XCTUnwrap(
                        patchPath.range(of: "/_git_data/").map {
                            "_git_data/" + patchPath[$0.upperBound...]
                        }
                    )
                    let committedRevision = fixture.contextA.window.workspaceManager
                        .selectionRevisionForMCP(
                            workspaceID: fixture.contextA.workspaceID,
                            tabID: fixture.contextA.tabID
                        )
                    XCTAssertTrue(publishedSelection.selectedPaths.contains(sourceFile.path))
                    XCTAssertTrue(patchText.contains(expectedMarker), patchText)
                    if let forbiddenMarker {
                        XCTAssertFalse(patchText.contains(forbiddenMarker), patchText)
                    }

                    var conversationTabID = fixture.contextA.tabID
                    var conversationSessionID = frozenContext.activeAgentSessionID
                    var conversationRunID = frozenContext.runID
                    var expectedDelegationID: UUID?
                    var expectedPackagedSourceMarker = expectedMarker
                    var directOracleConnectionID: UUID?

                    if delegateToChildRun {
                        let window = fixture.contextA.window
                        let agentModeViewModel = window.agentModeViewModel
                        let startConnectionID = UUID()
                        var targetRunID: UUID?
                        var sourceRunIDToCleanup: UUID?

                        if bindings.isEmpty {
                            window.mcpServer.setRequestMetadataOverrideForTesting(.init(
                                connectionID: startConnectionID,
                                clientName: "public-agent-run-window-only",
                                windowID: window.windowID,
                                runPurpose: .unknown,
                                explicitWindowRoutingHint: MCPExplicitWindowRoutingHint(
                                    connectionID: startConnectionID,
                                    toolName: "agent_run",
                                    windowID: window.windowID,
                                    windowStateIdentity: ObjectIdentifier(window),
                                    serverViewModelIdentity: ObjectIdentifier(window.mcpServer),
                                    provenance: .hiddenWindowArgument
                                ),
                                actorRoutedRunTab: nil
                            ))
                            XCTAssertEqual(
                                window.mcpServer.connectionBindingSnapshot(forConnection: startConnectionID).bindingKind,
                                .unbound
                            )
                        } else {
                            let sourceClientName = "public-agent-run-nested"
                            let sourceSessionID = UUID()
                            let sourceRunID = UUID()
                            sourceRunIDToCleanup = sourceRunID
                            trackSyntheticSession(sourceSessionID)
                            var sourceTab = try XCTUnwrap(
                                window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                            )
                            sourceTab.activeAgentSessionID = sourceSessionID
                            window.workspaceManager.updateComposeTab(sourceTab, markDirty: false)
                            let sourceSession = try XCTUnwrap(
                                agentModeViewModel.session(for: fixture.contextA.tabID, createIfNeeded: true)
                            )
                            sourceSession.testInstallPersistentSessionBinding(sessionID: sourceSessionID)
                            sourceSession.mcpControlContext = makeAgentMCPControlContext(
                                sessionID: sourceSessionID
                            )
                            sourceSession.worktreeBindings = bindings
                            sourceSession.runID = sourceRunID
                            try window.mcpServer.bindTabForConnection(
                                connectionID: startConnectionID,
                                clientName: sourceClientName,
                                tabID: fixture.contextA.tabID,
                                workspaceID: fixture.contextA.workspaceID,
                                windowID: window.windowID,
                                runID: sourceRunID
                            )
                            trackSyntheticRun(sourceRunID)
                            trackSyntheticConnection(
                                connectionID: startConnectionID,
                                clientName: sourceClientName,
                                runID: sourceRunID
                            )
                            await ServerNetworkManager.shared.debugSeedRunPolicyState(
                                runID: sourceRunID,
                                tabID: fixture.contextA.tabID,
                                restrictedTools: [],
                                additionalTools: nil,
                                purpose: .agentModeRun
                            )
                            await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
                                connectionID: startConnectionID,
                                runID: sourceRunID,
                                purpose: .agentModeRun
                            )
                            window.mcpServer.setRequestMetadataOverrideForTesting(.init(
                                connectionID: startConnectionID,
                                clientName: sourceClientName,
                                windowID: window.windowID,
                                runPurpose: .agentModeRun,
                                actorRoutedRunTab: nil
                            ))
                        }

                        window.mcpServer.setAgentRunDispatchOverrideForTesting {
                            sessionID,
                            tabID,
                            _,
                            _,
                            viewModel in
                            let runID = UUID()
                            targetRunID = runID
                            let session = viewModel.session(for: tabID)
                            session.runID = runID
                            session.runState = .running
                            guard viewModel.mcpBindPendingAgentRunOracleReviewContext(
                                tabID: tabID,
                                runID: runID
                            ) != nil else {
                                throw MCPError.internalError(
                                    "Public Agent Run test did not promote its staged Oracle source."
                                )
                            }
                            XCTAssertEqual(session.activeAgentSessionID, sessionID)
                            return .startedRun
                        }
                        apiSettings.isClaudeCodeConnected = true
                        let startValue = try await window.mcpServer.executeAgentRunForTesting(args: [
                            "op": .string("start"),
                            "message": .string("Start delegated Oracle review child."),
                            "model_id": .string("claudeCode:sonnet"),
                            "session_name": .string("Delegated Oracle child"),
                            "inherit_worktree": .bool(childInheritWorktreeBindings),
                            "worktree_create": .bool(childCreateWorktree),
                            "detach": .bool(true),
                            "timeout": .int(0)
                        ])
                        let startObject = try XCTUnwrap(startValue.objectValue)
                        let startSession = try XCTUnwrap(startObject["session"]?.objectValue)
                        let targetSessionID = try XCTUnwrap(
                            startObject["session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                        )
                        let targetTabID = try XCTUnwrap(
                            startSession["context_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                        )
                        let resolvedTargetRunID = try XCTUnwrap(targetRunID)
                        trackSyntheticSession(targetSessionID)
                        trackSyntheticRun(resolvedTargetRunID)
                        delegatedConversationSessionIDToDeactivate = targetSessionID
                        let delegated = try XCTUnwrap(
                            try agentModeViewModel.mcpDelegatedAgentRunOracleReviewContext(
                                tabID: targetTabID,
                                workspaceID: fixture.contextA.workspaceID,
                                sessionID: targetSessionID,
                                runID: resolvedTargetRunID
                            )
                        )
                        expectedDelegationID = delegated.source.delegationID
                        let actualTargetBindings = agentModeViewModel.session(for: targetTabID).worktreeBindings
                        let expectedTargetBindings = childCreateWorktree
                            ? actualTargetBindings
                            : (childInheritWorktreeBindings ? bindings : [])
                        if childCreateWorktree {
                            XCTAssertEqual(actualTargetBindings.count, 1)
                        }
                        XCTAssertEqual(delegated.target.worktreeBindings, expectedTargetBindings)
                        if bindings.isEmpty {
                            XCTAssertNil(startSession["parent_session_id"])
                            XCTAssertNil(delegated.source.sourceAgentSessionID)
                        } else {
                            XCTAssertNotNil(startSession["parent_session_id"]?.stringValue)
                        }
                        XCTAssertEqual(delegated.source.sourceTabID, fixture.contextA.tabID)
                        XCTAssertEqual(delegated.source.workspaceID, fixture.contextA.workspaceID)
                        if case let .captured(captured) = delegated.source {
                            XCTAssertEqual(captured.sourceSelectionRevision, committedRevision)
                            XCTAssertEqual(captured.selection, publishedSelection)
                        } else {
                            XCTFail("Expected public Agent Run to capture its launch package")
                        }

                        let liveMarker = "oracle_newer_live_" + repositoryKind.rawValue
                        try write(
                            "let oracleMarker = \"" + liveMarker + "\"\n",
                            to: physicalSourceFile
                        )
                        expectedPackagedSourceMarker = liveMarker
                        conversationTabID = targetTabID
                        conversationSessionID = targetSessionID
                        conversationRunID = resolvedTargetRunID
                        let childContext = MCPServerViewModel.TabContextSnapshot(
                            tabID: targetTabID,
                            windowID: fixture.contextA.window.windowID,
                            workspaceID: fixture.contextA.workspaceID,
                            promptText: "Child conversation prompt",
                            selection: StoredSelection(codemapAutoEnabled: false),
                            selectedMetaPromptIDs: [],
                            tabName: "Delegated Oracle child",
                            runID: resolvedTargetRunID,
                            activeAgentSessionID: targetSessionID,
                            worktreeBindingState: .hydrated(expectedTargetBindings),
                            explicitlyBound: false
                        )
                        if let sourceRunIDToCleanup {
                            await cleanupSyntheticMCPRoutingForOracleTest(
                                window: window,
                                sessionIDs: [],
                                runIDs: [sourceRunIDToCleanup],
                                connections: syntheticConnectionsToCleanup.filter {
                                    $0.runID == sourceRunIDToCleanup
                                }
                            )
                        }
                        if bindings.isEmpty {
                            try await configureAgentModeEndpoint(
                                endpoint,
                                context: childContext,
                                fixture: fixture
                            )
                        } else {
                            let childOracleClientName = "linked-public-child-oracle"
                            let connectionID = UUID()
                            directOracleConnectionID = connectionID
                            try window.mcpServer.bindTabForConnection(
                                connectionID: connectionID,
                                clientName: childOracleClientName,
                                tabID: targetTabID,
                                workspaceID: fixture.contextA.workspaceID,
                                windowID: window.windowID,
                                runID: resolvedTargetRunID
                            )
                            trackSyntheticConnection(
                                connectionID: connectionID,
                                clientName: childOracleClientName,
                                runID: resolvedTargetRunID
                            )
                            await ServerNetworkManager.shared.setRunPurpose(
                                .agentModeRun,
                                for: connectionID
                            )
                            try await ServerNetworkManager.shared.debugSeedConnectionRunRouting(
                                connectionID: connectionID,
                                runID: resolvedTargetRunID,
                                purpose: .agentModeRun,
                                windowID: window.windowID
                            )
                            window.mcpServer.setRequestMetadataOverrideForTesting(.init(
                                connectionID: connectionID,
                                clientName: childOracleClientName,
                                windowID: window.windowID,
                                runPurpose: .agentModeRun,
                                actorRoutedRunTab: nil
                            ))
                        }
                    }

                    fixture.contextA.window.promptManager
                        .setAutomaticReviewGitDiffProviderOverrideForTesting { _ in
                            await automaticProviderCounter.recordInvocation()
                            return AutomaticReviewGitDiffResult(
                                text: "AUTOMATIC_FALLBACK_INVOKED",
                                completeness: .complete,
                                outcomes: [],
                                pathIssues: []
                            )
                        }
                    fixture.contextA.window.mcpServer
                        .setOracleReviewPackagingTraceObserverForTesting {
                            traceCapture.record($0)
                        }
                    fixture.contextA.window.mcpServer
                        .setOraclePostPackagingTransportOverrideForTesting { message, model in
                            transportCapture.record(
                                message: message,
                                model: model,
                                serializedMessages: customOpenAIProvider
                                    .serializedMessagesForTesting(message)
                            )
                            let stream = AsyncThrowingStream<ChatStreamOutput, Error> {
                                continuation in
                                continuation.yield(ChatStreamOutput(
                                    text: "transported oracle response",
                                    reasoning: nil,
                                    tokens: ChatTokenInfo(),
                                    isFinal: true
                                ))
                                continuation.finish()
                            }
                            return (UUID(), stream)
                        }

                    settings.setMCPShowModelPresets(false, commit: false)
                    settings.setMCPTemporarilyDisablePresets(false, commit: false)
                    apiSettings.isCustomProviderValid = true
                    fixture.contextA.window.promptManager.planningModelName =
                        AIModel.customProviderUser(
                            name: "oracle-serialization-test"
                        ).rawValue

                    let oracleViewModel = fixture.contextA.window.oracleViewModel
                    XCTAssertFalse(
                        oracleViewModel.sessions
                            .filter { $0.composeTabID == conversationTabID }
                            .flatMap { oracleViewModel.messagesSnapshot(for: $0.id) }
                            .contains { $0.isUser }
                    )
                    if directOracleConnectionID != nil {
                        let freshValue = try await ServerNetworkManager.withConnectionID(
                            XCTUnwrap(directOracleConnectionID)
                        ) {
                            try await fixture.contextA.window.mcpServer
                                .executeAskOracleForTesting(args: [
                                    "message": .string("Review the published patch."),
                                    "mode": .string("review")
                                ])
                        }
                        XCTAssertTrue(
                            freshValue.objectValue?["response"]?.stringValue?
                                .contains("transported oracle response") == true
                        )
                    } else {
                        let freshResponse = try await endpoint.callTool(
                            name: MCPWindowToolName.askOracle,
                            arguments: [
                                "message": "Review the published patch.",
                                "mode": "review"
                            ],
                            timeoutSeconds: 30
                        )
                        XCTAssertTrue(
                            try toolResultText(freshResponse).contains(
                                "transported oracle response"
                            )
                        )
                    }
                    let sessionDescriptions = oracleViewModel.sessions.map {
                        "tab=\($0.composeTabID) session=\(String(describing: $0.agentModeSessionID)) run=\(String(describing: $0.agentModeRunID))"
                    }
                    let freshSession = try XCTUnwrap(
                        oracleViewModel.sessions.first {
                            $0.composeTabID == conversationTabID
                                && $0.agentModeSessionID == conversationSessionID
                                && $0.agentModeRunID == conversationRunID
                        },
                        "Expected tab=\(conversationTabID) session=\(String(describing: conversationSessionID)) run=\(String(describing: conversationRunID)); actual=\(sessionDescriptions)"
                    )
                    XCTAssertEqual(freshSession.composeTabID, conversationTabID)
                    XCTAssertEqual(freshSession.agentModeSessionID, conversationSessionID)
                    XCTAssertEqual(freshSession.agentModeRunID, conversationRunID)
                    let chatID = freshSession.shortID
                    if directOracleConnectionID != nil {
                        let continuingValue = try await ServerNetworkManager.withConnectionID(
                            XCTUnwrap(directOracleConnectionID)
                        ) {
                            try await fixture.contextA.window.mcpServer
                                .executeAskOracleForTesting(args: [
                                    "message": .string("Continue reviewing the same published patch."),
                                    "mode": .string("review"),
                                    "chat_id": .string(chatID)
                                ])
                        }
                        XCTAssertTrue(
                            continuingValue.objectValue?["response"]?.stringValue?
                                .contains("transported oracle response") == true
                        )
                    } else {
                        let continuingResponse = try await endpoint.callTool(
                            name: MCPWindowToolName.askOracle,
                            arguments: [
                                "message": "Continue reviewing the same published patch.",
                                "mode": "review",
                                "chat_id": chatID
                            ],
                            timeoutSeconds: 30
                        )
                        XCTAssertTrue(
                            try toolResultText(continuingResponse).contains(
                                "transported oracle response"
                            )
                        )
                    }
                    let continuingSessionIDs = Set(
                        oracleViewModel.sessions.compactMap { session in
                            session.composeTabID == conversationTabID
                                && session.agentModeSessionID == conversationSessionID
                                && session.agentModeRunID == conversationRunID
                                ? session.id
                                : nil
                        }
                    )
                    XCTAssertEqual(continuingSessionIDs, [freshSession.id])

                    let messages = transportCapture.messages
                    let expectedFingerprint =
                        OracleReviewPackagingDiagnostics.fingerprint(patchText)
                    XCTAssertEqual(messages.count, 2)
                    XCTAssertEqual(
                        transportCapture.serializedGitDiffFingerprints,
                        Array(repeating: expectedFingerprint, count: 2)
                    )
                    XCTAssertTrue(
                        transportCapture.models.allSatisfy {
                            $0.providerType == .customProvider
                        }
                    )
                    let automaticInvocationCount =
                        await automaticProviderCounter.invocationCount()
                    XCTAssertEqual(automaticInvocationCount, 0)
                    let traceTurns = traceCapture.completedTurns()
                    XCTAssertEqual(traceTurns.count, 2)
                    XCTAssertEqual(Set(traceTurns.map(\.correlationID)).count, 2)

                    for turn in traceTurns {
                        let frozen = try XCTUnwrap(turn.frozen)
                        let preassembly = try XCTUnwrap(turn.preassembly)
                        let submission = try XCTUnwrap(turn.submission)
                        XCTAssertNil(turn.failureType)
                        XCTAssertEqual(frozen.origin, .askOracle)
                        XCTAssertEqual(frozen.conversationTabID, conversationTabID)
                        XCTAssertEqual(frozen.conversationWorkspaceID, fixture.contextA.workspaceID)
                        XCTAssertEqual(frozen.sourceTabID, fixture.contextA.tabID)
                        XCTAssertEqual(frozen.sourceWorkspaceID, fixture.contextA.workspaceID)
                        XCTAssertEqual(frozen.sourceSelectionRevision, committedRevision)
                        XCTAssertEqual(frozen.delegationID, expectedDelegationID)
                        XCTAssertEqual(frozen.conversationAgentSessionID, conversationSessionID)
                        XCTAssertEqual(frozen.conversationAgentRunID, conversationRunID)
                        XCTAssertEqual(
                            Set(frozen.selectedIdentityHashes),
                            Set(publishedSelection.selectedPaths.map(
                                OracleReviewPackagingDiagnostics.identityHash
                            ))
                        )
                        XCTAssertEqual(
                            frozen.capability?.workspaceID,
                            fixture.contextA.workspaceID
                        )
                        XCTAssertEqual(
                            frozen.capability?.creatorTabID,
                            fixture.contextA.tabID
                        )
                        XCTAssertEqual(
                            Set(frozen.capability?.boundRepositoryIDs ?? []),
                            Set(bindings.map(\.repositoryID))
                        )
                        XCTAssertEqual(
                            Set(frozen.capability?.boundWorktreeIDs ?? []),
                            Set(bindings.map(\.worktreeID))
                        )

                        XCTAssertEqual(preassembly.gitInclusion, GitInclusion.selected.rawValue)
                        XCTAssertFalse(
                            preassembly.disabledPromptSections.contains(
                                String(describing: PromptSection.gitDiff)
                            )
                        )
                        XCTAssertEqual(
                            preassembly.selectedArtifactPolicy,
                            String(
                                describing: SelectedGitDiffArtifactPolicy
                                    .includeBeforeGitInclusion
                            )
                        )
                        XCTAssertEqual(preassembly.resolutionSource, .selectedArtifact)
                        XCTAssertEqual(preassembly.gitDiff, expectedFingerprint)
                        XCTAssertEqual(submission.gitDiff, expectedFingerprint)
                        XCTAssertEqual(preassembly.fileBlocks, submission.fileBlocks)
                        XCTAssertTrue(
                            preassembly.artifactDispositions.contains {
                                $0.pathHash == OracleReviewPackagingDiagnostics.identityHash(mapPath)
                                    && $0.status == .authorized
                                    && $0.kind == SelectedGitArtifactKind.map.rawValue
                                    && $0.detail == "readable"
                            }
                        )
                        XCTAssertTrue(
                            preassembly.artifactDispositions.contains {
                                $0.pathHash == OracleReviewPackagingDiagnostics.identityHash(patchPath)
                                    && $0.status == .authorized
                                    && $0.kind == SelectedGitArtifactKind.patch.rawValue
                                    && $0.detail == "readable"
                            }
                        )
                        XCTAssertFalse(
                            preassembly.artifactDispositions.contains {
                                $0.status == .rejected
                            }
                        )
                    }

                    for (message, serializedUserContent) in zip(
                        messages,
                        transportCapture.serializedUserContents
                    ) {
                        XCTAssertEqual(message.gitDiff, patchText)
                        XCTAssertTrue(
                            serializedUserContent.contains(
                                "<git_diff>\n" + patchText + "\n</git_diff>"
                            )
                        )
                        XCTAssertEqual(
                            serializedUserContent.components(
                                separatedBy: mapAlias
                            ).count - 1,
                            1
                        )
                        XCTAssertFalse(serializedUserContent.contains(patchAlias))
                        XCTAssertTrue(serializedUserContent.contains(expectedPackagedSourceMarker))
                        if let forbiddenMarker {
                            XCTAssertFalse(
                                serializedUserContent.contains(forbiddenMarker)
                            )
                        }
                        XCTAssertEqual(
                            message.fileBlocks.count { $0.contains(mapAlias) },
                            1
                        )
                        XCTAssertFalse(
                            message.fileBlocks.contains {
                                $0.contains("<path>" + patchAlias + "</path>")
                            }
                        )
                        let packagedSources = message.fileBlocks.joined(separator: "\n")
                        XCTAssertTrue(
                            packagedSources.contains(expectedPackagedSourceMarker),
                            packagedSources
                        )
                        if delegateToChildRun {
                            XCTAssertFalse(packagedSources.contains(expectedMarker), packagedSources)
                        }
                        if let forbiddenMarker {
                            XCTAssertFalse(
                                packagedSources.contains(forbiddenMarker),
                                packagedSources
                            )
                        }
                    }

                    if delegateToChildRun,
                       let conversationSessionID
                    {
                        await fixture.contextA.window.agentModeViewModel
                            .mcpDeactivateControlContext(
                                sessionID: conversationSessionID,
                                cleanupSessionStore: true
                            )
                        XCTAssertFalse(
                            fixture.contextA.window.agentModeViewModel
                                .mcpHasAgentRunOracleReviewContextExpectation(
                                    tabID: conversationTabID
                                )
                        )
                    }

                    await cleanupSyntheticMCPRoutingForOracleTest(
                        window: fixture.contextA.window,
                        sessionIDs: syntheticSessionIDsToCleanup,
                        runIDs: syntheticRunIDsToCleanup,
                        connections: syntheticConnectionsToCleanup
                    )
                    await fixture.cleanup()
                } catch {
                    if delegateToChildRun,
                       let delegatedConversationSessionIDToDeactivate
                    {
                        await fixture.contextA.window.agentModeViewModel
                            .mcpDeactivateControlContext(
                                sessionID: delegatedConversationSessionIDToDeactivate,
                                cleanupSessionStore: true
                            )
                    }
                    await cleanupSyntheticMCPRoutingForOracleTest(
                        window: fixture.contextA.window,
                        sessionIDs: syntheticSessionIDsToCleanup,
                        runIDs: syntheticRunIDsToCleanup,
                        connections: syntheticConnectionsToCleanup
                    )
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleFailsClosedWhenOneOfMultipleBoundRootsIsUnavailable() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleWorktreeCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let logicalRootA = fixture.contextA.rootURL
                    let logicalFileA = fixture.contextA.fileURL
                    let logicalRootB = try makeTemporaryRoot(name: "OracleMixedLogicalB")
                    let logicalFileB = logicalRootB.appendingPathComponent("Sources/Second.swift")
                    let worktreeRootA = try makeTemporaryRoot(name: "OracleMixedWorktreeA")
                    let worktreeFileA = worktreeRootA
                        .appendingPathComponent("Sources", isDirectory: true)
                        .appendingPathComponent(logicalFileA.lastPathComponent)
                    let missingWorktreeB = fixture.rootURL.appendingPathComponent(
                        "missing-mixed-oracle-worktree-\(UUID().uuidString)",
                        isDirectory: true
                    )

                    try write("let value = \"canonical_oracle_mixed_a\"\n", to: logicalFileA)
                    try write("let value = \"canonical_oracle_mixed_b\"\n", to: logicalFileB)
                    try write("let value = \"worktree_oracle_mixed_a\"\n", to: worktreeFileA)
                    _ = try await fixture.contextA.window.workspaceFileContextStore.loadRoot(path: logicalRootB.path)

                    let bindings = [
                        makeBinding(logicalRoot: logicalRootA, worktreeRoot: worktreeRootA, suffix: "mixed-a"),
                        makeBinding(logicalRoot: logicalRootB, worktreeRoot: missingWorktreeB, suffix: "mixed-b")
                    ]
                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(
                            selectedPaths: [logicalFileA.path, logicalFileB.path],
                            codemapAutoEnabled: false
                        ),
                        bindings: bindings
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)
                    installOracleCapture(capture, on: fixture.contextA.window)

                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: ["message": "Compare the mixed-availability roots."],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(response.rawJSON.contains("worktree projection is unavailable"), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains(missingWorktreeB.standardizedFileURL.path), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains("canonical_oracle_mixed_a"), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains("canonical_oracle_mixed_b"), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains("worktree_oracle_mixed_a"), response.rawJSON)
                    XCTAssertFalse(capture.wasInvoked)

                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleUnavailableWorktreeFailsBeforeCanonicalPackaging() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleWorktreeCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let canonicalSentinel = "canonical_oracle_must_not_leak"
                    try write("let value = \"\(canonicalSentinel)\"\n", to: fixture.contextA.fileURL)
                    let missingWorktree = fixture.rootURL.appendingPathComponent(
                        "missing-oracle-worktree-\(UUID().uuidString)",
                        isDirectory: true
                    )
                    let binding = makeBinding(
                        logicalRoot: fixture.contextA.rootURL,
                        worktreeRoot: missingWorktree,
                        suffix: "missing"
                    )
                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(
                            selectedPaths: [fixture.contextA.fileURL.path],
                            codemapAutoEnabled: false
                        ),
                        bindings: [binding]
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)
                    installOracleCapture(capture, on: fixture.contextA.window)

                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: ["message": "Inspect the unavailable worktree."],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(response.rawJSON.contains("worktree projection is unavailable"), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains(missingWorktree.standardizedFileURL.path), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains(canonicalSentinel), response.rawJSON)
                    XCTAssertFalse(capture.wasInvoked)

                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleFailsClosedWhenFrozenBindingStateIsUnhydrated() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleWorktreeCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let canonicalSentinel = "canonical_oracle_unhydrated_must_not_leak"
                    try write("let value = \"\(canonicalSentinel)\"\n", to: fixture.contextA.fileURL)
                    let context = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(
                            selectedPaths: [fixture.contextA.fileURL.path],
                            codemapAutoEnabled: false
                        ),
                        bindings: [],
                        bindingState: .unhydrated
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(endpoint, context: context, fixture: fixture)
                    installOracleCapture(capture, on: fixture.contextA.window)

                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.askOracle,
                        arguments: ["message": "Inspect the unknown worktree state."],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(response.rawJSON.contains("bindings are not hydrated or are unavailable"), response.rawJSON)
                    XCTAssertFalse(response.rawJSON.contains(canonicalSentinel), response.rawJSON)
                    XCTAssertFalse(capture.wasInvoked)

                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleSelectionModesPackageSendLocalContextWithoutMutatingSharedSelection() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleSelectionPackagingCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let selectedFile = fixture.contextA.fileURL
                    try write(
                        "let first = \"slice_first\"\nlet middle = \"slice_middle\"\nlet last = \"slice_last\"\n",
                        to: selectedFile
                    )
                    let sharedSelection = StoredSelection(
                        selectedPaths: [selectedFile.path],
                        codemapAutoEnabled: false
                    )
                    _ = await fixture.contextA.window.selectionCoordinator.persistActiveSelection(
                        sharedSelection,
                        source: .runtimeMutation,
                        mirrorToUI: true
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: makeFrozenContext(
                            fixture: fixture,
                            selection: sharedSelection,
                            bindings: []
                        ),
                        fixture: fixture
                    )
                    let continuationChat = ChatSession(
                        workspaceID: fixture.contextA.window.workspaceManager
                            .activeWorkspace?.id,
                        composeTabID: fixture.contextA.tabID,
                        name: "Selection mode continuation",
                        messages: [
                            StoredMessage(
                                isUser: false,
                                rawText: "existing response",
                                sequenceIndex: 0
                            )
                        ]
                    )
                    fixture.contextA.window.oracleViewModel.sessions.append(
                        continuationChat
                    )
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting {
                        args, promptVM, tabContext in
                        let context = try XCTUnwrap(tabContext)
                        let config = PromptContextResolved(
                            includeFiles: true,
                            includeUserPrompt: true,
                            includeMetaPrompts: false,
                            includeFileTree: true,
                            fileTreeMode: .auto,
                            codeMapUsage: .none,
                            gitInclusion: .complete,
                            storedPromptIds: []
                        )
                        let message = await promptVM.packagePrompt(
                            conversation: [ConversationEntry(
                                role: .user,
                                content: args["message"]?.stringValue ?? ""
                            )],
                            overridePromptConfig: config,
                            overrideMode: .review,
                            gitInclusionOverride: context.packaging.gitInclusionOverride,
                            selectionOverride: context.packaging.selection,
                            lookupContextOverride: context.packaging.lookupContext,
                            reviewGitContextOverride: context.packaging.reviewGitContext
                        )
                        capture.record(context: context, message: message)
                        return [
                            "chat_id": .string(UUID().uuidString),
                            "short_id": .string("selection-mode-capture"),
                            "mode": .string("review"),
                            "response": .string("captured")
                        ]
                    }

                    let connectionID = endpoint.connectionID
                    func ask(_ extra: [String: Value] = [:]) async throws {
                        var args: [String: Value] = [
                            "message": .string("Review this exact send-local context."),
                            "mode": .string("review")
                        ]
                        args.merge(extra) { _, new in new }
                        _ = try await ServerNetworkManager.withConnectionID(connectionID) {
                            try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: args)
                        }
                    }

                    let workspaceID = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.activeWorkspace?.id
                    )
                    let revisionBefore = fixture.contextA.window.workspaceManager.selectionRevisionForMCP(
                        workspaceID: workspaceID,
                        tabID: fixture.contextA.tabID
                    )

                    try await ask()
                    try await ask(["selection_mode": .string("current")])
                    try await ask([
                        "chat_id": .string(continuationChat.shortID),
                        "selection_mode": .string("none")
                    ])
                    try await ask([
                        "chat_id": .string(continuationChat.shortID),
                        "selection_mode": .string("explicit_slices"),
                        "slices": .array([.object([
                            "path": .string(selectedFile.path),
                            "ranges": .array([.object([
                                "start_line": .int(2),
                                "end_line": .int(2)
                            ])])
                        ])])
                    ])

                    // Fresh chats are an explicit conversation target too (plan A1).
                    let freshArgs: [String: Value] = [
                        "new_chat": .bool(true),
                        "model": .string("FreshContextOracle")
                    ]
                    try await ask(freshArgs.merging(["selection_mode": .string("none")]) { _, new in new })
                    try await ask(freshArgs.merging([
                        "selection_mode": .string("explicit_slices"),
                        "slices": .array([.object([
                            "path": .string(selectedFile.path),
                            "ranges": .array([.object([
                                "start_line": .int(2),
                                "end_line": .int(2)
                            ])])
                        ])])
                    ]) { _, new in new })
                    try await ask(freshArgs.merging(["selection_mode": .string("current")]) { _, new in new })
                    do {
                        try await ask(freshArgs.merging([
                            "selection_mode": .string("explicit_slices"),
                            "slices": .array([.object([
                                "path": .string("does/not/exist-fresh-slice.swift"),
                                "ranges": .array([.object([
                                    "start_line": .int(1),
                                    "end_line": .int(1)
                                ])])
                            ])])
                        ]) { _, new in new })
                        XCTFail("Expected an unresolvable fresh-chat slice to fail before provider start")
                    } catch {
                        XCTAssertTrue(
                            error.localizedDescription.contains("Invalid explicit Oracle slices"),
                            error.localizedDescription
                        )
                    }

                    let turns = capture.turns
                    XCTAssertEqual(turns.count, 7, "An invalid fresh slice must not reach sendChat")
                    XCTAssertEqual(turns[0].message.systemPrompt, turns[1].message.systemPrompt)
                    XCTAssertEqual(
                        turns[0].message.buildTail(embedSystemPrompt: false),
                        turns[1].message.buildTail(embedSystemPrompt: false),
                        "Omitted selection_mode must remain byte-identical to explicit current"
                    )
                    XCTAssertEqual(
                        turns[0].message.conversationMessages.map(\.content),
                        turns[1].message.conversationMessages.map(\.content)
                    )

                    XCTAssertTrue(turns[2].context.packaging.selection.selectedPaths.isEmpty)
                    XCTAssertTrue(turns[2].context.packaging.selection.slices.isEmpty)
                    XCTAssertEqual(
                        turns[2].context.packaging.gitInclusionOverride,
                        GitInclusion.none
                    )
                    XCTAssertTrue(turns[2].message.fileBlocks.isEmpty)
                    XCTAssertNil(turns[2].message.gitDiff)

                    let sliced = turns[3].message.fileBlocks.joined(separator: "\n")
                    XCTAssertTrue(sliced.contains("slice_middle"), sliced)
                    XCTAssertFalse(sliced.contains("slice_first"), sliced)
                    XCTAssertFalse(sliced.contains("slice_last"), sliced)
                    XCTAssertEqual(
                        turns[3].context.packaging.selection.slices[selectedFile.path],
                        [LineRange(start: 2, end: 2)]
                    )
                    XCTAssertEqual(
                        turns[3].context.packaging.gitInclusionOverride,
                        GitInclusion.none
                    )
                    XCTAssertNil(turns[3].message.gitDiff)

                    XCTAssertTrue(turns[4].context.packaging.selection.selectedPaths.isEmpty)
                    XCTAssertTrue(turns[4].context.packaging.selection.slices.isEmpty)
                    XCTAssertEqual(turns[4].context.packaging.gitInclusionOverride, GitInclusion.none)
                    XCTAssertEqual(turns[4].context.packaging.reviewGitContext, .automaticOnly())
                    XCTAssertTrue(turns[4].message.fileBlocks.isEmpty)
                    XCTAssertNil(turns[4].message.gitDiff)

                    let freshSliced = turns[5].message.fileBlocks.joined(separator: "\n")
                    XCTAssertTrue(freshSliced.contains("slice_middle"), freshSliced)
                    XCTAssertFalse(freshSliced.contains("slice_first"), freshSliced)
                    XCTAssertFalse(freshSliced.contains("slice_last"), freshSliced)
                    XCTAssertEqual(
                        turns[5].context.packaging.selection.slices[selectedFile.path],
                        [LineRange(start: 2, end: 2)]
                    )
                    XCTAssertEqual(turns[5].context.packaging.gitInclusionOverride, GitInclusion.none)
                    XCTAssertEqual(turns[5].context.packaging.reviewGitContext, .automaticOnly())
                    XCTAssertNil(turns[5].message.gitDiff)

                    XCTAssertEqual(turns[6].context.packaging.selection, turns[1].context.packaging.selection)
                    XCTAssertEqual(
                        turns[6].context.packaging.gitInclusionOverride,
                        turns[1].context.packaging.gitInclusionOverride
                    )
                    XCTAssertEqual(
                        turns[6].message.buildTail(embedSystemPrompt: false),
                        turns[1].message.buildTail(embedSystemPrompt: false),
                        "A fresh current send packages exactly like an implicit current send"
                    )

                    XCTAssertEqual(
                        fixture.contextA.window.workspaceManager.selectionRevisionForMCP(
                            workspaceID: workspaceID,
                            tabID: fixture.contextA.tabID
                        ),
                        revisionBefore,
                        "Send-local selection modes never mutate the shared selection revision"
                    )

                    let persisted = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    ).selection
                    XCTAssertEqual(persisted, sharedSelection)

                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        /// Explicit slices that the shared parser would silently drop (path-only, misplaced line keys,
        /// empty ranges) reject the whole send before admission instead of shrinking the context.
        func testAskOracleExplicitSlicesRejectDroppableEntriesBeforeAdmission() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleSliceSelectionCapture()
                do {
                    try await activateWorkspace(fixture.contextA)
                    let selectedFile = fixture.contextA.fileURL
                    try write(
                        "let first = \"slice_first\"\nlet middle = \"slice_middle\"\nlet last = \"slice_last\"\n",
                        to: selectedFile
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: makeFrozenContext(
                            fixture: fixture,
                            selection: StoredSelection(codemapAutoEnabled: false),
                            bindings: []
                        ),
                        fixture: fixture
                    )
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting {
                        _, _, tabContext in
                        let context = try XCTUnwrap(tabContext)
                        capture.record(context.packaging.selection)
                        return [
                            "chat_id": .string(UUID().uuidString),
                            "short_id": .string("slice-validation-capture"),
                            "mode": .string("chat"),
                            "response": .string("captured")
                        ]
                    }

                    let connectionID = endpoint.connectionID
                    func ask(slices: [Value]) async throws {
                        let args: [String: Value] = [
                            "message": .string("Review this exact send-local context."),
                            "new_chat": .bool(true),
                            "model": .string("FreshContextOracle"),
                            "selection_mode": .string("explicit_slices"),
                            "slices": .array(slices)
                        ]
                        _ = try await ServerNetworkManager.withConnectionID(connectionID) {
                            try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: args)
                        }
                    }

                    let path = selectedFile.path
                    let validRanges: Value = .object([
                        "path": .string(path),
                        "ranges": .array([.object(["start_line": .int(2), "end_line": .int(2)])])
                    ])
                    let pathOnly: Value = .object(["path": .string(path)])
                    let rejectedCases: [(name: String, slices: [Value], expected: [String])] = [
                        ("path-only", [pathOnly], [
                            "slices[0] (\(path)): missing ranges or lines; a path alone is rejected"
                        ]),
                        ("misplaced line keys", [.object([
                            "path": .string(path),
                            "start_line": .int(2),
                            "end_line": .int(2)
                        ])], [
                            "slices[0] (\(path)): start_line/end_line must be inside ranges, not on the slice"
                        ]),
                        ("mixed valid and path-only", [validRanges, pathOnly], [
                            "slices[1] (\(path)): missing ranges or lines"
                        ]),
                        ("empty ranges", [.object([
                            "path": .string(path),
                            "ranges": .array([])
                        ])], [
                            "slices[0] (\(path)): ranges must be a non-empty array"
                        ]),
                        ("non-object range item", [.object([
                            "path": .string(path),
                            "ranges": .array([.int(2)])
                        ])], [
                            #"slices[0] (\#(path)): ranges[0] must be an object like {"start_line":10,"end_line":40}"#
                        ]),
                        ("wrong types", [
                            .string(path),
                            .object(["path": .string(path), "ranges": .string("1-2")]),
                            .object(["path": .string(path), "lines": .int(5)])
                        ], [
                            "slices[0]: must be an object | slices[1] (\(path)): ranges must be an array | slices[2] (\(path)): lines must be a string."
                        ])
                    ]
                    // The real admission observable: sendChat is overridden, so chat-session counts
                    // cannot move; a rejected-before-admission send must not reserve an operation.
                    let operationStore = fixture.contextA.window.oracleViewModel.mcpOperationStore
                    @MainActor func operationFootprint() -> Int {
                        operationStore.test_recordCount() + operationStore.test_tombstoneCount()
                    }
                    let footprintBefore = operationFootprint()
                    for rejected in rejectedCases {
                        do {
                            try await ask(slices: rejected.slices)
                            XCTFail("Expected \(rejected.name) slices to be rejected before admission")
                        } catch {
                            let description = error.localizedDescription
                            for fragment in rejected.expected + [
                                "Invalid explicit Oracle slices",
                                #"{"path":"Sources/App.swift","ranges":[{"start_line":10,"end_line":40}]}"#,
                                "No consultation was started."
                            ] {
                                XCTAssertTrue(description.contains(fragment), "\(rejected.name): \(description)")
                            }
                            if rejected.name == "mixed valid and path-only" {
                                XCTAssertFalse(description.contains("slices[0]"), description)
                            }
                        }
                    }
                    XCTAssertTrue(capture.selections.isEmpty, "Rejected slices must not reach sendChat")
                    XCTAssertEqual(
                        operationFootprint(),
                        footprintBefore,
                        "Rejected slices must not reserve an Oracle operation"
                    )

                    // Shape-valid but range-free lines reach the resolver backstop during startup.
                    do {
                        try await ask(slices: [validRanges, .object(["path": .string(path), "lines": .string(",")])])
                        XCTFail("Expected a range-free lines slice to hit the resolver backstop")
                    } catch {
                        XCTAssertTrue(
                            error.localizedDescription.contains(
                                "selection_mode:explicit_slices: one or more slices resolved to no line ranges; no consultation was started"
                            ),
                            error.localizedDescription
                        )
                    }
                    XCTAssertTrue(capture.selections.isEmpty, "Backstopped slices must not reach sendChat")

                    let acceptedSlices: [Value] = [
                        validRanges,
                        .object(["path": .string(path), "lines": .string("2-2")]),
                        .object(["path": .string(path), "ranges": .null, "lines": .string("2-2")]),
                        .object(["path": .string(path), "ranges": .array([]), "lines": .string("2-2")]),
                        .object([
                            "path": .string(path),
                            "ranges": .array([.object(["start_line": .int(2), "end_line": .int(2)])]),
                            "lines": .string("")
                        ])
                    ]
                    let footprintBeforeAccepted = operationFootprint()
                    for slice in acceptedSlices {
                        try await ask(slices: [slice])
                    }
                    XCTAssertGreaterThan(
                        operationFootprint(),
                        footprintBeforeAccepted,
                        "Accepted sends reserve operations, so the footprint assertion above is not vacuous"
                    )
                    XCTAssertEqual(capture.selections.count, acceptedSlices.count)
                    for selection in capture.selections {
                        XCTAssertEqual(selection.slices[path], [LineRange(start: 2, end: 2)])
                    }

                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        /// Plan A1 downstream check: a fresh review with send-local context is packaged by the real
        /// Oracle send path and reaches the provider transport instead of being rejected as empty.
        func testAskOracleFreshReviewSelectionModesReachTransportThroughRealPackaging() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let presetsManager = ModelPresetsManager.shared
                let settings = GlobalSettingsStore.shared
                let previousPresets = presetsManager.presets
                let previousShowPresets = settings.mcpShowModelPresets()
                let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
                let apiSettings = try XCTUnwrap(fixture.contextA.window.promptManager.apiSettingsViewModel)
                let previousClaudeCodeConnected = apiSettings.isClaudeCodeConnected
                defer {
                    presetsManager.presets = previousPresets
                    settings.setMCPShowModelPresets(previousShowPresets, commit: false)
                    settings.setMCPTemporarilyDisablePresets(previousTemporaryDisable, commit: false)
                    apiSettings.isClaudeCodeConnected = previousClaudeCodeConnected
                    fixture.contextA.window.mcpServer.setOraclePostPackagingTransportOverrideForTesting(nil)
                }

                do {
                    try await activateWorkspace(fixture.contextA)
                    let selectedFile = fixture.contextA.fileURL
                    try write(
                        "let fresh_selected_marker = 1\nlet fresh_slice_marker = 2\n",
                        to: selectedFile
                    )
                    let sharedSelection = StoredSelection(
                        selectedPaths: [selectedFile.path],
                        codemapAutoEnabled: false
                    )
                    // Seed the exact tab this test later reads, as an agent's MCP selection write
                    // would. `persistActiveSelection` targets whichever compose tab is active in the
                    // shared window, and a `.runtimeMutation` seed has no canonical-selection fence,
                    // so a stale headless UI flush (token counting, packaging snapshots) could
                    // overwrite it independently of the send-local mode under test.
                    let sharedIdentity = WorkspaceSelectionIdentity(
                        workspaceID: fixture.contextA.workspaceID,
                        tabID: fixture.contextA.tabID
                    )
                    _ = await fixture.contextA.window.selectionCoordinator.persistSelection(
                        sharedSelection,
                        for: sharedIdentity,
                        source: .mcpTabContext,
                        mirrorToUIIfActive: true
                    )
                    try XCTAssertEqual(
                        XCTUnwrap(
                            fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                        ).selection,
                        sharedSelection,
                        "Precondition: the shared selection is seeded on the source tab"
                    )
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: makeFrozenContext(
                            fixture: fixture,
                            selection: sharedSelection,
                            bindings: []
                        ),
                        fixture: fixture
                    )
                    let preset = ModelPreset(
                        name: "FreshContextReviewA",
                        model: .claudeCodeSonnet,
                        supportedModes: SupportedModes(chat: true, plan: true, review: true)
                    )
                    let otherPreset = ModelPreset(
                        name: "FreshContextReviewB",
                        model: .claudeCodeSonnet,
                        supportedModes: SupportedModes(chat: true, plan: true, review: true)
                    )
                    presetsManager.presets = [preset, otherPreset]
                    settings.setMCPShowModelPresets(true, commit: false)
                    settings.setMCPTemporarilyDisablePresets(false, commit: false)
                    apiSettings.isClaudeCodeConnected = true

                    let transport = OracleTransportMessageCapture()
                    fixture.contextA.window.mcpServer.setOraclePostPackagingTransportOverrideForTesting {
                        message, _ in
                        transport.record(message)
                        let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                            continuation.yield(ChatStreamOutput(
                                text: "fresh review response",
                                reasoning: nil,
                                tokens: ChatTokenInfo(),
                                isFinal: true
                            ))
                            continuation.finish()
                        }
                        return (UUID(), stream)
                    }

                    func freshReview(_ extra: [String: Value]) async throws -> Value {
                        var args: [String: Value] = [
                            "message": .string("Review only the context this send supplies."),
                            "mode": .string("review"),
                            "model": .string(preset.id.uuidString),
                            "new_chat": .bool(true)
                        ]
                        args.merge(extra) { _, new in new }
                        return try await ServerNetworkManager.withConnectionID(endpoint.connectionID) {
                            try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: args)
                        }
                    }

                    let revisionBefore = fixture.contextA.window.workspaceManager.selectionRevisionForMCP(
                        workspaceID: fixture.contextA.workspaceID,
                        tabID: fixture.contextA.tabID
                    )
                    let none = try await freshReview(["selection_mode": .string("none")])
                    let sliced = try await freshReview([
                        "selection_mode": .string("explicit_slices"),
                        "slices": .array([.object([
                            "path": .string(selectedFile.path),
                            "ranges": .array([.object([
                                "start_line": .int(2),
                                "end_line": .int(2)
                            ])])
                        ])])
                    ])
                    for result in [none, sliced] {
                        XCTAssertEqual(
                            result.objectValue?["response"]?.stringValue,
                            "fresh review response",
                            ToolOutputFormatter.rawJSONString(result)
                        )
                    }

                    let messages = transport.messages
                    XCTAssertEqual(messages.count, 2, "Both fresh reviews must reach the provider transport")
                    let noneFiles = messages.first?.fileBlocks.joined(separator: "\n") ?? ""
                    XCTAssertFalse(noneFiles.contains("fresh_selected_marker"), noneFiles)
                    XCTAssertFalse(noneFiles.contains("fresh_slice_marker"), noneFiles)
                    XCTAssertNil(messages.first?.gitDiff)
                    let slicedFiles = messages.last?.fileBlocks.joined(separator: "\n") ?? ""
                    XCTAssertTrue(slicedFiles.contains("fresh_slice_marker"), slicedFiles)
                    XCTAssertFalse(slicedFiles.contains("fresh_selected_marker"), slicedFiles)
                    XCTAssertNil(messages.last?.gitDiff)

                    let persisted = try XCTUnwrap(
                        fixture.contextA.window.workspaceManager.composeTab(with: fixture.contextA.tabID)
                    ).selection
                    XCTAssertEqual(persisted, sharedSelection)
                    XCTAssertEqual(
                        fixture.contextA.window.workspaceManager.selectionRevisionForMCP(
                            workspaceID: fixture.contextA.workspaceID,
                            tabID: fixture.contextA.tabID
                        ),
                        revisionBefore,
                        "Send-local fresh reviews must not mutate the shared selection"
                    )

                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleBudgetPreflightRejectsBeforeChatMutationAndUnknownWindowSkipsCheck() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let presetsManager = ModelPresetsManager.shared
                let settings = GlobalSettingsStore.shared
                let previousPresets = presetsManager.presets
                let previousShowPresets = settings.mcpShowModelPresets()
                let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
                let apiSettings = try XCTUnwrap(fixture.contextA.window.promptManager.apiSettingsViewModel)
                let previousClaudeCodeConnected = apiSettings.isClaudeCodeConnected
                defer {
                    presetsManager.presets = previousPresets
                    settings.setMCPShowModelPresets(previousShowPresets, commit: false)
                    settings.setMCPTemporarilyDisablePresets(previousTemporaryDisable, commit: false)
                    apiSettings.isClaudeCodeConnected = previousClaudeCodeConnected
                    fixture.contextA.window.mcpServer.setOracleContextWindowOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer.setOraclePostPackagingTransportOverrideForTesting(nil)
                }

                do {
                    try await activateWorkspace(fixture.contextA)
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: makeFrozenContext(
                            fixture: fixture,
                            selection: StoredSelection(codemapAutoEnabled: false),
                            bindings: []
                        ),
                        fixture: fixture
                    )
                    let preset = ModelPreset(
                        name: "BudgetPreflightOracle",
                        model: .claudeCodeSonnet,
                        supportedModes: SupportedModes(chat: true, plan: true, review: true)
                    )
                    presetsManager.presets = [preset]
                    settings.setMCPShowModelPresets(true, commit: false)
                    settings.setMCPTemporarilyDisablePresets(false, commit: false)
                    apiSettings.isClaudeCodeConnected = true

                    let transport = OracleTransportInvocationCapture()
                    fixture.contextA.window.mcpServer.setOraclePostPackagingTransportOverrideForTesting {
                        _, _ in
                        transport.recordInvocation()
                        let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                            continuation.yield(ChatStreamOutput(
                                text: "budget transport response",
                                reasoning: nil,
                                tokens: ChatTokenInfo(),
                                isFinal: true
                            ))
                            continuation.finish()
                        }
                        return (UUID(), stream)
                    }

                    let oracle = fixture.contextA.window.oracleViewModel
                    let beforeSessions = Dictionary(uniqueKeysWithValues: oracle.sessions.map {
                        ($0.id, $0.effectiveMessageCount)
                    })
                    let beforeMessages = Dictionary(uniqueKeysWithValues: oracle.sessions.map {
                        ($0.id, oracle.messagesSnapshot(for: $0.id))
                    })
                    fixture.contextA.window.mcpServer.setOracleContextWindowOverrideForTesting { _ in 128 }

                    do {
                        _ = try await ServerNetworkManager.withConnectionID(endpoint.connectionID) {
                            try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: [
                                "message": .string("Reject this request before mutating the chat."),
                                "mode": .string("review"),
                                "model": .string(preset.id.uuidString),
                                "new_chat": .bool(true),
                                "max_output_tokens": .int(64)
                            ])
                        }
                        XCTFail("Expected context-budget overflow")
                    } catch let error as ChatToolError {
                        XCTAssertEqual(error.code, .oracleContextOverflow)
                        XCTAssertNotNil(error.details?["largest_contributors"])
                        XCTAssertTrue(error.details?["remedies"]?.contains("selection_mode:none") == true)
                        XCTAssertTrue(
                            error.details?["remedies"]?.contains(
                                "selection_mode:none or explicit_slices on the same chat_id or a fresh chat"
                            ) == true,
                            error.details?["remedies"] ?? ""
                        )
                        XCTAssertTrue(error.message.contains("context window is 128"), error.message)
                    }
                    XCTAssertEqual(transport.invocationCount, 0)
                    XCTAssertEqual(
                        Dictionary(uniqueKeysWithValues: oracle.sessions.map {
                            ($0.id, $0.effectiveMessageCount)
                        }),
                        beforeSessions
                    )
                    for (sessionID, messages) in beforeMessages {
                        XCTAssertEqual(oracle.messagesSnapshot(for: sessionID), messages)
                        XCTAssertFalse(oracle.isSessionStreaming(sessionID))
                    }

                    XCTAssertEqual(
                        AIModelCapabilityMetadata.resolve(for: .claudeCodeSonnet)
                            .windowSource,
                        .providerFallback
                    )
                    XCTAssertEqual(
                        AIModelCapabilityMetadata.resolve(for: .claude5Opus)
                            .windowSource,
                        .exact
                    )
                    XCTAssertEqual(
                        AIModelCapabilityMetadata.safeUsagePercentage(
                            inputTokens: Int.max,
                            contextWindowTokens: 1
                        ),
                        Int.max
                    )

                    fixture.contextA.window.mcpServer
                        .setOracleContextWindowOverrideForTesting(
                            { _ in 128 },
                            source: .providerFallback
                        )
                    let fallbackAccepted = try await ServerNetworkManager
                        .withConnectionID(endpoint.connectionID) {
                            try await fixture.contextA.window.mcpServer
                                .executeAskOracleForTesting(args: [
                                    "message": .string(
                                        "Fallback windows must not hard reject this request."
                                    ),
                                    "mode": .string("review"),
                                    "model": .string(preset.id.uuidString),
                                    "new_chat": .bool(true),
                                    "max_output_tokens": .int(64)
                                ])
                        }
                    XCTAssertEqual(
                        fallbackAccepted.objectValue?["response"]?.stringValue,
                        "budget transport response"
                    )
                    let fallbackUsage = try XCTUnwrap(
                        fallbackAccepted.objectValue?["usage"]?.objectValue
                    )
                    XCTAssertNil(fallbackUsage["context_window"])
                    XCTAssertNil(fallbackUsage["pct"])
                    XCTAssertEqual(
                        fallbackUsage["output_reserve_tokens"]?.intValue,
                        64
                    )
                    XCTAssertEqual(transport.invocationCount, 1)

                    fixture.contextA.window.mcpServer
                        .setOracleContextWindowOverrideForTesting { _ in nil }
                    let accepted = try await ServerNetworkManager.withConnectionID(
                        endpoint.connectionID
                    ) {
                        try await fixture.contextA.window.mcpServer
                            .executeAskOracleForTesting(args: [
                                "message": .string(
                                    "Unknown context windows skip only the overflow gate."
                                ),
                                "mode": .string("review"),
                                "model": .string(preset.id.uuidString),
                                "new_chat": .bool(true),
                                "max_output_tokens": .int(64)
                            ])
                    }
                    XCTAssertEqual(
                        accepted.objectValue?["response"]?.stringValue,
                        "budget transport response"
                    )
                    XCTAssertEqual(transport.invocationCount, 2)

                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleValidatesAndForwardsParallelSessionArgumentsAtServiceBoundary() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let capture = OracleArgsCapture()
                let presetsManager = ModelPresetsManager.shared
                let settings = GlobalSettingsStore.shared
                let previousPresets = presetsManager.presets
                let previousShowPresets = settings.mcpShowModelPresets()
                let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
                defer {
                    presetsManager.presets = previousPresets
                    settings.setMCPShowModelPresets(previousShowPresets, commit: false)
                    settings.setMCPTemporarilyDisablePresets(previousTemporaryDisable, commit: false)
                }
                do {
                    try await activateWorkspace(fixture.contextA)
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: makeFrozenContext(
                            fixture: fixture,
                            selection: StoredSelection(codemapAutoEnabled: false),
                            bindings: []
                        ),
                        fixture: fixture
                    )
                    let singleModel = AIModel.claudeCodeSonnet
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting { args, _, _ in
                        capture.record(args)
                        return [
                            "chat_id": .string(UUID().uuidString),
                            "short_id": .string("argument-capture"),
                            "mode": .string("review"),
                            "response": .string("captured"),
                            "model_source": .string("preset"),
                            "model_id": .string(singleModel.rawValue),
                            "model_name": .string(singleModel.displayName),
                            "ui_model_id": .string(singleModel.rawValue),
                            "ui_model_name": .string(singleModel.displayName)
                        ]
                    }

                    let connectionID = endpoint.connectionID
                    let singleValue = try await ServerNetworkManager.withConnectionID(connectionID) {
                        try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: [
                            "message": .string("Review independently"),
                            "mode": .string("review"),
                            "model": .string("GPT_5_6_Sol_xhigh"),
                            "chat_name": .string("Sol review lane"),
                            "new_chat": .bool(true)
                        ])
                    }
                    let singleWireJSON = ToolOutputFormatter.rawJSONString(singleValue)
                    XCTAssertFalse(singleWireJSON.contains(singleModel.rawValue), singleWireJSON)
                    XCTAssertFalse(singleWireJSON.contains(singleModel.displayName), singleWireJSON)
                    XCTAssertNil(singleValue.objectValue?["model_id"])
                    XCTAssertNil(singleValue.objectValue?["model_name"])
                    XCTAssertNil(singleValue.objectValue?["ui_model_id"])
                    XCTAssertNil(singleValue.objectValue?["ui_model_name"])
                    XCTAssertEqual(capture.args?["model"]?.stringValue, "GPT_5_6_Sol_xhigh")
                    XCTAssertEqual(capture.args?["chat_name"]?.stringValue, "Sol review lane")
                    XCTAssertEqual(capture.args?["new_chat"]?.boolValue, true)
                    XCTAssertEqual(capture.callCount, 1)

                    do {
                        _ = try await ServerNetworkManager.withConnectionID(connectionID) {
                            try await fixture.contextA.window.mcpServer
                                .executeOracleChatLogForTesting(args: ["part": .int(7)])
                        }
                        XCTFail("Expected a non-string chat-log part to fail")
                    } catch {
                        XCTAssertTrue(
                            error.localizedDescription.contains("part must be a string"),
                            error.localizedDescription
                        )
                    }

                    let firstPreset = ModelPreset(
                        name: "KnowledgeDuelA",
                        model: .claude4Sonnet,
                        supportedModes: SupportedModes(chat: true, plan: true, review: true)
                    )
                    let secondPreset = ModelPreset(
                        name: "KnowledgeDuelB",
                        model: .geminiFlash25,
                        supportedModes: SupportedModes(chat: true, plan: true, review: true)
                    )
                    presetsManager.presets = [firstPreset, secondPreset]
                    settings.setMCPShowModelPresets(true, commit: false)
                    settings.setMCPTemporarilyDisablePresets(false, commit: false)

                    let modelsResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.oracleUtils,
                        arguments: ["op": "models"],
                        timeoutSeconds: 20
                    )
                    XCTAssertFalse(modelsResponse.rawJSON.contains("\"isError\":true"), modelsResponse.rawJSON)
                    XCTAssertTrue(modelsResponse.rawJSON.contains(firstPreset.name), modelsResponse.rawJSON)
                    XCTAssertTrue(modelsResponse.rawJSON.contains(secondPreset.name), modelsResponse.rawJSON)
                    XCTAssertTrue(modelsResponse.rawJSON.contains("context_window: 200000"), modelsResponse.rawJSON)
                    XCTAssertTrue(modelsResponse.rawJSON.contains("context_window: 1000000"), modelsResponse.rawJSON)
                    XCTAssertFalse(modelsResponse.rawJSON.contains(firstPreset.model.rawValue), modelsResponse.rawJSON)
                    XCTAssertFalse(modelsResponse.rawJSON.contains(firstPreset.model.displayName), modelsResponse.rawJSON)
                    XCTAssertFalse(modelsResponse.rawJSON.contains(secondPreset.model.rawValue), modelsResponse.rawJSON)
                    XCTAssertFalse(modelsResponse.rawJSON.contains(secondPreset.model.displayName), modelsResponse.rawJSON)

                    let disabledModelsResponse = MCPOracleToolService.modelPresetDiagnosticLines(
                        usageState: .disabledByToggle,
                        configuredPresets: [firstPreset, secondPreset]
                    ).joined(separator: "\n")
                    XCTAssertTrue(
                        disabledModelsResponse.contains("Model preset state: disabled for MCP"),
                        disabledModelsResponse
                    )
                    XCTAssertTrue(
                        disabledModelsResponse.contains("NOT selectable"),
                        disabledModelsResponse
                    )
                    XCTAssertTrue(disabledModelsResponse.contains(firstPreset.name))
                    XCTAssertTrue(disabledModelsResponse.contains(firstPreset.id.uuidString))
                    XCTAssertTrue(disabledModelsResponse.contains(secondPreset.name))
                    XCTAssertTrue(disabledModelsResponse.contains(secondPreset.id.uuidString))
                    XCTAssertTrue(
                        disabledModelsResponse.contains("Use Oracle Model Presets for MCP"),
                        disabledModelsResponse
                    )

                    settings.setMCPShowModelPresets(false, commit: false)
                    do {
                        _ = try await ServerNetworkManager.withConnectionID(connectionID) {
                            try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: [
                                "message": .string("Use the exact disabled preset"),
                                "mode": .string("review"),
                                "model": .string(firstPreset.id.uuidString),
                                "new_chat": .bool(true)
                            ])
                        }
                        XCTFail("Expected an explicitly requested disabled preset to fail closed")
                    } catch {
                        let message = error.localizedDescription
                        XCTAssertTrue(message.contains(firstPreset.name), message)
                        XCTAssertTrue(message.contains("exists but is not selectable"), message)
                        XCTAssertTrue(message.contains("Use Oracle Model Presets for MCP"), message)
                        XCTAssertTrue(message.contains("It was not used"), message)
                    }

                    settings.setMCPShowModelPresets(true, commit: false)
                    settings.setMCPTemporarilyDisablePresets(true, commit: false)
                    let hiddenModelsResponse = MCPOracleToolService.modelPresetDiagnosticLines(
                        usageState: .temporarilyHidden,
                        configuredPresets: [firstPreset, secondPreset]
                    ).joined(separator: "\n")
                    XCTAssertTrue(
                        hiddenModelsResponse.contains("temporarily hidden by Setup Wizard"),
                        hiddenModelsResponse
                    )
                    XCTAssertTrue(hiddenModelsResponse.contains(firstPreset.name))
                    XCTAssertTrue(hiddenModelsResponse.contains(secondPreset.name))
                    XCTAssertTrue(hiddenModelsResponse.contains("Show presets"))

                    settings.setMCPTemporarilyDisablePresets(false, commit: false)

                    let sessionsResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.oracleUtils,
                        arguments: ["op": "sessions"],
                        timeoutSeconds: 20
                    )
                    XCTAssertTrue(sessionsResponse.rawJSON.contains("\"isError\":true"), sessionsResponse.rawJSON)
                    XCTAssertTrue(sessionsResponse.rawJSON.contains("unavailable in Agent Mode"), sessionsResponse.rawJSON)

                    var listedRetryUUID: String?
                    for chatName in [String?.none, "Knowledge Duel A"] {
                        var ambiguousArgs: [String: Value] = [
                            "message": .string("Ask both named Oracles"),
                            "mode": .string("review"),
                            "new_chat": .bool(true)
                        ]
                        if let chatName {
                            ambiguousArgs["chat_name"] = .string(chatName)
                        }
                        do {
                            _ = try await ServerNetworkManager.withConnectionID(connectionID) {
                                try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(
                                    args: ambiguousArgs
                                )
                            }
                            XCTFail("Expected a new Oracle lane without model to fail closed")
                        } catch {
                            let message = error.localizedDescription
                            XCTAssertTrue(message.contains("oracle_model_required: "), message)
                            XCTAssertTrue(message.contains("requires an explicit model"), message)
                            XCTAssertTrue(message.contains("'review' mode (2 compatible configured presets)"), message)
                            XCTAssertTrue(message.contains("pre-provider validation failure"), message)
                            XCTAssertTrue(
                                message.contains("Retry the same call with model set to exactly one of these preset UUIDs"),
                                message
                            )
                            XCTAssertTrue(message.contains("This list is current; no oracle_utils call is needed"), message)
                            XCTAssertTrue(message.contains("chat_name only labels"), message)
                            XCTAssertTrue(message.contains(firstPreset.name), message)
                            XCTAssertTrue(message.contains(firstPreset.id.uuidString), message)
                            XCTAssertTrue(message.contains(secondPreset.name), message)
                            XCTAssertTrue(message.contains(secondPreset.id.uuidString), message)
                            let firstRange = try XCTUnwrap(message.range(of: firstPreset.id.uuidString))
                            let secondRange = try XCTUnwrap(message.range(of: secondPreset.id.uuidString))
                            XCTAssertLessThan(
                                firstRange.lowerBound,
                                secondRange.lowerBound,
                                "Presets keep the deterministic name order"
                            )
                            let listed = try XCTUnwrap(message.range(of: "preset UUIDs: "))
                            let retryUUID = message[listed.upperBound...]
                                .split(separator: "(", maxSplits: 1)
                                .last?
                                .prefix(36)
                            listedRetryUUID = retryUUID.map(String.init)
                        }
                    }
                    XCTAssertEqual(capture.callCount, 1, "Ambiguous named lanes must fail before sendChat")

                    // The rejection alone is enough to retry: reuse a UUID copied from its text.
                    let retryUUID = try XCTUnwrap(listedRetryUUID)
                    XCTAssertEqual(retryUUID, firstPreset.id.uuidString)
                    _ = try await ServerNetworkManager.withConnectionID(connectionID) {
                        try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: [
                            "message": .string("Ask both named Oracles"),
                            "mode": .string("review"),
                            "model": .string(retryUUID),
                            "new_chat": .bool(true)
                        ])
                    }
                    XCTAssertEqual(capture.callCount, 2, "A UUID listed by the rejection retries directly")
                    XCTAssertEqual(capture.args?["model"]?.stringValue, retryUUID)

                    let invalidCases: [([String: Value], String)] = [
                        (["message": .string("x"), "mode": .int(7)], "mode must be a string"),
                        (["message": .string("x"), "response_mode": .int(7)], "response_mode must be a string"),
                        (["message": .string("x"), "chat_id": .int(7)], "chat_id must be a string"),
                        (["message": .string("x"), "model": .string("  ")], "model cannot be empty"),
                        (["message": .string("x"), "chat_name": .string("Lane")], "chat_name is only valid"),
                        (["message": .string("x"), "selection_mode": .int(1)], "selection_mode must be a string"),
                        (["message": .string("x"), "selection_mode": .string("explicit_slices")], "requires an explicit conversation target"),
                        (["message": .string("x"), "selection_mode": .string("none")], "requires an explicit conversation target"),
                        (["message": .string("x"), "slices": .array([])], "slices is only valid"),
                        (["message": .string("x"), "max_output_tokens": .int(0)], "must be a positive integer"),
                        ([
                            "message": .string("x"),
                            "selection_mode": .string("explicit_slices"),
                            "new_chat": .bool(true),
                            "model": .string(firstPreset.id.uuidString)
                        ], "requires a non-empty slices array"),
                        ([
                            "message": .string("x"),
                            "selection_mode": .string("none"),
                            "new_chat": .bool(true),
                            "model": .string(firstPreset.id.uuidString),
                            "slices": .array([.object(["path": .string("a.swift")])])
                        ], "slices is only valid"),
                        ([
                            "message": .string("x"),
                            "chat_id": .string("abc123"),
                            "new_chat": .bool(true)
                        ], "cannot be used together")
                    ]
                    for (args, expectedMessage) in invalidCases {
                        do {
                            _ = try await ServerNetworkManager.withConnectionID(connectionID) {
                                try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: args)
                            }
                            XCTFail("Expected invalid ask_oracle arguments: \(args)")
                        } catch {
                            XCTAssertTrue(error.localizedDescription.contains(expectedMessage), error.localizedDescription)
                        }
                    }

                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                } catch {
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleBatchConsultationsPreserveOrderAndBlinding() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let presetsManager = ModelPresetsManager.shared
                let settings = GlobalSettingsStore.shared
                let previousPresets = presetsManager.presets
                let previousShowPresets = settings.mcpShowModelPresets()
                let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
                defer {
                    presetsManager.presets = previousPresets
                    settings.setMCPShowModelPresets(previousShowPresets, commit: false)
                    settings.setMCPTemporarilyDisablePresets(previousTemporaryDisable, commit: false)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                }
                do {
                    try await activateWorkspace(fixture.contextA)
                    let endpoint = try fixture.endpointA()
                    let frozenContext = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(codemapAutoEnabled: false),
                        bindings: [],
                        activeAgentSessionID: nil
                    )
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: frozenContext,
                        fixture: fixture
                    )
                    try activateRunOnlyBatchOwner(context: frozenContext, fixture: fixture)
                    let first = ModelPreset(
                        name: "BatchOracleA",
                        model: .claudeCodeSonnet,
                        supportedModes: SupportedModes(chat: true, plan: true, review: true)
                    )
                    let second = ModelPreset(
                        name: "BatchOracleB",
                        model: .claudeCodeOpus,
                        supportedModes: SupportedModes(chat: true, plan: true, review: true)
                    )
                    presetsManager.presets = [first, second]
                    settings.setMCPShowModelPresets(true, commit: false)
                    settings.setMCPTemporarilyDisablePresets(false, commit: false)

                    var seenModels: [String] = []
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting { args, _, _ in
                        let model = args["model"]?.stringValue ?? ""
                        let selectedPreset = model == first.id.uuidString ? first : second
                        seenModels.append(model)
                        let rawResult: [String: Value] = [
                            "chat_id": .string("chat-\(model)"),
                            "short_id": .string("short-\(model)"),
                            "mode": .string("chat"),
                            "response": .string("answer for \(model)"),
                            "model_source": .string("preset"),
                            "model_preset_id": .string(selectedPreset.id.uuidString),
                            "model_preset_name": .string(selectedPreset.name),
                            "model_selection": .string("explicit"),
                            "model_id": .string(selectedPreset.model.rawValue),
                            "model_name": .string(selectedPreset.model.displayName),
                            "ui_model_id": .string(selectedPreset.model.rawValue),
                            "ui_model_name": .string(selectedPreset.model.displayName),
                            "legacy_shape": .object([
                                "model_id": .string(selectedPreset.model.rawValue),
                                "model_name": .string(selectedPreset.model.displayName),
                                "ui_model_id": .string(selectedPreset.model.rawValue),
                                "ui_model_name": .string(selectedPreset.model.displayName)
                            ]),
                            "usage": .object([
                                "input_tokens": .int(12),
                                "source": .string("app_estimate")
                            ])
                        ]
                        return rawResult
                    }

                    let value = try await ServerNetworkManager.withConnectionID(endpoint.connectionID) {
                        try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: [
                            "consultations": .array([
                                .object([
                                    "message": .string("Lane A"),
                                    "model": .string(first.name),
                                    "chat_name": .string("A")
                                ]),
                                .object([
                                    "message": .string("Lane B"),
                                    "model": .string(second.id.uuidString),
                                    "chat_name": .string("B")
                                ])
                            ])
                        ])
                    }
                    let results = try XCTUnwrap(value.objectValue?["results"]?.arrayValue)
                    XCTAssertEqual(results.count, 2)
                    XCTAssertEqual(results[0].objectValue?["ok"]?.boolValue, true)
                    XCTAssertEqual(results[1].objectValue?["ok"]?.boolValue, true)
                    XCTAssertEqual(results[0].objectValue?["index"]?.intValue, 0)
                    XCTAssertEqual(results[1].objectValue?["index"]?.intValue, 1)
                    XCTAssertEqual(results[0].objectValue?["chat_id"]?.stringValue, "chat-\(first.id.uuidString)")
                    XCTAssertEqual(results[1].objectValue?["chat_id"]?.stringValue, "chat-\(second.id.uuidString)")
                    XCTAssertEqual(results[0].objectValue?["model_preset_name"]?.stringValue, first.name)
                    XCTAssertEqual(results[1].objectValue?["model_preset_id"]?.stringValue, second.id.uuidString)
                    XCTAssertNil(results[0].objectValue?["model_id"])
                    XCTAssertNil(results[0].objectValue?["model_name"])
                    XCTAssertNil(results[0].objectValue?["ui_model_id"])
                    XCTAssertNil(results[0].objectValue?["ui_model_name"])
                    let nestedLegacy = results[0].objectValue?["legacy_shape"]?.objectValue
                    XCTAssertNil(nestedLegacy?["model_id"])
                    XCTAssertNil(nestedLegacy?["model_name"])
                    XCTAssertNil(nestedLegacy?["ui_model_id"])
                    XCTAssertNil(nestedLegacy?["ui_model_name"])
                    XCTAssertEqual(seenModels, [first.id.uuidString, second.id.uuidString])
                    let agentSession = fixture.contextA.window.agentModeViewModel.session(
                        for: fixture.contextA.tabID
                    )
                    let capturedUISidecars = Array(
                        agentSession.oracleUIIdentitySidecarByChatID.values
                    )
                    XCTAssertEqual(capturedUISidecars.count, 2)
                    let wireJSON = ToolOutputFormatter.rawJSONString(value)
                    for preset in [first, second] {
                        XCTAssertTrue(capturedUISidecars.contains {
                            $0.contains(preset.model.rawValue)
                                && $0.contains(preset.model.displayName)
                        })
                        XCTAssertFalse(wireJSON.contains(preset.model.rawValue), wireJSON)
                        XCTAssertFalse(wireJSON.contains(preset.model.displayName), wireJSON)
                    }

                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleBatchValidationRejectsMixedParamsAndRequireDistinct() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let presetsManager = ModelPresetsManager.shared
                let settings = GlobalSettingsStore.shared
                let previousPresets = presetsManager.presets
                let previousShowPresets = settings.mcpShowModelPresets()
                let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
                var sendCount = 0
                defer {
                    presetsManager.presets = previousPresets
                    settings.setMCPShowModelPresets(previousShowPresets, commit: false)
                    settings.setMCPTemporarilyDisablePresets(previousTemporaryDisable, commit: false)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                }
                do {
                    try await activateWorkspace(fixture.contextA)
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: makeFrozenContext(
                            fixture: fixture,
                            selection: StoredSelection(codemapAutoEnabled: false),
                            bindings: []
                        ),
                        fixture: fixture
                    )
                    let preset = ModelPreset(
                        name: "DistinctOracle",
                        model: .claudeCodeSonnet,
                        supportedModes: SupportedModes(chat: true, plan: true, review: true)
                    )
                    presetsManager.presets = [preset]
                    settings.setMCPShowModelPresets(true, commit: false)
                    settings.setMCPTemporarilyDisablePresets(false, commit: false)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting { _, _, _ in
                        sendCount += 1
                        return [
                            "chat_id": .string("should-not-run"),
                            "mode": .string("chat"),
                            "response": .string("nope")
                        ]
                    }

                    do {
                        _ = try await ServerNetworkManager.withConnectionID(endpoint.connectionID) {
                            try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: [
                                "message": .string("single"),
                                "consultations": .array([
                                    .object([
                                        "message": .string("batch"),
                                        "model": .string(preset.name)
                                    ])
                                ])
                            ])
                        }
                        XCTFail("Expected mixed params rejection")
                    } catch {
                        XCTAssertTrue(
                            error.localizedDescription.contains("mutually exclusive"),
                            error.localizedDescription
                        )
                    }

                    do {
                        _ = try await ServerNetworkManager.withConnectionID(endpoint.connectionID) {
                            try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: [
                                "require_distinct": .bool(true),
                                "consultations": .array([
                                    .object([
                                        "message": .string("one"),
                                        "model": .string(preset.name)
                                    ]),
                                    .object([
                                        "message": .string("two"),
                                        "model": .string(preset.id.uuidString)
                                    ])
                                ])
                            ])
                        }
                        XCTFail("Expected require_distinct rejection")
                    } catch {
                        XCTAssertTrue(
                            error.localizedDescription.contains("require_distinct"),
                            error.localizedDescription
                        )
                        XCTAssertTrue(
                            error.localizedDescription.contains("No lanes were started"),
                            error.localizedDescription
                        )
                    }
                    for (field, value) in [
                        ("mode", Value.int(7)),
                        ("response_mode", Value.bool(true))
                    ] {
                        do {
                            _ = try await ServerNetworkManager.withConnectionID(
                                endpoint.connectionID
                            ) {
                                try await fixture.contextA.window.mcpServer
                                    .executeAskOracleForTesting(args: [
                                        "consultations": .array([
                                            .object([
                                                "message": .string("invalid type"),
                                                "model": .string(preset.name),
                                                field: value
                                            ])
                                        ])
                                    ])
                            }
                            XCTFail("Expected consultations[0].\(field) type rejection")
                        } catch {
                            XCTAssertTrue(
                                error.localizedDescription.contains(
                                    "consultations[0].\(field) must be a string"
                                ),
                                error.localizedDescription
                            )
                        }
                    }
                    XCTAssertEqual(sendCount, 0)

                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleTrimmedExportFailureReturnsPaidResponseInline() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let presetsManager = ModelPresetsManager.shared
                let settings = GlobalSettingsStore.shared
                let previousPresets = presetsManager.presets
                let previousShowPresets = settings.mcpShowModelPresets()
                let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
                defer {
                    presetsManager.presets = previousPresets
                    settings.setMCPShowModelPresets(previousShowPresets, commit: false)
                    settings.setMCPTemporarilyDisablePresets(
                        previousTemporaryDisable,
                        commit: false
                    )
                    fixture.contextA.window.mcpServer
                        .setOracleChatSendOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer
                        .setOracleExportOverrideForTesting(nil)
                }

                do {
                    try await activateWorkspace(fixture.contextA)
                    let endpoint = try fixture.endpointA()
                    let frozenContext = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(codemapAutoEnabled: false),
                        bindings: [],
                        activeAgentSessionID: nil
                    )
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: frozenContext,
                        fixture: fixture
                    )
                    try activateRunOnlyBatchOwner(context: frozenContext, fixture: fixture)
                    let preset = ModelPreset(
                        name: "ExportFailureOracle",
                        model: .claudeCodeSonnet,
                        supportedModes: SupportedModes(
                            chat: true,
                            plan: true,
                            review: true
                        )
                    )
                    presetsManager.presets = [preset]
                    settings.setMCPShowModelPresets(true, commit: false)
                    settings.setMCPTemporarilyDisablePresets(false, commit: false)

                    fixture.contextA.window.mcpServer
                        .setOracleChatSendOverrideForTesting { _, _, _ in
                            [
                                "chat_id": .string("paid-chat"),
                                "mode": .string("chat"),
                                "response": .string("paid response must survive")
                            ]
                        }
                    fixture.contextA.window.mcpServer
                        .setOracleExportOverrideForTesting { _ in
                            throw NSError(
                                domain: "OracleExportFailure",
                                code: 91,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "disk unavailable"
                                ]
                            )
                        }

                    let value = try await ServerNetworkManager.withConnectionID(
                        endpoint.connectionID
                    ) {
                        try await fixture.contextA.window.mcpServer
                            .executeAskOracleForTesting(args: [
                                "consultations": .array([
                                    .object([
                                        "message": .string("Return the paid answer"),
                                        "model": .string(preset.id.uuidString),
                                        "response_mode": .string("tail")
                                    ])
                                ])
                            ])
                    }

                    let item = try XCTUnwrap(
                        value.objectValue?["results"]?.arrayValue?.first?
                            .objectValue
                    )
                    XCTAssertEqual(item["ok"]?.boolValue, true)
                    XCTAssertEqual(
                        item["response"]?.stringValue,
                        "paid response must survive"
                    )
                    XCTAssertEqual(item["chat_id"]?.stringValue, "paid-chat")
                    XCTAssertEqual(item["response_mode"]?.stringValue, "full")
                    XCTAssertTrue(
                        item["export_failed_warning"]?.stringValue?
                            .contains("returning the full response inline") == true
                    )
                    XCTAssertNil(item["excerpt"])
                    XCTAssertNil(item["export_path"])

                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleBatchTrimmedExportUsesFrozenSourceWorkspaceWhenVisibleWorkspaceDiffers() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let presetsManager = ModelPresetsManager.shared
                let settings = GlobalSettingsStore.shared
                let previousPresets = presetsManager.presets
                let previousShowPresets = settings.mcpShowModelPresets()
                let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
                var alternateWorkspaceID: UUID?
                defer {
                    presetsManager.presets = previousPresets
                    settings.setMCPShowModelPresets(previousShowPresets, commit: false)
                    settings.setMCPTemporarilyDisablePresets(
                        previousTemporaryDisable,
                        commit: false
                    )
                    fixture.contextA.window.mcpServer
                        .setOracleChatSendOverrideForTesting(nil)
                    fixture.contextA.window.mcpServer
                        .setOracleExportOverrideForTesting(nil)
                    if let source = fixture.contextA.window.workspaceManager.workspace(
                        withID: fixture.contextA.workspaceID
                    ) {
                        fixture.contextA.window.workspaceManager.activeWorkspace = source
                    }
                    if let alternateWorkspaceID {
                        fixture.contextA.window.workspaceManager.workspaces.removeAll {
                            $0.id == alternateWorkspaceID
                        }
                    }
                }

                do {
                    try await activateWorkspace(fixture.contextA)
                    let endpoint = try fixture.endpointA()
                    let frozenContext = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(codemapAutoEnabled: false),
                        bindings: [],
                        activeAgentSessionID: nil
                    )
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: frozenContext,
                        fixture: fixture
                    )
                    try activateRunOnlyBatchOwner(
                        context: frozenContext,
                        fixture: fixture
                    )
                    let preset = ModelPreset(
                        name: "FrozenExportWorkspaceOracle",
                        model: .claudeCodeSonnet,
                        supportedModes: SupportedModes(chat: true, plan: true, review: true)
                    )
                    presetsManager.presets = [preset]
                    settings.setMCPShowModelPresets(true, commit: false)
                    settings.setMCPTemporarilyDisablePresets(false, commit: false)

                    var alternate = WorkspaceModel(
                        name: "Visible Alternate Export Workspace",
                        repoPaths: [fixture.contextB.rootURL.path]
                    )
                    alternate.isEphemeral = true
                    alternate.composeTabs = [ComposeTabState(id: UUID())]
                    alternate.activeComposeTabID = alternate.composeTabs.first?.id
                    alternateWorkspaceID = alternate.id
                    fixture.contextA.window.workspaceManager.workspaces.append(alternate)
                    fixture.contextA.window.workspaceManager.activeWorkspace = alternate

                    fixture.contextA.window.mcpServer
                        .setOracleChatSendOverrideForTesting { _, _, _ in
                            [
                                "chat_id": .string("frozen-export-chat"),
                                "mode": .string("chat"),
                                "response": .string(
                                    String(repeating: "frozen response ", count: 200)
                                )
                            ]
                        }
                    let exportCapture = OracleExportDestinationCapture()
                    fixture.contextA.window.mcpServer
                        .setOracleExportOverrideForTesting { request in
                            exportCapture.record(request)
                            return OracleExportFile(
                                path: "/tmp/frozen-export.md",
                                instruction: "read frozen export"
                            )
                        }

                    let value = try await ServerNetworkManager.withConnectionID(
                        endpoint.connectionID
                    ) {
                        try await fixture.contextA.window.mcpServer
                            .executeAskOracleForTesting(args: [
                                "consultations": .array([
                                    .object([
                                        "message": .string("Trim against the frozen workspace"),
                                        "model": .string(preset.id.uuidString),
                                        "response_mode": .string("tail")
                                    ])
                                ])
                            ])
                    }
                    let item = try XCTUnwrap(
                        value.objectValue?["results"]?.arrayValue?.first?.objectValue
                    )
                    XCTAssertEqual(item["ok"]?.boolValue, true)
                    XCTAssertEqual(item["export_path"]?.stringValue, "/tmp/frozen-export.md")
                    let destination = try XCTUnwrap(exportCapture.destinations.first)
                    XCTAssertEqual(destination.workspaceID, fixture.contextA.workspaceID)
                    XCTAssertEqual(destination.tabID, fixture.contextA.tabID)
                    XCTAssertEqual(
                        destination.primaryRootPath,
                        fixture.contextA.rootURL.standardizedFileURL.path
                    )
                    XCTAssertNotEqual(destination.workspaceID, alternate.id)

                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleBatchQueuedStartupSurvivesConnectionRemovalWithCapturedSource() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let presetsManager = ModelPresetsManager.shared
                let settings = GlobalSettingsStore.shared
                let apiSettings = try XCTUnwrap(
                    fixture.contextA.window.promptManager.apiSettingsViewModel
                )
                let previousPresets = presetsManager.presets
                let previousShowPresets = settings.mcpShowModelPresets()
                let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
                let previousClaudeCodeConnected = apiSettings.isClaudeCodeConnected
                defer {
                    presetsManager.presets = previousPresets
                    settings.setMCPShowModelPresets(previousShowPresets, commit: false)
                    settings.setMCPTemporarilyDisablePresets(previousTemporaryDisable, commit: false)
                    apiSettings.isClaudeCodeConnected = previousClaudeCodeConnected
                    fixture.contextA.window.mcpServer
                        .setBeforeAskOraclePreparationForTesting(nil)
                    fixture.contextA.window.mcpServer
                        .setOraclePostPackagingTransportOverrideForTesting(nil)
                }
                do {
                    try await activateWorkspace(fixture.contextA)
                    let originatingEndpoint = try fixture.endpointA()
                    let recoveryEndpoint = try fixture.endpointB()
                    let frozenContext = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(
                            selectedPaths: [fixture.contextA.fileURL.path],
                            codemapAutoEnabled: false
                        ),
                        bindings: [],
                        activeAgentSessionID: nil
                    )
                    try await configureAgentModeEndpoint(
                        originatingEndpoint,
                        context: frozenContext,
                        fixture: fixture
                    )
                    try activateRunOnlyBatchOwner(
                        context: frozenContext,
                        fixture: fixture
                    )
                    let preset = ModelPreset(
                        name: "ConnectionIndependentBatchOracle",
                        model: .claudeCodeSonnet,
                        supportedModes: SupportedModes(chat: true, plan: true, review: true)
                    )
                    presetsManager.presets = [preset]
                    settings.setMCPShowModelPresets(true, commit: false)
                    settings.setMCPTemporarilyDisablePresets(false, commit: false)
                    apiSettings.isClaudeCodeConnected = true

                    let gate = OracleWorktreeGate()
                    fixture.contextA.window.mcpServer
                        .setBeforeAskOraclePreparationForTesting {
                            await gate.markStartedAndWaitForRelease()
                        }
                    let transport = OracleTransportInvocationCapture()
                    fixture.contextA.window.mcpServer
                        .setOraclePostPackagingTransportOverrideForTesting { message, model in
                            transport.record(message: message, model: model)
                            let stream = AsyncThrowingStream<ChatStreamOutput, Error> {
                                continuation in
                                continuation.yield(ChatStreamOutput(
                                    text: "connection-independent answer",
                                    reasoning: nil,
                                    tokens: ChatTokenInfo(),
                                    isFinal: true
                                ))
                                continuation.finish()
                            }
                            return (UUID(), stream)
                        }

                    let initial = try await ServerNetworkManager.withConnectionID(
                        originatingEndpoint.connectionID
                    ) {
                        try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: [
                            "consultations": .array([
                                .object([
                                    "message": .string("Use the frozen source after disconnect"),
                                    "model": .string(preset.id.uuidString)
                                ])
                            ]),
                            "timeout_seconds": .int(0)
                        ])
                    }
                    let receipt = try XCTUnwrap(
                        initial.objectValue?["results"]?.arrayValue?.first?.objectValue
                    )
                    let operationID = try XCTUnwrap(
                        receipt["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                    )
                    XCTAssertEqual(receipt["index"]?.intValue, 0)
                    let didStart = await gate.waitUntilStarted()
                    XCTAssertTrue(didStart)

                    originatingEndpoint.client.close()
                    await originatingEndpoint.connectionManager.stop()
                    await fixture.networkManager.debugRemoveConnection(
                        originatingEndpoint.connectionID
                    )
                    await fixture.networkManager.debugClearPersistedRoutingState(
                        for: originatingEndpoint.clientName
                    )
                    fixture.contextA.window.mcpServer.removeTabContext(
                        forConnectionID: originatingEndpoint.connectionID,
                        clientName: originatingEndpoint.clientName,
                        windowID: nil,
                        runID: nil
                    )

                    try await configureAgentModeEndpoint(
                        recoveryEndpoint,
                        context: frozenContext,
                        fixture: fixture
                    )
                    await gate.release()

                    let collected = try await ServerNetworkManager.withConnectionID(
                        recoveryEndpoint.connectionID
                    ) {
                        try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: [
                            "op": .string("wait"),
                            "operation_ids": .array([.string(operationID.uuidString)])
                        ])
                    }
                    let result = try XCTUnwrap(
                        collected.objectValue?["results"]?.arrayValue?.first?.objectValue
                    )
                    XCTAssertEqual(result["ok"]?.boolValue, true)
                    XCTAssertEqual(
                        result["response"]?.stringValue,
                        "connection-independent answer"
                    )
                    XCTAssertEqual(transport.invocationCount, 1)
                    XCTAssertEqual(transport.models, [preset.model])
                    let packagedFiles = try XCTUnwrap(transport.messages.first)
                        .fileBlocks.joined(separator: "\n")
                    XCTAssertTrue(
                        packagedFiles.contains(fixture.contextA.sentinel),
                        packagedFiles
                    )

                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAgentRunResponseModeReplayPreservesWireRecoveryAndSingleMutation() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let window = fixture.contextA.window
                let apiSettings = try XCTUnwrap(window.promptManager.apiSettingsViewModel)
                let previousClaudeCodeConnected = apiSettings.isClaudeCodeConnected
                var childSessionID: UUID?
                defer {
                    window.mcpServer.setAgentRunDispatchOverrideForTesting(nil)
                    apiSettings.isClaudeCodeConnected = previousClaudeCodeConnected
                }

                do {
                    try await activateWorkspace(fixture.contextA)
                    let endpoint = try fixture.endpointA()
                    let frozenContext = makeFrozenContext(
                        fixture: fixture,
                        selection: StoredSelection(codemapAutoEnabled: false),
                        bindings: [],
                        activeAgentSessionID: nil
                    )
                    _ = try await endpoint.callTool(
                        name: "bind_context",
                        arguments: [
                            "op": "bind",
                            "context_id": frozenContext.tabID.uuidString
                        ]
                    )
                    await fixture.networkManager.debugSetAdditionalTools(
                        for: endpoint.connectionID,
                        additionalTools: [MCPWindowToolName.agentRun]
                    )
                    window.mcpServer.installFrozenTabContext(
                        clientID: endpoint.connectionID.uuidString,
                        clientName: endpoint.clientName,
                        context: frozenContext
                    )
                    apiSettings.isClaudeCodeConnected = true

                    let body = "PUBLIC_AGENT_RUN_RESULT\n"
                        + String(repeating: "z", count: 2100)
                        + "\nWIRE_RECOVERY_SENTINEL"
                    var dispatchCount = 0
                    window.mcpServer.setAgentRunDispatchOverrideForTesting {
                        _, tabID, _, _, viewModel in
                        dispatchCount += 1
                        let runID = UUID()
                        let session = viewModel.session(for: tabID)
                        session.runID = runID
                        session.runState = .completed
                        session.mcpFollowUpRunPending = false
                        session.items = [.assistant(body, sequenceIndex: 0)]
                        return .startedRun
                    }

                    let tools = await window.mcpServer.windowMCPTools
                    let agentRun = try XCTUnwrap(
                        tools.first { $0.name == MCPWindowToolName.agentRun }
                    )
                    let requestID = UUID().uuidString
                    let baseArgs: [String: Value] = [
                        "op": .string("start"),
                        "message": .string("Return a terminal public-boundary result."),
                        "model_id": .string("claudeCode:sonnet"),
                        "detach": .bool(false),
                        "timeout": .int(0),
                        "request_id": .string(requestID)
                    ]

                    var tailArgs = baseArgs
                    tailArgs["response_mode"] = .string("tail")
                    let tailValue = try await ServerNetworkManager.withConnectionID(
                        endpoint.connectionID
                    ) {
                        try await agentRun(tailArgs)
                    }
                    let tail = try XCTUnwrap(tailValue.objectValue)
                    childSessionID = tail["session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                    let tailText = try XCTUnwrap(tail["assistant_text"]?.stringValue)
                    XCTAssertEqual(
                        tailText.count,
                        OracleResponseMode.tailExcerptCharacterBudget
                    )
                    let tailPresentation = try XCTUnwrap(
                        tail[AgentRunResponsePresentation.presentationKey]?.objectValue
                    )
                    let tailPath = try XCTUnwrap(
                        tailPresentation["export_path"]?.stringValue
                    )
                    XCTAssertTrue(tailPath.hasPrefix(fixture.contextA.rootURL.path + "/"))
                    XCTAssertFalse(tailPath.hasPrefix(fixture.contextB.rootURL.path + "/"))
                    XCTAssertEqual(dispatchCount, 1)

                    var fullArgs = baseArgs
                    fullArgs["response_mode"] = .string("full")
                    let fullValue = try await ServerNetworkManager.withConnectionID(
                        endpoint.connectionID
                    ) {
                        try await agentRun(fullArgs)
                    }
                    let full = try XCTUnwrap(fullValue.objectValue)
                    XCTAssertEqual(full["assistant_text"]?.stringValue, body)
                    XCTAssertNil(
                        full[AgentRunResponsePresentation.presentationKey],
                        "Full replay must remain canonical Value presentation"
                    )
                    XCTAssertEqual(
                        full["_meta"]?.objectValue?["request_id_replay"]?.boolValue,
                        true
                    )
                    XCTAssertEqual(dispatchCount, 1)

                    let noneResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.agentRun,
                        arguments: [
                            "op": "start",
                            "message": "Return a terminal public-boundary result.",
                            "model_id": "claudeCode:sonnet",
                            "detach": false,
                            "timeout": 0,
                            "request_id": requestID,
                            "response_mode": "none"
                        ],
                        timeoutSeconds: 30
                    )
                    let noneText = try toolResultText(noneResponse)
                    XCTAssertTrue(noneText.contains("- Response mode: `none`"), noneText)
                    XCTAssertTrue(noneText.contains("- Full output: `"), noneText)
                    XCTAssertTrue(noneText.contains("- Retrieval: Read the complete assistant result"), noneText)
                    XCTAssertFalse(noneText.contains(body), noneText)
                    XCTAssertEqual(dispatchCount, 1)

                    let nonePath = try XCTUnwrap(
                        noneText.components(separatedBy: "- Full output: `")
                            .dropFirst()
                            .first?
                            .components(separatedBy: "`")
                            .first
                    )
                    XCTAssertTrue(nonePath.hasPrefix(fixture.contextA.rootURL.path + "/"))
                    XCTAssertNotEqual(nonePath, tailPath)

                    let readResponse = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile,
                        arguments: ["path": nonePath],
                        timeoutSeconds: 30
                    )
                    let readText = try toolResultText(readResponse)
                    XCTAssertTrue(readText.contains(body), readText)

                    if let childSessionID {
                        await window.agentModeViewModel.mcpDeactivateControlContext(
                            sessionID: childSessionID,
                            cleanupSessionStore: true
                        )
                    }
                    await fixture.cleanup()
                } catch {
                    if let childSessionID {
                        await window.agentModeViewModel.mcpDeactivateControlContext(
                            sessionID: childSessionID,
                            cleanupSessionStore: true
                        )
                    }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testAskOracleResponseModeTailAndNoneAutoExport() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let presetsManager = ModelPresetsManager.shared
                let settings = GlobalSettingsStore.shared
                let previousPresets = presetsManager.presets
                let previousShowPresets = settings.mcpShowModelPresets()
                let previousTemporaryDisable = settings.mcpTemporarilyDisablePresets()
                defer {
                    presetsManager.presets = previousPresets
                    settings.setMCPShowModelPresets(previousShowPresets, commit: false)
                    settings.setMCPTemporarilyDisablePresets(previousTemporaryDisable, commit: false)
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting(nil)
                }
                do {
                    try await activateWorkspace(fixture.contextA)
                    let endpoint = try fixture.endpointA()
                    try await configureAgentModeEndpoint(
                        endpoint,
                        context: makeFrozenContext(
                            fixture: fixture,
                            selection: StoredSelection(codemapAutoEnabled: false),
                            bindings: []
                        ),
                        fixture: fixture
                    )
                    let preset = ModelPreset(
                        name: "ResponseModeOracle",
                        model: .claudeCodeSonnet,
                        supportedModes: SupportedModes(chat: true, plan: true, review: true)
                    )
                    presetsManager.presets = [preset]
                    settings.setMCPShowModelPresets(true, commit: false)
                    settings.setMCPTemporarilyDisablePresets(false, commit: false)

                    let body = String(repeating: "x", count: 2100) + "\n## Recommendations\n- keep going"
                    fixture.contextA.window.mcpServer.setOracleChatSendOverrideForTesting { _, _, _ in
                        [
                            "chat_id": .string("response-mode-chat"),
                            "mode": .string("chat"),
                            "response": .string(body),
                            "model_source": .string("preset"),
                            "model_preset_name": .string(preset.name),
                            "model_preset_id": .string(preset.id.uuidString),
                            "model_selection": .string("explicit")
                        ]
                    }

                    let tail = try await ServerNetworkManager.withConnectionID(endpoint.connectionID) {
                        try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: [
                            "message": .string("trim me"),
                            "model": .string(preset.name),
                            "new_chat": .bool(true),
                            "response_mode": .string("tail")
                        ])
                    }.objectValue
                    XCTAssertNil(tail?["response"])
                    let excerpt = try XCTUnwrap(tail?["excerpt"]?.stringValue)
                    XCTAssertEqual(excerpt.count, OracleResponseMode.tailExcerptCharacterBudget)
                    XCTAssertTrue(excerpt.contains("## Recommendations"))
                    let exportPath = try XCTUnwrap(tail?["export_path"]?.stringValue)
                    XCTAssertEqual(tail?["oracle_export_path"]?.stringValue, exportPath)
                    XCTAssertEqual(tail?["char_count"]?.intValue, body.count)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: exportPath))
                    let exported = try String(contentsOfFile: exportPath, encoding: .utf8)
                    XCTAssertTrue(exported.contains(body))

                    let none = try await ServerNetworkManager.withConnectionID(endpoint.connectionID) {
                        try await fixture.contextA.window.mcpServer.executeAskOracleForTesting(args: [
                            "message": .string("hide me"),
                            "model": .string(preset.name),
                            "new_chat": .bool(true),
                            "response_mode": .string("none")
                        ])
                    }.objectValue
                    XCTAssertNil(none?["response"])
                    XCTAssertNil(none?["excerpt"])
                    XCTAssertEqual(none?["excerpt_lines"]?.intValue, 0)
                    let nonePath = try XCTUnwrap(none?["export_path"]?.stringValue)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: nonePath))

                    await fixture.cleanup()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private func installOracleCapture(
            _ capture: OracleWorktreeCapture,
            on window: WindowState,
            gitInclusion: GitInclusion = .none
        ) {
            window.mcpServer.setOracleChatSendOverrideForTesting { args, promptVM, tabContext in
                let context = try XCTUnwrap(tabContext)
                if gitInclusion != .none {
                    promptVM.gitViewModel.selectedDiffBranch = "missing/live-ui-base"
                    XCTAssertEqual(context.packaging.reviewGitContext.compareIntent, .uncommittedHEAD)
                }
                let config = PromptContextResolved(
                    includeFiles: true,
                    includeUserPrompt: true,
                    includeMetaPrompts: false,
                    includeFileTree: true,
                    fileTreeMode: .auto,
                    codeMapUsage: .none,
                    gitInclusion: gitInclusion,
                    storedPromptIds: []
                )
                let message = await promptVM.packagePrompt(
                    conversation: [
                        ConversationEntry(
                            role: .user,
                            content: args["message"]?.stringValue ?? ""
                        )
                    ],
                    overridePromptConfig: config,
                    overrideMode: gitInclusion == .none ? .chat : .review,
                    selectionOverride: context.packaging.selection,
                    lookupContextOverride: context.packaging.lookupContext,
                    reviewGitContextOverride: context.packaging.reviewGitContext
                )
                capture.record(
                    tabContext: context,
                    fileTree: message.fileTree,
                    fileBlocks: message.fileBlocks,
                    gitDiff: message.gitDiff
                )
                return [
                    "chat_id": .string(UUID().uuidString),
                    "short_id": .string("oracle-capture"),
                    "mode": .string("chat"),
                    "response": .string("captured oracle response")
                ]
            }
        }

        private func makeFrozenContext(
            fixture: PersistentMCPTestFixture,
            selection: StoredSelection,
            bindings: [AgentSessionWorktreeBinding],
            bindingState: AgentSessionWorktreeBindingState? = nil,
            activeAgentSessionID: UUID? = UUID()
        ) -> MCPServerViewModel.TabContextSnapshot {
            MCPServerViewModel.TabContextSnapshot(
                tabID: fixture.contextA.tabID,
                windowID: fixture.contextA.window.windowID,
                workspaceID: fixture.contextA.workspaceID,
                promptText: "Oracle worktree prompt",
                selection: selection,
                selectedMetaPromptIDs: [],
                tabName: "Oracle Worktree",
                runID: UUID(),
                activeAgentSessionID: activeAgentSessionID,
                worktreeBindings: bindings,
                worktreeBindingState: bindingState,
                explicitlyBound: false
            )
        }

        private func activateRunOnlyBatchOwner(
            context: MCPServerViewModel.TabContextSnapshot,
            fixture: PersistentMCPTestFixture
        ) throws {
            let runID = try XCTUnwrap(context.runID)
            let session = try XCTUnwrap(
                fixture.contextA.window.agentModeViewModel.session(for: context.tabID, createIfNeeded: true)
            )
            session.runID = runID
            session.runState = .running
            fixture.contextA.window.agentModeViewModel.setAgentRunActive(
                context.tabID,
                isActive: true
            )
        }

        private func configureAgentModeEndpoint(
            _ endpoint: PersistentMCPTestEndpoint,
            context: MCPServerViewModel.TabContextSnapshot,
            fixture: PersistentMCPTestFixture,
            sessionProfile: AgentSessionProfile = .standard,
            leaseSpec: ((_ runID: UUID) -> MCPBootstrapLeaseSpec)? = nil
        ) async throws {
            _ = try await endpoint.callTool(
                name: "bind_context",
                arguments: ["op": "bind", "context_id": context.tabID.uuidString]
            )
            let runID = try XCTUnwrap(context.runID)
            let spec = leaseSpec?(runID)
            let purpose = spec?.purpose ?? .agentModeRun
            await fixture.networkManager.setRunPurpose(purpose, for: endpoint.connectionID)
            try await fixture.networkManager.debugSeedConnectionRunRouting(
                connectionID: endpoint.connectionID,
                runID: runID,
                purpose: purpose,
                windowID: context.windowID
            )
            if sessionProfile == .knowledge {
                await fixture.networkManager.installClientConnectionPolicy(
                    for: endpoint.clientName,
                    windowID: context.windowID,
                    restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                    oneShot: true,
                    reason: "knowledge read-to-oracle integration",
                    ttl: 10,
                    tabID: context.tabID,
                    runID: runID,
                    additionalTools: AgentModeMCPPolicyInstaller.additionalTools(
                        for: .codexExec,
                        sessionProfile: .knowledge
                    ),
                    allowedToolsOverride: AgentModeMCPToolPolicy.knowledgeAllowedTools,
                    sessionProfile: .knowledge,
                    purpose: .agentModeRun
                )
                let admission = await fixture.networkManager.debugApplyPendingPolicy(
                    clientName: endpoint.clientName,
                    connectionID: endpoint.connectionID,
                    requireRunRouting: false
                )
                XCTAssertEqual(admission.outcome, "applied")
                XCTAssertEqual(admission.sessionProfile, .knowledge)
                let advertisedToolNames = try await endpoint.listToolNames()
                XCTAssertEqual(
                    Set(advertisedToolNames),
                    AgentModeMCPToolPolicy.knowledgeAllowedTools
                )
            } else if let spec {
                // A production lease builder supplies every field the run's policy installs.
                await fixture.networkManager.installClientConnectionPolicy(
                    for: endpoint.clientName,
                    windowID: context.windowID,
                    restrictedTools: spec.restrictedTools,
                    oneShot: true,
                    reason: spec.reason ?? "lease surface integration",
                    ttl: 10,
                    tabID: context.tabID,
                    runID: runID,
                    additionalTools: spec.additionalTools,
                    allowedToolsOverride: spec.allowedToolsOverride,
                    sessionProfile: spec.sessionProfile,
                    purpose: spec.purpose,
                    taskLabelKind: spec.taskLabelKind,
                    allowsAgentExternalControlTools: spec.allowsAgentExternalControlTools
                )
                let admission = await fixture.networkManager.debugApplyPendingPolicy(
                    clientName: endpoint.clientName,
                    connectionID: endpoint.connectionID,
                    requireRunRouting: false
                )
                XCTAssertEqual(admission.outcome, "applied")
            } else {
                await fixture.networkManager.debugSetAdditionalTools(
                    for: endpoint.connectionID,
                    additionalTools: [MCPWindowToolName.askOracle]
                )
            }
            var canonicalTab = try XCTUnwrap(
                fixture.contextA.window.workspaceManager.composeTab(with: context.tabID)
            )
            canonicalTab.selection = context.selection
            fixture.contextA.window.workspaceManager.updateComposeTab(canonicalTab, markDirty: false)
            fixture.contextA.window.mcpServer.installFrozenTabContext(
                clientID: endpoint.connectionID.uuidString,
                clientName: endpoint.clientName,
                context: context
            )
        }

        private func activateWorkspace(_ context: PersistentMCPTestContext) async throws {
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            await context.window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "MCPAskOracleWorktreeTests"
            )
            let activeWorkspace = try XCTUnwrap(context.window.workspaceManager.activeWorkspace)
            context.window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        }

        private func writeGitArtifactManifest(
            to url: URL,
            snapshotID: String,
            repoKey: String,
            repoRoot: URL,
            layout: GitRepositoryLayout,
            tabID: UUID
        ) throws {
            let manifest = GitDiffSnapshotManifest(
                snapshotID: snapshotID,
                generatedAt: Date(timeIntervalSince1970: 1),
                mode: .standard,
                compare: "HEAD",
                compareInput: nil,
                scope: .selected,
                requestedPaths: ["Sources/Feature.swift"],
                fingerprint: GitDiffFingerprint(
                    headSHA: "abc",
                    baseRef: "HEAD",
                    statusHash: "status",
                    generatedAt: Date(timeIntervalSince1970: 1)
                ),
                contextLines: 3,
                detectRenames: false,
                summary: GitDiffSnapshotManifest.Summary(files: 1, insertions: 1, deletions: 0),
                files: [],
                repoKey: repoKey,
                repoRoot: repoRoot.path,
                isWorktree: true,
                worktreeName: repoRoot.lastPathComponent,
                worktreeRoot: repoRoot.path,
                mainWorktreeRoot: layout.knownMainWorktreeRoot?.path,
                commonGitDir: layout.commonDir.path,
                tabID: tabID
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try write(
                XCTUnwrap(try String(data: encoder.encode(manifest), encoding: .utf8)),
                to: url
            )
        }

        private func requireSelectedPath(
            suffix: String,
            in selection: StoredSelection,
            context: String,
            toolOutput: String? = nil,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws -> String {
            try XCTUnwrap(
                selection.selectedPaths.first { $0.hasSuffix(suffix) },
                missingSelectedPathDiagnostic(
                    suffix: suffix,
                    selection: selection,
                    context: context,
                    toolOutput: toolOutput
                ),
                file: file,
                line: line
            )
        }

        private func missingSelectedPathDiagnostic(
            suffix: String,
            selection: StoredSelection,
            context: String,
            toolOutput: String?
        ) -> String {
            var message = "Missing selected path suffix \(suffix) during \(context)."
            message += "\nSelected paths:\n"
            message += selection.selectedPaths.sorted().joined(separator: "\n")
            if let toolOutput, !toolOutput.isEmpty {
                message += "\nGit tool output:\n"
                message += truncatedDiagnostic(toolOutput)
            }
            return message
        }

        private func truncatedDiagnostic(_ text: String, limit: Int = 6000) -> String {
            guard text.count > limit else { return text }
            return String(text.prefix(limit))
                + "\n… truncated \(text.count - limit) additional characters"
        }

        private func cleanupSyntheticMCPRoutingForOracleTest(
            window: WindowState,
            sessionIDs: [UUID],
            runIDs: [UUID],
            connections: [SyntheticMCPConnectionCleanup]
        ) async {
            var seenConnections = Set<UUID>()
            let uniqueConnections = connections.filter { cleanup in
                seenConnections.insert(cleanup.connectionID).inserted
            }
            for connection in uniqueConnections {
                window.mcpServer.removeTabContext(
                    forConnectionID: connection.connectionID,
                    clientName: connection.clientName,
                    windowID: window.windowID,
                    runID: connection.runID
                )
            }

            var seenSessionIDs = Set<UUID>()
            let uniqueSessionIDs = sessionIDs.filter { seenSessionIDs.insert($0).inserted }
            let materializer = WorkspaceRootBindingProjectionMaterializer(
                store: window.workspaceFileContextStore
            )
            for sessionID in uniqueSessionIDs {
                await materializer.release(sessionID: sessionID)
            }

            var seenRunIDs = Set<UUID>()
            let uniqueRunIDs = runIDs.filter { seenRunIDs.insert($0).inserted }
            for runID in uniqueRunIDs {
                await ServerNetworkManager.shared.unregisterToolObservers(for: runID)
                await ServerNetworkManager.shared.cleanupRunRoutingState(
                    for: runID,
                    windowID: window.windowID
                )
                await AgentRunCoordinator.shared.cleanupRouting(runID: runID)
            }

            for connection in uniqueConnections {
                await ServerNetworkManager.shared.debugRemoveConnection(connection.connectionID)
                await ServerNetworkManager.shared.clearClientConnectionPolicy(
                    for: connection.clientName,
                    windowID: window.windowID,
                    runID: connection.runID
                )
                await ServerNetworkManager.shared.debugClearPersistedRoutingState(
                    for: connection.clientName
                )
            }
        }

        private static func resultObject(_ response: PersistentMCPTestRPCResponse) throws -> [String: Any] {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try XCTUnwrap(object["result"] as? [String: Any], response.rawJSON)
        }

        private func toolResultText(_ response: PersistentMCPTestRPCResponse) throws -> String {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return content.compactMap { $0["text"] as? String }.joined()
        }

        private func makeAgentMCPControlContext(
            sessionID: UUID
        ) -> AgentMCPControlContext {
            AgentMCPControlContext(
                sessionID: sessionID,
                activationID: UUID(),
                registration: .init(sessionID: sessionID, generation: 0),
                currentEpoch: nil,
                preparedEpoch: nil,
                pendingEpochTransition: nil,
                originatingConnectionID: nil,
                interactionTransport: .mcp(
                    sessionID: sessionID,
                    originatingConnectionID: nil
                ),
                suppressUserNotifications: false,
                forceAutoEditEnabled: false,
                autoEditEnabledBeforeOverride: true,
                taskLabelKind: .pair
            )
        }

        private func makeBinding(
            logicalRoot: URL,
            worktreeRoot: URL,
            suffix: String
        ) -> AgentSessionWorktreeBinding {
            AgentSessionWorktreeBinding(
                id: "binding-\(suffix)",
                repositoryID: "repo-\(suffix)",
                repoKey: logicalRoot.path,
                logicalRootPath: logicalRoot.path,
                logicalRootName: logicalRoot.lastPathComponent,
                worktreeID: "worktree-\(suffix)",
                worktreeRootPath: worktreeRoot.path,
                worktreeName: worktreeRoot.lastPathComponent,
                branch: "feature/\(suffix)",
                source: "test"
            )
        }

        private func makeTemporaryRoot(name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCPAskOracleWorktreeTests", isDirectory: true)
                .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url.standardizedFileURL
        }

        private func write(_ content: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        private func waitUntil(
            timeout: Duration = .seconds(2),
            condition: @escaping @MainActor () -> Bool
        ) async -> Bool {
            let timeoutSeconds = TimeInterval(timeout.components.seconds)
                + TimeInterval(timeout.components.attoseconds) / 1_000_000_000_000_000_000
            do {
                try await AsyncTestWait.waitUntil(
                    "MCPAskOracleWorktreeTests.waitUntil",
                    timeout: max(timeoutSeconds, 0.001),
                    initialDelayNanoseconds: 1_000_000,
                    maximumDelayNanoseconds: 25_000_000
                ) {
                    await condition()
                }
                return true
            } catch {
                return condition()
            }
        }
    }

    private enum ProductionOracleRepositoryKind: String {
        case canonical
        case linkedWorktree
        case visibleLinkedWorktree
    }

    private struct SyntheticMCPConnectionCleanup {
        let connectionID: UUID
        let clientName: String
        let runID: UUID?
    }

    @MainActor
    private final class OracleReviewPackagingTraceCapture {
        struct Turn {
            let correlationID: UUID
            var frozen: OracleReviewPackagingFrozenSnapshot?
            var preassembly: OracleReviewPackagingPreassemblySnapshot?
            var submission: OracleReviewPackagingSubmissionSnapshot?
            var failureType: String?
        }

        private var order: [UUID] = []
        private var turnsByID: [UUID: Turn] = [:]

        func record(_ event: OracleReviewPackagingTraceEvent) {
            let correlationID: UUID
            switch event {
            case let .contextFrozen(id, snapshot):
                correlationID = id
                ensureTurn(id)
                turnsByID[id]?.frozen = snapshot
            case let .preassemblyCompleted(id, snapshot):
                correlationID = id
                ensureTurn(id)
                turnsByID[id]?.preassembly = snapshot
            case let .messageSubmitted(id, snapshot):
                correlationID = id
                ensureTurn(id)
                turnsByID[id]?.submission = snapshot
            case let .failedOrCancelled(id, errorType):
                correlationID = id
                ensureTurn(id)
                turnsByID[id]?.failureType = errorType
            }
            precondition(turnsByID[correlationID] != nil)
        }

        func completedTurns() -> [Turn] {
            order.compactMap { turnsByID[$0] }
        }

        private func ensureTurn(_ id: UUID) {
            guard turnsByID[id] == nil else { return }
            order.append(id)
            turnsByID[id] = Turn(correlationID: id)
        }
    }

    @MainActor
    private final class OracleReviewTransportCapture {
        private(set) var messages: [AIMessage] = []
        private(set) var models: [AIModel] = []
        private(set) var serializedUserContents: [String] = []
        private(set) var serializedGitDiffFingerprints:
            [OracleReviewPackagingContentFingerprint] = []

        func record(
            message: AIMessage,
            model: AIModel,
            serializedMessages: [CompletionParams.Message]
        ) {
            messages.append(message)
            models.append(model)
            let serializedUserContent = Self.serializedUserContent(
                from: serializedMessages
            )
            serializedUserContents.append(serializedUserContent ?? "")
            serializedGitDiffFingerprints.append(
                OracleReviewPackagingDiagnostics.fingerprint(
                    serializedUserContent.flatMap(Self.serializedGitDiff)
                )
            )
        }

        private static func serializedUserContent(
            from messages: [CompletionParams.Message]
        ) -> String? {
            guard let userMessage = messages.reversed().first(where: {
                $0.role == .user
            }),
                case let .text(content) = userMessage.content
            else { return nil }
            return content
        }

        private static func serializedGitDiff(from content: String) -> String? {
            guard let open = content.range(of: "<git_diff>\n"),
                  let close = content.range(
                      of: "\n</git_diff>",
                      range: open.upperBound ..< content.endIndex
                  )
            else { return nil }
            return String(content[open.upperBound ..< close.lowerBound])
        }
    }

    private actor OracleAutomaticProviderCounter {
        private var count = 0
        private var selectedPaths: [String] = []

        func recordInvocation(_ request: AutomaticReviewGitDiffRequest? = nil) {
            count += 1
            if let request {
                selectedPaths = request.pathResolution.paths
            }
        }

        func invocationCount() -> Int {
            count
        }

        func lastSelectedPaths() -> [String] {
            selectedPaths
        }
    }

    private actor ExplicitWindowRoutingHintCapture {
        private var hints: [MCPExplicitWindowRoutingHint?] = []

        func record(_ hint: MCPExplicitWindowRoutingHint?) {
            hints.append(hint)
        }

        func snapshot() -> [MCPExplicitWindowRoutingHint?] {
            hints
        }
    }

    @MainActor
    private final class OracleSelectionPackagingCapture {
        struct Turn {
            let context: OracleViewModel.OracleSendTabContext
            let message: AIMessage
        }

        private(set) var turns: [Turn] = []

        func record(context: OracleViewModel.OracleSendTabContext, message: AIMessage) {
            turns.append(Turn(context: context, message: message))
        }
    }

    @MainActor
    private final class OracleSliceSelectionCapture {
        private(set) var selections: [StoredSelection] = []

        func record(_ selection: StoredSelection) {
            selections.append(selection)
        }
    }

    @MainActor
    private final class OracleExportDestinationCapture {
        private(set) var destinations: [OracleExportDestination] = []

        func record(_ request: OracleExportRequest) {
            if let destination = request.destination {
                destinations.append(destination)
            }
        }
    }

    @MainActor
    private final class OracleTransportInvocationCapture {
        private(set) var invocationCount = 0
        private(set) var messages: [AIMessage] = []
        private(set) var models: [AIModel] = []

        func recordInvocation() {
            invocationCount += 1
        }

        func record(message: AIMessage, model: AIModel) {
            invocationCount += 1
            messages.append(message)
            models.append(model)
        }
    }

    @MainActor
    private final class OracleTransportMessageCapture {
        private(set) var messages: [AIMessage] = []

        func record(_ message: AIMessage) {
            messages.append(message)
        }
    }

    @MainActor
    private final class OracleArgsCapture {
        private(set) var args: [String: Value]?
        private(set) var callCount = 0

        func record(_ args: [String: Value]) {
            self.args = args
            callCount += 1
        }
    }

    @MainActor
    private final class OracleWorktreeCapture {
        private(set) var wasInvoked = false
        private(set) var tabContext: OracleViewModel.OracleSendTabContext?
        private(set) var fileTree = ""
        private(set) var fileBlocks: [String] = []
        private(set) var gitDiff: String?

        func record(
            tabContext: OracleViewModel.OracleSendTabContext,
            fileTree: String,
            fileBlocks: [String],
            gitDiff: String?
        ) {
            wasInvoked = true
            self.tabContext = tabContext
            self.fileTree = fileTree
            self.fileBlocks = fileBlocks
            self.gitDiff = gitDiff
        }
    }

    private enum OracleWorktreeTestError: LocalizedError {
        case autoSelectionDidNotStart(readDiagnostic: String)

        var errorDescription: String? {
            switch self {
            case let .autoSelectionDidNotStart(readDiagnostic):
                "read_file auto-selection did not start within 2 seconds. read_file result: " + readDiagnostic
            }
        }
    }

    private actor OracleWorktreeGate {
        private var started = false
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            started = true
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStarted(timeout: Duration = .seconds(2)) async -> Bool {
            let timeoutSeconds = TimeInterval(timeout.components.seconds)
                + TimeInterval(timeout.components.attoseconds) / 1_000_000_000_000_000_000
            do {
                try await AsyncTestWait.waitUntil(
                    "OracleWorktreeGate started",
                    timeout: max(timeoutSeconds, 0.001),
                    initialDelayNanoseconds: 1_000_000,
                    maximumDelayNanoseconds: 25_000_000
                ) {
                    await self.hasStarted()
                }
                return true
            } catch {
                return started
            }
        }

        private func hasStarted() -> Bool {
            started
        }

        func release() {
            guard !released else { return }
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
#endif
