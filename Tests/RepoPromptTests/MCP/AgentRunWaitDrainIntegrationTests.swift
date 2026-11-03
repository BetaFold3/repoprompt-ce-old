import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class AgentRunWaitDrainIntegrationTests: XCTestCase {
    func testRealDrainHandlesOracleOnlyResumableWait() async throws {
        try await AgentRunWaitDrainTestHarness.withHarness { harness in
            let executionID = try await harness.beginOracleResumableWait()
            harness.endOracleExecutionOnWake(executionID)

            XCTAssertTrue(harness.server.test_oracleWaitScopeExists(executionID: executionID))
            let drained = await harness.drain(source: "test-oracle-only-drain")

            XCTAssertEqual(drained, .drained)
            XCTAssertFalse(harness.server.test_oracleWaitScopeExists(executionID: executionID))
            XCTAssertFalse(harness.server.hasActiveToolExecutions(runID: harness.parentRunID))
        }
    }

    func testRealDrainTimeoutReportsOracleOnlyBlockerWithoutChildAttribution() async throws {
        try await AgentRunWaitDrainTestHarness.withHarness { harness in
            // An Oracle invocation that never returns after its wake (for example, suspended in
            // result finalization) is the only blocker; no child agent_run wait exists.
            let executionID = try await harness.beginOracleResumableWait()
            XCTAssertFalse(harness.server.hasActiveChildAgentRunWaits(runID: harness.parentRunID))

            let outcome = await harness.drain(source: "test-oracle-only-timeout", timeoutSeconds: 0.2)

            guard case let .timedOut(blockers) = outcome else {
                return XCTFail("Expected a timed-out drain, got \(outcome)")
            }
            XCTAssertEqual(blockers.childAgentRunWaitCount, 0)
            XCTAssertNil(blockers.oldestChildAgentRunWaitAgeSeconds)
            XCTAssertEqual(blockers.oracleInvocationCount, 1)
            XCTAssertNotNil(blockers.oldestOracleInvocationAgeSeconds)
            XCTAssertTrue(harness.server.oracleWaitScopeSteeringRequested(executionID: executionID))
            XCTAssertTrue(
                harness.server.test_oracleWaitScopeExists(executionID: executionID),
                "a timed-out drain never force-unregisters still-active Oracle work"
            )
            let message = CodexAgentModeCoordinator.activeSendDrainFailureMessage(blockers)
            XCTAssertTrue(message.contains("1 ask_oracle invocation"))
            XCTAssertFalse(message.contains("agent_run.wait"))

            harness.server.test_endToolExecution(executionID: executionID)
            let drained = await harness.drain(source: "test-oracle-only-timeout-recovered")
            XCTAssertEqual(drained, .drained)
        }
    }

    func testProductionDrainTracksRegistrationBeforeInvocationResolutionAndIncludesBatch() async throws {
        try await AgentRunWaitDrainTestHarness.withHarness { harness in
            let registered = await harness.server.test_beginResolvedToolExecution(
                metadata: harness.metadata,
                resolvedContext: nil,
                toolName: MCPWindowToolName.askOracle,
                toolArgs: ["op": .string("wait")]
            )
            let execution = try XCTUnwrap(registered)
            XCTAssertTrue(harness.server.test_oracleWaitScopeExists(executionID: execution.executionID))

            let drainTask = Task { @MainActor in
                await harness.drain(source: "test-registration-time-oracle-drain")
            }
            try await AsyncTestWait.waitUntil("registration-time steer becomes sticky") {
                await MainActor.run {
                    harness.server.oracleWaitScopeSteeringRequested(executionID: execution.executionID)
                }
            }
            XCTAssertTrue(
                harness.server.test_oracleWaitScopeExists(executionID: execution.executionID),
                "drain must not report completion before invocation resolution and execution cleanup"
            )

            _ = await MCPServerViewModel.$currentToolExecutionID.withValue(execution.executionID) {
                await harness.server.resolveOracleWaitInvocation()
            }
            harness.endOracleExecutionOnWake(execution.executionID)

            let drainedBeforeResolutionCompleted = await drainTask.value
            XCTAssertEqual(drainedBeforeResolutionCompleted, .drained)
            XCTAssertFalse(harness.server.test_oracleWaitScopeExists(executionID: execution.executionID))
            XCTAssertFalse(harness.server.hasActiveToolExecutions(runID: harness.parentRunID))

            // Registration classification runs before argument dispatch; this synthetic lane is
            // intentionally never parsed, so it does not need the public batch model field.
            let batch = await harness.server.test_beginResolvedToolExecution(
                metadata: harness.metadata,
                resolvedContext: nil,
                toolName: MCPWindowToolName.askOracle,
                toolArgs: ["consultations": .array([.object(["message": .string("bounded")])])]
            )
            let batchExecution = try XCTUnwrap(batch)
            XCTAssertTrue(
                harness.server.test_oracleWaitScopeExists(executionID: batchExecution.executionID),
                "bounded batch sends join the resumable steering drain"
            )
            let batchDrainTask = Task { @MainActor in
                await harness.drain(source: "test-bounded-batch-inclusion")
            }
            try await AsyncTestWait.waitUntil("batch steering wake becomes sticky") {
                await MainActor.run {
                    harness.server.oracleWaitScopeSteeringRequested(
                        executionID: batchExecution.executionID
                    )
                }
            }
            _ = await MCPServerViewModel.$currentToolExecutionID.withValue(
                batchExecution.executionID
            ) {
                await harness.server.resolveOracleWaitInvocation()
            }
            harness.endOracleExecutionOnWake(batchExecution.executionID)
            let batchDrained = await batchDrainTask.value
            XCTAssertEqual(batchDrained, .drained)
            XCTAssertFalse(
                harness.server.test_oracleWaitScopeExists(executionID: batchExecution.executionID)
            )
            XCTAssertFalse(harness.server.hasActiveToolExecutions(runID: harness.parentRunID))
        }
    }

    func testRealDrainHandlesMixedChildAndOracleWaits() async throws {
        try await AgentRunWaitDrainTestHarness.withHarness { harness in
            let childWait = harness.startWait()
            try await harness.waitUntilBlocked()
            let executionID = try await harness.beginOracleResumableWait()
            harness.endOracleExecutionOnWake(executionID)

            let drained = await harness.drain(source: "test-mixed-child-oracle-drain")
            XCTAssertEqual(drained, .drained)
            let childValue = try await childWait.value
            XCTAssertEqual(
                childValue.objectValue?["wait"]?.objectValue?["result"]?.stringValue,
                "interrupted_by_steering"
            )
            XCTAssertFalse(harness.server.hasActiveChildAgentRunWaits(runID: harness.parentRunID))
            XCTAssertFalse(harness.server.test_oracleWaitScopeExists(executionID: executionID))
            XCTAssertFalse(harness.server.hasActiveToolExecutions(runID: harness.parentRunID))
        }
    }

    func testRealParentWaitScopeDrainInterruptsOnceAndAllowsCleanRewait() async throws {
        try await AgentRunWaitDrainTestHarness.withHarness { harness in
            let firstWait = harness.startWait()
            try await harness.waitUntilBlocked()

            XCTAssertTrue(harness.server.hasActiveChildAgentRunWaits(runID: harness.parentRunID))
            XCTAssertEqual(harness.activeScopeCount(), 1)

            let drained = await harness.drain(source: "test-real-wait-scope-drain")
            XCTAssertEqual(drained, .drained)

            let interruptedValue = try await firstWait.value
            let interruptedObject = try XCTUnwrap(interruptedValue.objectValue)
            XCTAssertEqual(
                interruptedObject["wait"]?.objectValue?["result"]?.stringValue,
                "interrupted_by_steering"
            )
            XCTAssertEqual(
                interruptedObject["_meta"]?.objectValue?["wake_reason"]?.stringValue,
                AgentRunSessionStore.WakeReason.steeringRequested.rawValue
            )
            // The final service value, not a hand-built fixture, must reach the parent model as
            // one same-session, tool-correct resume instruction.
            let sessionID = harness.fixture.sessionID.uuidString
            let runText = try Self.formattedText(
                ToolOutputFormatter.formatAgentRun(args: ["op": .string("wait")], value: interruptedValue)
            )
            XCTAssertEqual(runText.components(separatedBy: "### Resume waiting").count - 1, 1)
            XCTAssertTrue(runText.contains("call `agent_run` with `op=wait` and `session_id=\"\(sessionID)\"`"))
            XCTAssertTrue(runText.contains("- Status: **Running**"))
            let exploreText = try Self.formattedText(
                ToolOutputFormatter.formatAgentExplore(args: ["op": .string("wait")], value: interruptedValue)
            )
            XCTAssertTrue(exploreText.contains("call `agent_explore` with `op=wait` and `session_id=\"\(sessionID)\"`"))
            XCTAssertFalse(exploreText.contains("agent_run"))
            XCTAssertFalse(harness.server.hasActiveChildAgentRunWaits(runID: harness.parentRunID))
            XCTAssertEqual(harness.activeScopeCount(), 0)
            let firstCompletions = await harness.completionRecorder.completions()
            let registrationRemainsActive = await AgentRunSessionStore.hasActiveRegistration(
                sessionID: harness.fixture.sessionID
            )
            XCTAssertEqual(firstCompletions.count, 1)
            XCTAssertEqual(firstCompletions.first?.result, "interrupted_by_steering")
            XCTAssertTrue(registrationRemainsActive)

            let secondWait = harness.startWait()
            try await harness.waitUntilBlocked()
            try await Task.sleep(nanoseconds: 50_000_000)

            XCTAssertTrue(harness.server.hasActiveChildAgentRunWaits(runID: harness.parentRunID))
            XCTAssertEqual(harness.activeScopeCount(), 1)
            let secondWaiterCount = await AgentRunSessionStore.shared.test_waiterCount(
                registration: harness.fixture.registration
            )
            XCTAssertEqual(
                secondWaiterCount,
                1,
                "A stale steering wake must not complete the subsequent wait"
            )

            try await harness.publishTerminal()
            let terminalValue = try await secondWait.value
            XCTAssertEqual(terminalValue.objectValue?["status"]?.stringValue, AgentRunMCPSnapshot.Status.completed.rawValue)
            let terminalText = try Self.formattedText(
                ToolOutputFormatter.formatAgentRun(args: ["op": .string("wait")], value: terminalValue)
            )
            XCTAssertFalse(terminalText.contains("### Resume waiting"))
            XCTAssertFalse(harness.server.hasActiveChildAgentRunWaits(runID: harness.parentRunID))
            XCTAssertEqual(harness.activeScopeCount(), 0)
            let allCompletions = await harness.completionRecorder.completions()
            XCTAssertEqual(allCompletions.count, 2)
            XCTAssertEqual(allCompletions.last?.reason, .snapshotReady)
        }
    }

    private static func formattedText(_ blocks: [MCP.Tool.Content]) throws -> String {
        XCTAssertEqual(blocks.count, 1)
        guard case let .text(text, _, _) = try XCTUnwrap(blocks.first) else {
            XCTFail("Expected a text block")
            return ""
        }
        return text
    }
}

@MainActor
final class AgentRunWaitDrainTestHarness {
    struct Fixture {
        let sessionID: UUID
        let registration: AgentRunSessionStore.Registration
        let epoch: AgentRunTurnEpoch
        let cursor: AgentRunSessionStore.WaitCursor
        let runningSnapshot: AgentRunMCPSnapshot
    }

    let window: WindowState
    let server: MCPServerViewModel
    let parentRunID: UUID
    let connectionID: UUID
    let fixture: Fixture
    let completionRecorder: AgentRunWaitDrainCompletionRecorder

    private let service: AgentRunMCPToolService
    private let liveSnapshots: AgentRunWaitDrainLiveSnapshots
    private var waitTasks: [Task<Value, Error>] = []
    private var didCleanup = false

    var metadata: MCPServerViewModel.RequestMetadata {
        MCPServerViewModel.RequestMetadata(
            connectionID: connectionID,
            clientName: "agent-run-wait-drain-tests",
            windowID: window.windowID,
            actorRoutedRunTab: nil
        )
    }

    private init(
        window: WindowState,
        parentRunID: UUID,
        connectionID: UUID,
        fixture: Fixture,
        completionRecorder: AgentRunWaitDrainCompletionRecorder,
        service: AgentRunMCPToolService,
        liveSnapshots: AgentRunWaitDrainLiveSnapshots
    ) {
        self.window = window
        server = window.mcpServer
        self.parentRunID = parentRunID
        self.connectionID = connectionID
        self.fixture = fixture
        self.completionRecorder = completionRecorder
        self.service = service
        self.liveSnapshots = liveSnapshots
    }

    static func withHarness<T>(
        parentRunID: UUID = UUID(),
        operation: @MainActor (AgentRunWaitDrainTestHarness) async throws -> T
    ) async throws -> T {
        let harness = try await make(parentRunID: parentRunID)
        do {
            let result = try await operation(harness)
            await harness.cleanup()
            return result
        } catch {
            await harness.cleanup()
            throw error
        }
    }

    static func make(parentRunID: UUID = UUID()) async throws -> AgentRunWaitDrainTestHarness {
        let window = makeWindow()
        let connectionID = UUID()
        let liveSnapshots = AgentRunWaitDrainLiveSnapshots()
        let completionRecorder = AgentRunWaitDrainCompletionRecorder()
        let childViewModel = makeChildViewModel(windowID: window.windowID)
        let fixture: Fixture
        do {
            fixture = try await installRunningSession(
                in: childViewModel,
                liveSnapshots: liveSnapshots
            )
        } catch {
            WindowStatesManager.shared.unregisterWindowState(window)
            throw error
        }

        guard window.mcpServer.registerRunIDMapping(
            connectionID: connectionID,
            runID: parentRunID,
            windowID: window.windowID
        ) else {
            await AgentRunSessionStore.cleanup(registration: fixture.registration)
            WindowStatesManager.shared.unregisterWindowState(window)
            throw AgentRunWaitDrainHarnessError.failedToRegisterRunMapping
        }

        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: connectionID,
                    clientName: "agent-run-wait-drain-tests",
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
                throw MCPError.internalError("startRun should not be used by wait-drain tests")
            }
        )
        service.beginAgentRunWait = { metadata, sessionIDs, timeoutSeconds in
            await window.mcpServer.test_beginAgentRunWaitScope(
                metadata: metadata,
                sessionIDs: sessionIDs,
                timeoutSeconds: timeoutSeconds
            )
        }
        service.endAgentRunWait = { token, completion in
            await window.mcpServer.test_endAgentRunWaitScope(token, completion: completion)
            await completionRecorder.record(completion)
        }
        service.currentSnapshotProvider = { sessionID, _ in
            await liveSnapshots.snapshot(for: sessionID)
        }
        service.testAgentModeViewModel = childViewModel

        return AgentRunWaitDrainTestHarness(
            window: window,
            parentRunID: parentRunID,
            connectionID: connectionID,
            fixture: fixture,
            completionRecorder: completionRecorder,
            service: service,
            liveSnapshots: liveSnapshots
        )
    }

    func beginOracleResumableWait() async throws -> UUID {
        let registered = await server.test_beginResolvedToolExecution(
            metadata: metadata,
            resolvedContext: nil,
            toolName: MCPWindowToolName.askOracle
        )
        let execution = try XCTUnwrap(registered)
        _ = await MCPServerViewModel.$currentToolExecutionID.withValue(execution.executionID) {
            await server.resolveOracleWaitInvocation()
        }
        return execution.executionID
    }

    func endOracleExecutionOnWake(_ executionID: UUID) {
        server.subscribeOracleWaitScope(executionID: executionID) { [server] in
            Task { @MainActor in
                server.test_endToolExecution(executionID: executionID)
            }
        }
    }

    func startWait(timeoutSeconds: TimeInterval = 2) -> Task<Value, Error> {
        let task = Task { @MainActor [service, fixture] in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(timeoutSeconds)
            ])
        }
        waitTasks.append(task)
        return task
    }

    func waitUntilBlocked(timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let waiterCount = await AgentRunSessionStore.shared.test_waiterCount(
                registration: fixture.registration
            )
            if waiterCount == 1,
               activeScopeCount() == 1,
               server.hasActiveChildAgentRunWaits(runID: parentRunID)
            {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw AgentRunWaitDrainHarnessError.timedOutWaitingForBlockedScope
    }

    func drain(
        source: String,
        timeoutSeconds: TimeInterval = 1
    ) async -> AgentRunWaitDrainOutcome {
        await server.wakeAndDrainAgentRunWaitersOwnedByActiveRun(
            runID: parentRunID,
            source: source,
            timeoutSeconds: timeoutSeconds
        ) { [fixture] sessionID in
            guard sessionID == fixture.sessionID else { return nil }
            return (fixture.runningSnapshot, fixture.cursor)
        }
    }

    func activeScopeCount() -> Int {
        server.test_agentRunWaitScopeCount(parentRunID: parentRunID)
    }

    func publishTerminal() async throws {
        let terminal = Self.makeSnapshot(sessionID: fixture.sessionID, status: .completed)
        await liveSnapshots.set(terminal)
        let result = await AgentRunSessionStore.publishTerminal(
            .init(epoch: fixture.epoch, snapshot: terminal),
            registration: fixture.registration,
            commitID: UUID(),
            successorKind: nil
        )
        guard case .accepted = result else {
            throw AgentRunWaitDrainHarnessError.failedToPublishTerminal
        }
    }

    func cleanup() async {
        guard !didCleanup else { return }
        didCleanup = true
        let tasks = waitTasks
        waitTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            _ = try? await task.value
        }
        server.cleanupRunIDMapping(runID: parentRunID, connectionID: connectionID)
        await AgentRunSessionStore.cleanup(registration: fixture.registration)
        WindowStatesManager.shared.unregisterWindowState(window)
    }

    private static func makeWindow() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }

    private static func makeChildViewModel(windowID: Int) -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: windowID,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in AgentRunWaitDrainCodexController() }
        )
    }

    private static func installRunningSession(
        in viewModel: AgentModeViewModel,
        liveSnapshots: AgentRunWaitDrainLiveSnapshots
    ) async throws -> Fixture {
        let sessionID = UUID()
        let session = try! await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        do {
            try await viewModel.mcpActivateControlContext(
                forTabID: session.tabID,
                sessionID: sessionID,
                originatingConnectionID: nil,
                startPending: true
            )
            await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
            guard let context = session.mcpControlContext,
                  let epoch = context.currentEpoch
            else {
                throw AgentRunWaitDrainHarnessError.missingControlContext
            }
            let cursor = AgentRunSessionStore.WaitCursor(
                registration: context.registration,
                epoch: epoch
            )
            let runningSnapshot = makeSnapshot(
                sessionID: sessionID,
                status: .running,
                latestAssistantPreview: "stale assistant text"
            )
            await liveSnapshots.set(runningSnapshot)
            await AgentRunSessionStore.signalSnapshot(runningSnapshot, cursor: cursor)
            return Fixture(
                sessionID: sessionID,
                registration: context.registration,
                epoch: epoch,
                cursor: cursor,
                runningSnapshot: runningSnapshot
            )
        } catch {
            if let registration = session.mcpControlContext?.registration {
                await AgentRunSessionStore.cleanup(registration: registration)
            }
            throw error
        }
    }

    private static func makeSnapshot(
        sessionID: UUID,
        status: AgentRunMCPSnapshot.Status,
        latestAssistantPreview: String? = nil
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            tabID: nil,
            sessionName: "Child Agent",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: status,
            statusText: status.rawValue,
            latestAssistantPreview: latestAssistantPreview,
            interaction: nil,
            transcriptItemCount: 1,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }
}

actor AgentRunWaitDrainCompletionRecorder {
    private var recordedCompletions: [AgentRunWaitScopeCompletion] = []

    func record(_ completion: AgentRunWaitScopeCompletion) {
        recordedCompletions.append(completion)
    }

    func count() -> Int {
        recordedCompletions.count
    }

    func completions() -> [AgentRunWaitScopeCompletion] {
        recordedCompletions
    }
}

actor AgentRunWaitDrainLiveSnapshots {
    private var snapshots: [UUID: AgentRunMCPSnapshot] = [:]

    func set(_ snapshot: AgentRunMCPSnapshot) {
        snapshots[snapshot.sessionID] = snapshot
    }

    func snapshot(for sessionID: UUID) -> AgentRunMCPSnapshot? {
        snapshots[sessionID]
    }
}

private enum AgentRunWaitDrainHarnessError: Error {
    case failedToRegisterRunMapping
    case timedOutWaitingForBlockedScope
    case failedToPublishTerminal
    case missingControlContext
}

private final class AgentRunWaitDrainCodexController: CodexSessionControllerTurnDispatchTestDefaults {
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
        .init(conversationID: "wait-drain-test", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "wait-drain-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "wait-drain-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        .init(
            conversationID: "wait-drain-test",
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
