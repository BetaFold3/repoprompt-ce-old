import Darwin
import Foundation
import NIOCore
import NIOHTTP1
@testable import RepoPromptGateway
import XCTest

/// Host allowlist (DNS-rebinding guard) on the real loopback gateway listener, HTTP and the
/// WebSocket upgrade. Requests are written over a raw socket so the Host header is exactly what
/// the test sends. No network beyond 127.0.0.1, no Tailscale.
final class GatewayHostAllowlistTests: XCTestCase {
    private static let browserOrigin = "https://mac.example-tailnet.ts.net:8443"
    private static let browserAuthority = "mac.example-tailnet.ts.net:8443"

    func testHTTPRoutesAcceptOnlyTheBindAddressAndBrowserAuthority() async throws {
        let port = try await startServer(browserOrigin: Self.browserOrigin)
        let cases: [(name: String, headers: [String], status: Int)] = [
            ("bind address", ["Host: 127.0.0.1:\(port)"], 200),
            ("browser authority", ["Host: \(Self.browserAuthority)"], 200),
            ("browser authority, mixed case", ["Host: MAC.Example-Tailnet.TS.net:8443"], 200),
            ("rebinding name on the bind port", ["Host: attacker.example:\(port)"], 421),
            ("browser name on the gateway port", ["Host: mac.example-tailnet.ts.net:\(port)"], 421),
            ("bind address on another port", ["Host: 127.0.0.1:\(port == 1 ? 2 : port - 1)"], 421),
            ("bind address without port", ["Host: 127.0.0.1"], 421),
            ("browser name without port", ["Host: mac.example-tailnet.ts.net"], 421),
            ("localhost alias", ["Host: localhost:\(port)"], 421),
            ("duplicate Host", ["Host: 127.0.0.1:\(port)", "Host: attacker.example"], 421),
            ("missing Host", [], 421),
            (
                "forwarded headers are not trusted",
                [
                    "Host: attacker.example",
                    "X-Forwarded-Host: \(Self.browserAuthority)",
                    "Forwarded: host=\(Self.browserAuthority)"
                ],
                421
            )
        ]
        for testCase in cases {
            let status = try await statusCode(port: port, requestLine: "GET /healthz HTTP/1.1", headers: testCase.headers)
            XCTAssertEqual(status, testCase.status, testCase.name)
        }

        // Every route is behind the check, not only /healthz.
        for path in ["/", "/app.js", "/readyz", "/no-such-route"] {
            let status = try await statusCode(port: port, requestLine: "GET \(path) HTTP/1.1", headers: ["Host: attacker.example"])
            XCTAssertEqual(status, 421, path)
        }
        let pwa = try await statusCode(port: port, requestLine: "GET / HTTP/1.1", headers: ["Host: \(Self.browserAuthority)"])
        XCTAssertEqual(pwa, 200, "The PWA shell is served on the browser authority")
    }

    func testWebSocketUpgradeAcceptsOnlyTheBindAddressAndBrowserAuthority() async throws {
        let port = try await startServer(browserOrigin: Self.browserOrigin)
        // A refused upgrade is closed without a response: NIO's WebSocket upgrader reports the
        // refusal through errorCaught, and the existing gateway handler closes on errors (the same as
        // an unauthorized upgrade). nil means "closed with no response bytes", never 101.
        let cases: [(name: String, host: String?, status: Int?)] = [
            ("bind address", "127.0.0.1:\(port)", 101),
            ("browser authority", Self.browserAuthority, 101),
            ("rebinding name", "attacker.example:\(port)", nil),
            ("browser name on the gateway port", "mac.example-tailnet.ts.net:\(port)", nil),
            ("missing Host", nil, nil)
        ]
        for testCase in cases {
            var headers = [
                "Upgrade: websocket",
                "Connection: Upgrade",
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
                "Sec-WebSocket-Version: 13",
                "X-Forwarded-Host: \(Self.browserAuthority)"
            ]
            if let host = testCase.host {
                headers.insert("Host: \(host)", at: 0)
            }
            let status = try await optionalStatusCode(port: port, requestLine: "GET /ws HTTP/1.1", headers: headers)
            XCTAssertEqual(status, testCase.status, testCase.name)
        }
    }

    func testWithoutBrowserOriginOnlyTheBindAddressIsAccepted() async throws {
        let port = try await startServer(browserOrigin: nil)
        let allowed = try await statusCode(port: port, requestLine: "GET /healthz HTTP/1.1", headers: ["Host: 127.0.0.1:\(port)"])
        XCTAssertEqual(allowed, 200)
        let browser = try await statusCode(port: port, requestLine: "GET /healthz HTTP/1.1", headers: ["Host: \(Self.browserAuthority)"])
        XCTAssertEqual(browser, 421)
    }

    /// Step 4: an accepted socket on the `127.0.0.1` companion allows its own exact authority and
    /// the browser authority; the direct (tailnet) listener gains no loopback authority because a
    /// companion exists, and forwarded headers rescue neither.
    func testCompanionSocketAddsOnlyItsOwnLoopbackAuthority() throws {
        let root = try GatewayTestHelpers.temporaryRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let configuration = try GatewayConfiguration.parse(
            arguments: [
                "--app-support-root", root.path,
                "--bootstrap-socket", root.appendingPathComponent("bootstrap.sock").path,
                "--bind-host", "100.64.0.8",
                "--port", "47392",
                "--browser-origin", Self.browserOrigin
            ],
            environment: [:]
        )
        let companion = try GatewayHostAllowlist(
            configuration: configuration,
            localAddress: SocketAddress(ipAddress: "127.0.0.1", port: 47392)
        )
        let direct = try GatewayHostAllowlist(
            configuration: configuration,
            localAddress: SocketAddress(ipAddress: "100.64.0.8", port: 47392)
        )
        XCTAssertEqual(companion.authorities, ["100.64.0.8:47392", "127.0.0.1:47392", Self.browserAuthority])
        XCTAssertEqual(direct.authorities, ["100.64.0.8:47392", Self.browserAuthority])

        func head(_ headers: [(String, String)]) -> HTTPRequestHead {
            HTTPRequestHead(version: .http1_1, method: .GET, uri: "/healthz", headers: HTTPHeaders(headers))
        }
        XCTAssertTrue(companion.allows(head([("Host", "127.0.0.1:47392")])))
        XCTAssertTrue(companion.allows(head([("Host", Self.browserAuthority)])))
        XCTAssertFalse(direct.allows(head([("Host", "127.0.0.1:47392")])), "No loopback authority on the direct listener")
        XCTAssertFalse(companion.allows(head([("Host", "localhost:47392")])))
        XCTAssertFalse(companion.allows(head([("Host", "127.0.0.1:8443")])))
        XCTAssertFalse(companion.allows(head([
            ("Host", "attacker.example"),
            ("X-Forwarded-Host", Self.browserAuthority),
            ("Forwarded", "host=\(Self.browserAuthority)")
        ])))
    }

    /// Step 4 over the real companion: the primary binds `::1`, so IPv4 requests to `127.0.0.1`
    /// reach the companion, which applies the same allowlist to HTTP and the WebSocket upgrade.
    func testLoopbackCompanionListenerEnforcesTheSameHostAllowlist() async throws {
        let port = try await startServer(browserOrigin: Self.browserOrigin, bindHost: "::1")
        let cases: [(name: String, headers: [String], status: Int)] = [
            ("companion address", ["Host: 127.0.0.1:\(port)"], 200),
            ("browser authority, as Serve forwards it", ["Host: \(Self.browserAuthority)"], 200),
            ("rebinding name on the gateway port", ["Host: attacker.example:\(port)"], 421),
            ("browser name on the gateway port", ["Host: mac.example-tailnet.ts.net:\(port)"], 421),
            ("localhost alias", ["Host: localhost:\(port)"], 421),
            ("missing Host", [], 421),
            (
                "forwarded headers are not trusted",
                ["Host: attacker.example", "X-Forwarded-Host: \(Self.browserAuthority)"],
                421
            )
        ]
        for testCase in cases {
            let status = try await statusCode(port: port, requestLine: "GET /healthz HTTP/1.1", headers: testCase.headers)
            XCTAssertEqual(status, testCase.status, testCase.name)
        }
        for (host, expected) in [(Self.browserAuthority, 101), ("attacker.example:\(port)", nil)] as [(String, Int?)] {
            let status = try await optionalStatusCode(
                port: port,
                requestLine: "GET /ws HTTP/1.1",
                headers: [
                    "Host: \(host)",
                    "Upgrade: websocket",
                    "Connection: Upgrade",
                    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
                    "Sec-WebSocket-Version: 13"
                ]
            )
            XCTAssertEqual(status, expected, host)
        }
    }

    // MARK: - Helpers

    private func startServer(browserOrigin: String?, bindHost: String = "127.0.0.1") async throws -> Int {
        if bindHost.contains(":") {
            try GatewayTestHelpers.requireIPv6Loopback()
        }
        let root = try GatewayTestHelpers.temporaryRoot()
        var arguments = [
            "--app-support-root", root.path,
            "--audit-dir", root.appendingPathComponent("audit", isDirectory: true).path,
            "--bootstrap-token", "bootstrap-token",
            "--bootstrap-socket", root.appendingPathComponent("bootstrap.sock").path,
            "--bind-host", bindHost,
            "--port", "0"
        ]
        if let browserOrigin {
            arguments += ["--browser-origin", browserOrigin]
        }
        let configuration = try GatewayConfiguration.parse(arguments: arguments, environment: [:])
        let appLink = AppLinkSession(
            config: configuration,
            connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection()),
            sleep: { _ in }
        )
        let runtime = try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: CommandLedger(),
            watchManager: SessionWatchManager(appLink: appLink),
            auditLog: nil
        )
        let server = GatewayHTTPServer(
            configuration: configuration,
            runtime: runtime,
            pairingRelay: GatewayPairingRelay(appLink: appLink)
        )
        addTeardownBlock {
            await server.shutdown()
            await appLink.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        try await server.start()
        let port = try XCTUnwrap(server.localAddress?.port)
        if bindHost != "127.0.0.1", browserOrigin != nil {
            XCTAssertEqual(server.companionLocalAddress?.ipAddress, "127.0.0.1")
            XCTAssertEqual(server.companionLocalAddress?.port, port)
        }
        return port
    }

    /// Sends one raw HTTP/1.1 request to 127.0.0.1 and returns the response status code.
    private func statusCode(port: Int, requestLine: String, headers: [String]) async throws -> Int {
        guard let status = try await optionalStatusCode(port: port, requestLine: requestLine, headers: headers) else {
            XCTFail("Connection closed without a response")
            return -1
        }
        return status
    }

    /// Like `statusCode`, but nil when the server closes the connection without sending any bytes.
    private func optionalStatusCode(port: Int, requestLine: String, headers: [String]) async throws -> Int? {
        // Only the status line is read; the gateway answers each plain request with Connection: close.
        let request = ([requestLine] + headers).joined(separator: "\r\n") + "\r\n\r\n"
        let line = try await Task.detached { try RawHTTPClient.statusLine(port: port, request: request) }.value
        guard let statusLine = line else { return nil }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else {
            XCTFail("Unexpected status line: \(statusLine)")
            return -1
        }
        return code
    }
}

/// Minimal blocking loopback client with 5 s send/receive timeouts.
private enum RawHTTPClient {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// nil when the peer closes before sending any bytes; throws on timeout or a partial line.
    static func statusLine(port: Int, request: String) throws -> String? {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw Failure(description: "socket() failed") }
        defer { close(socketFD) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw Failure(description: "connect() failed") }

        let bytes = Array(request.utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { send(socketFD, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { throw Failure(description: "send() failed") }
            sent += count
        }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while received.range(of: Data("\r\n".utf8)) == nil {
            let count = recv(socketFD, &buffer, buffer.count, 0)
            if count < 0 {
                throw Failure(description: "recv() failed or timed out (errno \(errno))")
            }
            guard count > 0 else { break }
            received.append(buffer, count: count)
        }
        if received.isEmpty { return nil }
        guard let end = received.range(of: Data("\r\n".utf8)) else {
            throw Failure(description: "no status line (\(received.count) bytes)")
        }
        return String(decoding: received[..<end.lowerBound], as: UTF8.self)
    }
}
