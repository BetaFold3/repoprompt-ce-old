import CryptoKit
import Foundation
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

final class GatewayHelloAckHostNameTests: XCTestCase {
    private var root: URL!
    private var appLink: AppLinkSession!
    private var server: GatewayHTTPServer!
    private var port: Int!
    private var authenticator: DeviceAuthenticator!
    private var runtimeConnection: RecordingAppLinkConnection!

    override func setUp() async throws {
        try await super.setUp()
        root = try GatewayTestHelpers.temporaryRoot("gateway-hello-ack-host-name")
        let configuration = try GatewayConfiguration.parse(
            arguments: [
                "--app-support-root", root.path,
                "--audit-dir", root.appendingPathComponent("audit", isDirectory: true).path,
                "--bootstrap-token", "bootstrap-token",
                "--bootstrap-socket", root.appendingPathComponent("bootstrap.sock").path,
                "--static-token", "dev-token",
                "--allow-static-token-auth",
                "--port", "0"
            ],
            environment: [:]
        )
        runtimeConnection = RecordingAppLinkConnection()
        appLink = AppLinkSession(
            config: configuration,
            connector: StaticAppLinkConnector(connection: runtimeConnection)
        )
        try await appLink.connect()
        let watchManager = SessionWatchManager(appLink: appLink)
        let runtime = try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: CommandLedger(),
            watchManager: watchManager,
            auditLog: nil
        )
        // Step 3 flip: the static-token connection now binds through the access authority and is
        // allowed only while trust is valid with no required policy, so provide an authenticator with
        // an all-off capability snapshot applied.
        authenticator = try DeviceAuthenticator(
            usedTicketStore: GatewayAuthTestSupport.makeUsedTicketStore(root: root)
        )
        _ = await authenticator.applyCapabilityTrust(GatewayAuthTestSupport.capabilityOffSnapshot())
        server = GatewayHTTPServer(
            configuration: configuration,
            runtime: runtime,
            authenticator: authenticator,
            hostName: "Static Token Host"
        )
        try await server.start()
        guard let boundPort = server.localAddress?.port else {
            throw XCTSkip("Could not determine the ephemeral gateway port")
        }
        port = boundPort
    }

    override func tearDown() async throws {
        if let server {
            await server.shutdown()
        }
        if let appLink {
            await appLink.shutdown()
        }
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    func testStaticTokenHelloAckIncludesHostName() async throws {
        let socket = try URLSession.shared.webSocketTask(with: XCTUnwrap(URL(string: "ws://127.0.0.1:\(port!)/ws?token=dev-token")))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let hello = try GatewayAuthTestSupport.unsignedFrameData(
            object: GatewayAuthTestSupport.frameObject(
                type: "hello",
                payload: .object(["static_token": .string("dev-token")])
            )
        )
        try await socket.send(.string(String(decoding: hello, as: UTF8.self)))
        let ack = try await receiveFrame(socket)

        XCTAssertEqual(ack.type, "hello_ack")
        XCTAssertEqual(ack.payload?.objectValue?["auth"]?.stringValue, "static_token")
        XCTAssertEqual(ack.payload?.objectValue?["device_id"]?.stringValue, RemoteGatewayRuntime.phase0DeviceID)
        XCTAssertEqual(ack.payload?.objectValue?["host_name"]?.stringValue, "Static Token Host")
        XCTAssertEqual(ack.payload?.objectValue?["sig"], .null)
    }

    /// S3-I01 regression: a static-developer connection queues two runtime requests behind a slow one.
    /// Required policy arrives mid-flight and withdraws static access entirely. The queued request #2
    /// must NOT execute on the app: the static runtime head rechecks CURRENT authorized access and
    /// denies it with a sanitized `static_access_denied` BEFORE `runtime.handle`. The outbound sink can
    /// suppress a result but cannot undo a mutation, so the gate — not merely result suppression — is
    /// what the test proves. `static_access_denied` on a ready static runtime frame is produced only by
    /// that pre-execution gate (never after a tool call), so receiving it for request #2 is dispositive
    /// evidence the app was never asked to run it.
    func testQueuedStaticRuntimeFrameIsDeniedAfterAccessIsWithdrawnAndNeverDispatched() async throws {
        let socket = try URLSession.shared.webSocketTask(with: XCTUnwrap(URL(string: "ws://127.0.0.1:\(port!)/ws?token=dev-token")))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        try await sendStaticFrame(socket, type: "hello", payload: .object(["static_token": .string("dev-token")]))
        let ack = try await receiveFrame(socket)
        XCTAssertEqual(ack.type, "hello_ack")

        // Gate the FIRST runtime request inside the app connection so it holds the serial runtime chain
        // and request #2 is strictly queued behind it (never started while #1 is suspended in callTool).
        let hold = RecordingAppLinkResponseGate()
        await runtimeConnection.enqueue(.gated(
            GatewayTestHelpers.toolResult(json: .object(["sessions": .array([])])),
            hold
        ))

        try await sendStaticFrame(socket, type: "list_sessions", requestID: "reqA")
        try await sendStaticFrame(socket, type: "list_sessions", requestID: "reqB")

        // Request #1 is now suspended in the app call; #2 waits behind it on the serial chain.
        await hold.waitUntilEntered()

        // Withdraw static access mid-flight: a required-policy device appears, so `staticAccessAllowed()`
        // becomes false and the static connection's current access flips to `.locked`.
        let requiredDevice = GatewayAuthTestSupport.makeDevice(deviceID: "remote:required-withdraw")
        _ = await authenticator.applyCapabilityTrust(
            GatewayAuthTestSupport.capabilityRequiredSnapshot(
                hostSigner: P256.Signing.PrivateKey(),
                required: [requiredDevice],
                epoch: 2,
                revision: 2,
                issuance: "issuance-2"
            )
        ).settle()

        let callsWhileHeld = await runtimeConnection.calls.count

        await hold.release()

        // After release, request #1 (legitimately admitted while unprotected) runs but its result is
        // now WITHHELD behind a sanitized `passkey_locked` settlement; request #2, which was still
        // queued when access was withdrawn, is denied at the runtime head. Collect the correlated
        // frames and assert request #2's sanitized pre-execution denial.
        var byRequest: [String: RemoteServerFrame] = [:]
        for _ in 0 ..< 8 {
            let frame = try await receiveFrame(socket)
            if let requestID = frame.requestID {
                byRequest[requestID] = frame
            }
            if byRequest["reqB"] != nil { break }
        }

        let deniedB = try XCTUnwrap(byRequest["reqB"], "Request #2 produced no correlated server frame")
        XCTAssertEqual(deniedB.type, "command_error")
        XCTAssertEqual(deniedB.payload?.objectValue?["code"]?.stringValue, "static_access_denied")

        // Request #1's own result is correctly suppressed by the sink (it may not surface as a real
        // command_result once the connection is locked).
        if let settledA = byRequest["reqA"] {
            XCTAssertNotEqual(settledA.type, "command_result", "Request #1's protected result must not surface after lock")
        }

        // Request #2 never reached `runtime.handle`, so it added no app tool call beyond request #1's.
        let callsAfter = await runtimeConnection.calls.count
        XCTAssertEqual(callsAfter, callsWhileHeld, "The queued static request executed on the app after its access was withdrawn")
    }

    /// S3-R1-01 regression: once a static-developer connection is READY its channel is in the shared
    /// connection registry (registration now happens right after the bind barrier, before the final
    /// denial recheck). When a required policy appears and withdraws static access, the authority's
    /// `closeAccessDeniedConnections()` sweep must FIND that registered channel and close the socket —
    /// a denied connection is never left open until some later cleanup. (The bind↔registration race
    /// window itself is not deterministically reproducible over a real loopback socket; this asserts
    /// the registry-backed sweep closure the fix guarantees.)
    func testDeniedStaticConnectionIsClosedByTheAccessSweepViaTheRegistry() async throws {
        let socket = try URLSession.shared.webSocketTask(with: XCTUnwrap(URL(string: "ws://127.0.0.1:\(port!)/ws?token=dev-token")))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        try await sendStaticFrame(socket, type: "hello", payload: .object(["static_token": .string("dev-token")]))
        let ack = try await receiveFrame(socket)
        XCTAssertEqual(ack.type, "hello_ack", "The static connection reached ready and registered its channel.")

        // A required-policy device appears: `staticAccessAllowed()` flips false, so the static
        // connection's current access becomes denied.
        let requiredDevice = GatewayAuthTestSupport.makeDevice(deviceID: "remote:required-sweep")
        await authenticator.applyCapabilityTrust(
            GatewayAuthTestSupport.capabilityRequiredSnapshot(
                hostSigner: P256.Signing.PrivateKey(),
                required: [requiredDevice],
                epoch: 2,
                revision: 2,
                issuance: "issuance-2"
            )
        ).settle()

        // The sweep must close the denied connection through the registry.
        await server.closeAccessDeniedConnections()

        var closed = false
        for _ in 0 ..< 8 {
            do {
                // Any benign pre-close frame is tolerated; keep reading until the socket closes.
                _ = try await receiveFrame(socket, timeout: 5)
            } catch let error as GatewayTestError {
                XCTFail("The denied static connection was not closed by the sweep: \(error)")
                return
            } catch {
                closed = true
                break
            }
        }
        XCTAssertTrue(closed, "closeAccessDeniedConnections must close the denied static connection found in the registry.")
    }

    private func sendStaticFrame(
        _ socket: URLSessionWebSocketTask,
        type: String,
        requestID: String? = nil,
        payload: JSONValue? = nil
    ) async throws {
        let data = try GatewayAuthTestSupport.unsignedFrameData(
            object: GatewayAuthTestSupport.frameObject(type: type, requestID: requestID, payload: payload)
        )
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveFrame(
        _ task: URLSessionWebSocketTask,
        timeout: TimeInterval = 10
    ) async throws -> RemoteServerFrame {
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await task.receive()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw GatewayTestError(message: "Timed out waiting for a server frame")
            }
            guard let first = try await group.next() else {
                throw GatewayTestError(message: "No server frame")
            }
            group.cancelAll()
            return first
        }
        let data: Data = switch message {
        case let .string(text): Data(text.utf8)
        case let .data(payload): payload
        @unknown default: Data()
        }
        return try RemoteWireProtocol.decodeServerFrame(from: data)
    }
}
