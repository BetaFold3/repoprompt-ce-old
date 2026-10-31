import CryptoKit
import Foundation
import Logging
import NIOCore
import NIOPosix
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptGateway
@testable import RepoPromptPlatform
import RepoPromptRemoteWire
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// End-to-end M4 contract over a real loopback WebSocket:
/// a paired device authenticates with an app-minted ticket plus frame signatures,
/// observe-only operations succeed, `steer` is denied until the scope is granted,
/// signed-frame replay is rejected (with an audit entry), a one-time ticket cannot be
/// reused, and bootstrap capacity rejections surface as `channel_closing {reason}`.
final class GatewayAuthE2EContractTests: XCTestCase {
    private var root: URL!
    private var configuration: GatewayConfiguration!
    private var hostSigner: P256.Signing.PrivateKey!
    private var device: GatewayAuthTestSupport.TestDeviceIdentity!
    private var capacityDevice: GatewayAuthTestSupport.TestDeviceIdentity!
    private var connector: E2EPoolConnector!
    private var watchManager: SessionWatchManager!
    private var appLinkPool: AppLinkPool!
    private var defaultAppLink: AppLinkSession!
    private var server: GatewayHTTPServer!
    private var port: Int!

    private static let browserOrigin = "https://mac.example-tailnet.ts.net:8443"

    override func setUp() async throws {
        try await super.setUp()
        root = try GatewayTestHelpers.temporaryRoot("gateway-auth-e2e")
        hostSigner = P256.Signing.PrivateKey()
        device = GatewayAuthTestSupport.makeDevice(deviceID: "remote:1a2b3c4d")
        capacityDevice = GatewayAuthTestSupport.makeDevice(deviceID: "remote:eeff0011")
        try await makeServer()
        try await server.start()
        guard let boundPort = server.localAddress?.port else {
            throw XCTSkip("Could not determine the ephemeral gateway port")
        }
        port = boundPort
    }

    /// Builds, but does not start, the gateway under test. `extraArguments` follow the defaults,
    /// so a later `--port` or `--bind-host` wins.
    private func makeServer(extraArguments: [String] = []) async throws {
        configuration = try GatewayConfiguration.parse(
            arguments: [
                "--app-support-root", root.path,
                "--audit-dir", root.appendingPathComponent("audit", isDirectory: true).path,
                "--bootstrap-token", "bootstrap-token",
                "--bootstrap-socket", root.appendingPathComponent("bootstrap.sock").path,
                "--port", "0"
            ] + extraArguments,
            environment: [:]
        )
        let trust = GatewayAuthTestSupport.trustSnapshot(
            hostSigner: hostSigner,
            devices: [(device, false), (capacityDevice, false)]
        )
        let usedTicketStore = try GatewayAuthTestSupport.makeUsedTicketStore(root: root)
        let authenticator = DeviceAuthenticator(usedTicketStore: usedTicketStore, trust: trust)

        connector = E2EPoolConnector(capacityRejectedClientName: capacityDevice.deviceID)
        let pool = AppLinkPool(
            configuration: configuration,
            connector: connector,
            bindingProbe: { _ in .bound }
        )
        appLinkPool = pool

        let defaultAppLink = AppLinkSession(
            config: configuration,
            connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection())
        )
        self.defaultAppLink = defaultAppLink
        try await defaultAppLink.connect()

        let watchManager = SessionWatchManager(appLink: defaultAppLink, appLinkPool: pool)
        self.watchManager = watchManager
        let auditLog = try RemoteAuditLog(directoryURL: configuration.auditDirectoryURL)
        let runtime = try RemoteGatewayRuntime(
            appLink: defaultAppLink,
            ledger: CommandLedger(),
            watchManager: watchManager,
            auditLog: auditLog,
            appLinkPool: pool
        )
        server = GatewayHTTPServer(
            configuration: configuration,
            runtime: runtime,
            authenticator: authenticator,
            appLinkPool: pool,
            auditLog: auditLog,
            hostName: "Gateway Auth E2E Host"
        )
    }

    /// Stops the gateway under test and the app link, pool, and watch manager built with it, in
    /// the gateway's own shutdown order.
    private func disposeServer() async {
        await server?.shutdown()
        await watchManager?.shutdown()
        await appLinkPool?.shutdownAll()
        await defaultAppLink?.shutdown()
    }

    /// Replaces the default `127.0.0.1` gateway with one configured by `extraArguments`. An IPv6
    /// bind host is probed first; the gateway start itself is never turned into a skip.
    private func restartServer(extraArguments: [String]) async throws {
        await disposeServer()
        try await makeServer(extraArguments: extraArguments)
        if configuration.bindHost.contains(":") {
            try GatewayTestHelpers.requireIPv6Loopback()
        }
        try await server.start()
        port = try XCTUnwrap(server.localAddress?.port)
    }

    /// An IPv6-loopback primary with a browser origin: `openSocket()` (IPv4 `127.0.0.1`) then
    /// reaches the companion listener, never the primary.
    private func restartWithLoopbackCompanion() async throws {
        try await restartServer(extraArguments: ["--bind-host", "::1", "--browser-origin", Self.browserOrigin])
        XCTAssertEqual(server.localAddress?.ipAddress, "::1")
        XCTAssertEqual(server.companionLocalAddress?.ipAddress, "127.0.0.1")
        XCTAssertEqual(server.companionLocalAddress?.port, port, "The companion uses the primary's actual port")
    }

    override func tearDown() async throws {
        await disposeServer()
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    // MARK: - WS plumbing

    private func openSocket() -> URLSessionWebSocketTask {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port!)/ws")!)
        task.resume()
        return task
    }

    private func send(_ data: Data, over task: URLSessionWebSocketTask) async throws {
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
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

    private func performTicketHello(
        _ task: URLSessionWebSocketTask,
        ticket: RemoteTicket,
        deviceKey: P256.Signing.PrivateKey,
        counter: UInt64 = 1
    ) async throws -> RemoteServerFrame {
        let hello = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.helloObject(ticketJSON: ticket.jsonValue),
            ticketID: ticket.ticketID,
            deviceID: ticket.deviceID,
            counter: counter,
            deviceKey: deviceKey
        )
        try await send(hello, over: task)
        return try await receiveFrame(task)
    }

    // MARK: - Contract

    func testPairedDeviceObserveOnlyContract() async throws {
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let socket = openSocket()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        // 1. Ticket hello admits the paired device.
        let helloAck = try await performTicketHello(socket, ticket: ticket, deviceKey: device.signer)
        XCTAssertEqual(helloAck.type, "hello_ack")
        XCTAssertEqual(helloAck.payload?.objectValue?["auth"]?.stringValue, "ticket")
        XCTAssertEqual(helloAck.payload?.objectValue?["device_id"]?.stringValue, device.deviceID)
        XCTAssertEqual(helloAck.payload?.objectValue?["host_name"]?.stringValue, "Gateway Auth E2E Host")

        // 2. Observe-only operation succeeds through the per-device app link.
        let listFrame = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.frameObject(type: "list_sessions"),
            ticketID: ticket.ticketID,
            deviceID: device.deviceID,
            counter: 2,
            deviceKey: device.signer
        )
        try await send(listFrame, over: socket)
        let listResult = try await receiveFrame(socket)
        XCTAssertEqual(listResult.type, "command_result")
        XCTAssertEqual(connector.connectedClientNames.first, device.deviceID)

        // 3. steer is denied until sessions:operate is granted.
        let steerFrame = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.frameObject(
                type: "steer",
                requestID: "req-steer-1",
                sessionID: "session-a",
                payload: .object(["message": .string("do more")])
            ),
            ticketID: ticket.ticketID,
            deviceID: device.deviceID,
            counter: 3,
            deviceKey: device.signer
        )
        try await send(steerFrame, over: socket)
        let steerResult = try await receiveFrame(socket)
        XCTAssertEqual(steerResult.type, "command_error")
        XCTAssertEqual(steerResult.payload?.objectValue?["code"]?.stringValue, "insufficient_scope")

        // 4. Byte-identical replay of the signed list frame is rejected and audited.
        try await send(listFrame, over: socket)
        let replayResult = try await receiveFrame(socket)
        XCTAssertEqual(replayResult.type, "command_error")
        XCTAssertEqual(replayResult.payload?.objectValue?["code"]?.stringValue, "counter_replayed")

        try await assertAuditContains(code: "counter_replayed", deviceID: device.deviceID)
        try await assertAuditContains(code: "insufficient_scope", deviceID: device.deviceID)
    }

    func testSubscribeAcknowledgmentReleasesAuthenticatedFIFOBeforeDeferredCatchUp() async throws {
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let socket = openSocket()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let helloAck = try await performTicketHello(socket, ticket: ticket, deviceKey: device.signer)
        XCTAssertEqual(helloAck.type, "hello_ack")

        let appConnection = try XCTUnwrap(connector.connection(for: device.deviceID))
        let validationGate = RecordingAppLinkResponseGate()
        await appConnection.enqueue(.gated(
            GatewayTestHelpers.toolResult(
                json: GatewayTestHelpers.snapshot(sessionID: "session-a", status: "running")
            ),
            validationGate
        ))
        await appConnection.enqueue(.result(GatewayTestHelpers.toolResult(json: .object([
            "session_id": .string("session-a"),
            "offset": .int(0),
            "limit": .int(20),
            "returned_turn_count": .int(0),
            "total_turns": .int(0),
            "transcript": .string("<transcript/>")
        ]))))

        let subscribe = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.frameObject(
                type: "subscribe",
                requestID: "req-subscribe",
                sessionID: "session-a"
            ),
            ticketID: ticket.ticketID,
            deviceID: device.deviceID,
            counter: 2,
            deviceKey: device.signer
        )
        try await send(subscribe, over: socket)
        let subscribeResult = try await receiveFrame(socket)
        XCTAssertEqual(subscribeResult.type, "command_result")
        XCTAssertEqual(subscribeResult.requestID, "req-subscribe")
        await validationGate.waitUntilEntered()

        let getLog = try GatewayAuthTestSupport.signedFrameData(
            object: GatewayAuthTestSupport.frameObject(
                type: "get_log",
                requestID: "req-get-log",
                sessionID: "session-a",
                payload: .object(["offset": .int(0), "limit": .int(20)])
            ),
            ticketID: ticket.ticketID,
            deviceID: device.deviceID,
            counter: 3,
            deviceKey: device.signer
        )
        try await send(getLog, over: socket)
        let getLogResult = try await receiveFrame(socket)
        XCTAssertEqual(getLogResult.type, "command_result")
        XCTAssertEqual(getLogResult.requestID, "req-get-log")

        await validationGate.release()
        let update = try await receiveFrame(socket)
        XCTAssertEqual(update.type, "session_update")
        XCTAssertEqual(update.sessionID, "session-a")
    }

    func testOneTimeTicketCannotBeReusedForASecondConnection() async throws {
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let first = openSocket()
        defer { first.cancel(with: .normalClosure, reason: nil) }
        let helloAck = try await performTicketHello(first, ticket: ticket, deviceKey: device.signer)
        XCTAssertEqual(helloAck.type, "hello_ack")

        let second = openSocket()
        defer { second.cancel(with: .normalClosure, reason: nil) }
        let replayAck = try await performTicketHello(
            second,
            ticket: ticket,
            deviceKey: device.signer,
            counter: 5
        )
        XCTAssertEqual(replayAck.type, "command_error")
        XCTAssertEqual(replayAck.payload?.objectValue?["code"]?.stringValue, "ticket_already_used")
        try await assertAuditContains(code: "ticket_already_used", deviceID: device.deviceID)
    }

    func testHelloWithoutTicketIsRejectedWhenStaticTokenModeIsOff() async throws {
        let socket = openSocket()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let hello = try GatewayAuthTestSupport.unsignedFrameData(
            object: GatewayAuthTestSupport.frameObject(
                type: "hello",
                payload: .object(["static_token": .string("anything")])
            )
        )
        try await send(hello, over: socket)
        let response = try await receiveFrame(socket)
        XCTAssertEqual(response.type, "command_error")
        XCTAssertEqual(response.payload?.objectValue?["code"]?.stringValue, "ticket_required")
    }

    func testRevokedWhilePassivelyConnectedClosesWebSocket() async throws {
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let socket = openSocket()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let helloAck = try await performTicketHello(socket, ticket: ticket, deviceKey: device.signer)
        XCTAssertEqual(helloAck.type, "hello_ack")

        // Simulate trust sync revoking a passively-connected PWA. The client sends
        // no post-hello frames, so this must not depend on verifyFrame running.
        await watchManager.teardownDevice(
            deviceID: device.deviceID,
            reason: "device_revoked",
            message: "revoked"
        )
        server.closeConnections(forDevice: device.deviceID)

        let closing = try await receiveFrame(socket)
        XCTAssertEqual(closing.type, "channel_closing")
        XCTAssertEqual(closing.payload?.objectValue?["reason"]?.stringValue, "device_revoked")
        do {
            _ = try await receiveFrame(socket, timeout: 0.5)
            XCTFail("Expected revoked WebSocket to close without delivering further events")
        } catch {
            // Expected: the socket is closed (or no more frames can arrive) after revocation.
        }
    }

    func testBootstrapCapacityRejectionSurfacesAsChannelClosing() async throws {
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: capacityDevice.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let socket = openSocket()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let response = try await performTicketHello(
            socket,
            ticket: ticket,
            deviceKey: capacityDevice.signer
        )
        XCTAssertEqual(response.type, "channel_closing")
        XCTAssertEqual(
            response.payload?.objectValue?["reason"]?.stringValue,
            "capacity_exceeded"
        )
        try await assertAuditContains(code: "capacity_exceeded", deviceID: capacityDevice.deviceID)
    }

    // MARK: - Loopback companion (Step 4)

    /// The rule follows the actual bound address: a companion is added only when the primary does
    /// not already accept IPv4 `127.0.0.1`; unknown coverage fails instead of silently omitting it.
    func testLoopbackCompanionCoverageFollowsThePrimaryBoundAddress() throws {
        func needs(_ ip: String, ipv6Only: Bool? = nil) throws -> Bool {
            try GatewayHTTPServer.needsLoopbackCompanion(
                primary: SocketAddress(ipAddress: ip, port: 47392),
                isIPv6Only: ipv6Only
            )
        }
        XCTAssertFalse(try needs("127.0.0.1"))
        XCTAssertFalse(try needs("0.0.0.0"), "An opted-in IPv4 wildcard already covers loopback")
        XCTAssertTrue(try needs("100.64.0.8"), "A tailnet address does not")
        XCTAssertTrue(try needs("127.0.0.2"))
        XCTAssertTrue(try needs("::1"))
        XCTAssertTrue(try needs("fd7a:115c:a1e0::1"))
        XCTAssertFalse(try needs("::", ipv6Only: false), "A dual-stack IPv6 wildcard covers loopback")
        XCTAssertTrue(try needs("::", ipv6Only: true))
        XCTAssertThrowsError(try needs("::"), "Unknown IPv6-only state")
        XCTAssertThrowsError(try GatewayHTTPServer.needsLoopbackCompanion(primary: nil, isIPv6Only: nil))
    }

    func testLoopbackCompanionListensOnThePrimaryPortOnlyWithABrowserOrigin() async throws {
        XCTAssertNil(server.companionLocalAddress, "Default 127.0.0.1 primary without a browser origin")

        try await restartServer(extraArguments: ["--bind-host", "::1"])
        XCTAssertNil(server.companionLocalAddress, "No browser origin: only the primary")

        try await restartServer(extraArguments: ["--browser-origin", Self.browserOrigin])
        XCTAssertNil(server.companionLocalAddress, "A 127.0.0.1 primary is not bound twice")
        let loopbackPrimaryHealth = try await healthStatus(host: "127.0.0.1")
        XCTAssertEqual(loopbackPrimaryHealth, 200)

        try await restartWithLoopbackCompanion()
        let primaryHealth = try await healthStatus(host: "[::1]")
        let companionHealth = try await healthStatus(host: "127.0.0.1")
        XCTAssertEqual(primaryHealth, 200)
        XCTAssertEqual(companionHealth, 200)
    }

    /// The companion is not a localhost bypass: ticket auth, its rejection, and revocation through
    /// it behave exactly as on the primary.
    func testLoopbackCompanionUsesTheSameTicketAuthAndRevocation() async throws {
        try await restartWithLoopbackCompanion()

        let unticketed = openSocket()
        defer { unticketed.cancel(with: .normalClosure, reason: nil) }
        try await send(
            GatewayAuthTestSupport.unsignedFrameData(
                object: GatewayAuthTestSupport.frameObject(type: "hello", payload: .object([:]))
            ),
            over: unticketed
        )
        let rejected = try await receiveFrame(unticketed)
        XCTAssertEqual(rejected.payload?.objectValue?["code"]?.stringValue, "ticket_required")

        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let socket = openSocket()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let helloAck = try await performTicketHello(socket, ticket: ticket, deviceKey: device.signer)
        XCTAssertEqual(helloAck.type, "hello_ack")

        await watchManager.teardownDevice(deviceID: device.deviceID, reason: "device_revoked", message: "revoked")
        server.closeConnections(forDevice: device.deviceID)
        let closing = try await receiveFrame(socket)
        XCTAssertEqual(closing.type, "channel_closing")
        XCTAssertEqual(closing.payload?.objectValue?["reason"]?.stringValue, "device_revoked")
    }

    func testCompanionBindFailureFailsStartAndReleasesThePrimary() async throws {
        try GatewayTestHelpers.requireIPv6Loopback()
        let blocker = try await bindProbe(host: "127.0.0.1", port: 0)
        addTeardownBlock { try? await blocker.close().get() }
        let blockedPort = try XCTUnwrap(blocker.localAddress?.port)
        await disposeServer()
        try await makeServer(extraArguments: [
            "--bind-host", "::1",
            "--port", String(blockedPort),
            "--browser-origin", Self.browserOrigin
        ])
        do {
            try await server.start()
            XCTFail("A browser origin whose companion cannot bind must fail the start")
        } catch let error as IOError {
            XCTAssertEqual(error.errnoCode, EADDRINUSE)
        }
        try await blocker.close().get()
        XCTAssertNil(server.localAddress)
        XCTAssertNil(server.companionLocalAddress)
        let primaryReleased = try await bindProbe(host: "::1", port: blockedPort)
        try await primaryReleased.close().get()
    }

    func testShutdownReleasesPrimaryAndCompanionListeners() async throws {
        try await restartWithLoopbackCompanion()
        let boundPort = try XCTUnwrap(port)
        await server.shutdown()
        XCTAssertNil(server.localAddress)
        XCTAssertNil(server.companionLocalAddress)
        for host in ["::1", "127.0.0.1"] {
            let probe = try await bindProbe(host: host, port: boundPort)
            try await probe.close().get()
        }
    }

    private func healthStatus(host: String) async throws -> Int {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.connectionProxyDictionary = [:]
        sessionConfiguration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: XCTUnwrap(URL(string: "http://\(host):\(port!)/healthz")))
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    /// A throwaway listener; it binds only while no other listener owns exactly `host:port`.
    private func bindProbe(host: String, port: Int) async throws -> Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port)
            .get()
    }

    // MARK: - Audit assertions

    private func assertAuditContains(
        code: String,
        deviceID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try auditRecords().contains(where: { $0.code == code && $0.deviceID == deviceID }) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Audit log never recorded code=\(code) for \(deviceID)", file: file, line: line)
    }

    private func auditRecords() throws -> [RemoteAuditRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: configuration.auditDirectoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        var records: [RemoteAuditRecord] = []
        for file in files where file.pathExtension == "jsonl" {
            let data = (try? Data(contentsOf: file)) ?? Data()
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                if let record = try? decoder.decode(RemoteAuditRecord.self, from: Data(line)) {
                    records.append(record)
                }
            }
        }
        return records
    }
}

/// Pool connector for E2E tests: per-device links succeed with a recording
/// connection; one device is rejected with a capacity error at bootstrap.
private final class E2EPoolConnector: AppLinkConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let capacityRejectedClientName: String
    private(set) var connectedClientNames: [String] = []
    private var connectionsByClientName: [String: RecordingAppLinkConnection] = [:]

    init(capacityRejectedClientName: String) {
        self.capacityRejectedClientName = capacityRejectedClientName
    }

    func connection(for clientName: String) -> RecordingAppLinkConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connectionsByClientName[clientName]
    }

    func connect(
        configuration _: GatewayConfiguration,
        clientName: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        if clientName == capacityRejectedClientName {
            throw AppLinkError.handshakeRejected(errorCode: "capacity_exceeded", reason: "Server at capacity")
        }
        let connection = RecordingAppLinkConnection()
        lock.lock()
        connectedClientNames.append(clientName)
        connectionsByClientName[clientName] = connection
        lock.unlock()
        return connection
    }
}
