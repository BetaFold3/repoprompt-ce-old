import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class AgentRunWaitStatusUpdateTests: XCTestCase {
    override func tearDown() {
        AgentRunMCPToolService.statusUpdateSliceSecondsOverride = nil
        AgentRunMCPToolService.waitClockNowOverride = nil
        AgentRunSessionStore.waiterTimeoutSleepOverride = nil
        super.tearDown()
    }

    func testWaitWithIncludeStatusUpdatesReturnsOnRunningStatusTextChange() async throws {
        AgentRunMCPToolService.statusUpdateSliceSecondsOverride = 0.02
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(
            in: viewModel,
            liveSnapshots: liveSnapshots,
            initialStatusText: "Connecting…"
        )
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let service = makeService(window: window, viewModel: viewModel, liveSnapshots: liveSnapshots, recorder: recorder)

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(1),
                "include_status_updates": .bool(true)
            ])
        }
        try await waitForAgentRunSessionStoreWaiter(registration: fixture.registration)

        let updated = makeSnapshot(sessionID: fixture.sessionID, status: .running, statusText: "Thinking…")
        await liveSnapshots.set(updated)
        await AgentRunSessionStore.signalSnapshot(updated, cursor: fixture.cursor)

        let value = try await waitTask.value
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["session_id"]?.stringValue, fixture.sessionID.uuidString)
        XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertEqual(object["status_text"]?.stringValue, "Thinking…")
        XCTAssertEqual(object["_meta"]?.objectValue?["wait_result"]?.stringValue, "status_update")
    }

    func testWaitStatusUpdateResultCarriesWaitResultMeta() async throws {
        AgentRunMCPToolService.statusUpdateSliceSecondsOverride = 0.02
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(
            in: viewModel,
            liveSnapshots: liveSnapshots,
            initialStatusText: "Sending…"
        )
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let service = makeService(window: window, viewModel: viewModel, liveSnapshots: liveSnapshots, recorder: recorder)

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(1),
                "include_status_updates": .bool(true)
            ])
        }
        try await waitForAgentRunSessionStoreWaiter(registration: fixture.registration)

        let updated = makeSnapshot(sessionID: fixture.sessionID, status: .running, statusText: "Waiting…")
        await liveSnapshots.set(updated)
        await AgentRunSessionStore.signalSnapshot(updated, cursor: fixture.cursor)

        let value = try await waitTask.value
        let meta = try XCTUnwrap(value.objectValue?["_meta"]?.objectValue)
        XCTAssertEqual(meta["wait_result"]?.stringValue, "status_update")
        XCTAssertNil(meta["wake_reason"])

        let completions = await recorder.completions()
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].reason, .statusUpdate)
        XCTAssertEqual(completions[0].result, "status_update")
        XCTAssertEqual(completions[0].winnerSessionID, fixture.sessionID)
        XCTAssertTrue(completions[0].pendingSessionIDs.isEmpty)
    }

    func testWaitWithIncludeStatusUpdatesIgnoresTransitionToNilStatusText() async throws {
        AgentRunMCPToolService.statusUpdateSliceSecondsOverride = 0.01
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(
            in: viewModel,
            liveSnapshots: liveSnapshots,
            initialStatusText: "Thinking…"
        )
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let service = makeService(window: window, viewModel: viewModel, liveSnapshots: liveSnapshots, recorder: recorder)

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(0.08),
                "include_status_updates": .bool(true)
            ])
        }
        try await waitForAgentRunSessionStoreWaiter(registration: fixture.registration)

        let updated = makeSnapshot(sessionID: fixture.sessionID, status: .running, statusText: nil)
        await liveSnapshots.set(updated)
        await AgentRunSessionStore.signalSnapshot(updated, cursor: fixture.cursor)

        let value = try await waitTask.value
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, AgentRunMCPSnapshot.Status.running.rawValue)
        XCTAssertNil(object["status_text"])
        XCTAssertEqual(object["_meta"]?.objectValue?["wait_result"]?.stringValue, "timed_out")
    }

    func testWaitWithoutOptInBlocksThroughStatusTextChange() async throws {
        AgentRunMCPToolService.statusUpdateSliceSecondsOverride = 0.01
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(
            in: viewModel,
            liveSnapshots: liveSnapshots,
            initialStatusText: "Connecting…"
        )
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let service = makeService(window: window, viewModel: viewModel, liveSnapshots: liveSnapshots, recorder: recorder)

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(0.08)
            ])
        }
        try await waitForAgentRunSessionStoreWaiter(registration: fixture.registration)

        let updated = makeSnapshot(sessionID: fixture.sessionID, status: .running, statusText: "Thinking…")
        await liveSnapshots.set(updated)
        await AgentRunSessionStore.signalSnapshot(updated, cursor: fixture.cursor)

        let value = try await waitTask.value
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status_text"]?.stringValue, "Thinking…")
        XCTAssertEqual(object["_meta"]?.objectValue?["wait_result"]?.stringValue, "timed_out")
    }

    func testWaitStatusUpdateRespectsRealDeadlineShorterThanSlice() async throws {
        AgentRunMCPToolService.statusUpdateSliceSecondsOverride = 0.2
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let fixture = try await installRunningSession(
            in: viewModel,
            liveSnapshots: liveSnapshots,
            initialStatusText: "Connecting…"
        )
        defer { Task { await AgentRunSessionStore.cleanup(registration: fixture.registration) } }
        let service = makeService(window: window, viewModel: viewModel, liveSnapshots: liveSnapshots, recorder: recorder)
        let clock = ControlledAgentRunWaitClock()
        let timeoutGate = AgentRunSessionStoreTimeoutGate()
        AgentRunMCPToolService.waitClockNowOverride = { clock.now() }
        AgentRunSessionStore.waiterTimeoutSleepOverride = { nanoseconds in
            await timeoutGate.sleep(nanoseconds: nanoseconds)
        }

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_id": .string(fixture.sessionID.uuidString),
                "timeout": .double(0.03),
                "include_status_updates": .bool(true)
            ])
        }
        defer {
            timeoutGate.release()
            waitTask.cancel()
        }

        do {
            try await waitForAgentRunSessionStoreWaiter(registration: fixture.registration)
            let requestedTimeoutNanoseconds = try await timeoutGate.waitForRequestedTimeout()
            let requestedTimeoutSeconds = TimeInterval(requestedTimeoutNanoseconds) / 1_000_000_000
            XCTAssertGreaterThan(requestedTimeoutSeconds, 0)
            XCTAssertLessThan(requestedTimeoutSeconds, 0.2)
            XCTAssertEqual(requestedTimeoutSeconds, 0.03, accuracy: 0.001)

            clock.advance(by: .seconds(1))
            let updated = makeSnapshot(sessionID: fixture.sessionID, status: .running, statusText: "Thinking…")
            await liveSnapshots.set(updated)
            await AgentRunSessionStore.signalSnapshot(updated, cursor: fixture.cursor)
            timeoutGate.release()

            let value = try await waitForBoundedFixtureTaskValue(
                waitTask,
                description: "status-update deadline completion",
                cleanupBeforeCancellation: {
                    timeoutGate.release()
                }
            )
            XCTAssertEqual(value.objectValue?["_meta"]?.objectValue?["wait_result"]?.stringValue, "timed_out")
        } catch {
            timeoutGate.release()
            waitTask.cancel()
            _ = await waitTask.result
            throw error
        }
    }

    func testTimeoutGateWithoutRequestThrowsBoundedErrorAndLeavesNoParkedSleep() async {
        let timeoutGate = AgentRunSessionStoreTimeoutGate()

        do {
            _ = try await timeoutGate.waitForRequestedTimeout(timeout: 0.03)
            XCTFail("Expected bounded timeout-request observation to fail when no request arrives")
        } catch let error as AsyncTestConditionTimeout {
            XCTAssertEqual(error.description, "AgentRunSessionStore timeout request")
            XCTAssertEqual(error.timeout, 0.03)
        } catch {
            XCTFail("Unexpected timeout-request observation error: \(error)")
        }

        timeoutGate.release()
        XCTAssertTrue(timeoutGate.isReleased)
        XCTAssertEqual(timeoutGate.parkedSleepCount, 0)
    }

    func testMultiSessionWaitReturnsFirstStatusTextChange() async throws {
        AgentRunMCPToolService.statusUpdateSliceSecondsOverride = 0.02
        let window = makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let liveSnapshots = LiveSnapshots()
        let recorder = WaitScopeRecorder()
        let viewModel = makeViewModel(windowID: window.windowID)
        let first = try await installRunningSession(
            in: viewModel,
            liveSnapshots: liveSnapshots,
            initialStatusText: "Connecting…"
        )
        let second = try await installRunningSession(
            in: viewModel,
            liveSnapshots: liveSnapshots,
            initialStatusText: "Connecting…"
        )
        defer {
            Task {
                await AgentRunSessionStore.cleanup(registration: first.registration)
                await AgentRunSessionStore.cleanup(registration: second.registration)
            }
        }
        let service = makeService(window: window, viewModel: viewModel, liveSnapshots: liveSnapshots, recorder: recorder)

        let waitTask = Task { @MainActor in
            try await service.execute(args: [
                "op": .string("wait"),
                "session_ids": .array([
                    .string(first.sessionID.uuidString),
                    .string(second.sessionID.uuidString)
                ]),
                "timeout": .double(1),
                "include_status_updates": .bool(true)
            ])
        }
        try await waitForAgentRunSessionStoreWaiter(registration: first.registration)
        try await waitForAgentRunSessionStoreWaiter(registration: second.registration)

        let updated = makeSnapshot(sessionID: second.sessionID, status: .running, statusText: "Thinking…")
        await liveSnapshots.set(updated)
        await AgentRunSessionStore.signalSnapshot(updated, cursor: second.cursor)

        let value = try await waitTask.value
        let object = try XCTUnwrap(value.objectValue)
        let wait = try XCTUnwrap(object["wait"]?.objectValue)
        XCTAssertEqual(object["session_id"]?.stringValue, second.sessionID.uuidString)
        XCTAssertEqual(object["_meta"]?.objectValue?["wait_result"]?.stringValue, "status_update")
        XCTAssertEqual(wait["result"]?.stringValue, "status_update")
        XCTAssertEqual(wait["winner_session_id"]?.stringValue, second.sessionID.uuidString)
        XCTAssertEqual(
            wait["pending_session_ids"]?.arrayValue?.compactMap(\.stringValue),
            [first.sessionID.uuidString]
        )
    }

    func testNormalizedStatusTextKeyTrimsAndNilsEmpty() {
        XCTAssertNil(AgentRunMCPToolService.normalizedStatusTextKey(nil))
        XCTAssertNil(AgentRunMCPToolService.normalizedStatusTextKey(""))
        XCTAssertNil(AgentRunMCPToolService.normalizedStatusTextKey("  \n\t  "))
        XCTAssertEqual(AgentRunMCPToolService.normalizedStatusTextKey("  Thinking…\n"), "Thinking…")
    }

    func testShouldReturnStatusUpdatePredicateTable() {
        let sessionID = UUID()
        XCTAssertFalse(AgentRunMCPToolService.shouldReturnStatusUpdate(baselineKey: nil, latest: nil))
        XCTAssertFalse(AgentRunMCPToolService.shouldReturnStatusUpdate(
            baselineKey: "Thinking…",
            latest: makeSnapshot(sessionID: sessionID, status: .running, statusText: " Thinking… ")
        ))
        XCTAssertTrue(AgentRunMCPToolService.shouldReturnStatusUpdate(
            baselineKey: "Connecting…",
            latest: makeSnapshot(sessionID: sessionID, status: .running, statusText: "Thinking…")
        ))
        XCTAssertTrue(AgentRunMCPToolService.shouldReturnStatusUpdate(
            baselineKey: nil,
            latest: makeSnapshot(sessionID: sessionID, status: .running, statusText: "Thinking…")
        ))
        XCTAssertFalse(AgentRunMCPToolService.shouldReturnStatusUpdate(
            baselineKey: "Connecting…",
            latest: makeSnapshot(sessionID: sessionID, status: .running, statusText: nil)
        ))
        XCTAssertFalse(AgentRunMCPToolService.shouldReturnStatusUpdate(
            baselineKey: "Connecting…",
            latest: makeSnapshot(sessionID: sessionID, status: .completed, statusText: "Thinking…")
        ))
        XCTAssertFalse(AgentRunMCPToolService.shouldReturnStatusUpdate(
            baselineKey: "Connecting…",
            latest: makeSnapshot(sessionID: sessionID, status: .waitingForInput, statusText: "Thinking…")
        ))
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
            codexControllerFactory: { _, _, _, _, _, _ in WaitStatusUpdateTestCodexController() }
        )
    }

    private func installRunningSession(
        in viewModel: AgentModeViewModel,
        liveSnapshots: LiveSnapshots,
        initialStatusText: String?
    ) async throws -> RunningSessionFixture {
        let sessionID = UUID()
        let session = try! await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        let context = try XCTUnwrap(session.mcpControlContext)
        let epoch = try XCTUnwrap(context.currentEpoch)
        let cursor = AgentRunSessionStore.WaitCursor(registration: context.registration, epoch: epoch)
        let runningSnapshot = makeSnapshot(
            sessionID: sessionID,
            status: .running,
            statusText: initialStatusText,
            latestAssistantPreview: "stale assistant text"
        )
        await liveSnapshots.set(runningSnapshot)
        await AgentRunSessionStore.signalSnapshot(runningSnapshot, cursor: cursor)
        return RunningSessionFixture(
            sessionID: sessionID,
            registration: context.registration,
            epoch: epoch,
            cursor: cursor,
            runningSnapshot: runningSnapshot
        )
    }

    private func makeService(
        window: WindowState,
        viewModel: AgentModeViewModel,
        liveSnapshots: LiveSnapshots,
        recorder: WaitScopeRecorder
    ) -> AgentRunMCPToolService {
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "agent-run-status-update-tests",
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
                throw MCPError.internalError("startRun should not be used by status update wait tests")
            }
        )
        service.beginAgentRunWait = {
            (_: MCPServerViewModel.RequestMetadata, sessionIDs: Set<UUID>, _: TimeInterval?) async -> UUID? in
            await recorder.begin(sessionIDs: sessionIDs)
        }
        service.endAgentRunWait = {
            (token: UUID, completion: AgentRunWaitScopeCompletion) async in
            await recorder.end(token: token, completion: completion)
        }
        service.currentSnapshotProvider = {
            (sessionID: UUID, _: AgentModeViewModel) async -> AgentRunMCPSnapshot? in
            await liveSnapshots.snapshot(for: sessionID)
        }
        service.testAgentModeViewModel = viewModel
        return service
    }

    private func makeSnapshot(
        sessionID: UUID,
        runID: UUID? = nil,
        status: AgentRunMCPSnapshot.Status,
        statusText: String?,
        latestAssistantPreview: String? = nil
    ) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            runID: runID,
            tabID: nil,
            sessionName: "Child Agent",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: status,
            statusText: statusText,
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

private final class ControlledAgentRunWaitClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now

    func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by duration: Duration) {
        lock.lock()
        instant = instant.advanced(by: duration)
        lock.unlock()
    }
}

private struct RunningSessionFixture {
    let sessionID: UUID
    let registration: AgentRunSessionStore.Registration
    let epoch: AgentRunTurnEpoch
    let cursor: AgentRunSessionStore.WaitCursor
    let runningSnapshot: AgentRunMCPSnapshot
}

private actor LiveSnapshots {
    private var snapshots: [UUID: AgentRunMCPSnapshot] = [:]

    func set(_ snapshot: AgentRunMCPSnapshot) {
        snapshots[snapshot.sessionID] = snapshot
    }

    func snapshot(for sessionID: UUID) -> AgentRunMCPSnapshot? {
        snapshots[sessionID]
    }
}

private final class WaitStatusUpdateTestCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "status-update-wait-test", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "status-update-wait-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "status-update-wait-test", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        .init(
            conversationID: "status-update-wait-test",
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

private actor WaitScopeRecorder {
    private var startedSessionIDs: [Set<UUID>] = []
    private var recordedCompletions: [AgentRunWaitScopeCompletion] = []

    func begin(sessionIDs: Set<UUID>) -> UUID {
        startedSessionIDs.append(sessionIDs)
        return UUID()
    }

    func end(token _: UUID, completion: AgentRunWaitScopeCompletion) {
        recordedCompletions.append(completion)
    }

    func beginRecords() -> [Set<UUID>] {
        startedSessionIDs
    }

    func completions() -> [AgentRunWaitScopeCompletion] {
        recordedCompletions
    }
}
