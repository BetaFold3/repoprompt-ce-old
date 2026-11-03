import Foundation
@testable import RepoPromptGateway
import XCTest

final class GatewayDiscoveryRoutingTests: XCTestCase {
    func testRealHTTPRouteEnforcesTwoKiBIngressBoundary() async throws {
        let fixture = try await makeFixture(connectAppLink: true)
        let exactBody = try discoveryBody(paddedTo: GatewayPairingRelay.maximumDiscoveryRequestBytes)
        let accepted = try await performRequest(body: exactBody, fixture: fixture)
        XCTAssertEqual(accepted.statusCode, 200)

        let oversized = Data(repeating: 0x20, count: GatewayPairingRelay.maximumDiscoveryRequestBytes + 1)
        let rejected = try await performRequest(body: oversized, fixture: fixture)
        XCTAssertEqual(rejected.statusCode, 413)
    }

    func testRealHTTPRouteUsesDirectPeerAndIgnoresForwardedHeader() async throws {
        let observedPeer = LockedStringBox()
        let fixture = try await makeFixture(
            connectAppLink: true,
            peerObserver: { observedPeer.value = $0 }
        )
        let response = try await performRequest(
            body: discoveryBody(),
            fixture: fixture,
            forwardedFor: "100.64.0.99"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNotEqual(observedPeer.value, "100.64.0.99")
        XCTAssertTrue(["127.0.0.1", "::1"].contains(observedPeer.value))
    }

    func testReadinessRouteRequiresConnectedAppLink() async throws {
        let fixture = try await makeFixture(connectAppLink: false)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(fixture.port)/readyz"))
        let (_, response) = try await URLSession.shared.data(from: url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
    }

    func testHealthRouteReportsCompiledBuildChannel() async throws {
        let fixture = try await makeFixture(connectAppLink: false)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(fixture.port)/healthz"))
        let (data, response) = try await URLSession.shared.data(from: url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "ok")
        XCTAssertEqual(object["service"] as? String, "repoprompt-gateway")
        #if DEBUG
            XCTAssertEqual(object["channel"] as? String, "debug")
        #else
            XCTAssertEqual(object["channel"] as? String, "release")
        #endif
    }

    private func makeFixture(
        connectAppLink: Bool,
        peerObserver: (@Sendable (String) -> Void)? = nil
    ) async throws -> Fixture {
        let root = try GatewayTestHelpers.temporaryRoot()
        let configuration = try GatewayConfiguration.parse(
            arguments: [
                "--app-support-root", root.path,
                "--audit-dir", root.appendingPathComponent("audit", isDirectory: true).path,
                "--bootstrap-token", "bootstrap-token",
                "--bootstrap-socket", root.appendingPathComponent("bootstrap.sock").path,
                "--port", "0"
            ],
            environment: [:]
        )
        let appLink = AppLinkSession(
            config: configuration,
            connector: StaticAppLinkConnector(connection: RecordingAppLinkConnection()),
            sleep: { _ in }
        )
        if connectAppLink {
            try await appLink.connect()
        }
        let watchManager = SessionWatchManager(appLink: appLink)
        let runtime = try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: CommandLedger(),
            watchManager: watchManager,
            auditLog: nil
        )
        let relay = GatewayPairingRelay(
            appLink: appLink,
            discoveryPeerObserver: peerObserver
        )
        let server = GatewayHTTPServer(
            configuration: configuration,
            runtime: runtime,
            pairingRelay: relay
        )
        try await server.start()
        let port = try XCTUnwrap(server.localAddress?.port)
        addTeardownBlock {
            await server.shutdown()
            await appLink.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(port: port)
    }

    private func performRequest(
        body: Data,
        fixture: Fixture,
        forwardedFor: String? = nil
    ) async throws -> HTTPURLResponse {
        let url = try XCTUnwrap(URL(
            string:
            "http://127.0.0.1:\(fixture.port)\(GatewayPairingRelay.discoveryPath)"
        ))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let forwardedFor {
            request.setValue(forwardedFor, forHTTPHeaderField: "X-Forwarded-For")
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(response as? HTTPURLResponse)
    }

    private func discoveryBody(paddedTo size: Int? = nil) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "kind": "repoprompt_remote_discovery",
            "nonce": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "channel": "release"
        ])
        if let size {
            XCTAssertLessThanOrEqual(data.count, size)
            data.append(Data(repeating: 0x20, count: size - data.count))
        }
        return data
    }

    private struct Fixture {
        let port: Int
    }
}

private final class LockedStringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
