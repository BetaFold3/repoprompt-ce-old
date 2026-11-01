import Darwin
import Foundation
import Logging
import MCP
@testable import RepoPromptGateway
import RepoPromptMCPClientKit
import RepoPromptShared
import XCTest

final class AppLinkSessionTests: XCTestCase {
    func testDerivedSessionTokenIsStablePerGatewayLaunchAndLinkIdentity() {
        let bootstrapToken = "gateway-bootstrap-token"

        let phase0 = AppLinkSessionToken.derive(
            bootstrapToken: bootstrapToken,
            clientName: "repoprompt-gateway"
        )
        let deviceA = AppLinkSessionToken.derive(
            bootstrapToken: bootstrapToken,
            clientName: "remote:aaaa1111"
        )
        let deviceB = AppLinkSessionToken.derive(
            bootstrapToken: bootstrapToken,
            clientName: "remote:bbbb2222"
        )

        XCTAssertEqual(
            phase0,
            AppLinkSessionToken.derive(
                bootstrapToken: bootstrapToken,
                clientName: "repoprompt-gateway"
            )
        )
        XCTAssertNotEqual(phase0, deviceA)
        XCTAssertNotEqual(phase0, deviceB)
        XCTAssertNotEqual(deviceA, deviceB)
        XCTAssertTrue(phase0.hasPrefix("\(bootstrapToken):"))
        XCTAssertTrue(deviceA.hasPrefix("\(bootstrapToken):"))
        XCTAssertTrue(deviceB.hasPrefix("\(bootstrapToken):"))
    }

    func testStubBootstrapAcceptEmitsConnected() async throws {
        let connector = StubAppLinkConnector(outcomes: [.success(StubAppLinkConnection())])
        let session = try AppLinkSession(
            config: GatewayConfiguration.parse(arguments: [], environment: [:]),
            connector: connector,
            sleep: { _ in }
        )
        var events = session.stateEvents.makeAsyncIterator()

        await session.start()
        let first = await events.next()

        XCTAssertEqual(first, .connected)
        await session.shutdown()
    }

    func testCallToolInjectsRawJSONFlagCentrallyAndAllowsOverride() async throws {
        let connection = RecordingAppLinkConnection()
        let session = try AppLinkSession(
            config: GatewayConfiguration.parse(arguments: [], environment: [:]),
            connector: StaticAppLinkConnector(connection: connection),
            sleep: { _ in }
        )
        try await session.connect()

        _ = try await session.callTool(name: "remote_pairing", arguments: ["op": .string("list_devices")])
        _ = try await session.callTool(name: "agent_run", arguments: ["_rawJSON": .bool(false)])

        let calls = await connection.calls
        XCTAssertEqual(calls.count, 2)
        // Regression: trust sync (and any other consumer) must receive raw JSON
        // tool output, not the app's ```json fenced markdown rendering; otherwise
        // trust never loads and remote connects fail with `trust_unavailable`.
        XCTAssertEqual(calls[0].arguments["_rawJSON"]?.boolValue, true)
        // Explicit caller overrides are preserved.
        XCTAssertEqual(calls[1].arguments["_rawJSON"]?.boolValue, false)
        await session.shutdown()
    }

    func testStubBootstrapRejectThrowsFromConnect() async throws {
        let connector = StubAppLinkConnector(outcomes: [.failure(StubAppLinkError.rejected)])
        let session = try AppLinkSession(
            config: GatewayConfiguration.parse(arguments: [], environment: [:]),
            connector: connector,
            sleep: { _ in }
        )

        do {
            try await session.connect()
            XCTFail("Expected connect to throw")
        } catch StubAppLinkError.rejected {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReconnectEmitsReconnectingThenConnected() async throws {
        let connector = StubAppLinkConnector(outcomes: [
            .failure(StubAppLinkError.rejected),
            .success(StubAppLinkConnection())
        ])
        let session = try AppLinkSession(
            config: GatewayConfiguration.parse(arguments: [], environment: [:]),
            connector: connector,
            sleep: { _ in },
            initialReconnectBackoff: 0.001,
            maximumReconnectBackoff: 0.001
        )
        var events = session.stateEvents.makeAsyncIterator()

        await session.start()
        let first = await events.next()
        let second = await events.next()

        XCTAssertEqual(first, .reconnecting(attempt: 1, reason: "rejected"))
        XCTAssertEqual(second, .connected)
        await session.shutdown()
    }

    func testReconnectAttemptsUseSameConfigurationAndClientName() async throws {
        let connector = StubAppLinkConnector(outcomes: [
            .failure(StubAppLinkError.rejected),
            .success(StubAppLinkConnection())
        ])
        let configuration = try GatewayConfiguration.parse(
            arguments: [],
            environment: [
                GatewayConfiguration.EnvironmentKey.bootstrapToken: "gateway-bootstrap-token"
            ]
        )
        let session = AppLinkSession(
            config: configuration,
            clientName: "remote:aaaa1111",
            connector: connector,
            sleep: { _ in },
            initialReconnectBackoff: 0.001,
            maximumReconnectBackoff: 0.001
        )
        var events = session.stateEvents.makeAsyncIterator()

        await session.start()
        _ = await events.next()
        _ = await events.next()

        let attempts = await connector.recordedAttempts
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.map(\.configuration), [configuration, configuration])
        XCTAssertEqual(attempts.map(\.clientName), ["remote:aaaa1111", "remote:aaaa1111"])
        await session.shutdown()
    }

    func testReconnectEmitsFailedAfterConfiguredAttemptBudget() async throws {
        let connector = StubAppLinkConnector(outcomes: [
            .failure(StubAppLinkError.rejected),
            .failure(StubAppLinkError.rejected)
        ])
        let session = try AppLinkSession(
            config: GatewayConfiguration.parse(arguments: [], environment: [:]),
            connector: connector,
            sleep: { _ in },
            initialReconnectBackoff: 0.001,
            maximumReconnectBackoff: 0.001,
            maximumReconnectAttempts: 2
        )
        var events = session.stateEvents.makeAsyncIterator()

        await session.start()
        let first = await events.next()
        let second = await events.next()

        XCTAssertEqual(first, .reconnecting(attempt: 1, reason: "rejected"))
        XCTAssertEqual(second, .failed(reason: "rejected"))
        await session.shutdown()
    }

    func testAppChannelClosingNotificationEmitsClosingState() async throws {
        let connector = ChannelClosingCapturingConnector()
        let session = try AppLinkSession(
            config: GatewayConfiguration.parse(arguments: [], environment: [:]),
            connector: connector,
            sleep: { _ in }
        )
        var events = session.stateEvents.makeAsyncIterator()

        await session.start()
        let first = await events.next()
        XCTAssertEqual(first, .connected)

        let capturedHandler = await connector.capturedHandler
        let handler = try XCTUnwrap(capturedHandler, "connect must register the channel_closing handler")
        await handler(RepoPromptChannelClosingParams(
            reason: .serverShutdown,
            message: "restarting"
        ))

        let second = await events.next()
        XCTAssertEqual(second, .closing(reason: TerminationReason.serverShutdown.rawValue, message: "restarting"))
        await session.shutdown()
    }

    // MARK: - Connection incarnation fencing

    func testDelayedSuccessFromSupersededConnectionIsRejectedAndReplacementStaysUsable() async throws {
        let gate = AppLinkCallGate()
        let old = GatedAppLinkConnection(outcome: .success, gate: gate)
        let replacement = GatedAppLinkConnection(outcome: .success)
        let connector = SequencedAppLinkConnector(connections: [old, replacement])
        let session = try Self.makeSession(connector: connector)
        try await session.connect()

        let staleCall = Task { try await session.callTool(name: "remote_pairing") }
        await gate.waitUntilEntered()
        try await session.connect()
        await gate.release()

        await Self.assertSuperseded(staleCall)
        let result = try await session.callTool(name: "remote_pairing")
        XCTAssertEqual(result.isError, false)
        let replacementCalls = await replacement.callCount
        let attempts = await connector.attemptCount
        let state = await session.currentState()
        XCTAssertEqual(replacementCalls, 1)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(state, .reconnected)
        await session.shutdown()
    }

    func testDelayedFailureFromSupersededConnectionNeverClearsReplacement() async throws {
        let gate = AppLinkCallGate()
        let old = GatedAppLinkConnection(outcome: .failure(MCPError.connectionClosed), gate: gate)
        let replacement = GatedAppLinkConnection(outcome: .success)
        let connector = SequencedAppLinkConnector(connections: [old, replacement])
        let session = try Self.makeSession(connector: connector)
        try await session.connect()

        let staleCall = Task { try await session.callTool(name: "remote_pairing") }
        await gate.waitUntilEntered()
        try await session.connect()
        await gate.release()

        await Self.assertSuperseded(staleCall)
        let stateAfterStaleFailure = await session.currentState()
        XCTAssertEqual(stateAfterStaleFailure, .reconnected, "A superseded failure must not report a disconnect")
        let result = try await session.callTool(name: "remote_pairing")
        XCTAssertEqual(result.isError, false)
        let replacementCalls = await replacement.callCount
        let attempts = await connector.attemptCount
        XCTAssertEqual(replacementCalls, 1)
        XCTAssertEqual(attempts, 2, "A superseded failure must not start a reconnect")
        await session.shutdown()
    }

    func testDelayedAuthoritativeFailureFromSupersededConnectionIsStaleTransport() async throws {
        let gate = AppLinkCallGate()
        let old = try GatedAppLinkConnection(
            outcome: .failure(Self.wireError(code: -32600, detail: "stale principal")),
            gate: gate
        )
        let connector = SequencedAppLinkConnector(connections: [old, GatedAppLinkConnection(outcome: .success)])
        let session = try Self.makeSession(connector: connector)
        try await session.connect()

        let staleCall = Task { try await session.callTool(name: "remote_pairing") }
        await gate.waitUntilEntered()
        try await session.connect()
        await gate.release()

        await Self.assertSuperseded(staleCall)
        await session.shutdown()
    }

    func testCompletionAfterShutdownIsRejectedWithoutPublication() async throws {
        let successGate = AppLinkCallGate()
        let failureGate = AppLinkCallGate()
        let succeeding = GatedAppLinkConnection(outcome: .success, gate: successGate)
        let failing = GatedAppLinkConnection(outcome: .failure(MCPError.connectionClosed), gate: failureGate)

        let successSession = try Self.makeSession(connector: SequencedAppLinkConnector(connections: [succeeding]))
        try await successSession.connect()
        let successCall = Task { try await successSession.callTool(name: "remote_pairing") }
        await successGate.waitUntilEntered()
        await successSession.shutdown()
        await successGate.release()
        await Self.assertSuperseded(successCall)

        let failureConnector = SequencedAppLinkConnector(connections: [failing])
        let failureSession = try Self.makeSession(connector: failureConnector)
        try await failureSession.connect()
        let failureCall = Task { try await failureSession.callTool(name: "remote_pairing") }
        await failureGate.waitUntilEntered()
        await failureSession.shutdown()
        await failureGate.release()
        await Self.assertSuperseded(failureCall)
        let state = await failureSession.currentState()
        let attempts = await failureConnector.attemptCount
        XCTAssertEqual(state, .disconnected(reason: "shutdown"))
        XCTAssertEqual(attempts, 1)
    }

    func testCancellationFromSupersededConnectionRemainsCancellation() async throws {
        let gate = AppLinkCallGate()
        let old = GatedAppLinkConnection(outcome: .failure(CancellationError()), gate: gate)
        let connector = SequencedAppLinkConnector(connections: [old, GatedAppLinkConnection(outcome: .success)])
        let session = try Self.makeSession(connector: connector)
        try await session.connect()

        let staleCall = Task { try await session.callTool(name: "remote_pairing") }
        await gate.waitUntilEntered()
        try await session.connect()
        await gate.release()

        do {
            _ = try await staleCall.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let state = await session.currentState()
        XCTAssertEqual(state, .reconnected)
        await session.shutdown()
    }

    // MARK: - Authoritative response vs transport classification

    func testAuthoritativeResponseCodeClassifiesOnlyProvablyServerOriginatedErrors() throws {
        // Wire-decoded server responses whose cases no local client/transport path produces.
        for code in [-32700, -32600, -32601, -32602, -32050, -32042] {
            let decoded = try Self.wireError(code: code, detail: "detail")
            XCTAssertEqual(AppLinkError.authoritativeResponseCode(for: decoded), code, "code \(code)")
        }
        // Wire codes that decode to the same cases local failures use are not authoritative.
        for code in [-32000, -32001, -32603] {
            let decoded = try Self.wireError(code: code, detail: "detail")
            XCTAssertNil(AppLinkError.authoritativeResponseCode(for: decoded), "code \(code)")
        }
        // Local client/transport failures from the pinned SDK and BootstrapSocketMCPTransport.
        let localErrors: [Error] = [
            MCPError.connectionClosed,
            MCPError.transportError(POSIXError(.ENOTCONN)),
            MCPError.internalError("Client connection not initialized"),
            AppLinkError.notConnected,
            AppLinkError.toolCallTimedOut(1),
            StubAppLinkError.rejected,
            CancellationError()
        ]
        for error in localErrors {
            XCTAssertNil(AppLinkError.authoritativeResponseCode(for: error), "\(error)")
        }
    }

    func testOverlappingSDKCasesAndUnknownErrorsAreIndistinguishablyUncertain() throws {
        // Wire-decoded server responses and their locally constructed SDK twins map to the same
        // kind on purpose: the pinned SDK erases which side produced them.
        let expectations: [(wire: Int, local: MCPError, kind: AppLinkUncertainFailureKind)] = [
            (-32603, .internalError("Client connection not initialized"), .internalError),
            (-32000, .connectionClosed, .connectionClosed),
            (-32001, .transportError(POSIXError(.ENOTCONN)), .transportError)
        ]
        for expectation in expectations {
            let decoded = try Self.wireError(code: expectation.wire, detail: "detail")
            XCTAssertEqual(AppLinkError.uncertainFailureKind(for: decoded), expectation.kind)
            XCTAssertEqual(AppLinkError.uncertainFailureKind(for: expectation.local), expectation.kind)
        }
        XCTAssertEqual(AppLinkError.uncertainFailureKind(for: StubAppLinkError.rejected), .unclassified)
        XCTAssertEqual(
            AppLinkError.uncertainFailureKind(for: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))),
            .unclassified
        )
    }

    func testAuthoritativeJSONRPCErrorKeepsConnectionWithoutRetainingMessage() async throws {
        let connection = try ScriptedAppLinkConnection(outcomes: [
            .failure(Self.wireError(code: -32602, detail: "secret-detail")),
            .success
        ])
        let connector = SequencedAppLinkConnector(connections: [connection])
        let session = try Self.makeSession(connector: connector)
        try await session.connect()

        do {
            _ = try await session.callTool(name: "remote_pairing")
            XCTFail("Expected authoritative failure")
        } catch let error as AppLinkError {
            XCTAssertEqual(error, .authoritativeToolFailure(code: -32602))
            XCTAssertFalse(String(describing: error).contains("secret-detail"))
        }
        let result = try await session.callTool(name: "remote_pairing")
        XCTAssertEqual(result.isError, false)
        let state = await session.currentState()
        let attempts = await connector.attemptCount
        XCTAssertEqual(state, .connected)
        XCTAssertEqual(attempts, 1, "An authoritative response must not tear down or reconnect the link")
        await session.shutdown()
    }

    func testTimeoutKeepsConnectionWhileUncertainFailureRecoversWithoutRawMessage() async throws {
        let uncertainCases: [(error: Error, kind: AppLinkUncertainFailureKind)] = try [
            (MCPError.connectionClosed, .connectionClosed),
            (MCPError.transportError(POSIXError(.ECONNRESET)), .transportError),
            (Self.wireError(code: -32603, detail: "secret-detail"), .internalError),
            (Self.wireError(code: -32001, detail: "secret-detail"), .transportError),
            (SecretBearingError(), .unclassified)
        ]
        for uncertainCase in uncertainCases {
            let connection = ScriptedAppLinkConnection(outcomes: [
                .failure(AppLinkError.toolCallTimedOut(1)),
                .success,
                .failure(uncertainCase.error)
            ])
            let session = try Self.makeSession(connector: SequencedAppLinkConnector(connections: [connection]))
            try await session.connect()

            do {
                _ = try await session.callTool(name: "remote_pairing")
                XCTFail("Expected timeout")
            } catch let error as AppLinkError {
                XCTAssertEqual(error, .toolCallTimedOut(1))
            }
            _ = try await session.callTool(name: "remote_pairing")
            do {
                _ = try await session.callTool(name: "remote_pairing")
                XCTFail("Expected uncertain failure")
            } catch let error as AppLinkError {
                XCTAssertEqual(error, .uncertainToolFailure(kind: uncertainCase.kind))
                XCTAssertFalse(String(describing: error).contains("secret"))
            }
            // Existing recovery: the captured connection is cleared. The reconnect loop may
            // already have exhausted its one-attempt budget (`.failed`).
            let state = await session.currentState()
            XCTAssertNotEqual(state, .connected, "An uncertain failure must clear the connection")
            switch state {
            case let .disconnected(reason), let .failed(reason), let .reconnecting(_, reason):
                XCTAssertFalse(reason.contains("secret"), "State events must not carry the raw message")
            default:
                break
            }
            do {
                _ = try await session.callTool(name: "remote_pairing")
                XCTFail("Expected the cleared connection to be unavailable")
            } catch let error as AppLinkError {
                XCTAssertEqual(error, .notConnected)
            }
            await session.shutdown()
        }
    }

    func testExplicitAppLinkOutageRemainsKnownOutage() async throws {
        let connection = ScriptedAppLinkConnection(outcomes: [.failure(AppLinkError.appLinkLost("socket closed"))])
        let session = try Self.makeSession(connector: SequencedAppLinkConnector(connections: [connection]))
        try await session.connect()

        do {
            _ = try await session.callTool(name: "remote_pairing")
            XCTFail("Expected known outage")
        } catch let error as AppLinkError {
            XCTAssertEqual(error, .appLinkLost("socket closed"))
        }
        let state = await session.currentState()
        XCTAssertNotEqual(state, .connected)
        await session.shutdown()
    }

    /// Drives the real `GatewayMCPAppConnection` + `BootstrapSocketMCPTransport` + pinned SDK
    /// `Client` over a socketpair. The peer answers `initialize`, then returns a valid JSON-RPC
    /// envelope whose `result` is not a valid `CallTool.Result`.
    func testPinnedSDKInvalidCallToolResultSurfacesAsUncertainUnclassified() async throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let peer = CannedMCPPeer(fd: descriptors[1])
        peer.start()
        defer { peer.stop() }
        let transport = try BootstrapSocketMCPTransport(connectedFD: descriptors[0])
        let client = Client(name: "applink-fixture", version: "1.0")
        _ = try await client.connect(transport: transport)
        let connection = GatewayMCPAppConnection(client: client, transport: transport)
        let session = try Self.makeSession(connector: SequencedAppLinkConnector(connections: [connection]))
        try await session.connect()

        // Control: the same fixture path delivers a valid result.
        let valid = try await session.callTool(name: CannedMCPPeer.validToolName, timeout: 10)
        XCTAssertEqual(valid.isError, false)

        do {
            _ = try await session.callTool(name: "invalid_result", timeout: 10)
            XCTFail("Expected the SDK to reject the invalid CallTool.Result")
        } catch let error as AppLinkError {
            // If the pinned SDK dropped the response silently this would be `.toolCallTimedOut`.
            XCTAssertEqual(error, .uncertainToolFailure(kind: .unclassified))
            XCTAssertFalse(String(describing: error).contains(CannedMCPPeer.invalidContentMarker))
        }
        await session.shutdown()
    }

    private static func makeSession(connector: any AppLinkConnecting) throws -> AppLinkSession {
        try AppLinkSession(
            config: GatewayConfiguration.parse(arguments: [], environment: [:]),
            connector: connector,
            sleep: { _ in },
            maximumReconnectAttempts: 1
        )
    }

    private static func wireError(code: Int, detail: String) throws -> MCPError {
        let json = #"{"code":\#(code),"message":"wire message","data":{"detail":"\#(detail)"}}"#
        return try JSONDecoder().decode(MCPError.self, from: Data(json.utf8))
    }

    private static func assertSuperseded(
        _ call: Task<MCPToolResult, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await call.value
            XCTFail("Expected superseded-connection rejection", file: file, line: line)
        } catch let error as AppLinkError {
            XCTAssertEqual(error, .appLinkLost(AppLinkSession.supersededConnectionReason), file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private struct SecretBearingError: Error, CustomStringConvertible {
    var description: String {
        "secret-underlying-description"
    }
}

/// Minimal newline-delimited JSON-RPC peer for the pinned-SDK fixture: answers `initialize`,
/// ignores notifications, and answers `tools/call` with either a valid or an invalid result.
private final class CannedMCPPeer: @unchecked Sendable {
    static let validToolName = "valid_result"
    static let invalidContentMarker = "secret-invalid-content"

    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    func start() {
        Thread { [self] in serve() }.start()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if !closed { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    private func serve() {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            guard byte == UInt8(ascii: "\n") else {
                line.append(byte)
                continue
            }
            respond(to: line)
            line.removeAll()
        }
        lock.lock()
        closed = true
        Darwin.close(fd)
        lock.unlock()
    }

    private func respond(to line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = message["id"],
              let method = message["method"] as? String
        else { return }
        let params = message["params"] as? [String: Any]
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": params?["protocolVersion"] ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "applink-fixture", "version": "1.0"]
            ]
        case "tools/call" where params?["name"] as? String == Self.validToolName:
            result = ["content": [["type": "text", "text": "ok"]], "isError": false]
        case "tools/call":
            result = ["content": Self.invalidContentMarker]
        default:
            return
        }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}

private enum AppLinkCallOutcome {
    case success
    case failure(any Error)

    func resolve() throws -> MCPToolResult {
        switch self {
        case .success:
            return CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)], isError: false)
        case let .failure(error):
            throw error
        }
    }
}

/// Continuation-based gate: a call parks after signalling entry until the test releases it.
private actor AppLinkCallGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor GatedAppLinkConnection: AppLinkConnection {
    private let outcome: AppLinkCallOutcome
    private let gate: AppLinkCallGate?
    private(set) var callCount = 0

    init(outcome: AppLinkCallOutcome, gate: AppLinkCallGate? = nil) {
        self.outcome = outcome
        self.gate = gate
    }

    func callTool(
        name _: String,
        arguments _: [String: Value],
        timeout _: TimeInterval?
    ) async throws -> MCPToolResult {
        callCount += 1
        await gate?.enterAndWait()
        return try outcome.resolve()
    }

    func disconnect() async {}
}

private actor ScriptedAppLinkConnection: AppLinkConnection {
    private var outcomes: [AppLinkCallOutcome]

    init(outcomes: [AppLinkCallOutcome]) {
        self.outcomes = outcomes
    }

    func callTool(
        name _: String,
        arguments _: [String: Value],
        timeout _: TimeInterval?
    ) async throws -> MCPToolResult {
        try (outcomes.isEmpty ? .success : outcomes.removeFirst()).resolve()
    }

    func disconnect() async {}
}

private actor SequencedAppLinkConnector: AppLinkConnecting {
    private var connections: [any AppLinkConnection]
    private(set) var attemptCount = 0

    init(connections: [any AppLinkConnection]) {
        self.connections = connections
    }

    func connect(
        configuration _: GatewayConfiguration,
        clientName _: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        attemptCount += 1
        guard !connections.isEmpty else { throw StubAppLinkError.rejected }
        return connections.removeFirst()
    }
}

private enum StubAppLinkError: Error, CustomStringConvertible {
    case rejected

    var description: String {
        switch self {
        case .rejected: "rejected"
        }
    }
}

private actor StubAppLinkConnector: AppLinkConnecting {
    struct Attempt: Equatable {
        let configuration: GatewayConfiguration
        let clientName: String
    }

    private var outcomes: [Result<StubAppLinkConnection, Error>]
    private var attempts: [Attempt] = []

    init(outcomes: [Result<StubAppLinkConnection, Error>]) {
        self.outcomes = outcomes
    }

    var recordedAttempts: [Attempt] {
        attempts
    }

    func connect(
        configuration: GatewayConfiguration,
        clientName: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        attempts.append(Attempt(configuration: configuration, clientName: clientName))
        guard !outcomes.isEmpty else { return StubAppLinkConnection() }
        return try outcomes.removeFirst().get()
    }
}

/// Plan §6.3: captures the `onChannelClosing` handler AppLinkSession registers so
/// tests can simulate the app's graceful channel-closing announcement.
private actor ChannelClosingCapturingConnector: AppLinkConnecting {
    private(set) var capturedHandler: (@Sendable (RepoPromptChannelClosingParams) async -> Void)?

    func connect(
        configuration _: GatewayConfiguration,
        clientName _: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        StubAppLinkConnection()
    }

    func connect(
        configuration _: GatewayConfiguration,
        clientName _: String,
        logger _: Logger,
        onChannelClosing: @escaping @Sendable (RepoPromptChannelClosingParams) async -> Void
    ) async throws -> any AppLinkConnection {
        capturedHandler = onChannelClosing
        return StubAppLinkConnection()
    }
}

private struct StubAppLinkConnection: AppLinkConnection {
    func callTool(
        name _: String,
        arguments _: [String: Value],
        timeout _: TimeInterval?
    ) async throws -> MCPToolResult {
        CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)], isError: false)
    }

    func disconnect() async {}
}
