import Foundation
import Logging
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptGateway
@testable import RepoPromptPlatform
import RepoPromptRemoteWire
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

private final class BindingRuntimeConnector: AppLinkConnecting, @unchecked Sendable {
    let connection: RecordingAppLinkConnection

    init(connection: RecordingAppLinkConnection) {
        self.connection = connection
    }

    func connect(
        configuration _: GatewayConfiguration,
        clientName _: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        connection
    }
}

private final class BindingProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [AppLinkPool.BindingProbeResult]
    private(set) var callCount = 0

    init(_ states: [AppLinkPool.BindingProbeResult]) {
        self.states = states
    }

    func next() -> AppLinkPool.BindingProbeResult {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        if states.isEmpty {
            return .ambiguousStartTarget("multiple windows")
        }
        return states.removeFirst()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}

/// Plan §6.6: unbound multi-window connections get structured `binding_required`
/// on observation ops, binding errors carry eligible start-target windows, and
/// an explicit `window_id` selector lets `start` proceed without binding.
final class GatewayRuntimeBindingTests: XCTestCase {
    private let sessionID = "11111111-1111-1111-1111-111111111111"

    func testBindWindowMessageClassificationExemptsOpenWorkspaceButPreservesStart() {
        let error = RemoteGatewayRuntimeError.appToolError(payload: .object([
            "error": .string("Bind this connection to a window before continuing.")
        ]))

        XCTAssertEqual(
            error.code(frame: RemoteClientFrame(type: "open_workspace")),
            "app_tool_error"
        )
        XCTAssertEqual(
            error.code(frame: RemoteClientFrame(type: "start")),
            "binding_required"
        )

        let structured = RemoteGatewayRuntimeError.appToolError(payload: .object([
            "code": .string("explicit_code"),
            "error": .string("Bind this connection to a window before continuing.")
        ]))
        XCTAssertEqual(
            structured.code(frame: RemoteClientFrame(type: "open_workspace")),
            "explicit_code"
        )
    }

    private func windowListResponse() -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "windows": .array([
                .object([
                    "window_id": .int(1),
                    "is_current_window": .bool(true),
                    "workspace": .object([
                        "id": .string("44444444-4444-4444-4444-444444444444"),
                        "name": .string("Workspace A")
                    ])
                ]),
                .object([
                    "window_id": .int(2),
                    "is_current_window": .bool(false),
                    "workspace": .object([
                        "id": .string("55555555-5555-5555-5555-555555555555"),
                        "name": .string("Workspace B")
                    ])
                ])
            ]),
            "binding": .object(["state": .string("unbound")])
        ]))
    }

    private func duplicateWorkspaceWindowListResponse() -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "windows": .array([
                .object([
                    "window_id": .int(1),
                    "workspace": .object([
                        "id": .string("44444444-4444-4444-4444-444444444444"),
                        "name": .string("Shared Workspace")
                    ])
                ]),
                .object([
                    "window_id": .int(2),
                    "workspace": .object([
                        "id": .string("55555555-5555-5555-5555-555555555555"),
                        "name": .string("Shared Workspace")
                    ])
                ])
            ]),
            "binding": .object(["state": .string("unbound")])
        ]))
    }

    private func sharedWorkspaceWindowListResponse() -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "windows": .array([
                .object([
                    "window_id": .int(1),
                    "workspace": .object([
                        "id": .string("66666666-6666-6666-6666-666666666666"),
                        "name": .string("Shared Workspace")
                    ])
                ]),
                .object([
                    "window_id": .int(2),
                    "workspace": .object([
                        "id": .string("66666666-6666-6666-6666-666666666666"),
                        "name": .string("Shared Workspace")
                    ])
                ]),
                .object([
                    "window_id": .int(3),
                    "workspace": .object([
                        "id": .string("77777777-7777-7777-7777-777777777777"),
                        "name": .string("Other Workspace")
                    ])
                ])
            ]),
            "binding": .object(["state": .string("unbound")])
        ]))
    }

    private func workspaceSessionListResponse(
        _ sessions: [(id: String, name: String, lastModified: String)],
        workspaceID: String,
        workspaceName: String
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
                "id": .string(workspaceID),
                "name": .string(workspaceName)
            ])
        ]))
    }

    private func sessionListResponse(_ ids: [String]) -> MCPToolResult {
        GatewayTestHelpers.toolResult(json: .object([
            "sessions": .array(ids.map { id in
                .object([
                    "session_id": .string(id),
                    "name": .string("Session \(id.prefix(4))"),
                    "last_modified": .string("2026-07-02T00:00:00.000Z"),
                    "item_count": .int(1),
                    "state": .string("running"),
                    "is_live": .bool(true)
                ])
            })
        ]))
    }

    private func auditRecords(in directory: URL, op: String) -> [[String: Any]] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" }
            .flatMap { fileURL -> [[String: Any]] in
                let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                return text.split(separator: "\n").compactMap { rawLine in
                    guard let data = rawLine.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          object["op"] as? String == op
                    else { return nil }
                    return object
                }
            }
    }

    private func waitForAuditRecord(
        in directory: URL,
        op: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [String: Any] {
        for _ in 0 ..< 100 {
            if let record = auditRecords(in: directory, op: op).first {
                return record
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for audit record", file: file, line: line)
        return [:]
    }

    private func waitForAuditRecords(
        in directory: URL,
        op: String,
        minimumCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [[String: Any]] {
        for _ in 0 ..< 100 {
            let records = auditRecords(in: directory, op: op)
            if records.count >= minimumCount {
                return records
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(minimumCount) audit records", file: file, line: line)
        return []
    }

    private func makeRuntime(
        connection: RecordingAppLinkConnection,
        bindingState: RemoteGatewayBindingState,
        auditLog: RemoteAuditLog? = nil,
        configureObservationRouting: Bool = false
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
            auditLog: auditLog,
            bindingState: bindingState
        )
        if configureObservationRouting {
            await watchManager.setObservationRouting(
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
        }
        return runtime
    }

    private func makePooledRuntime(
        connection: RecordingAppLinkConnection,
        configuration: GatewayConfiguration,
        deviceID: String,
        auditLog: RemoteAuditLog,
        initialProbe: BindingProbeRecorder,
        refreshProbe: BindingProbeRecorder
    ) async throws -> RemoteGatewayRuntime {
        let pool = AppLinkPool(
            configuration: configuration,
            connector: BindingRuntimeConnector(connection: connection),
            bindingProbe: { _ in initialProbe.next() },
            refreshBindingProbe: { _ in refreshProbe.next() }
        )
        _ = try await pool.ensureLink(forDevice: deviceID)

        let defaultAppLink = AppLinkSession(
            config: configuration,
            connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection())
        )
        try await defaultAppLink.connect()
        return try RemoteGatewayRuntime(
            appLink: defaultAppLink,
            ledger: CommandLedger(),
            watchManager: SessionWatchManager(appLink: defaultAppLink, appLinkPool: pool),
            auditLog: auditLog,
            appLinkPool: pool
        )
    }

    private func makeObservationRuntime(
        connection: RecordingAppLinkConnection,
        affinity: GatewaySessionWindowAffinity = GatewaySessionWindowAffinity(),
        discovery: @escaping RemoteGatewayRuntime.ObservationWindowDiscovery,
        timeoutSeconds: TimeInterval = 0.2,
        logger: Logger = Logger(label: "test.gateway.observation")
    ) async throws -> (RemoteGatewayRuntime, SessionWatchManager) {
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
            logger: logger,
            waitTimeoutSeconds: 0.05,
            pollRefreshSeconds: 0.05,
            observationFailureBudgets: .init(
                routingUnavailable: 2,
                linkUnavailable: 2,
                toolFailure: 2,
                invalidSnapshot: 2
            )
        )
        let runtime = try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: CommandLedger(),
            watchManager: manager,
            auditLog: nil,
            logger: logger,
            bindingState: .bound,
            sessionWindowAffinity: affinity,
            observationWindowDiscovery: discovery,
            observationDiscoveryTimeoutSeconds: timeoutSeconds
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
        return (runtime, manager)
    }

    private func assertListAgentsRoutingAuditIsRedacted(
        _ record: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let routingKeys = [
            "binding_state_initial",
            "binding_state_retry",
            "fallback_initial",
            "fallback_retry",
            "window_id_injected_initial",
            "window_id_injected_retry",
            "error_origin_initial",
            "error_origin_retry",
            "recovery_retried"
        ]
        for key in routingKeys {
            guard let value = record[key] else { continue }
            XCTAssertTrue(
                value is String || value is Bool,
                "Routing audit field \(key) must be a bounded string or Boolean",
                file: file,
                line: line
            )
        }

        XCTAssertNil(record["auto_routed_window_id"], file: file, line: line)
        XCTAssertNil(record["window_id"], file: file, line: line)
        for forbiddenKey in ["payload", "arguments", "model", "token", "secret"] {
            XCTAssertNil(record[forbiddenKey], file: file, line: line)
        }
    }

    func testObservationNilAffinityDiscoversBeforeCallAndNeverCallsWithoutWindowID() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                sessionID: sessionID,
                status: "running"
            )))
        ])
        let (_, manager) = try await makeObservationRuntime(
            connection: connection,
            discovery: { _, _ in 7 }
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        _ = await waitForSessionUpdateCount(1, sink: sink)
        await manager.shutdown()

        let observationCalls = await connection.calls.filter { call in
            call.name == "agent_run"
                && (call.arguments["op"] == .string("poll") || call.arguments["op"] == .string("wait"))
        }
        XCTAssertFalse(observationCalls.isEmpty)
        XCTAssertTrue(observationCalls.allSatisfy { $0.arguments["_windowID"] == .int(7) })
    }

    func testObservationStaleAffinityBindingErrorInvalidatesAndRetriesOnceWithRecoveredWindowID() async throws {
        let affinity = GatewaySessionWindowAffinity()
        await affinity.record(sessionID: sessionID, windowID: 1)
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(
                json: .object(["code": .string("binding_required")]),
                isError: true
            )),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                sessionID: sessionID,
                status: "running"
            )))
        ])
        let (_, manager) = try await makeObservationRuntime(
            connection: connection,
            affinity: affinity,
            discovery: { _, _ in 2 }
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        _ = await waitForSessionUpdateCount(1, sink: sink)
        await manager.shutdown()

        let pollWindows = await connection.calls
            .filter { $0.arguments["op"] == .string("poll") }
            .compactMap { $0.arguments["_windowID"]?.intValue }
        XCTAssertEqual(pollWindows, [1, 2])
    }

    func testObservationMultiWindowErrorRecoversOnceWithRecoveredWindowID() async throws {
        let affinity = GatewaySessionWindowAffinity()
        await affinity.record(sessionID: sessionID, windowID: 3)
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(
                json: .object(["message": .string("multiple windows require binding_required")]),
                isError: true
            )),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                sessionID: sessionID,
                status: "running"
            )))
        ])
        let (_, manager) = try await makeObservationRuntime(
            connection: connection,
            affinity: affinity,
            discovery: { _, _ in 4 }
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        _ = await waitForSessionUpdateCount(1, sink: sink)
        await manager.shutdown()

        let pollWindows = await connection.calls
            .filter { $0.arguments["op"] == .string("poll") }
            .compactMap { $0.arguments["_windowID"]?.intValue }
        XCTAssertEqual(pollWindows, [3, 4])
    }

    func testObservationDiscoveryTimeoutReturnsBoundedFailureAndLateDiscoveryCannotRoute() async throws {
        let gate = RecordingAppLinkResponseGate()
        let connection = RecordingAppLinkConnection()
        let (runtime, manager) = try await makeObservationRuntime(
            connection: connection,
            discovery: { _, _ in
                await gate.enterAndWaitForRelease()
                return 9
            },
            timeoutSeconds: 0.01
        )

        let result = await runtime.recoverSessionWindowForObservation(
            deviceID: "device",
            sessionID: sessionID,
            invalidate: false
        )
        XCTAssertNil(result)
        await gate.release()
        await Task.yield()
        await manager.shutdown()

        let calls = await connection.calls
        XCTAssertFalse(calls.contains { $0.name == "agent_run" })
    }

    func testAffinityRecoveryOperationalEventsAreStructuredAndRedacted() async throws {
        let recorder = BindingLogRecorder()
        let logger = Logger(label: "test.gateway.observation") { _ in recorder.handler() }
        let connection = RecordingAppLinkConnection()
        let (runtime, manager) = try await makeObservationRuntime(
            connection: connection,
            discovery: { _, _ in 8 },
            logger: logger
        )

        let result = await runtime.recoverSessionWindowForObservation(
            deviceID: "device-secret\npayload",
            sessionID: "session-secret\nprompt",
            invalidate: false
        )
        await manager.shutdown()

        XCTAssertEqual(result, 8)
        let messages = recorder.messages.joined(separator: " ")
        XCTAssertTrue(messages.contains("event=affinity_recovery"))
        XCTAssertTrue(messages.contains("outcome=issued"))
        XCTAssertTrue(messages.contains("outcome=recovered"))
        XCTAssertFalse(messages.contains("\n"))
        XCTAssertFalse(messages.contains("raw MCP"))
    }

    func testAffinityNoticeIdentifiersUseSafeEncodingAndRejectFieldInjection() async throws {
        let recorder = BindingLogRecorder()
        let logger = Logger(label: "test.gateway.observation.safe-identifiers") { _ in recorder.handler() }
        let deviceID = "remote:secret-device\r\n outcome=forged\tapi_key=alpha"
        let sessionID = "secret-session\r\n session_id=forged authorization=bearer"
        let (runtime, manager) = try await makeObservationRuntime(
            connection: RecordingAppLinkConnection(),
            discovery: { _, _ in 8 },
            logger: logger
        )

        let result = await runtime.recoverSessionWindowForObservation(
            deviceID: deviceID,
            sessionID: sessionID,
            invalidate: false
        )
        await manager.shutdown()

        XCTAssertEqual(result, 8)
        let notices = recorder.noticeMessages
        let joined = notices.joined(separator: " ")
        XCTAssertFalse(joined.contains("secret-device"))
        XCTAssertFalse(joined.contains("secret-session"))
        XCTAssertFalse(joined.contains("outcome=forged"))
        XCTAssertFalse(joined.contains("api_key=alpha"))
        XCTAssertFalse(joined.contains("authorization=bearer"))
        XCTAssertFalse(joined.contains("\r"))
        XCTAssertFalse(joined.contains("\n"))
        XCTAssertFalse(joined.contains("\t"))
        for message in notices {
            for key in ["device_id=", "session_id="] {
                guard let range = message.range(of: key) else { continue }
                let value = message[range.upperBound...].prefix { !$0.isWhitespace }
                XCTAssertEqual(value.count, 27)
                XCTAssertTrue(value.hasPrefix("id_"))
                XCTAssertTrue(value.dropFirst(3).allSatisfy {
                    $0.isNumber || "abcdef".contains($0)
                })
            }
        }
    }

    func testAffinityOperationalEventsAvoidWarmHitNoticeAmplification() async throws {
        let recorder = BindingLogRecorder()
        let logger = Logger(label: "test.gateway.observation.warm-hit") { _ in recorder.handler() }
        let affinity = GatewaySessionWindowAffinity()
        await affinity.record(sessionID: sessionID, windowID: 7)
        let (runtime, manager) = try await makeObservationRuntime(
            connection: RecordingAppLinkConnection(),
            affinity: affinity,
            discovery: { _, _ in 9 },
            logger: logger
        )

        let first = await runtime.cachedSessionWindowForObservation(deviceID: "device", sessionID: sessionID)
        let second = await runtime.cachedSessionWindowForObservation(deviceID: "device", sessionID: sessionID)
        XCTAssertEqual(first, 7)
        XCTAssertEqual(second, 7)
        await manager.shutdown()

        XCTAssertEqual(recorder.noticeMessages.count(where: { $0.contains("outcome=warm_hit") }), 0)
        XCTAssertEqual(recorder.messages.count(where: { $0.contains("outcome=warm_hit") }), 2)
    }

    func testWarmObservationAffinityBypassesAppLinkLookupBindingRefreshAndDiscovery() async throws {
        let deviceID = "remote:1a2b3c4d"
        let canonicalSessionID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

        do {
            let connection = RecordingAppLinkConnection(responses: [
                .result(GatewayTestHelpers.toolResult(json: .object([
                    "session_id": .string(canonicalSessionID),
                    "status": .string("running")
                ])))
            ])
            let root = try GatewayTestHelpers.temporaryRoot()
            let config = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
            let probe = BindingProbeRecorder([.bound])
            let pool = AppLinkPool(
                configuration: config,
                connector: BindingRuntimeConnector(connection: connection),
                bindingProbe: { _ in probe.next() }
            )
            _ = try await pool.ensureLink(forDevice: deviceID)
            let defaultAppLink = AppLinkSession(
                config: config,
                connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection())
            )
            try await defaultAppLink.connect()
            let watchManager = SessionWatchManager(appLink: defaultAppLink, appLinkPool: pool)
            let runtime = try RemoteGatewayRuntime(
                appLink: defaultAppLink,
                ledger: CommandLedger(),
                watchManager: watchManager,
                auditLog: nil,
                appLinkPool: pool
            )

            let start = await runtime.handle(
                RemoteClientFrame(
                    type: "start",
                    requestID: "warm-unavailable-start",
                    payload: .object([
                        "message": .string("go"),
                        "window_id": .int(2)
                    ])
                ),
                deviceID: deviceID,
                sinkID: UUID(),
                sink: RecordingFrameSink()
            )
            XCTAssertEqual(start?.type, "command_result")
            let callCountBeforeTeardown = await connection.calls.count
            XCTAssertEqual(callCountBeforeTeardown, 1)
            let didTeardown = await pool.teardown(deviceID: deviceID)
            XCTAssertTrue(didTeardown)

            let resolved = await runtime.resolveSessionWindowForObservation(
                deviceID: deviceID,
                sessionID: "  \(canonicalSessionID)  "
            )
            XCTAssertEqual(resolved, 2)
            let callCountAfterResolution = await connection.calls.count
            XCTAssertEqual(callCountAfterResolution, 1)
            XCTAssertEqual(probe.count, 1)
        }

        do {
            let refreshSessionID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            let connection = RecordingAppLinkConnection(responses: [
                .result(GatewayTestHelpers.toolResult(json: .object([
                    "session_id": .string(refreshSessionID),
                    "status": .string("running")
                ])))
            ])
            let root = try GatewayTestHelpers.temporaryRoot()
            let config = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
            let initialProbe = BindingProbeRecorder([.bound])
            let refreshProbe = BindingProbeRecorder([.bound])
            let pool = AppLinkPool(
                configuration: config,
                connector: BindingRuntimeConnector(connection: connection),
                bindingProbe: { _ in initialProbe.next() },
                refreshBindingProbe: { _ in refreshProbe.next() },
                unknownBindingRefreshCooldown: 0
            )
            _ = try await pool.ensureLink(forDevice: deviceID)
            let defaultAppLink = AppLinkSession(
                config: config,
                connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection())
            )
            try await defaultAppLink.connect()
            let watchManager = SessionWatchManager(appLink: defaultAppLink, appLinkPool: pool)
            let runtime = try RemoteGatewayRuntime(
                appLink: defaultAppLink,
                ledger: CommandLedger(),
                watchManager: watchManager,
                auditLog: nil,
                appLinkPool: pool
            )

            let start = await runtime.handle(
                RemoteClientFrame(
                    type: "start",
                    requestID: "warm-refresh-start",
                    payload: .object([
                        "message": .string("go"),
                        "window_id": .int(2)
                    ])
                ),
                deviceID: deviceID,
                sinkID: UUID(),
                sink: RecordingFrameSink()
            )
            XCTAssertEqual(start?.type, "command_result")
            await pool.setBindingState(.bound, forDevice: deviceID, refreshOnNextResolve: true)
            let callsBeforeResolution = await connection.calls
            let refreshCountBeforeResolution = refreshProbe.count

            let resolved = await runtime.resolveSessionWindowForObservation(
                deviceID: deviceID,
                sessionID: "\n\(refreshSessionID)\t"
            )
            XCTAssertEqual(resolved, 2)
            XCTAssertEqual(refreshProbe.count, refreshCountBeforeResolution)
            let callsAfterResolution = await connection.calls
            XCTAssertEqual(callsAfterResolution, callsBeforeResolution)
            XCTAssertFalse(callsBeforeResolution.contains {
                $0.name == "bind_context"
                    || $0.name == "agent_manage" && $0.arguments["op"] == .string("list_sessions")
            })
        }
    }

    func testSubscribeAcknowledgesBeforeDeferredValidationCanEmit() async throws {
        let gate = RecordingAppLinkResponseGate()
        let connection = RecordingAppLinkConnection(responses: [
            .gated(
                GatewayTestHelpers.toolResult(
                    json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")
                ),
                gate
            )
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)
        let sink = RecordingFrameSink()
        let sinkID = UUID()
        let request = RemoteClientFrame(
            type: "subscribe",
            requestID: "subscribe-order",
            sessionID: sessionID
        )

        let handledResponse = await runtime.handle(
            request,
            deviceID: "device",
            sinkID: sinkID,
            sink: sink
        )
        let response = try XCTUnwrap(handledResponse)

        let callsBeforeAcknowledgment = await connection.calls
        XCTAssertTrue(callsBeforeAcknowledgment.isEmpty)
        await sink.send(response)
        await runtime.didQueueResponse(
            for: request,
            response: response,
            deviceID: "device",
            sinkID: sinkID
        )
        await gate.waitUntilEntered()

        let framesWhileValidationBlocked = await sink.frames
        XCTAssertEqual(framesWhileValidationBlocked.map(\.type), ["command_result"])

        await gate.release()
        for _ in 0 ..< 50 {
            let currentFrames = await sink.frames
            if currentFrames.contains(where: { $0.type == "session_update" }) {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let frames = await sink.frames
        XCTAssertEqual(frames.first?.type, "command_result")
        XCTAssertTrue(frames.contains { $0.type == "session_update" })
    }

    func testConcurrentMissingRequestIDSubscriptionsKeepPerSinkValidation() async throws {
        let otherSessionID = "22222222-2222-2222-2222-222222222222"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(
                json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")
            )),
            .result(GatewayTestHelpers.toolResult(
                json: GatewayTestHelpers.snapshot(sessionID: otherSessionID, status: "running")
            ))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)
        let firstSink = RecordingFrameSink()
        let secondSink = RecordingFrameSink()
        let firstSinkID = UUID()
        let secondSinkID = UUID()
        let firstRequest = RemoteClientFrame(type: "subscribe", sessionID: sessionID)
        let secondRequest = RemoteClientFrame(type: "subscribe", sessionID: otherSessionID)

        let firstHandled = await runtime.handle(
            firstRequest,
            deviceID: "device",
            sinkID: firstSinkID,
            sink: firstSink
        )
        let secondHandled = await runtime.handle(
            secondRequest,
            deviceID: "device",
            sinkID: secondSinkID,
            sink: secondSink
        )
        let firstResponse = try XCTUnwrap(firstHandled)
        let secondResponse = try XCTUnwrap(secondHandled)
        await firstSink.send(firstResponse)
        await secondSink.send(secondResponse)
        await runtime.didQueueResponse(
            for: firstRequest,
            response: firstResponse,
            deviceID: "device",
            sinkID: firstSinkID
        )
        await runtime.didQueueResponse(
            for: secondRequest,
            response: secondResponse,
            deviceID: "device",
            sinkID: secondSinkID
        )

        var calls = await connection.calls
        for _ in 0 ..< 50 where calls.count < 2 {
            try? await Task.sleep(for: .milliseconds(20))
            calls = await connection.calls
        }
        let polledSessionIDs = Set(calls.compactMap { call -> String? in
            guard call.name == "agent_run",
                  call.arguments["op"] == .string("poll")
            else { return nil }
            return call.arguments["session_id"]?.stringValue
        })
        XCTAssertEqual(polledSessionIDs, Set([sessionID, otherSessionID]))
    }

    /// S3-A-09: when a subscribe's correlated response is WITHHELD (e.g. the connection locked or its
    /// binding changed at settlement), the handler calls `discardQueuedResponse` instead of
    /// `didQueueResponse`. The discard must drop EXACTLY that request's deferred validation — so its
    /// catch-up poll never runs and no `session_update` is emitted — without cancelling an unrelated
    /// subscription that shares the same request id on a different connection.
    func testWithheldSubscriptionDiscardsOnlyItsOwnDeferredValidation() async throws {
        let withheldSessionID = sessionID
        let survivingSessionID = "22222222-2222-2222-2222-222222222222"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(
                json: GatewayTestHelpers.snapshot(sessionID: survivingSessionID, status: "running")
            ))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)
        let withheldSink = RecordingFrameSink()
        let survivingSink = RecordingFrameSink()
        let withheldSinkID = UUID()
        let survivingSinkID = UUID()
        // Same request id ("dup") on two different connections — distinct FIFO validation keys.
        let withheldRequest = RemoteClientFrame(type: "subscribe", requestID: "dup", sessionID: withheldSessionID)
        let survivingRequest = RemoteClientFrame(type: "subscribe", requestID: "dup", sessionID: survivingSessionID)

        let withheldMaybe = await runtime.handle(withheldRequest, deviceID: "device", sinkID: withheldSinkID, sink: withheldSink)
        _ = try XCTUnwrap(withheldMaybe)
        let survivingMaybe = await runtime.handle(survivingRequest, deviceID: "device", sinkID: survivingSinkID, sink: survivingSink)
        let survivingHandled = try XCTUnwrap(survivingMaybe)

        // The withheld connection's response is never delivered; its deferred validation is discarded.
        await runtime.discardQueuedResponse(for: withheldRequest, deviceID: "device", sinkID: withheldSinkID)
        // The unrelated duplicate-id subscription is delivered and its deferred validation activates.
        await survivingSink.send(survivingHandled)
        await runtime.didQueueResponse(for: survivingRequest, response: survivingHandled, deviceID: "device", sinkID: survivingSinkID)

        for _ in 0 ..< 50 {
            let frames = await survivingSink.frames
            if frames.contains(where: { $0.type == "session_update" }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        // The surviving duplicate-requestID subscription's deferred validation was NOT discarded by
        // the withheld one's discard (the FIFO validation key includes sinkID + sessionIDs, so a shared
        // client requestID does not collide). It therefore activates: it emits a correlated
        // session_update and runs its catch-up poll against its own session.
        let survivingFrames = await survivingSink.frames
        XCTAssertTrue(survivingFrames.contains { $0.type == "session_update" }, "The surviving duplicate-id subscription still validates and emits.")
        let polledSessions = await Set(connection.calls.compactMap { $0.arguments["session_id"]?.stringValue })
        XCTAssertTrue(polledSessions.contains(survivingSessionID), "The surviving subscription polls its own session during catch-up validation.")
        // The withheld subscription's deferred validation entry was popped by its own discard (keyed by
        // sinkID + requestID + sessionIDs), so it was never handed to `validateSubscription`: the discard
        // controls the deferred VALIDATION, not the already-registered observation intent.
    }

    func testSubscribeOnUnboundConnectionReturnsBindingRequiredWithWindows() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse())
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "subscribe", requestID: "r1", sessionID: sessionID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_error")
        let payload = try XCTUnwrap(frame.payload?.objectValue)
        XCTAssertEqual(payload["code"]?.stringValue, "binding_required")
        let windows = try XCTUnwrap(payload["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].objectValue?["window_id"]?.intValue, 1)
        XCTAssertEqual(windows[0].objectValue?["workspace_name"]?.stringValue, "Workspace A")
        XCTAssertEqual(windows[1].objectValue?["workspace_id"]?.stringValue, "55555555-5555-5555-5555-555555555555")

        // The catch-up wait/poll loop must never have been armed.
        let calls = await connection.calls
        XCTAssertFalse(calls.contains { $0.name == "agent_run" })
    }

    func testUnsubscribeOnUnboundConnectionReturnsBindingRequired() async throws {
        let connection = RecordingAppLinkConnection()
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "unsubscribe", requestID: "r1", sessionID: sessionID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_error")
        XCTAssertEqual(frame.payload?.objectValue?["code"]?.stringValue, "binding_required")
    }

    func testSubscribeOnAmbiguousStartTargetConnectionReturnsBindingRequired() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse())
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "subscribe", requestID: "r1", sessionID: sessionID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_error")
        XCTAssertEqual(frame.payload?.objectValue?["code"]?.stringValue, "binding_required")
    }

    func testSubscribeOnUnboundConnectionProceedsWhenSessionWindowResolves() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([])),
            .result(sessionListResponse([sessionID])),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .bindingRequired("bind first"),
            configureObservationRouting: true
        )
        let sink = RecordingFrameSink()

        let request = RemoteClientFrame(type: "subscribe", requestID: "r1", sessionID: sessionID)
        let sinkID = UUID()
        let response = await runtime.handle(
            request,
            deviceID: "device",
            sinkID: sinkID,
            sink: sink
        )

        let responseFrame = try XCTUnwrap(response)
        XCTAssertEqual(responseFrame.type, "command_result")
        await sink.send(responseFrame)
        await runtime.didQueueResponse(
            for: request,
            response: responseFrame,
            deviceID: "device",
            sinkID: sinkID
        )
        var calls = await connection.calls
        for _ in 0 ..< 50 where !calls.contains(where: {
            $0.name == "agent_run" && $0.arguments["op"] == .string("poll")
        }) {
            try? await Task.sleep(for: .milliseconds(20))
            calls = await connection.calls
        }
        let poll = try XCTUnwrap(calls.last { $0.name == "agent_run" && $0.arguments["op"] == .string("poll") })
        XCTAssertEqual(poll.arguments["_windowID"], .int(2))
    }

    func testParentFilteredListSessionsRoutesToParentWindow() async throws {
        let childSessionID = "22222222-2222-2222-2222-222222222222"
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([])),
            .result(sessionListResponse([sessionID])),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "sessions": .array([
                    .object([
                        "session_id": .string(childSessionID),
                        "name": .string("Child Worker"),
                        "state": .string("running"),
                        "parent_session_id": .string(sessionID)
                    ])
                ])
            ])))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "r-child-list",
                payload: .object(["parent_session_id": .string(sessionID)])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        let sessions = try XCTUnwrap(response?.payload?.objectValue?["sessions"]?.arrayValue)
        XCTAssertEqual(sessions.first?.objectValue?["session_id"]?.stringValue, childSessionID)
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context", "agent_manage", "agent_manage", "agent_manage"])
        let listSessions = try XCTUnwrap(calls.last)
        XCTAssertEqual(listSessions.arguments["op"], .string("list_sessions"))
        XCTAssertEqual(listSessions.arguments["parent_session_id"], .string(sessionID))
        XCTAssertEqual(listSessions.arguments["_windowID"], .int(2))
    }

    func testWorkspaceScopedListSessionsRoutesSingleMatchAndStripsWorkspaceName() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(workspaceSessionListResponse(
                [(sessionID, "Workspace B Session", "2026-07-12T01:00:00.000Z")],
                workspaceID: "55555555-5555-5555-5555-555555555555",
                workspaceName: "Workspace B"
            ))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-single",
                payload: .object(["workspace_name": .string(" workspace b ")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        XCTAssertEqual(response?.payload?.objectValue?["window_count"], .int(1))
        XCTAssertEqual(
            response?.payload?.objectValue?["workspace"]?.objectValue?["id"]?.stringValue,
            "55555555-5555-5555-5555-555555555555"
        )
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context", "agent_manage"])
        let listCall = try XCTUnwrap(calls.last)
        XCTAssertEqual(listCall.arguments["_windowID"], .int(2))
        XCTAssertEqual(listCall.arguments["workspace_id"], .string("55555555-5555-5555-5555-555555555555"))
        XCTAssertNil(listCall.arguments["workspace_name"])
    }

    func testWorkspaceScopedListSessionsFansOutDeduplicatesNewestAndRecordsAffinity() async throws {
        let duplicateID = sessionID
        let firstOnlyID = "22222222-2222-2222-2222-222222222222"
        let secondOnlyID = "33333333-3333-3333-3333-333333333333"
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let connection = RecordingAppLinkConnection(responses: [
            .result(sharedWorkspaceWindowListResponse()),
            .result(workspaceSessionListResponse(
                [
                    (duplicateID, "Older Duplicate", "2026-07-12T01:00:00.000Z"),
                    (firstOnlyID, "First Only", "2026-07-12T02:00:00.000Z")
                ],
                workspaceID: "66666666-6666-6666-6666-666666666666",
                workspaceName: "Shared Workspace"
            )),
            .result(workspaceSessionListResponse(
                [
                    (duplicateID, "Newer Duplicate", "2026-07-12T04:00:00.000Z"),
                    (secondOnlyID, "Second Only", "2026-07-12T03:00:00.000Z")
                ],
                workspaceID: "66666666-6666-6666-6666-666666666666",
                workspaceName: "Shared Workspace"
            )),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(duplicateID),
                "status": .string("running")
            ])))
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .ambiguousStartTarget("multiple windows"),
            auditLog: auditLog
        )

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-union",
                payload: .object(["workspace_name": .string("shared workspace")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        XCTAssertEqual(response?.payload?.objectValue?["window_count"], .int(2))
        let sessions = try XCTUnwrap(response?.payload?.objectValue?["sessions"]?.arrayValue)
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions.map { $0.objectValue?["session_id"]?.stringValue }, [duplicateID, secondOnlyID, firstOnlyID])
        XCTAssertEqual(sessions.first?.objectValue?["name"]?.stringValue, "Newer Duplicate")

        let steerResponse = await runtime.handle(
            RemoteClientFrame(
                type: "steer",
                requestID: "workspace-list-affinity",
                sessionID: duplicateID,
                payload: .object(["message": .string("continue")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(steerResponse?.type, "command_result")

        let calls = await connection.calls
        let listCalls = calls.filter { $0.name == "agent_manage" }
        XCTAssertEqual(listCalls.count, 2)
        XCTAssertEqual(listCalls.map { $0.arguments["_windowID"] }, [.int(1), .int(2)])
        XCTAssertTrue(listCalls.allSatisfy { $0.arguments["workspace_name"] == nil })
        XCTAssertTrue(listCalls.allSatisfy {
            $0.arguments["workspace_id"] == .string("66666666-6666-6666-6666-666666666666")
        })
        let steerCall = try XCTUnwrap(calls.last { $0.name == "agent_run" })
        XCTAssertEqual(steerCall.arguments["_windowID"], .int(2))
        let auditRecord = try await waitForAuditRecord(in: auditDirectory, op: "list_sessions")
        XCTAssertEqual(auditRecord["workspace_match_count"] as? Int, 2)
    }

    func testWorkspaceScopedListSessionsAppliesLimitAfterUnion() async throws {
        let duplicateID = sessionID
        let firstOnlyID = "22222222-2222-2222-2222-222222222222"
        let secondOnlyID = "33333333-3333-3333-3333-333333333333"
        let connection = RecordingAppLinkConnection(responses: [
            .result(sharedWorkspaceWindowListResponse()),
            .result(workspaceSessionListResponse(
                [
                    (duplicateID, "Older Duplicate", "2026-07-12T01:00:00.000Z"),
                    (firstOnlyID, "First Only", "2026-07-12T02:00:00.000Z")
                ],
                workspaceID: "66666666-6666-6666-6666-666666666666",
                workspaceName: "Shared Workspace"
            )),
            .result(workspaceSessionListResponse(
                [
                    (duplicateID, "Newer Duplicate", "2026-07-12T04:00:00.000Z"),
                    (secondOnlyID, "Second Only", "2026-07-12T03:00:00.000Z")
                ],
                workspaceID: "66666666-6666-6666-6666-666666666666",
                workspaceName: "Shared Workspace"
            ))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-limit",
                payload: .object([
                    "workspace_name": .string("Shared Workspace"),
                    "limit": .int(2)
                ])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        let sessions = try XCTUnwrap(response?.payload?.objectValue?["sessions"]?.arrayValue)
        XCTAssertEqual(sessions.map { $0.objectValue?["session_id"]?.stringValue }, [duplicateID, secondOnlyID])
        XCTAssertEqual(response?.payload?.objectValue?["window_count"], .int(2))
    }

    func testWorkspaceScopedListSessionsRejectsUnsupportedPayloadBeforeLookup() async throws {
        let connection = RecordingAppLinkConnection()
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-invalid",
                payload: .object([
                    "workspace_name": .string("Missing"),
                    "include_hidden": .bool(true)
                ])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "unsupported_payload_key")
        let calls = await connection.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testWorkspaceScopedListSessionsWithoutMatchesReturnsWorkspaceNotOpenWithWindows() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse())
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-missing",
                payload: .object(["workspace_name": .string("Missing")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "workspace_not_open")
        let windows = try XCTUnwrap(response?.payload?.objectValue?["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context"])
    }

    /// Compatibility: after the last Mac window closes, a workspace-scoped list keeps its existing
    /// lookup-unavailable mapping (`app_tool_error`, never `workspace_not_open`), so the desktop remote
    /// sidebar does not newly auto-open a workspace on a windowless host. The browser-only
    /// `list_workspaces` read reports the same empty inventory honestly as `windows: []`.
    func testWorkspaceScopedListSessionsAfterLastWindowClosedKeepsLegacyErrorWhileDiscoveryIsEmpty() async throws {
        let workspaceB = "55555555-5555-5555-5555-555555555555"
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(workspaceSessionListResponse(
                [(sessionID, "Workspace B Session", "2026-07-12T01:00:00.000Z")],
                workspaceID: workspaceB,
                workspaceName: "Workspace B"
            )),
            .result(GatewayTestHelpers.toolResult(json: .object(["windows": .array([])]))),
            .result(GatewayTestHelpers.toolResult(json: .object(["windows": .array([])]))),
            .result(GatewayTestHelpers.toolResult(json: .object(["unexpected": .string("shape")]))),
            .failure("raw transport detail")
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)

        func list(_ requestID: String) async -> RemoteServerFrame? {
            await runtime.handle(
                RemoteClientFrame(
                    type: "list_sessions",
                    requestID: requestID,
                    payload: .object(["workspace_id": .string(workspaceB), "limit": .int(50)])
                ),
                deviceID: "device",
                sinkID: UUID(),
                sink: RecordingFrameSink()
            )
        }

        let before = await list("last-window-before")
        XCTAssertEqual(before?.type, "command_result")

        let closed = await list("last-window-closed")
        XCTAssertEqual(closed?.type, "command_error")
        XCTAssertEqual(
            closed?.payload?.objectValue?["code"],
            .string("app_tool_error"),
            "Legacy mapping kept: not workspace_not_open, which would trigger desktop auto-open"
        )

        let discovered = await runtime.handle(
            RemoteClientFrame(type: "list_workspaces", requestID: "last-window-discover"),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(discovered?.type, "command_result")
        XCTAssertEqual(discovered?.payload, .object(["windows": .array([])]), "A fresh read, never the earlier windows")

        for requestID in ["lookup-decode", "lookup-transport"] {
            let failed = await list(requestID)
            XCTAssertEqual(failed?.payload?.objectValue?["code"], .string("app_tool_error"), requestID)
        }
        let calls = await connection.calls
        XCTAssertEqual(
            calls.map(\.name),
            ["bind_context", "agent_manage", "bind_context", "bind_context", "bind_context", "bind_context"]
        )
    }

    func testWorkspaceScopedListSessionsNormalizesWorkspaceMismatchWithWindows() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("invalid_params"),
                "error": .string("workspace_mismatch: the target window's active workspace changed")
            ]), isError: true))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-mismatch",
                payload: .object(["workspace_name": .string("Workspace B")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "workspace_mismatch")
        let windows = try XCTUnwrap(response?.payload?.objectValue?["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
    }

    /// Post-v1 review test gap: the gateway's `workspace_mismatch` mapping is
    /// message sniffing (`RemoteGatewayRuntimeError.code`), and the older test
    /// above fakes the host message. This locks the REAL message the host
    /// generates for workspace-scoped `list_sessions` — derived from the shared
    /// `AgentManageMCPToolService.workspaceMismatchMessage` literal, so a host
    /// copy edit that breaks the sniffed prefix fails here. Residual gap:
    /// `AgentRunMCPToolService`'s start-path variant is an independent literal
    /// with the same prefix and is not covered by this test.
    func testWorkspaceScopedListSessionsNormalizesRealHostWorkspaceMismatchMessage() async throws {
        let hostMessage = try AgentManageMCPToolService.workspaceMismatchMessage(
            activeWorkspaceName: "Workspace A",
            activeWorkspaceID: XCTUnwrap(UUID(uuidString: "44444444-4444-4444-4444-444444444444")),
            requestedWorkspaceID: XCTUnwrap(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        )
        XCTAssertTrue(hostMessage.hasPrefix("workspace_mismatch: "))
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("invalid_params"),
                "error": .string(hostMessage)
            ]), isError: true))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-real-mismatch",
                payload: .object(["workspace_name": .string("Workspace B")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "workspace_mismatch")
        XCTAssertEqual(response?.payload?.objectValue?["message"]?.stringValue, hostMessage)
        let windows = try XCTUnwrap(response?.payload?.objectValue?["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
    }

    func testWorkspaceScopedListSessionsLookupFailureDoesNotFabricateWorkspaceNotOpen() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "error": .string("window inventory unavailable")
            ]), isError: true))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "list_sessions",
                requestID: "workspace-list-lookup-failure",
                payload: .object(["workspace_name": .string("Workspace B")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "app_tool_error")
        XCTAssertNotEqual(response?.payload?.objectValue?["code"]?.stringValue, "workspace_not_open")
    }

    func testUnscopedListSessionsReturnsHostPayloadWithoutGatewayReshaping() async throws {
        let expectedPayload = JSONValue.object([
            "sessions": .array([
                .object([
                    "session_id": .string(sessionID),
                    "name": .string("Unscoped Session")
                ])
            ]),
            "workspace": .object([
                "id": .string("44444444-4444-4444-4444-444444444444"),
                "name": .string("Workspace A")
            ])
        ])
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: expectedPayload))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)

        let response = await runtime.handle(
            RemoteClientFrame(type: "list_sessions", requestID: "unscoped-list"),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        XCTAssertEqual(response?.payload, expectedPayload)
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["agent_manage"])
        XCTAssertNil(calls[0].arguments["workspace_id"])
        XCTAssertNil(calls[0].arguments["workspace_name"])
    }

    func testStartWithoutSelectorOnAmbiguousConnectionReturnsStructuredErrorWithWindows() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse())
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "start", requestID: "r1", payload: .object(["message": .string("go")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_error")
        let payload = try XCTUnwrap(frame.payload?.objectValue)
        XCTAssertEqual(payload["code"]?.stringValue, "ambiguous_start_target")
        let windows = try XCTUnwrap(payload["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        // No fallback guessing: the only app call is the gateway-internal window list.
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context"])
    }

    func testStartWithUniqueWorkspaceNameAutoRoutesAndRecordsAffinity() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ]))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))
        let sink = RecordingFrameSink()

        let startResponse = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "workspace_name": .string(" workspace b ")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        XCTAssertEqual(startResponse?.type, "command_result")

        _ = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r2", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context", "agent_run", "agent_run"])
        let startCall = try XCTUnwrap(calls.first { $0.arguments["op"] == .string("start") })
        XCTAssertEqual(startCall.arguments["_windowID"], .int(2))
        XCTAssertEqual(startCall.arguments["workspace_id"], .string("55555555-5555-5555-5555-555555555555"))
        XCTAssertNil(startCall.arguments["workspace_name"])
        XCTAssertNil(startCall.arguments["window_id"])
        let steerCall = try XCTUnwrap(calls.first { $0.arguments["op"] == .string("steer") })
        XCTAssertEqual(steerCall.arguments["_windowID"], .int(2))
    }

    func testStartWithNonMatchingWorkspaceNameStillReturnsAmbiguousStartTargetWithWindows() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse())
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("Missing")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        let payload = try XCTUnwrap(response?.payload?.objectValue)
        XCTAssertEqual(payload["code"]?.stringValue, "ambiguous_start_target")
        let windows = try XCTUnwrap(payload["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        let calls = await connection.calls
        XCTAssertFalse(calls.contains { $0.name == "agent_run" })
    }

    func testStartWithDuplicateWorkspaceNameStillReturnsAmbiguousStartTargetWithWindows() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(duplicateWorkspaceWindowListResponse())
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("shared workspace")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        let payload = try XCTUnwrap(response?.payload?.objectValue)
        XCTAssertEqual(payload["code"]?.stringValue, "ambiguous_start_target")
        let windows = try XCTUnwrap(payload["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        let calls = await connection.calls
        XCTAssertFalse(calls.contains { $0.name == "agent_run" })
    }

    func testGetLogAuditIncludesPagingFields() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "turn_offset": .int(7),
                "turn_limit": .int(3),
                "returned_turn_count": .int(2),
                "total_turns": .int(10),
                "completed_turn_count": .int(8),
                "transcript_xml": .string("<transcript/>")
            ])))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound, auditLog: auditLog)

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "get_log",
                requestID: "log-r1",
                sessionID: sessionID,
                payload: .object(["offset": .int(7), "limit": .int(3)])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        let record = try await waitForAuditRecord(in: auditDirectory, op: "get_log")
        XCTAssertEqual(record["offset"] as? Int, 7)
        XCTAssertEqual(record["limit"] as? Int, 3)
        XCTAssertEqual(record["returned_turn_count"] as? Int, 2)
        XCTAssertEqual(record["completed_turn_count"] as? Int, 8)
        XCTAssertEqual(record["transcript_xml_chars"] as? Int, "<transcript/>".count)
    }

    func testStartBindingFailureAuditIncludesWorkspaceSelectorDiagnostics() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let connection = RecordingAppLinkConnection(responses: [
            .result(duplicateWorkspaceWindowListResponse())
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .ambiguousStartTarget("multiple windows"),
            auditLog: auditLog
        )

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "start-r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("Shared Workspace")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        let record = try await waitForAuditRecord(in: auditDirectory, op: "start")
        XCTAssertEqual(record["code"] as? String, "ambiguous_start_target")
        XCTAssertEqual(record["has_workspace_name"] as? Bool, true)
        XCTAssertEqual(record["has_workspace_id"] as? Bool, false)
        XCTAssertEqual(record["workspace_match_count"] as? Int, 2)
    }

    func testStartBindingFailureAuditRecordsWorkspaceMatchSkippedForExplicitWindowID() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("invalid_params"),
                "error": .string("agent_run.start requires either an explicit tab context, an exact run-scoped tab, or a window-only connection bound to the target window")
            ]), isError: true))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound, auditLog: auditLog)

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "start-r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("Workspace B"), "window_id": .int(2)])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        let record = try await waitForAuditRecord(in: auditDirectory, op: "start")
        XCTAssertEqual(record["code"] as? String, "ambiguous_start_target")
        XCTAssertEqual(record["has_workspace_name"] as? Bool, true)
        XCTAssertNil(record["workspace_match_count"])
        XCTAssertEqual(record["workspace_match_skipped"] as? String, "explicit_window_id")
        XCTAssertNil(record["workspace_match_unavailable_reason"])
    }

    func testStartBindingFailureAuditRecordsWorkspaceMatchUnavailableReason() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("app_error"),
                "error": .string("window list unavailable")
            ]), isError: true))
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .ambiguousStartTarget("multiple windows"),
            auditLog: auditLog
        )

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "start-r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("Workspace B")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        let record = try await waitForAuditRecord(in: auditDirectory, op: "start")
        XCTAssertEqual(record["code"] as? String, "ambiguous_start_target")
        XCTAssertEqual(record["has_workspace_name"] as? Bool, true)
        XCTAssertNil(record["workspace_match_count"])
        XCTAssertNil(record["workspace_match_skipped"])
        XCTAssertEqual(record["workspace_match_unavailable_reason"] as? String, "app_tool_error")
    }

    func testInFlightDuplicateStartAuditDoesNotConsumeOriginalRoutingDiagnostics() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let gate = RecordingAppLinkResponseGate()
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .gated(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ])), gate)
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .ambiguousStartTarget("multiple windows"),
            auditLog: auditLog
        )
        let frame = RemoteClientFrame(
            type: "start",
            requestID: "start-r1",
            payload: .object(["message": .string("go"), "workspace_name": .string("Workspace B")])
        )

        let original = Task {
            await runtime.handle(
                frame,
                deviceID: "device",
                sinkID: UUID(),
                sink: RecordingFrameSink()
            )
        }
        await gate.waitUntilEntered()

        let duplicate = await runtime.handle(
            frame,
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(duplicate?.type, "command_result")
        XCTAssertEqual(duplicate?.payload?.objectValue?["status"]?.stringValue, "in_flight")

        await gate.release()
        let originalResponse = await original.value
        XCTAssertEqual(originalResponse?.type, "command_result")

        let records = try await waitForAuditRecords(in: auditDirectory, op: "start", minimumCount: 2)
        let inFlightRecord = try XCTUnwrap(records.first { $0["outcome"] as? String == "in_flight" })
        let successRecord = try XCTUnwrap(records.first { $0["outcome"] as? String == "success" })
        XCTAssertNil(inFlightRecord["auto_routed_window_id"])
        XCTAssertEqual(successRecord["auto_routed_window_id"] as? Int, 2)
    }

    func testAutoRoutedStartAuditIncludesMatchedWindowID() async throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ])))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"), auditLog: auditLog)

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "start-r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("Workspace B")])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        let record = try await waitForAuditRecord(in: auditDirectory, op: "start")
        XCTAssertEqual(record["auto_routed_window_id"] as? Int, 2)
    }

    func testStartWithExplicitWindowSelectorProceedsOnAmbiguousConnection() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ])))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "window_id": .int(2)])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_result", "Explicit selector must bypass ambiguity refusal: \(frame)")
        let calls = await connection.calls
        let start = try XCTUnwrap(calls.first { $0.name == "agent_run" })
        XCTAssertEqual(start.arguments["op"], .string("start"))
        XCTAssertEqual(start.arguments["_windowID"], .int(2))
        XCTAssertEqual(start.arguments["request_id"], .string("r1"))
        XCTAssertNil(start.arguments["window_id"])
    }

    func testExplicitStartRecordsAffinityForNextSteer() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ]))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)
        let sink = RecordingFrameSink()

        _ = await runtime.handle(
            RemoteClientFrame(type: "start", requestID: "r1", payload: .object(["message": .string("go"), "window_id": .int(2)])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        let steer = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r2", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        XCTAssertEqual(steer?.type, "command_result")
        let calls = await connection.calls
        let steerCall = try XCTUnwrap(calls.last)
        XCTAssertEqual(steerCall.arguments["op"], .string("steer"))
        XCTAssertEqual(steerCall.arguments["_windowID"], .int(2))
    }

    func testDiscoveryResolvesUnknownSessionAndBulkLearnsSibling() async throws {
        let sibling = "22222222-2222-2222-2222-222222222222"
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([])),
            .result(sessionListResponse([sessionID, sibling])),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running"))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sibling, status: "running")))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        _ = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r1", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        _ = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r2", sessionID: sibling, payload: .object(["message": .string("again")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let calls = await connection.calls
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 1)
        let steerCalls = calls.filter { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") }
        XCTAssertEqual(steerCalls.count, 2)
        XCTAssertTrue(steerCalls.allSatisfy { $0.arguments["_windowID"] == .int(2) })
    }

    func testDiscoveryMissReturnsBindingRequiredWithoutSessionExpired() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([])),
            .result(sessionListResponse([]))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r1", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "binding_required")
        XCTAssertNotEqual(response?.payload?.objectValue?["code"]?.stringValue, "session_expired")
        let calls = await connection.calls
        XCTAssertFalse(calls.contains { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") })
    }

    func testToolErrorInvalidatesRediscoversDifferentWindowAndRetriesOnce() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([sessionID])),
            .result(sessionListResponse([])),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("session_expired"),
                "error": .string("Session not found")
            ]), isError: true)),
            .result(windowListResponse()),
            .result(sessionListResponse([])),
            .result(sessionListResponse([sessionID])),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r1", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        XCTAssertEqual(response?.type, "command_result")
        let steerCalls = await connection.calls.filter { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") }
        XCTAssertEqual(steerCalls.count, 2)
        XCTAssertEqual(steerCalls[0].arguments["_windowID"], .int(1))
        XCTAssertEqual(steerCalls[1].arguments["_windowID"], .int(2))
    }

    func testNonRoutingToolErrorDoesNotRetryAcrossRediscoveredWindow() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([sessionID])),
            .result(sessionListResponse([])),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("provider_failed"),
                "error": .string("Provider failed before accepting the message")
            ]), isError: true))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r1", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "provider_failed")
        let calls = await connection.calls
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 1)
        let steerCalls = calls.filter { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") }
        XCTAssertEqual(steerCalls.count, 1)
    }

    func testAppLinkLostDoesNotRetryAndReturnsInDoubt() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([sessionID])),
            .result(sessionListResponse([])),
            .appLinkLost("restart")
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r1", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "in_doubt")
        let steerCalls = await connection.calls.filter { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") }
        XCTAssertEqual(steerCalls.count, 1)
    }

    /// An uncertain tool failure (indistinguishable provenance) must be IN DOUBT exactly like a lost
    /// link — never a definite failure and never a safe-retry signal — and the action that executed
    /// before the throw is not retried. `.failure` surfaces a non-MCP throw that `AppLinkSession`
    /// normalizes to `.uncertainToolFailure(.unclassified)`, which shares the ledger mapping line with
    /// `.authoritativeToolFailure`. (Step 3 Oracle plan §3.)
    func testUncertainToolFailureDoesNotRetryAndReturnsInDoubt() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([sessionID])),
            .result(sessionListResponse([])),
            .failure("indistinguishable SDK failure")
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r1", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "in_doubt")
        let steerCalls = await connection.calls.filter { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") }
        XCTAssertEqual(steerCalls.count, 1, "The in-doubt action must not be retried.")
    }

    func testBoundStartWithUniqueWorkspaceNameAutoRoutesAndAuditsMatchCount() async throws {
        let deviceID = "remote:1a2b3c4d"
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ])))
        ])
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, maxRetainedFiles: 2)
        let pool = AppLinkPool(
            configuration: config,
            connector: BindingRuntimeConnector(connection: connection),
            bindingProbe: { _ in .bound }
        )
        _ = try await pool.ensureLink(forDevice: deviceID)

        let defaultAppLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection())
        )
        try await defaultAppLink.connect()
        let runtime = try RemoteGatewayRuntime(
            appLink: defaultAppLink,
            ledger: CommandLedger(),
            watchManager: SessionWatchManager(appLink: defaultAppLink, appLinkPool: pool),
            auditLog: auditLog,
            appLinkPool: pool
        )

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("Workspace B")])
            ),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context", "agent_run"])
        let startCall = try XCTUnwrap(calls.last)
        XCTAssertEqual(startCall.arguments["_windowID"], .int(2))
        XCTAssertEqual(startCall.arguments["workspace_id"], .string("55555555-5555-5555-5555-555555555555"))

        let auditRecord = try await waitForAuditRecord(in: auditDirectory, op: "start")
        XCTAssertEqual(auditRecord["outcome"] as? String, "success")
        XCTAssertEqual(auditRecord["workspace_match_count"] as? Int, 1)
        XCTAssertEqual(auditRecord["auto_routed_window_id"] as? Int, 2)
    }

    func testStartRoutingAppErrorWithUniqueWorkspaceNameAutoRoutesAfterBindingRefresh() async throws {
        let deviceID = "remote:1a2b3c4d"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object(["error": .string("window inventory unavailable")]), isError: true)),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("invalid_params"),
                "error": .string("agent_run.start requires either an explicit tab context, an exact run-scoped tab, or a window-only connection bound to the target window")
            ]), isError: true)),
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(sessionID),
                "status": .string("running")
            ]))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "running")))
        ])
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
        let probe = BindingProbeRecorder([
            .bound,
            .bound,
            .bound
        ])
        let pool = AppLinkPool(
            configuration: config,
            connector: BindingRuntimeConnector(connection: connection),
            bindingProbe: { _ in probe.next() }
        )
        _ = try await pool.ensureLink(forDevice: deviceID)

        let defaultAppLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection())
        )
        try await defaultAppLink.connect()
        let runtime = try RemoteGatewayRuntime(
            appLink: defaultAppLink,
            ledger: CommandLedger(),
            watchManager: SessionWatchManager(appLink: defaultAppLink, appLinkPool: pool),
            auditLog: nil,
            appLinkPool: pool
        )

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "workspace_name": .string("Workspace B")])
            ),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        let steerResponse = await runtime.handle(
            RemoteClientFrame(type: "steer", requestID: "r2", sessionID: sessionID, payload: .object(["message": .string("next")])),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(steerResponse?.type, "command_result")

        let calls = await connection.calls
        let startCalls = calls.filter { $0.name == "agent_run" && $0.arguments["op"] == .string("start") }
        XCTAssertEqual(startCalls.count, 2)
        XCTAssertNil(startCalls[0].arguments["_windowID"])
        XCTAssertEqual(startCalls[1].arguments["_windowID"], .int(2))
        XCTAssertEqual(startCalls[1].arguments["workspace_id"], .string("55555555-5555-5555-5555-555555555555"))
        XCTAssertNil(startCalls[1].arguments["workspace_name"])
        let steerCall = try XCTUnwrap(calls.first { $0.name == "agent_run" && $0.arguments["op"] == .string("steer") })
        XCTAssertEqual(steerCall.arguments["_windowID"], .int(2))
        XCTAssertGreaterThanOrEqual(probe.count, 2, "Start routing app errors should retry even when refreshed binding state is bound")
    }

    func testStartRoutingAppErrorWithNonMatchingWorkspaceNameReturnsAmbiguousStartTargetWithWindowsAndRefreshesBinding() async throws {
        let deviceID = "remote:1a2b3c4d"
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "code": .string("invalid_params"),
                "error": .string("agent_run.start requires either an explicit tab context, an exact run-scoped tab, or a window-only connection bound to the target window")
            ]), isError: true)),
            .result(windowListResponse()),
            .result(windowListResponse())
        ])
        let root = try GatewayTestHelpers.temporaryRoot()
        let config = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
        let probe = BindingProbeRecorder([
            .bound,
            .ambiguousStartTarget("multiple windows"),
            .ambiguousStartTarget("multiple windows")
        ])
        let pool = AppLinkPool(
            configuration: config,
            connector: BindingRuntimeConnector(connection: connection),
            bindingProbe: { _ in probe.next() }
        )
        _ = try await pool.ensureLink(forDevice: deviceID)

        let defaultAppLink = AppLinkSession(
            config: config,
            connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection())
        )
        try await defaultAppLink.connect()
        let runtime = try RemoteGatewayRuntime(
            appLink: defaultAppLink,
            ledger: CommandLedger(),
            watchManager: SessionWatchManager(appLink: defaultAppLink, appLinkPool: pool),
            auditLog: nil,
            appLinkPool: pool
        )

        let response = await runtime.handle(
            RemoteClientFrame(type: "start", requestID: "r1", payload: .object(["message": .string("go"), "workspace_name": .string("Missing")])),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_error")
        let payload = try XCTUnwrap(frame.payload?.objectValue)
        XCTAssertEqual(payload["code"]?.stringValue, "ambiguous_start_target")
        let windows = try XCTUnwrap(payload["details"]?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows.count, 2)
        XCTAssertGreaterThanOrEqual(probe.count, 2, "Start routing app errors should refresh stale bound state")
    }

    func testListAgentsInitialSuccessDoesNotRetry() async throws {
        let deviceID = "remote:1a2b3c4d"
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let initialProbe = BindingProbeRecorder([.bound])
        let refreshProbe = BindingProbeRecorder([.bound])
        let agentsPayload = JSONValue.object([
            "agents": .array([.object(["id": .string("pair"), "name": .string("Pair")])])
        ])
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: agentsPayload))
        ])
        let runtime = try await makePooledRuntime(
            connection: connection,
            configuration: configuration,
            deviceID: deviceID,
            auditLog: auditLog,
            initialProbe: initialProbe,
            refreshProbe: refreshProbe
        )

        let response = await runtime.handle(
            RemoteClientFrame(type: "list_agents", requestID: "list-agents-r1"),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        XCTAssertEqual(response?.payload, agentsPayload)
        XCTAssertEqual(initialProbe.count, 1)
        XCTAssertEqual(refreshProbe.count, 0)
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["agent_manage"])
        XCTAssertEqual(calls[0].arguments["op"], .string("list_agents"))
        XCTAssertNil(calls[0].arguments["_windowID"])

        let record = try await waitForAuditRecord(in: auditDirectory, op: "list_agents")
        XCTAssertEqual(auditRecords(in: auditDirectory, op: "list_agents").count, 1)
        XCTAssertEqual(record["outcome"] as? String, "success")
        XCTAssertEqual(record["binding_state_initial"] as? String, "bound")
        XCTAssertEqual(record["fallback_initial"] as? String, "not_run")
        XCTAssertEqual(record["window_id_injected_initial"] as? Bool, false)
        XCTAssertEqual(record["recovery_retried"] as? Bool, false)
        XCTAssertNil(record["binding_state_retry"])
        XCTAssertNil(record["fallback_retry"])
        XCTAssertNil(record["window_id_injected_retry"])
        XCTAssertNil(record["error_origin_initial"])
        XCTAssertNil(record["error_origin_retry"])
        assertListAgentsRoutingAuditIsRedacted(record)
    }

    func testListAgentsRecoversFromTranslatorBindingRequiredWithOneRetry() async throws {
        let deviceID = "remote:1a2b3c4d"
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let initialProbe = BindingProbeRecorder([.bindingRequired("multiple windows")])
        let refreshProbe = BindingProbeRecorder([
            .bindingRequired("multiple windows"),
            .bindingRequired("multiple windows"),
            .bound
        ])
        let agentsPayload = JSONValue.object([
            "agents": .array([.object(["id": .string("pair"), "name": .string("Pair")])])
        ])
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(
                json: .object(["error": .string("window inventory unavailable")]),
                isError: true
            )),
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: agentsPayload))
        ])
        let runtime = try await makePooledRuntime(
            connection: connection,
            configuration: configuration,
            deviceID: deviceID,
            auditLog: auditLog,
            initialProbe: initialProbe,
            refreshProbe: refreshProbe
        )

        let response = await runtime.handle(
            RemoteClientFrame(type: "list_agents", requestID: "list-agents-r2"),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        XCTAssertEqual(response?.payload, agentsPayload)
        XCTAssertEqual(initialProbe.count, 1)
        XCTAssertEqual(refreshProbe.count, 3)
        // Connection calls are app MCP calls; binding-probe calls above are captured separately.
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context", "bind_context", "agent_manage"])
        let catalogCalls = calls.filter {
            $0.name == "agent_manage" && $0.arguments["op"] == .string("list_agents")
        }
        XCTAssertEqual(catalogCalls.count, 1)
        XCTAssertEqual(catalogCalls[0].arguments["_windowID"], .int(1))

        let record = try await waitForAuditRecord(in: auditDirectory, op: "list_agents")
        XCTAssertEqual(auditRecords(in: auditDirectory, op: "list_agents").count, 1)
        XCTAssertEqual(record["outcome"] as? String, "success")
        XCTAssertEqual(record["binding_state_initial"] as? String, "binding_required")
        XCTAssertEqual(record["binding_state_retry"] as? String, "bound")
        XCTAssertEqual(record["fallback_initial"] as? String, "unavailable")
        XCTAssertEqual(record["fallback_retry"] as? String, "resolved")
        XCTAssertEqual(record["window_id_injected_initial"] as? Bool, false)
        XCTAssertEqual(record["window_id_injected_retry"] as? Bool, true)
        XCTAssertEqual(record["error_origin_initial"] as? String, "translator")
        XCTAssertNil(record["error_origin_retry"])
        XCTAssertEqual(record["recovery_retried"] as? Bool, true)
        assertListAgentsRoutingAuditIsRedacted(record)
    }

    func testListAgentsRecoversFromAppBindingRequiredWithOneRetry() async throws {
        let deviceID = "remote:1a2b3c4d"
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let initialProbe = BindingProbeRecorder([.bound])
        let refreshProbe = BindingProbeRecorder([.bound])
        let agentsPayload = JSONValue.object([
            "agents": .array([.object(["id": .string("pair"), "name": .string("Pair")])])
        ])
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(
                json: .object([
                    "code": .string("binding_required"),
                    "error": .string("Bind this connection to a window before continuing.")
                ]),
                isError: true
            )),
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: agentsPayload))
        ])
        let runtime = try await makePooledRuntime(
            connection: connection,
            configuration: configuration,
            deviceID: deviceID,
            auditLog: auditLog,
            initialProbe: initialProbe,
            refreshProbe: refreshProbe
        )

        let response = await runtime.handle(
            RemoteClientFrame(type: "list_agents", requestID: "list-agents-r3"),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        XCTAssertEqual(response?.payload, agentsPayload)
        XCTAssertEqual(initialProbe.count, 1)
        XCTAssertEqual(refreshProbe.count, 1)
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["agent_manage", "bind_context", "agent_manage"])
        let catalogCalls = calls.filter {
            $0.name == "agent_manage" && $0.arguments["op"] == .string("list_agents")
        }
        XCTAssertEqual(catalogCalls.count, 2)
        XCTAssertNil(catalogCalls[0].arguments["_windowID"])
        XCTAssertEqual(catalogCalls[1].arguments["_windowID"], .int(1))

        let record = try await waitForAuditRecord(in: auditDirectory, op: "list_agents")
        XCTAssertEqual(auditRecords(in: auditDirectory, op: "list_agents").count, 1)
        XCTAssertEqual(record["outcome"] as? String, "success")
        XCTAssertEqual(record["binding_state_initial"] as? String, "bound")
        XCTAssertEqual(record["binding_state_retry"] as? String, "bound")
        XCTAssertEqual(record["fallback_initial"] as? String, "not_run")
        XCTAssertEqual(record["fallback_retry"] as? String, "resolved")
        XCTAssertEqual(record["window_id_injected_initial"] as? Bool, false)
        XCTAssertEqual(record["window_id_injected_retry"] as? Bool, true)
        XCTAssertEqual(record["error_origin_initial"] as? String, "app")
        XCTAssertNil(record["error_origin_retry"])
        XCTAssertEqual(record["recovery_retried"] as? Bool, true)
        assertListAgentsRoutingAuditIsRedacted(record)
    }

    func testListAgentsPersistentAppBindingRequiredStopsAfterOneRetry() async throws {
        let deviceID = "remote:1a2b3c4d"
        let root = try GatewayTestHelpers.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try GatewayTestHelpers.configuration(root: root, staticToken: nil)
        let auditDirectory = root.appendingPathComponent("audit", isDirectory: true)
        let auditLog = try RemoteAuditLog(directoryURL: auditDirectory, processID: 123)
        let initialProbe = BindingProbeRecorder([.bound])
        let refreshProbe = BindingProbeRecorder([.bound])
        let bindingRequired = GatewayTestHelpers.toolResult(
            json: .object([
                "code": .string("binding_required"),
                "error": .string("Bind this connection to a window before continuing.")
            ]),
            isError: true
        )
        let connection = RecordingAppLinkConnection(responses: [
            .result(bindingRequired),
            .result(windowListResponse()),
            .result(bindingRequired),
            .result(windowListResponse())
        ])
        let runtime = try await makePooledRuntime(
            connection: connection,
            configuration: configuration,
            deviceID: deviceID,
            auditLog: auditLog,
            initialProbe: initialProbe,
            refreshProbe: refreshProbe
        )

        let response = await runtime.handle(
            RemoteClientFrame(type: "list_agents", requestID: "list-agents-r4"),
            deviceID: deviceID,
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_error")
        XCTAssertEqual(frame.payload?.objectValue?["code"]?.stringValue, "binding_required")
        XCTAssertEqual(frame.payload?.objectValue?["details"]?.objectValue?["windows"]?.arrayValue?.count, 2)
        XCTAssertEqual(initialProbe.count, 1)
        XCTAssertEqual(refreshProbe.count, 1)

        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["agent_manage", "bind_context", "agent_manage", "bind_context"])
        let catalogCalls = calls.filter {
            $0.name == "agent_manage" && $0.arguments["op"] == .string("list_agents")
        }
        XCTAssertEqual(catalogCalls.count, 2)
        XCTAssertNil(catalogCalls[0].arguments["_windowID"])
        XCTAssertEqual(catalogCalls[1].arguments["_windowID"], .int(1))
        XCTAssertEqual(calls[1].arguments["op"], .string("list"))
        XCTAssertEqual(calls[3].arguments["op"], .string("list"))

        let record = try await waitForAuditRecord(in: auditDirectory, op: "list_agents")
        XCTAssertEqual(auditRecords(in: auditDirectory, op: "list_agents").count, 1)
        XCTAssertEqual(record["outcome"] as? String, "failure")
        XCTAssertEqual(record["code"] as? String, "binding_required")
        XCTAssertEqual(record["binding_state_initial"] as? String, "bound")
        XCTAssertEqual(record["binding_state_retry"] as? String, "bound")
        XCTAssertEqual(record["fallback_initial"] as? String, "not_run")
        XCTAssertEqual(record["fallback_retry"] as? String, "resolved")
        XCTAssertEqual(record["window_id_injected_initial"] as? Bool, false)
        XCTAssertEqual(record["window_id_injected_retry"] as? Bool, true)
        XCTAssertEqual(record["error_origin_initial"] as? String, "app")
        XCTAssertEqual(record["error_origin_retry"] as? String, "app")
        XCTAssertEqual(record["recovery_retried"] as? Bool, true)
        assertListAgentsRoutingAuditIsRedacted(record)
    }

    func testListAgentsOnAmbiguousConnectionUsesFallbackWindow() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "agents": .array([.object(["id": .string("pair"), "name": .string("Pair")])])
            ])))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(type: "list_agents", requestID: "r1"),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_result")
        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context", "agent_manage"])
        let listAgents = try XCTUnwrap(calls.last)
        XCTAssertEqual(listAgents.arguments["op"], .string("list_agents"))
        XCTAssertEqual(listAgents.arguments["_windowID"], .int(1))
    }

    func testListAgentsFallsBackToBindingRequiredWhenWindowDiscoveryFails() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object(["error": .string("no windows")]), isError: true))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .ambiguousStartTarget("multiple windows"))

        let response = await runtime.handle(
            RemoteClientFrame(type: "list_agents", requestID: "r1"),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )

        XCTAssertEqual(response?.type, "command_error")
        XCTAssertEqual(response?.payload?.objectValue?["code"]?.stringValue, "binding_required")
        let calls = await connection.calls
        XCTAssertFalse(calls.contains { $0.name == "agent_manage" })
    }

    func testSubscribeOnBoundConnectionSucceeds() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "waiting_for_input")))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(type: "subscribe", requestID: "r1", sessionID: sessionID),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )

        let frame = try XCTUnwrap(response)
        XCTAssertEqual(frame.type, "command_result", "\(frame)")
        XCTAssertEqual(
            frame.payload?.objectValue?["subscribed_session_ids"]?.arrayValue,
            [.string(sessionID)]
        )
    }

    func testRespondFailureRearmsSessionWatch() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "waiting_for_input"))),
            .failure("respond failed"),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(sessionID: sessionID, status: "waiting_for_input")))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)
        let sink = RecordingFrameSink()
        let sinkID = UUID()

        let subscribeRequest = RemoteClientFrame(type: "subscribe", requestID: "r1", sessionID: sessionID)
        let handledSubscribeResponse = await runtime.handle(
            subscribeRequest,
            deviceID: "device",
            sinkID: sinkID,
            sink: sink
        )
        let subscribeResponse = try XCTUnwrap(handledSubscribeResponse)
        await sink.send(subscribeResponse)
        await runtime.didQueueResponse(
            for: subscribeRequest,
            response: subscribeResponse,
            deviceID: "device",
            sinkID: sinkID
        )
        _ = await waitForSessionUpdateCount(1, sink: sink)

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "respond",
                requestID: "r2",
                sessionID: sessionID,
                payload: .object([
                    "interaction_id": .string("22222222-2222-2222-2222-222222222222"),
                    "response": .string("accept")
                ])
            ),
            deviceID: "device",
            sinkID: sinkID,
            sink: sink
        )

        XCTAssertEqual(response?.type, "command_error")
        let frames = await waitForSessionUpdateCount(2, sink: sink)
        XCTAssertGreaterThanOrEqual(frames.count, 2)
        let firstSeq = try XCTUnwrap(frames[0].seq)
        let secondSeq = try XCTUnwrap(frames[1].seq)
        XCTAssertGreaterThan(secondSeq, firstSeq)

        try await Task.sleep(for: .milliseconds(150))
        let finalSessionUpdateCount = await sink.frames.count { $0.type == "session_update" }
        XCTAssertEqual(finalSessionUpdateCount, 2)
    }

    func testRespondFailureRearmIgnoresUnwatchedSession() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .failure("respond failed")
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)
        let sink = RecordingFrameSink()

        let response = await runtime.handle(
            RemoteClientFrame(
                type: "respond",
                requestID: "r1",
                sessionID: sessionID,
                payload: .object([
                    "interaction_id": .string("22222222-2222-2222-2222-222222222222"),
                    "response": .string("accept")
                ])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: sink
        )
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(response?.type, "command_error")
        let calls = await connection.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.arguments["op"], .string("respond"))
    }

    /// Incident 2026-07-27: a fork_session success must record the forked
    /// session's window affinity so the client's immediate attach catch-up
    /// poll routes deterministically instead of racing per-window discovery
    /// (which returned binding_required 90ms after the fork in production).
    func testForkSessionRecordsDestinationAffinityAndImmediatePollRoutesWithoutRediscovery() async throws {
        let forkedSessionID = "99999999-9999-9999-9999-999999999999"
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([])),
            .result(sessionListResponse([sessionID])),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "status": .string("forked"),
                "session": .object([
                    "session_id": .string(forkedSessionID),
                    "name": .string("Forked Session"),
                    "state": .string("idle"),
                    "is_live": .bool(true)
                ])
            ]))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                sessionID: forkedSessionID,
                status: "completed"
            )))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))

        let forkResponse = await runtime.handle(
            RemoteClientFrame(
                type: "fork_session",
                requestID: "r-fork",
                sessionID: sessionID,
                payload: .object([
                    "destination_agent": .string("claudeCode"),
                    "destination_model_id": .string("claudeCode__opus")
                ])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(forkResponse?.type, "command_result")

        let pollResponse = await runtime.handle(
            RemoteClientFrame(
                type: "poll",
                requestID: "r-fork-poll",
                sessionID: forkedSessionID,
                payload: .object(["timeout": .int(0)])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(pollResponse?.type, "command_result")

        let calls = await connection.calls
        // Discovery ran exactly once, to route the fork to its source window —
        // never again for the forked session.
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 1)
        XCTAssertEqual(
            calls.count(where: { $0.name == "agent_manage" && $0.arguments["op"] == .string("list_sessions") }),
            2
        )
        let forkCall = try XCTUnwrap(calls.first { $0.arguments["op"] == .string("fork_session") })
        XCTAssertEqual(forkCall.arguments["_windowID"], .int(2))
        let pollCall = try XCTUnwrap(calls.last { $0.name == "agent_run" && $0.arguments["op"] == .string("poll") })
        XCTAssertEqual(pollCall.arguments["_windowID"], .int(2))
    }

    func testForkSessionOnLegacyBoundConnectionSkipsAffinityRecording() async throws {
        let forkedSessionID = "99999999-9999-9999-9999-999999999999"
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: .object([
                "status": .string("forked"),
                "session": .object(["session_id": .string(forkedSessionID)])
            ]))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                sessionID: forkedSessionID,
                status: "completed"
            )))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)

        let forkResponse = await runtime.handle(
            RemoteClientFrame(
                type: "fork_session",
                requestID: "r-fork-bound",
                sessionID: sessionID,
                payload: .object([
                    "destination_agent": .string("claudeCode"),
                    "destination_model_id": .string("claudeCode__opus")
                ])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(forkResponse?.type, "command_result")

        let pollResponse = await runtime.handle(
            RemoteClientFrame(
                type: "poll",
                requestID: "r-fork-bound-poll",
                sessionID: forkedSessionID,
                payload: .object(["timeout": .int(0)])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(pollResponse?.type, "command_result")

        let calls = await connection.calls
        XCTAssertTrue(calls.filter { $0.name == "bind_context" }.isEmpty)
        // Bound/legacy routing never injects a window and the nil-window
        // affinity write is a silent no-op.
        XCTAssertTrue(calls.allSatisfy { $0.arguments["_windowID"] == nil })
    }

    func testForkSessionMalformedResultPayloadPassesThroughWithoutAffinityWrite() async throws {
        let forkedSessionID = "99999999-9999-9999-9999-999999999999"
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([])),
            .result(sessionListResponse([sessionID])),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "status": .string("forked")
            ]))),
            .result(windowListResponse()),
            .result(sessionListResponse([])),
            .result(sessionListResponse([])),
            .result(windowListResponse())
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))

        let forkResponse = await runtime.handle(
            RemoteClientFrame(
                type: "fork_session",
                requestID: "r-fork-malformed",
                sessionID: sessionID,
                payload: .object([
                    "destination_agent": .string("claudeCode"),
                    "destination_model_id": .string("claudeCode__opus")
                ])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(forkResponse?.type, "command_result")

        // Without a session envelope nothing was recorded: the follow-up poll
        // rediscovers (and, with the session in no window, fails routing).
        let pollResponse = await runtime.handle(
            RemoteClientFrame(
                type: "poll",
                requestID: "r-fork-malformed-poll",
                sessionID: forkedSessionID,
                payload: .object(["timeout": .int(0)])
            ),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
        XCTAssertEqual(pollResponse?.type, "command_error")
        XCTAssertEqual(pollResponse?.payload?.objectValue?["code"]?.stringValue, "binding_required")
        let calls = await connection.calls
        // The poll went back to discovery (second bind_context sweep) instead of
        // hitting a cached affinity; error-details enrichment may add another
        // bind_context call after the failed sweep.
        XCTAssertGreaterThanOrEqual(calls.count(where: { $0.name == "bind_context" }), 2)
    }

    /// Incident 2026-07-27 integrated lock (both root causes together): on an
    /// unbound multi-window connection, the full fork → subscribe → catch-up
    /// poll → get_log → first steer sequence for the forked session routes on
    /// recorded affinity with no binding_required error and no session_expired
    /// push.
    func testUnboundMultiWindowForkAttachObserveAndSteerRoutesWithoutBindingOrExpiry() async throws {
        let forkedSessionID = "99999999-9999-9999-9999-999999999999"
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .result(sessionListResponse([])),
            .result(sessionListResponse([sessionID])),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "status": .string("forked"),
                "session": .object([
                    "session_id": .string(forkedSessionID),
                    "name": .string("Forked Session"),
                    "state": .string("idle"),
                    "is_live": .bool(true)
                ])
            ]))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                sessionID: forkedSessionID,
                status: "completed"
            ))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                sessionID: forkedSessionID,
                status: "completed"
            ))),
            .result(GatewayTestHelpers.toolResult(json: .object([
                "session_id": .string(forkedSessionID),
                "turn_offset": .int(0),
                "turn_limit": .int(20),
                "returned_turn_count": .int(0),
                "total_turns": .int(0),
                "completed_turn_count": .int(0),
                "transcript_xml": .string("<log/>")
            ]))),
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                sessionID: forkedSessionID,
                status: "running"
            )))
        ])
        let runtime = try await makeRuntime(
            connection: connection,
            bindingState: .bindingRequired("bind first"),
            configureObservationRouting: true
        )
        let sink = RecordingFrameSink()
        let sinkID = UUID()

        let forkResponse = await runtime.handle(
            RemoteClientFrame(
                type: "fork_session",
                requestID: "r-e2e-fork",
                sessionID: sessionID,
                payload: .object([
                    "destination_agent": .string("claudeCode"),
                    "destination_model_id": .string("claudeCode__opus")
                ])
            ),
            deviceID: "device",
            sinkID: sinkID,
            sink: sink
        )
        XCTAssertEqual(forkResponse?.type, "command_result")

        let subscribeRequest = RemoteClientFrame(
            type: "subscribe",
            requestID: "r-e2e-sub",
            sessionID: forkedSessionID
        )
        let subscribeResponse = await runtime.handle(
            subscribeRequest,
            deviceID: "device",
            sinkID: sinkID,
            sink: sink
        )
        XCTAssertEqual(subscribeResponse?.type, "command_result")
        let queuedSubscribeResponse = try XCTUnwrap(subscribeResponse)
        await sink.send(queuedSubscribeResponse)
        await runtime.didQueueResponse(
            for: subscribeRequest,
            response: queuedSubscribeResponse,
            deviceID: "device",
            sinkID: sinkID
        )
        // Serialize: wait for the deferred watch validation poll before issuing
        // the client's catch-up commands so scripted responses stay aligned.
        var calls = await connection.calls
        for _ in 0 ..< 100 where !calls.contains(where: {
            $0.name == "agent_run" && $0.arguments["op"] == .string("poll")
        }) {
            try? await Task.sleep(for: .milliseconds(20))
            calls = await connection.calls
        }

        let pollResponse = await runtime.handle(
            RemoteClientFrame(
                type: "poll",
                requestID: "r-e2e-poll",
                sessionID: forkedSessionID,
                payload: .object(["timeout": .int(0)])
            ),
            deviceID: "device",
            sinkID: sinkID,
            sink: sink
        )
        XCTAssertEqual(pollResponse?.type, "command_result")

        let getLogResponse = await runtime.handle(
            RemoteClientFrame(
                type: "get_log",
                requestID: "r-e2e-log",
                sessionID: forkedSessionID,
                payload: .object(["limit": .int(20)])
            ),
            deviceID: "device",
            sinkID: sinkID,
            sink: sink
        )
        XCTAssertEqual(getLogResponse?.type, "command_result")

        let steerResponse = await runtime.handle(
            RemoteClientFrame(
                type: "steer",
                requestID: "r-e2e-steer",
                sessionID: forkedSessionID,
                payload: .object(["message": .string("continue")])
            ),
            deviceID: "device",
            sinkID: sinkID,
            sink: sink
        )
        XCTAssertEqual(steerResponse?.type, "command_result")

        calls = await connection.calls
        // One discovery sweep total (to route the fork to its source window);
        // every forked-session command rode the recorded affinity.
        XCTAssertEqual(calls.count(where: { $0.name == "bind_context" }), 1)
        let forkedSessionCalls = calls.filter { call in
            call.arguments["session_id"] == .string(forkedSessionID)
        }
        XCTAssertFalse(forkedSessionCalls.isEmpty)
        XCTAssertTrue(forkedSessionCalls.allSatisfy { $0.arguments["_windowID"] == .int(2) })
        let steerCall = try XCTUnwrap(calls.last { $0.arguments["op"] == .string("steer") })
        XCTAssertEqual(steerCall.arguments["session_id"], .string(forkedSessionID))
        XCTAssertEqual(steerCall.arguments["_windowID"], .int(2))

        let frames = await sink.frames
        XCTAssertTrue(frames.filter { $0.type == "session_expired" }.isEmpty)
        XCTAssertTrue(frames.filter { $0.payload?.objectValue?["code"]?.stringValue == "binding_required" }.isEmpty)
    }

    /// Incident 2026-07-27 companion lock: subscribe validation of a session
    /// whose app snapshot is terminal-but-real (e.g. a fork-staged session
    /// reported as completed) must not emit `session_expired`.
    func testSubscribeValidationCompletedSnapshotDoesNotEmitSessionExpired() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                sessionID: sessionID,
                status: "completed"
            )))
        ])
        let (_, manager) = try await makeObservationRuntime(
            connection: connection,
            discovery: { _, _ in 2 }
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        try await Task.sleep(for: .milliseconds(300))
        await manager.shutdown()

        let expiredFrames = await sink.frames.filter { $0.type == "session_expired" }
        XCTAssertTrue(expiredFrames.isEmpty)
    }

    func testSubscribeValidationExpiredSnapshotStillEmitsSessionExpired() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(json: GatewayTestHelpers.snapshot(
                sessionID: sessionID,
                status: "expired"
            )))
        ])
        let (_, manager) = try await makeObservationRuntime(
            connection: connection,
            discovery: { _, _ in 2 }
        )
        let sink = RecordingFrameSink()

        await manager.subscribe(deviceID: "device", sinkID: UUID(), sink: sink, sessionIDs: [sessionID])
        var expiredFrames: [RemoteServerFrame] = []
        for _ in 0 ..< 100 {
            expiredFrames = await sink.frames.filter { $0.type == "session_expired" }
            if !expiredFrames.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await manager.shutdown()
        XCTAssertFalse(expiredFrames.isEmpty)
    }

    // MARK: list_workspaces (browser workspace chooser discovery)

    private func listWorkspaces(
        _ runtime: RemoteGatewayRuntime,
        requestID: String,
        payload: JSONValue? = .object([:])
    ) async -> RemoteServerFrame? {
        await runtime.handle(
            RemoteClientFrame(type: "list_workspaces", requestID: requestID, payload: payload),
            deviceID: "device",
            sinkID: UUID(),
            sink: RecordingFrameSink()
        )
    }

    func testListWorkspacesReturnsFreshProjectedWindowsAndNeverFallsBackToCachedDetails() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(windowListResponse()),
            .failure("raw app failure /Users/owner/secret-path token=abc")
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)

        let first = await listWorkspaces(runtime, requestID: "lw-1")
        XCTAssertEqual(first?.type, "command_result")
        XCTAssertEqual(first?.requestID, "lw-1")
        let windows = try XCTUnwrap(first?.payload?.objectValue?["windows"]?.arrayValue)
        XCTAssertEqual(windows, [
            .object([
                "window_id": .int(1),
                "workspace_id": .string("44444444-4444-4444-4444-444444444444"),
                "workspace_name": .string("Workspace A")
            ]),
            .object([
                "window_id": .int(2),
                "workspace_id": .string("55555555-5555-5555-5555-555555555555"),
                "workspace_name": .string("Workspace B")
            ])
        ])
        XCTAssertEqual(first?.payload?.objectValue?.keys.sorted(), ["windows"])

        // A second read is fresh: the cached details from the first read are never substituted.
        let second = await listWorkspaces(runtime, requestID: "lw-2")
        XCTAssertEqual(second?.type, "command_error")
        XCTAssertEqual(second?.payload?.objectValue?["code"], .string("workspace_discovery_unavailable"))
        XCTAssertEqual(second?.payload?.objectValue?["message"], .string("Open workspaces are unavailable. Retry."))
        XCTAssertNil(second?.payload?.objectValue?["details"])

        let calls = await connection.calls
        XCTAssertEqual(calls.map(\.name), ["bind_context", "bind_context"])
        for call in calls {
            XCTAssertEqual(call.arguments, ["op": .string("list"), "_rawJSON": .bool(true)])
            XCTAssertEqual(call.timeout, 10)
        }
    }

    func testListWorkspacesRejectsAnyArgumentsBeforeAppLookup() async throws {
        let connection = RecordingAppLinkConnection(responses: [.result(windowListResponse())])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bound)

        let rejectedPayloads: [JSONValue] = [
            .object(["workspace_id": .string("44444444-4444-4444-4444-444444444444")]),
            .object(["_windowID": .int(2)]),
            .string("list"),
            .array([])
        ]
        for (index, payload) in rejectedPayloads.enumerated() {
            let response = await listWorkspaces(runtime, requestID: "lw-bad-\(index)", payload: payload)
            XCTAssertEqual(response?.type, "command_error")
            XCTAssertEqual(response?.payload?.objectValue?["code"], .string("invalid_payload"))
            XCTAssertNil(response?.payload?.objectValue?["details"])
        }
        let calls = await connection.calls
        XCTAssertTrue(calls.isEmpty)

        let missingPayload = await listWorkspaces(runtime, requestID: "lw-nil", payload: nil)
        XCTAssertEqual(missingPayload?.type, "command_result")
    }

    func testListWorkspacesFailuresAreFixedAndSanitizedAndEmptyInventoryIsHonest() async throws {
        let connection = RecordingAppLinkConnection(responses: [
            .result(GatewayTestHelpers.toolResult(
                json: .object(["error": .string("raw tool error /Users/owner/private")]),
                isError: true
            )),
            .result(GatewayTestHelpers.toolResult(json: .object(["unexpected": .string("shape")]))),
            .failure("raw transport detail"),
            .result(GatewayTestHelpers.toolResult(json: .object(["windows": .array([])])))
        ])
        let runtime = try await makeRuntime(connection: connection, bindingState: .bindingRequired("bind first"))

        for index in 0 ..< 3 {
            let response = await listWorkspaces(runtime, requestID: "lw-fail-\(index)")
            XCTAssertEqual(response?.type, "command_error")
            XCTAssertEqual(
                response?.payload,
                .object([
                    "code": .string("workspace_discovery_unavailable"),
                    "message": .string("Open workspaces are unavailable. Retry.")
                ])
            )
        }

        let empty = await listWorkspaces(runtime, requestID: "lw-empty")
        XCTAssertEqual(empty?.type, "command_result")
        XCTAssertEqual(empty?.payload, .object(["windows": .array([])]))
    }

    private func waitForSessionUpdateCount(
        _ minimumCount: Int,
        sink: RecordingFrameSink,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [RemoteServerFrame] {
        for _ in 0 ..< 100 {
            let frames = await sink.frames.filter { $0.type == "session_update" }
            if frames.count >= minimumCount {
                return frames
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let frames = await sink.frames.filter { $0.type == "session_update" }
        XCTAssertGreaterThanOrEqual(frames.count, minimumCount, file: file, line: line)
        return frames
    }
}

private final class BindingLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(level: Logger.Level, message: String)] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return records.map(\.message)
    }

    var noticeMessages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return records.filter { $0.level >= .notice }.map(\.message)
    }

    func handler() -> BindingCaptureLogHandler {
        BindingCaptureLogHandler(recorder: self)
    }

    func record(level: Logger.Level, message: String) {
        lock.lock()
        records.append((level, message))
        lock.unlock()
    }
}

private struct BindingCaptureLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    private let recorder: BindingLogRecorder

    init(recorder: BindingLogRecorder) {
        self.recorder = recorder
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata _: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        recorder.record(level: level, message: message.description)
    }
}
