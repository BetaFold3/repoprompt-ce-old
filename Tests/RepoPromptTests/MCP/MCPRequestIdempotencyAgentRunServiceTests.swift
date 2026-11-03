import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptWorkspace
@_spi(TestSupport) @testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
import XCTest

/// Plan §6.1: `agent_run` service-level `request_id` idempotency. Duplicates are
/// absorbed by `MCPRequestIdempotencyRegistry` before re-executing the mutation,
/// while `mcpResolvePendingInteraction` fencing stays strict for first attempts.
@MainActor
final class MCPRequestIdempotencyAgentRunServiceTests: XCTestCase {
    private final class CallCounter: @unchecked Sendable {
        private(set) var count = 0

        func increment() {
            count += 1
        }
    }

    func testDuplicateStartExecutesMutationOnceAndReplaysRecordedFailure() async throws {
        let registry = MCPRequestIdempotencyRegistry()
        let counter = CallCounter()
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "idempotency-service-tests",
                    windowID: nil,
                    actorRoutedRunTab: nil
                )
            },
            requireTargetWindow: {
                counter.increment()
                throw MCPError.invalidParams("start-sentinel-refusal")
            },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be reached")
            }
        )
        service.idempotencyRegistry = registry

        let args: [String: Value] = [
            "op": .string("start"),
            "message": .string("go"),
            "request_id": .string("req-start-1"),
            "response_mode": .string("tail")
        ]

        do {
            _ = try await service.execute(args: args)
            XCTFail("First start must fail through the sentinel refusal")
        } catch {
            XCTAssertTrue(String(describing: error).contains("start-sentinel-refusal"))
        }
        XCTAssertEqual(counter.count, 1)

        var replayArgs = args
        replayArgs["response_mode"] = .string("none")
        do {
            _ = try await service.execute(args: replayArgs)
            XCTFail("Duplicate start must replay the recorded outcome")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("already failed"),
                "Duplicate must be answered from the registry: \(error)"
            )
        }
        XCTAssertEqual(counter.count, 1, "Changing only response_mode must not execute the mutation a second time")
    }

    func testDuplicateRespondReplaysRecordedResultWhileVMFencingStaysStrict() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )

        let registry = MCPRequestIdempotencyRegistry()
        var service = makeService(window: window)
        service.idempotencyRegistry = registry

        let args: [String: Value] = [
            "op": .string("respond"),
            "session_id": .string(sessionID.uuidString),
            "interaction_id": .string(UUID().uuidString),
            "response": .string("yes"),
            "request_id": .string("req-respond-1")
        ]

        do {
            _ = try await service.execute(args: args)
            XCTFail("First respond must throw through strict VM interaction fencing")
        } catch {
            let description = String(describing: error)
            XCTAssertTrue(
                description.localizedCaseInsensitiveContains("interaction"),
                "First respond must fail via VM fencing: \(description)"
            )
            XCTAssertFalse(description.contains("already failed"))
        }

        do {
            _ = try await service.execute(args: args)
            XCTFail("Duplicate respond must replay the recorded outcome")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("already failed"),
                "Duplicate respond must be answered from the registry: \(error)"
            )
        }
    }

    func testSameRequestIDWithDifferentPayloadReturnsConflict() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )

        let registry = MCPRequestIdempotencyRegistry()
        var service = makeService(window: window)
        service.idempotencyRegistry = registry

        var args: [String: Value] = [
            "op": .string("respond"),
            "session_id": .string(sessionID.uuidString),
            "interaction_id": .string(UUID().uuidString),
            "response": .string("yes"),
            "request_id": .string("req-conflict-1")
        ]
        _ = try? await service.execute(args: args)

        args["response"] = .string("no")
        do {
            _ = try await service.execute(args: args)
            XCTFail("Same request_id with a different payload must conflict")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("request_id_conflict"),
                "Expected request_id_conflict, got: \(error)"
            )
        }
    }

    func testMutationWithoutRequestIDBypassesRegistry() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )

        let registry = MCPRequestIdempotencyRegistry()
        var service = makeService(window: window)
        service.idempotencyRegistry = registry

        _ = try? await service.execute(args: [
            "op": .string("respond"),
            "session_id": .string(sessionID.uuidString),
            "interaction_id": .string(UUID().uuidString),
            "response": .string("yes")
        ])

        let entryCount = await registry.test_entryCount()
        XCTAssertEqual(entryCount, 0, "request_id is opt-in; without it no idempotency entry is recorded")
    }

    /// Plan §6.3: the canonical root `wait_policy` tuple is recorded before idempotency storage
    /// and replayed verbatim — a duplicate never re-executes or recomputes the parent family.
    func testDuplicateSteerReplaysStoredWaitPolicyWithoutRecomputingParentFamily() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = try await makeRegisteredSession(in: window)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )

        let registry = MCPRequestIdempotencyRegistry()
        var service = makeService(window: window)
        service.idempotencyRegistry = registry
        let dispatchCounter = CallCounter()
        let resolutionCounter = CallCounter()
        var currentFamily: AgentMCPWaitPolicy.ParentFamily = .codex
        service.resolveWaitPolicyContext = { metadata in
            resolutionCounter.increment()
            return AgentMCPWaitPolicy.RequestContext(
                metadata: metadata,
                parentFamily: currentFamily,
                parentPromptCacheRetention: .standard
            )
        }
        service.testDispatchSteerInstruction = { dispatchedSessionID, _, _, agentModeVM in
            dispatchCounter.increment()
            let controlledSession = try XCTUnwrap(agentModeVM.mcpControlledSession(sessionID: dispatchedSessionID))
            await agentModeVM.prepareMCPWaitTrackingForRunStart(session: controlledSession)
            controlledSession.runState = .running
            agentModeVM.publishMCPStateChange(for: controlledSession)
            return .startedRun
        }
        // The steered run finishes immediately, so the automatic selection returns without parking.
        service.currentSnapshotProvider = { snapshotSessionID, _ in
            Self.completedSnapshot(sessionID: snapshotSessionID)
        }

        let args: [String: Value] = [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("steer with automatic wait"),
            "wait": .bool(true),
            "request_id": .string("req-steer-policy-1"),
            "response_mode": .string("full")
        ]
        let first = try await service.execute(args: args)
        let expectedPolicy: Value = .object([
            "mode": .string("automatic"),
            "timeout_seconds": .int(1500),
            "parent_family": .string("codex")
        ])
        XCTAssertEqual(first.objectValue?["wait_policy"], expectedPolicy)
        XCTAssertEqual(dispatchCounter.count, 1)
        XCTAssertEqual(resolutionCounter.count, 1)

        // The apparent parent changes; a replay must still present the stored tuple.
        currentFamily = .claude
        var replayArgs = args
        replayArgs["response_mode"] = .string("none")
        let replay = try await service.execute(args: replayArgs)
        XCTAssertEqual(replay.objectValue?["wait_policy"], expectedPolicy)
        XCTAssertEqual(replay.objectValue?["_meta"]?.objectValue?["request_id_replay"], .bool(true))
        XCTAssertEqual(dispatchCounter.count, 1, "Duplicate must not re-execute the steer")
        XCTAssertEqual(resolutionCounter.count, 1, "Duplicate must not recompute the parent family")

        session.runState = .idle
        await viewModel.mcpDeactivateControlContext(sessionID: sessionID, cleanupSessionStore: true)
    }

    /// `currentSnapshotProvider` is a `@Sendable` nonisolated closure, so the fixture builder
    /// must be callable off the main actor.
    private nonisolated static func completedSnapshot(sessionID: UUID) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            runID: nil,
            tabID: nil,
            sessionName: "Steered Agent",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: .completed,
            statusText: "completed",
            latestAssistantPreview: "steered result",
            interaction: nil,
            transcriptItemCount: 1,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: [],
            lastInteractionResolution: nil
        )
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
            name: "Request Idempotency \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "mcpRequestIdempotencyAgentRunServiceTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeService(window: WindowState) -> AgentRunMCPToolService {
        AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "idempotency-service-tests",
                    windowID: window.windowID,
                    actorRoutedRunTab: nil
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be reached")
            }
        )
    }
}
