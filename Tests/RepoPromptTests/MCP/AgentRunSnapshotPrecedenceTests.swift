import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class AgentRunSnapshotPrecedenceTests: XCTestCase {
    func testStoredTerminalPrecedencePrefersLiveNonTerminalOnly() {
        let sessionID = UUID()
        let stored = makeSnapshot(
            sessionID: sessionID,
            status: .completed,
            latestAssistantPreview: "stored-terminal"
        )

        let liveRunning = makeSnapshot(
            sessionID: sessionID,
            status: .running,
            latestAssistantPreview: "live-running"
        )
        XCTAssertEqual(
            AgentRunMCPToolService.preferredSnapshotWhenStoredTerminal(stored: stored, live: liveRunning),
            liveRunning
        )

        let liveWaiting = makeSnapshot(
            sessionID: sessionID,
            status: .waitingForInput,
            latestAssistantPreview: "live-waiting"
        )
        XCTAssertEqual(
            AgentRunMCPToolService.preferredSnapshotWhenStoredTerminal(stored: stored, live: liveWaiting),
            liveWaiting
        )

        let liveTerminal = makeSnapshot(
            sessionID: sessionID,
            status: .failed,
            latestAssistantPreview: "live-terminal"
        )
        XCTAssertEqual(
            AgentRunMCPToolService.preferredSnapshotWhenStoredTerminal(stored: stored, live: liveTerminal),
            stored
        )

        XCTAssertEqual(
            AgentRunMCPToolService.preferredSnapshotWhenStoredTerminal(stored: stored, live: nil),
            stored
        )
    }

    func testFollowUpPendingSerializesOnlyWhenTrueAndParsesAbsentAsFalse() throws {
        let sessionID = UUID()
        let pending = makeSnapshot(sessionID: sessionID, status: .running, followUpPending: true)
        let pendingObject = pending.asObject()
        XCTAssertEqual(pendingObject["followup_pending"]?.boolValue, true)
        let parsedPending = try XCTUnwrap(AgentRunMCPToolService.snapshot(from: pendingObject))
        XCTAssertTrue(parsedPending.followUpPending)

        let notPending = makeSnapshot(sessionID: sessionID, status: .running, followUpPending: false)
        let notPendingObject = notPending.asObject()
        XCTAssertNil(notPendingObject["followup_pending"])
        let parsedAbsent = try XCTUnwrap(AgentRunMCPToolService.snapshot(from: notPendingObject))
        XCTAssertFalse(parsedAbsent.followUpPending)
    }

    func testPollPrefersLiveRunningMaskOverRetainedStoredTerminal() async throws {
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let viewModel = makeViewModel(windowID: window.windowID)
        let service = makeService(window: window, viewModel: viewModel)
        let sessionID = UUID()
        let session = try await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        let ownership = session.beginRunAttempt(source: "test.snapshotPrecedence")
        session.runState = .completed
        session.mcpFollowUpRunPending = true
        let envelope = try XCTUnwrap(viewModel.test_makeTerminalPublicationEnvelope(
            for: session,
            ownership: ownership,
            terminalState: .completed
        ))
        XCTAssertEqual(envelope.snapshot.status, .completed)
        XCTAssertTrue(envelope.snapshot.followUpPending)

        let context = try XCTUnwrap(session.mcpControlContext)
        _ = await AgentRunSessionStore.publishTerminal(
            envelope,
            registration: context.registration,
            commitID: UUID(),
            successorKind: nil
        )
        defer { Task { await AgentRunSessionStore.cleanup(registration: context.registration) } }

        let maskedPoll = try await service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertEqual(maskedPoll.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertEqual(maskedPoll.objectValue?["followup_pending"]?.boolValue, true)

        session.mcpFollowUpRunPending = false
        let finalPoll = try await service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertEqual(finalPoll.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
    }

    private func makeWindow() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }

    private func makeViewModel(windowID: Int) -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in SnapshotPrecedenceCodexController() }
        )
    }

    private func makeService(window: WindowState, viewModel: AgentModeViewModel) -> AgentRunMCPToolService {
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "agent-run-snapshot-precedence-tests",
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
                throw MCPError.internalError("startRun should not be used by snapshot precedence tests")
            }
        )
        service.testAgentModeViewModel = viewModel
        return service
    }

    private func makeSnapshot(
        sessionID: UUID,
        status: AgentRunMCPSnapshot.Status,
        latestAssistantPreview: String? = nil,
        followUpPending: Bool = false
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            tabID: nil,
            sessionName: "Agent",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: status,
            statusText: status.rawValue,
            latestAssistantPreview: latestAssistantPreview,
            interaction: nil,
            transcriptItemCount: 1,
            updatedAt: Date(timeIntervalSince1970: 1),
            parentSessionID: nil,
            failureReason: nil,
            followUpPending: followUpPending,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }
}

private final class SnapshotPrecedenceCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "snapshot-precedence-test", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "snapshot-precedence-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "snapshot-precedence-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        .init(
            conversationID: "snapshot-precedence-test",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_: String, threadID _: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(
        _: CodexNativeSessionController.ThreadGoalStatus
    ) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
