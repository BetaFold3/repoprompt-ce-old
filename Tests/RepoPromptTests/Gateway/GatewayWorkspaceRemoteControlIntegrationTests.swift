import Foundation
import Logging
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

private final class WorkspaceRemoteDeviceConnector: AppLinkConnecting, @unchecked Sendable {
    let connection: RecordingAppLinkConnection
    private let lock = NSLock()
    private var clientNames: [String] = []

    init(connection: RecordingAppLinkConnection) {
        self.connection = connection
    }

    func connect(
        configuration _: GatewayConfiguration,
        clientName: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        lock.withLock {
            clientNames.append(clientName)
        }
        return connection
    }

    var recordedClientNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return clientNames
    }
}

private final class WorkspaceBindingProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() -> AppLinkPool.BindingProbeResult {
        lock.lock()
        value += 1
        lock.unlock()
        return .bound
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// V1-11 gateway-level integration lock for workspace-scoped remote control:
/// a two-window host sharing one workspace yields a unioned catalog, a session
/// the gateway never started is watchable with cold affinity (discovery sweep
/// only, as after a gateway restart) and warm affinity (recorded by the catalog
/// fan-out), steer round-trips on the resolved window, and a closed workspace
/// surfaces the structured `workspace_not_open` picker payload.
final class GatewayWorkspaceRemoteControlIntegrationTests: XCTestCase {
    private let windowOneOlderID = "11111111-1111-1111-1111-111111111111"
    private let windowOneNewerID = "22222222-2222-2222-2222-222222222222"
    private let windowTwoNewestID = "33333333-3333-3333-3333-333333333333"
    private let windowTwoOlderID = "44444444-4444-4444-4444-444444444444"
    private let sharedWorkspaceID = "66666666-6666-6666-6666-666666666666"

    private func twoWindowSharedWorkspaceListResponse() -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "windows": .array([
                .object([
                    "window_id": .int(1),
                    "workspace": .object([
                        "id": .string(sharedWorkspaceID),
                        "name": .string("Shared Workspace")
                    ])
                ]),
                .object([
                    "window_id": .int(2),
                    "workspace": .object([
                        "id": .string(sharedWorkspaceID),
                        "name": .string("Shared Workspace")
                    ])
                ])
            ]),
            "binding": .object(["state": .string("unbound")])
        ]))
    }

    private func workspaceSessionListResponse(
        _ sessions: [(id: String, name: String, lastModified: String)]
    ) -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "sessions": .array(sessions.map { session in
                .object([
                    "session_id": .string(session.id),
                    "name": .string(session.name),
                    "last_modified": .string(session.lastModified),
                    "state": .string("running")
                ])
            }),
            "workspace": .object([
                "id": .string(sharedWorkspaceID),
                "name": .string("Shared Workspace")
            ])
        ]))
    }

    private func windowOneSessions() -> [(id: String, name: String, lastModified: String)] {
        [
            (windowOneOlderID, "Window One Older", "2026-07-12T01:00:00.000Z"),
            (windowOneNewerID, "Window One Newer", "2026-07-12T02:00:00.000Z")
        ]
    }

    private func windowTwoSessions() -> [(id: String, name: String, lastModified: String)] {
        [
            (windowTwoNewestID, "Window Two Newest", "2026-07-12T04:00:00.000Z"),
            (windowTwoOlderID, "Window Two Older", "2026-07-12T03:00:00.000Z")
        ]
    }

    private func steerResult(sessionID: String) -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "session_id": .string(sessionID),
            "status": .string("running")
        ]))
    }

    private func makeRuntime(
        connection: RecordingAppLinkConnection,
        bindingState: RemoteGatewayBindingState
    ) async throws -> RemoteGatewayRuntime {
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root)
        let appLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await appLink.connect()
        let watchManager = SessionWatchManager(
            appLink: appLink,
            waitTimeoutSeconds: 0.2,
            pollRefreshSeconds: 0.2
        )
        let runtime = try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: CommandLedger(),
            watchManager: watchManager,
            auditLog: nil,
            bindingState: bindingState
        )
        await watchManager.setWindowResolver { deviceID, sessionID in
            await runtime.resolveSessionWindowForObservation(deviceID: deviceID, sessionID: sessionID)
        }
        return runtime
    }

    private func listWorkspaceSessions(
        runtime: RemoteGatewayRuntime,
        requestID: String
    ) async -> RemoteServerFrame? {
        await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: requestID,
                payload: .object(["workspace_name": .string("shared workspace")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
    }

    func testObservationRecoveryEmitsCurrentSnapshotFromRecoveredWindowWithoutClientRepoll() async throws {
        let sessionID = windowTwoNewestID
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                sessionID: sessionID,
                status: "running"
            )))
        ])
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root)
        let appLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await appLink.connect()
        let manager = SessionWatchManager(
            appLink: appLink,
            waitTimeoutSeconds: 0.05,
            pollRefreshSeconds: 0.05
        )
        let runtime = try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: CommandLedger(),
            watchManager: manager,
            auditLog: nil,
            bindingState: .bound,
            observationWindowDiscovery: { _, _ in 2 },
            observationDiscoveryTimeoutSeconds: 0.1
        )
        await manager.setObservationRouting(
            windowResolver: { deviceID, sessionID in
                await runtime.cachedSessionWindowForObservation(deviceID: deviceID, sessionID: sessionID)
            },
            windowRecovery: { deviceID, sessionID, invalidate in
                await runtime.recoverSessionWindowForObservation(
                    deviceID: deviceID,
                    sessionID: sessionID,
                    invalidate: invalidate
                )
            }
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        let frames = await waitForSessionUpdate(sink: sink, sessionID: sessionID)
        await manager.shutdown()

        XCTAssertTrue(frames.contains { $0.type == "session_update" && $0.sessionID == sessionID })
        let calls = await connection.calls.filter { $0.arguments["op"] == .string("poll") }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.arguments["_windowID"], .int(2))
    }

    func testRemoteOpenThenAutoRoutedStartSubscribeDidQueuePushesFromSecondWindow() async throws {
        let deviceID = "remote:1a2b3c4d"
        let sessionID = "99999999-9999-9999-9999-999999999999"
        let validationGate = RecordingAppLinkResponseGate()
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "status": .string("opened"),
                "window_id": .int(2),
                "workspace": .object([
                    "id": .string(sharedWorkspaceID),
                    "name": .string("Shared Workspace")
                ])
            ]))),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "windows": .array([
                    .object([
                        "window_id": .int(1),
                        "workspace": .object([
                            "id": .string("11111111-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
                            "name": .string("Initial Workspace")
                        ])
                    ]),
                    .object([
                        "window_id": .int(2),
                        "workspace": .object([
                            "id": .string(sharedWorkspaceID),
                            "name": .string("Shared Workspace")
                        ])
                    ])
                ]),
                "binding": .object(["state": .string("unbound")])
            ]))),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ]))),
            .gated(
                GatewayTestHelpers.toolResult(
                    json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")
                ),
                validationGate
            ),
            .result(GatewayTestHelpers.toolResult(
                json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "waiting_for_input")
            ))
        ])
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
        let connector = WorkspaceRemoteDeviceConnector(connection: connection)
        let bindingProbe = WorkspaceBindingProbeCounter()
        let refreshProbe = WorkspaceBindingProbeCounter()
        let pool = AppLinkPool(
            configuration: config,
            connector: connector,
            bindingProbe: { _ in bindingProbe.record() },
            refreshBindingProbe: { _ in refreshProbe.record() }
        )
        _ = try await pool.ensureLink(forDevice: deviceID)
        XCTAssertEqual(connector.recordedClientNames, [deviceID])
        XCTAssertEqual(bindingProbe.count, 1)

        let defaultAppLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection())
        )
        try await defaultAppLink.connect()
        let watchManager = SessionWatchManager(
            appLink: defaultAppLink,
            appLinkPool: pool,
            waitTimeoutSeconds: 0.2,
            pollRefreshSeconds: 0.2,
            terminalQuarantineSeconds: 0
        )
        let runtime = try RemoteGatewayRuntime(
            appLink: defaultAppLink,
            ledger: CommandLedger(),
            watchManager: watchManager,
            auditLog: nil,
            appLinkPool: pool
        )
        await watchManager.setWindowResolver { resolvedDeviceID, resolvedSessionID in
            await runtime.resolveSessionWindowForObservation(
                deviceID: resolvedDeviceID,
                sessionID: resolvedSessionID
            )
        }
        defer {
            Task {
                await watchManager.shutdown()
                await pool.shutdownAll()
                await defaultAppLink.shutdown()
            }
        }

        let open = await runtime.handle(
            RemoteClientFrame(
                type: "open_workspace",
                requestID: "topology-open",
                payload: .object(["workspace_name": .string("Shared Workspace")])
            ),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(open?.type, "command_result")
        XCTAssertEqual(open?.payload?.objectValue?["window_id"], .int(2))
        XCTAssertEqual(refreshProbe.count, 1)

        let start = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "topology-start",
                payload: .object([
                    "message": .string("Run in the opened workspace"),
                    "workspace_name": .string("Shared Workspace")
                ])
            ),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(start?.type, "command_result")
        XCTAssertEqual(start?.payload?.objectValue?["session_id"], .string(sessionID))
        let callsAfterStart = await connection.calls
        let startCall = try XCTUnwrap(callsAfterStart.last {
            $0.name == "agent_run" && $0.arguments["op"] == .string("start")
        })
        XCTAssertEqual(startCall.arguments["_windowID"], .int(2))

        let sink = RecordingFrameSink()
        let sinkID = UUID()
        let subscribeRequest = RemoteClientFrame(
            type: "subscribe",
            requestID: "topology-subscribe",
            sessionID: sessionID
        )
        let handledSubscribeResult = await runtime.handle(
            subscribeRequest,
            deviceID: deviceID,
            sinkID: sinkID,
            sink: sink
        )
        let subscribeResult = try XCTUnwrap(handledSubscribeResult)
        XCTAssertEqual(subscribeResult.type, "command_result")
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        let enteredBeforeQueue = await validationGate.hasEntered()
        XCTAssertFalse(enteredBeforeQueue)

        await sink.send(subscribeResult)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        let enteredBeforeDidQueue = await validationGate.hasEntered()
        let frameTypesBeforeDidQueue = await sink.frames.map(\.type)
        XCTAssertFalse(enteredBeforeDidQueue)
        XCTAssertEqual(frameTypesBeforeDidQueue, ["command_result"])

        await runtime.didQueueResponse(
            for: subscribeRequest,
            response: subscribeResult,
            deviceID: deviceID,
            sinkID: sinkID
        )
        await validationGate.waitUntilEntered()
        let frameTypesWhileValidationBlocked = await sink.frames.map(\.type)
        XCTAssertEqual(frameTypesWhileValidationBlocked, ["command_result"])
        await validationGate.release()

        for _ in 0 ..< 1000 {
            if await sink.frames.contains(where: { $0.type == "session_update" }) {
                break
            }
            await Task.yield()
        }
        let frames = await sink.frames
        XCTAssertEqual(frames.first?.type, "command_result")
        XCTAssertTrue(frames.dropFirst().contains {
            ($0.type == "session_update" || $0.type == "session_terminal")
                && $0.sessionID == sessionID
        })

        let observationCalls = await connection.calls.filter {
            $0.name == "agent_run"
                && ($0.arguments["op"] == .string("poll") || $0.arguments["op"] == .string("wait"))
        }
        XCTAssertFalse(observationCalls.isEmpty)
        XCTAssertTrue(observationCalls.allSatisfy { $0.arguments["_windowID"] == .int(2) })
        XCTAssertFalse(observationCalls.contains { $0.arguments["_windowID"] == nil })
    }

    func testOpenWorkspaceUnsubscribeResubscribeAdoptedSessionSteerCompletionDeliversAccountableFrame() async throws {
        let deviceID = "remote:1a2b3c4d"
        let oldSessionID = windowTwoNewestID
        let adoptedSessionID = windowTwoOlderID
        let validationGate = RecordingAppLinkResponseGate()
        let completionGate = RecordingAppLinkResponseGate()
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "status": .string("opened"),
                "window_id": .int(2),
                "workspace": .object([
                    "id": .string(sharedWorkspaceID),
                    "name": .string("Shared Workspace")
                ])
            ]))),
            .result(twoWindowSharedWorkspaceListResponse()),
            .result(workspaceSessionListResponse(windowOneSessions())),
            .result(workspaceSessionListResponse(windowTwoSessions())),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                sessionID: oldSessionID,
                status: "running"
            ))),
            .gated(
                GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                    sessionID: adoptedSessionID,
                    status: "running"
                )),
                validationGate
            ),
            .gated(
                GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                    sessionID: adoptedSessionID,
                    status: "completed"
                )),
                completionGate
            ),
            .result(steerResult(sessionID: adoptedSessionID))
        ])
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
        let connector = WorkspaceRemoteDeviceConnector(connection: connection)
        let pool = AppLinkPool(
            configuration: config,
            connector: connector,
            bindingProbe: { _ in .ambiguousStartTarget("choose a window") },
            refreshBindingProbe: { _ in .ambiguousStartTarget("choose a window") }
        )
        _ = try await pool.ensureLink(forDevice: deviceID)
        let defaultConnection = RecordingAppLinkConnection()
        let defaultAppLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: defaultConnection),
            sleep: { _ in }
        )
        try await defaultAppLink.connect()
        let watchManager = SessionWatchManager(
            appLink: defaultAppLink,
            appLinkPool: pool,
            waitTimeoutSeconds: 2,
            pollRefreshSeconds: 1,
            terminalQuarantineSeconds: 0
        )
        let runtime = try RemoteGatewayRuntime(
            appLink: defaultAppLink,
            ledger: CommandLedger(),
            watchManager: watchManager,
            auditLog: nil,
            appLinkPool: pool
        )
        await watchManager.setObservationRouting(
            windowResolver: { resolvedDeviceID, resolvedSessionID in
                await runtime.cachedSessionWindowForObservation(
                    deviceID: resolvedDeviceID,
                    sessionID: resolvedSessionID
                )
            },
            windowRecovery: { resolvedDeviceID, resolvedSessionID, invalidate in
                await runtime.recoverSessionWindowForObservation(
                    deviceID: resolvedDeviceID,
                    sessionID: resolvedSessionID,
                    invalidate: invalidate
                )
            }
        )
        defer {
            Task {
                await watchManager.shutdown()
                await pool.shutdownAll()
                await defaultAppLink.shutdown()
            }
        }
        let sink = RecordingFrameSink()
        let sinkID = UUID()
        _ = await watchManager.registerSubscription(
            deviceID: deviceID,
            sinkID: sinkID,
            sink: sink,
            sessionIDs: [oldSessionID]
        )

        let openRequest = RemoteClientFrame(
            type: "open_workspace",
            requestID: "accountable-open",
            payload: .object(["workspace_name": .string("Shared Workspace")])
        )
        let handledOpenResponse = await runtime.handle(
            openRequest,
            deviceID: deviceID,
            sinkID: sinkID,
            sink: sink
        )
        let openResponse = try XCTUnwrap(handledOpenResponse)
        XCTAssertEqual(openResponse.type, "command_result")
        XCTAssertEqual(openResponse.payload?.objectValue?["window_id"], .int(2))
        await sink.send(openResponse)

        let unsubscribeRequest = RemoteClientFrame(
            type: "unsubscribe",
            requestID: "accountable-unsubscribe",
            sessionID: oldSessionID
        )
        let handledUnsubscribeResponse = await runtime.handle(
            unsubscribeRequest,
            deviceID: deviceID,
            sinkID: sinkID,
            sink: sink
        )
        let unsubscribeResponse = try XCTUnwrap(handledUnsubscribeResponse)
        XCTAssertEqual(unsubscribeResponse.type, "command_result")
        await sink.send(unsubscribeResponse)

        let subscribeRequest = RemoteClientFrame(
            type: "subscribe",
            requestID: "accountable-subscribe",
            sessionID: adoptedSessionID
        )
        let handledSubscribeResponse = await runtime.handle(
            subscribeRequest,
            deviceID: deviceID,
            sinkID: sinkID,
            sink: sink
        )
        let subscribeResponse = try XCTUnwrap(handledSubscribeResponse)
        XCTAssertEqual(subscribeResponse.type, "command_result")
        XCTAssertEqual(
            subscribeResponse.payload?.objectValue?["subscribed_session_ids"]?.arrayValue,
            [.string(adoptedSessionID)]
        )
        let enteredBeforeQueue = await validationGate.hasEntered()
        XCTAssertFalse(enteredBeforeQueue)
        await sink.send(subscribeResponse)
        let enteredBeforeActivation = await validationGate.hasEntered()
        XCTAssertFalse(enteredBeforeActivation)
        let frameTypesBeforeActivation = await sink.frames.map(\.type)
        XCTAssertEqual(frameTypesBeforeActivation, ["command_result", "command_result", "command_result"])

        await runtime.didQueueResponse(
            for: subscribeRequest,
            response: subscribeResponse,
            deviceID: deviceID,
            sinkID: sinkID
        )
        await validationGate.waitUntilEntered()
        let frameTypesWhileValidationHeld = await sink.frames.map(\.type)
        XCTAssertEqual(frameTypesWhileValidationHeld, frameTypesBeforeActivation)
        await validationGate.release()
        await completionGate.waitUntilEntered()

        let steerRequest = RemoteClientFrame(
            type: "steer",
            requestID: "accountable-steer",
            sessionID: adoptedSessionID,
            payload: .object(["message": .string("finish the adopted session")])
        )
        let handledSteerResponse = await runtime.handle(
            steerRequest,
            deviceID: deviceID,
            sinkID: sinkID,
            sink: sink
        )
        let steerResponse = try XCTUnwrap(handledSteerResponse)
        XCTAssertEqual(steerResponse.type, "command_result")
        await sink.send(steerResponse)
        await completionGate.release()

        var frames = await sink.frames
        for _ in 0 ..< 100 {
            if frames.contains(where: { $0.type == "session_terminal" && $0.sessionID == adoptedSessionID }) {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
            frames = await sink.frames
        }
        await watchManager.shutdown()
        await pool.shutdownAll()
        await defaultAppLink.shutdown()

        let stateFrames = frames.filter { ["session_update", "session_terminal", "observation_failure"].contains($0.type) }
        XCTAssertFalse(stateFrames.contains { $0.sessionID == oldSessionID })
        XCTAssertFalse(stateFrames.contains { $0.sessionID != adoptedSessionID })
        XCTAssertTrue(stateFrames.contains {
            $0.type == "session_update"
                && $0.sessionID == adoptedSessionID
                && $0.payload?.objectValue?["status"]?.stringValue == "running"
        })
        let terminal = try XCTUnwrap(stateFrames.first {
            $0.type == "session_terminal" && $0.sessionID == adoptedSessionID
        })
        XCTAssertNotNil(terminal.seq)
        XCTAssertNotNil(terminal.seqEpoch)

        let calls = await connection.calls
        XCTAssertFalse(calls.contains { $0.arguments["op"] == .string("start") })
        let discoveryCalls = calls.filter {
            $0.name == "agent_manage" && $0.arguments["op"] == .string("list_sessions")
        }
        XCTAssertEqual(discoveryCalls.map { $0.arguments["_windowID"] }, [.int(1), .int(2)])
        let routedCalls = calls.filter {
            $0.name == "agent_run"
                && ["poll", "wait", "steer"].contains($0.arguments["op"]?.stringValue ?? "")
        }
        XCTAssertFalse(routedCalls.isEmpty)
        XCTAssertTrue(routedCalls.allSatisfy { $0.arguments["_windowID"] == .int(2) })
        let adoptedCalls = routedCalls.filter {
            $0.arguments["session_id"] == .string(adoptedSessionID)
        }
        XCTAssertTrue(adoptedCalls.contains { $0.arguments["op"] == .string("poll") })
        XCTAssertTrue(adoptedCalls.contains { $0.arguments["op"] == .string("wait") })
        XCTAssertTrue(adoptedCalls.contains { $0.arguments["op"] == .string("steer") })
        XCTAssertEqual(connector.recordedClientNames, [deviceID])
        let defaultCalls = await defaultConnection.calls
        XCTAssertTrue(defaultCalls.isEmpty)
    }

    func testWorkspaceCatalogUnionThenWarmAffinityWatchAndSteerWithoutRediscovery() async throws {
        let validationGate = RecordingAppLinkResponseGate()
        let connection = RecordingAppLinkConnection(responses: [
            .result(twoWindowSharedWorkspaceListResponse()),
            .result(workspaceSessionListResponse(windowOneSessions())),
            .result(workspaceSessionListResponse(windowTwoSessions())),
            .gated(
                GatewayTestHelpers.toolResult(
                    json: GatewayTestHelpers.snapshot(sessionID: windowOneNewerID, status: "running")
                ),
                validationGate
            )
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .ambiguousStartTarget("multiple windows")
        )
        let sink = RecordingFrameSink()

        // Two windows share the workspace with distinct session sets: the
        // catalog is the union, ordered newest-first, echoing the host workspace.
        let listResponse = await listWorkspaceSessions(runtime: runtime, requestID: "integration-union")
        XCTAssertEqual(listResponse?.type, "command_result")
        let listPayload = try XCTUnwrap(listResponse?.payload?.objectValue)
        XCTAssertEqual(listPayload["window_count"], .int(2))
        XCTAssertEqual(listPayload["workspace"]?.objectValue?["id"]?.stringValue, sharedWorkspaceID)
        XCTAssertEqual(listPayload["workspace"]?.objectValue?["name"]?.stringValue, "Shared Workspace")
        let sessions = try XCTUnwrap(listPayload["sessions"]?.arrayValue)
        XCTAssertEqual(
            sessions.map { $0.objectValue?["session_id"]?.stringValue },
            [windowTwoNewestID, windowTwoOlderID, windowOneNewerID, windowOneOlderID]
        )
        let fanOutCalls = await connection.calls.filter { $0.name == "agent_manage" }
        XCTAssertEqual(fanOutCalls.map { $0.arguments["_windowID"] }, [.int(1), .int(2)])
        XCTAssertTrue(fanOutCalls.allSatisfy { $0.arguments["workspace_id"] == .string(sharedWorkspaceID) })
        XCTAssertTrue(fanOutCalls.allSatisfy { $0.arguments["workspace_name"] == nil })

        // Subscribe to a window-one session the gateway never started: warm
        // affinity recorded by the fan-out routes the watch without rediscovery.
        let subscribeRequest = RemoteClientFrame(
            type: "subscribe",
            requestID: "integration-warm-subscribe",
            sessionID: windowOneNewerID
        )
        let subscribeSinkID = UUID()
        let subscribeResponse = await runtime.handle(
            subscribeRequest,
            deviceID: "device",
            sinkID: subscribeSinkID,
            sink: sink
        )
        XCTAssertEqual(subscribeResponse?.type, "command_result")
        XCTAssertEqual(
            subscribeResponse?.payload?.objectValue?["subscribed_session_ids"]?.arrayValue,
            [.string(windowOneNewerID)]
        )
        let queuedSubscribeResponse = try XCTUnwrap(subscribeResponse)
        await sink.send(queuedSubscribeResponse)
        await runtime.didQueueResponse(
            for: subscribeRequest,
            response: queuedSubscribeResponse,
            deviceID: "device",
            sinkID: subscribeSinkID
        )
        await validationGate.waitUntilEntered()
        await validationGate.release()

        var calls = await connection.calls
        let warmPoll = try XCTUnwrap(calls.last { $0.name == "agent_run" && $0.arguments["op"] == .string("poll") })
        XCTAssertEqual(warmPoll.arguments["_windowID"], .int(1))
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 1, "Warm affinity must not rediscover windows")

        // Steer round-trips to the affinity-resolved window.
        _ = await runtime.handle(
            RemoteClientFrame(type: "unsubscribe", requestID: "integration-warm-unsubscribe", sessionID: windowOneNewerID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        await connection.enqueue(.result(steerResult(sessionID: windowOneNewerID)))
        let steerResponse = await runtime.handle(
            RemoteClientFrame(
                type: "steer",
                requestID: "integration-warm-steer",
                sessionID: windowOneNewerID,
                payload: .object(["message": .string("continue picked-up work")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        XCTAssertEqual(steerResponse?.type, "command_result")
        calls = await connection.calls
        let steerCall = try XCTUnwrap(calls.last { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") })
        XCTAssertEqual(steerCall.arguments["_windowID"], .int(1))
        XCTAssertEqual(steerCall.arguments["message"], .string("continue picked-up work"))
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 1)
    }

    func testColdAffinityDiscoverySweepResolvesNeverStartedSessionAfterGatewayRestart() async throws {
        // First gateway lifetime: the catalog fan-out warms affinity.
        let firstConnection = RecordingAppLinkConnection(responses: [
            .result(twoWindowSharedWorkspaceListResponse()),
            .result(workspaceSessionListResponse(windowOneSessions())),
            .result(workspaceSessionListResponse(windowTwoSessions()))
        ])
        let firstRuntime = try await makeRuntime(
            connection: firstConnection,
            bindingState: .ambiguousStartTarget("multiple windows")
        )
        let firstList = await listWorkspaceSessions(runtime: firstRuntime, requestID: "integration-pre-restart")
        XCTAssertEqual(firstList?.type, "command_result")

        // Simulated gateway restart: a fresh runtime and connection carry no
        // affinity, so pickup of a never-started session must succeed through
        // the discovery sweep alone (Decision 5: affinity is only latency).
        let validationGate = RecordingAppLinkResponseGate()
        let connection = RecordingAppLinkConnection(responses: [
            .result(twoWindowSharedWorkspaceListResponse()),
            .result(workspaceSessionListResponse(windowOneSessions())),
            .result(workspaceSessionListResponse(windowTwoSessions())),
            .gated(
                GatewayTestHelpers.toolResult(
                    json: GatewayTestHelpers.snapshot(sessionID: windowTwoOlderID, status: "running")
                ),
                validationGate
            )
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .bindingRequired("bind first")
        )
        let sink = RecordingFrameSink()

        let subscribeRequest = RemoteClientFrame(
            type: "subscribe",
            requestID: "integration-cold-subscribe",
            sessionID: windowTwoOlderID
        )
        let subscribeSinkID = UUID()
        let subscribeResponse = await runtime.handle(
            subscribeRequest,
            deviceID: "device",
            sinkID: subscribeSinkID,
            sink: sink
        )
        XCTAssertEqual(subscribeResponse?.type, "command_result")
        XCTAssertEqual(
            subscribeResponse?.payload?.objectValue?["subscribed_session_ids"]?.arrayValue,
            [.string(windowTwoOlderID)]
        )
        let queuedSubscribeResponse = try XCTUnwrap(subscribeResponse)
        await sink.send(queuedSubscribeResponse)
        await runtime.didQueueResponse(
            for: subscribeRequest,
            response: queuedSubscribeResponse,
            deviceID: "device",
            sinkID: subscribeSinkID
        )
        await validationGate.waitUntilEntered()
        await validationGate.release()

        var calls = await connection.calls
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 1)
        let discoveryCalls = calls.filter { $0.name == "agent_manage" && $0.arguments["op"] == .string("list_sessions") }
        XCTAssertEqual(discoveryCalls.map { $0.arguments["_windowID"] }, [.int(1), .int(2)])
        let coldPoll = try XCTUnwrap(calls.last { $0.name == "agent_run" && $0.arguments["op"] == .string("poll") })
        XCTAssertEqual(coldPoll.arguments["_windowID"], .int(2))

        // Steer round-trips using the affinity learned by the sweep — no
        // further window discovery is required.
        _ = await runtime.handle(
            RemoteClientFrame(type: "unsubscribe", requestID: "integration-cold-unsubscribe", sessionID: windowTwoOlderID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        await connection.enqueue(.result(steerResult(sessionID: windowTwoOlderID)))
        let steerResponse = await runtime.handle(
            RemoteClientFrame(
                type: "steer",
                requestID: "integration-cold-steer",
                sessionID: windowTwoOlderID,
                payload: .object(["message": .string("resume after restart")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        XCTAssertEqual(steerResponse?.type, "command_result")
        calls = await connection.calls
        let steerCall = try XCTUnwrap(calls.last { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") })
        XCTAssertEqual(steerCall.arguments["_windowID"], .int(2))
        XCTAssertEqual(steerCall.arguments["message"], .string("resume after restart"))
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 1)
    }

    func testWorkspaceScopedListSessionsWithNoMatchingWindowsReturnsWorkspaceNotOpenPickerDetails() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(twoWindowSharedWorkspaceListResponse())
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .ambiguousStartTarget("multiple windows")
        )

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "integration-not-open",
                payload: .object(["workspace_name": .string("Closed Workspace")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        let payload = try XCTUnwrap(response?.payload?.objectValue)
        XCTAssertEqual(payload["code"]?.stringValue, "workspace_not_open")
        let windows = try XCTUnwrap(payload["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map { $0.objectValue?["window_id"]?.intValue }, [1, 2])
        XCTAssertTrue(windows.allSatisfy { $0.objectValue?["workspace_name"]?.stringValue == "Shared Workspace" })
        let calls = await connection.calls
        XCTAssertFalse(calls.contains { $0.name == "agent_manage" }, "Zero matches must not fan out to any window")
    }

    func testClosedWorkspaceOpenThenWorkspaceScopedListSessionsSucceeds() async throws {
        let closedWorkspaceID = "88888888-8888-8888-8888-888888888888"
        let closedWorkspaceName = "Closed Workspace"
        let openedWindowList = GatewayTestHelpers.toolResult(json: .object([
            "windows": .array([
                .object([
                    "window_id": .int(7),
                    "workspace": .object([
                        "id": .string(closedWorkspaceID),
                        "name": .string(closedWorkspaceName)
                    ])
                ])
            ]),
            "binding": .object(["state": .string("unbound")])
        ]))
        let openedSessions = GatewayTestHelpers.toolResult(json: .object([
            "sessions": .array([
                .object([
                    "session_id": .string(windowOneNewerID),
                    "name": .string("Opened Session"),
                    "last_modified": .string("2026-07-15T01:00:00.000Z"),
                    "state": .string("running")
                ])
            ]),
            "workspace": .object([
                "id": .string(closedWorkspaceID),
                "name": .string(closedWorkspaceName)
            ])
        ]))
        let connection = RecordingAppLinkConnection(responses: [
            .result(twoWindowSharedWorkspaceListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "status": .string("opened"),
                "window_id": .int(7),
                "workspace": .object([
                    "id": .string(closedWorkspaceID),
                    "name": .string(closedWorkspaceName)
                ])
            ]))),
            .result(openedWindowList),
            .result(openedSessions)
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .ambiguousStartTarget("multiple windows")
        )

        let before = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "integration-before-open",
                payload: .object(["workspace_name": .string(closedWorkspaceName)])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(before?.payload?.objectValue?["code"], .string("workspace_not_open"))

        let open = await runtime.handle(
            RemoteClientFrame(
                type: "open_workspace",
                requestID: "integration-open",
                payload: .object(["workspace_name": .string(closedWorkspaceName)])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(open?.type, "command_result")
        XCTAssertEqual(open?.payload?.objectValue?["status"], .string("opened"))

        let after = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "integration-after-open",
                payload: .object(["workspace_name": .string(closedWorkspaceName)])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(after?.type, "command_result")
        XCTAssertEqual(
            after?.payload?.objectValue?["sessions"]?.arrayValue?.first?.objectValue?["session_id"],
            .string(windowOneNewerID)
        )

        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), [
            "bind_context",
            "manage_workspaces",
            "bind_context",
            "agent_manage"
        ])
        XCTAssertEqual(calls[1].arguments["action"], .string("open"))
        XCTAssertEqual(calls[3].arguments["op"], .string("list_sessions"))
        XCTAssertEqual(calls[3].arguments["_windowID"], .int(7))
    }

    /// Owner-requested chooser: a BOUND single-window connection whose owner then opens a second Mac
    /// window can rediscover workspaces fresh, list the second workspace by ID only, and steer its
    /// session on the second window through catalog affinity — with no binding change and no
    /// window-closing workaround.
    func testBoundConnectionDiscoversSecondWindowThenChosenWorkspaceListsAndSteersByIDOnly() async throws {
        let workspaceAID = "77777777-7777-7777-7777-777777777777"
        let workspaceBID = "99999999-9999-9999-9999-999999999999"
        let windowA: JSONValue = .object([
            "window_id": .int(1),
            "workspace": .object(["id": .string(workspaceAID), "name": .string("Workspace A")])
        ])
        let windowB: JSONValue = .object([
            "window_id": .int(2),
            "workspace": .object(["id": .string(workspaceBID), "name": .string("Workspace B")])
        ])
        let singleWindow = GatewayTestHelpers.toolResult(json: .object(["windows": .array([windowA])]))
        let twoWindows = GatewayTestHelpers.toolResult(json: .object(["windows": .array([windowA, windowB])]))
        let workspaceBSessions = GatewayTestHelpers.toolResult(json: .object([
            "sessions": .array([
                .object([
                    "session_id": .string(windowTwoNewestID),
                    "name": .string("Window Two Session"),
                    "last_modified": .string("2026-07-12T04:00:00.000Z"),
                    "state": .string("running")
                ])
            ]),
            "workspace": .object(["id": .string(workspaceBID), "name": .string("Workspace B")])
        ]))
        let connection = RecordingAppLinkConnection(responses: [
            .result(singleWindow),
            .result(twoWindows),
            .result(twoWindows),
            .result(workspaceBSessions),
            .result(steerResult(sessionID: windowTwoNewestID))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)

        func handle(_ frame: RemoteClientFrame) async -> RemoteServerFrame? {
            await runtime.handle(frame, deviceID: "device", sinkID: UUID(), sink: RecordingFrameSink())
        }

        let before = await handle(RemoteClientFrame(type: "list_workspaces", requestID: "chooser-before"))
        XCTAssertEqual(before?.payload?.objectValue?["windows"]?.arrayValue?.count, 1)

        let after = await handle(RemoteClientFrame(type: "list_workspaces", requestID: "chooser-after"))
        let afterWindows = try XCTUnwrap(after?.payload?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(
            afterWindows.map { $0.objectValue?["workspace_id"]?.stringValue },
            [workspaceAID, workspaceBID]
        )

        let list = await handle(RemoteClientFrame(
            type: "list_sessions",
            requestID: "chooser-list-b",
            payload: .object(["workspace_id": .string(workspaceBID), "limit": .int(50)])
        ))
        XCTAssertEqual(list?.type, "command_result")
        XCTAssertEqual(list?.payload?.objectValue?["workspace"]?.objectValue?["id"], .string(workspaceBID))
        XCTAssertEqual(
            list?.payload?.objectValue?["sessions"]?.arrayValue?.map { $0.objectValue?["session_id"]?.stringValue },
            [windowTwoNewestID]
        )

        let steer = await handle(RemoteClientFrame(
            type: "steer",
            requestID: "chooser-steer-b",
            sessionID: windowTwoNewestID,
            payload: .object(["message": .string("continue on the second window")])
        ))
        XCTAssertEqual(steer?.type, "command_result")

        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context", "bind_context", "bind_context", "agent_manage", "agent_run"])
        XCTAssertEqual(calls[3].arguments["_windowID"], .int(2))
        XCTAssertEqual(calls[3].arguments["workspace_id"], .string(workspaceBID))
        XCTAssertNil(calls[3].arguments["workspace_name"])
        XCTAssertEqual(calls[4].arguments["op"], .string("steer"))
        XCTAssertEqual(calls[4].arguments["_windowID"], .int(2), "Catalog affinity must route the steer to window 2")
        XCTAssertFalse(calls.contains { $0.name == "manage_workspaces" }, "The chooser never opens or focuses a workspace")
    }

    /// The owner's main case: the phone connects while several Mac windows are open, so its link is
    /// UNBOUND (`binding_required`). Discovery, an ID-only list of the second window's workspace, a
    /// subscribe and a steer all succeed through catalog affinity, with no binding, open or focus.
    func testUnboundMultiWindowConnectionDiscoversListsSubscribesAndSteersChosenWorkspace() async throws {
        let workspaceAID = "77777777-7777-7777-7777-777777777777"
        let workspaceBID = "99999999-9999-9999-9999-999999999999"
        let twoWindows = GatewayTestHelpers.toolResult(json: .object([
            "windows": .array([
                .object([
                    "window_id": .int(1),
                    "workspace": .object(["id": .string(workspaceAID), "name": .string("Workspace A")])
                ]),
                .object([
                    "window_id": .int(2),
                    "workspace": .object(["id": .string(workspaceBID), "name": .string("Workspace B")])
                ])
            ]),
            "binding": .object(["state": .string("unbound")])
        ]))
        let workspaceBSessions = GatewayTestHelpers.toolResult(json: .object([
            "sessions": .array([
                .object([
                    "session_id": .string(windowTwoNewestID),
                    "name": .string("Window Two Session"),
                    "last_modified": .string("2026-07-12T04:00:00.000Z"),
                    "state": .string("running")
                ])
            ]),
            "workspace": .object(["id": .string(workspaceBID), "name": .string("Workspace B")])
        ]))
        let connection = RecordingAppLinkConnection(responses: [
            .result(twoWindows),
            .result(twoWindows),
            .result(workspaceBSessions)
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .bindingRequired("Multiple RepoPrompt windows are open; bind this connection to a window before remote operations.")
        )

        func handle(_ frame: RemoteClientFrame) async -> RemoteServerFrame? {
            await runtime.handle(frame, deviceID: "device", sinkID: UUID(), sink: RecordingFrameSink())
        }

        let discovered = await handle(RemoteClientFrame(type: "list_workspaces", requestID: "unbound-discover"))
        XCTAssertEqual(
            discovered?.payload?.objectValue?["windows"]?.arrayValue?.map { $0.objectValue?["workspace_id"]?.stringValue },
            [workspaceAID, workspaceBID]
        )

        let list = await handle(RemoteClientFrame(
            type: "list_sessions",
            requestID: "unbound-list-b",
            payload: .object(["workspace_id": .string(workspaceBID), "limit": .int(50)])
        ))
        XCTAssertEqual(list?.type, "command_result")
        XCTAssertEqual(
            list?.payload?.objectValue?["sessions"]?.arrayValue?.map { $0.objectValue?["session_id"]?.stringValue },
            [windowTwoNewestID]
        )

        let subscribe = await handle(RemoteClientFrame(
            type: "subscribe",
            requestID: "unbound-subscribe",
            payload: .object(["session_ids": .array([.string(windowTwoNewestID)])])
        ))
        XCTAssertEqual(subscribe?.type, "command_result", "Affinity from the scoped list resolves the unbound watch")
        XCTAssertEqual(
            subscribe?.payload?.objectValue?["subscribed_session_ids"]?.arrayValue,
            [.string(windowTwoNewestID)]
        )

        await connection.enqueue(.result(steerResult(sessionID: windowTwoNewestID)))
        let steer = await handle(RemoteClientFrame(
            type: "steer",
            requestID: "unbound-steer",
            sessionID: windowTwoNewestID,
            payload: .object(["message": .string("continue from the phone")])
        ))
        XCTAssertEqual(steer?.type, "command_result")

        let calls = await connection.calls
        let listCall = try XCTUnwrap(calls.first { $0.name == "agent_manage" })
        XCTAssertEqual(listCall.arguments["_windowID"], .int(2))
        XCTAssertEqual(listCall.arguments["workspace_id"], .string(workspaceBID))
        XCTAssertNil(listCall.arguments["workspace_name"])
        let steerCall = try XCTUnwrap(calls.last { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") })
        XCTAssertEqual(steerCall.arguments["_windowID"], .int(2))
        XCTAssertTrue(
            calls.filter { $0.name == "bind_context" }.allSatisfy { $0.arguments["op"] == .string("list") },
            "Only read-only window listing; the connection is never bound to a window"
        )
        XCTAssertFalse(calls.contains { $0.name == "manage_workspaces" }, "Nothing is opened or focused on the Mac")
    }

    private func waitForSessionUpdate(
        sink: RecordingFrameSink,
        sessionID: String
    ) async -> [RemoteServerFrame] {
        for _ in 0 ..< 100 {
            let frames = await sink.frames
            if frames.contains(where: { $0.type == "session_update" && $0.sessionID == sessionID }) {
                return frames
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await sink.frames
    }
}
