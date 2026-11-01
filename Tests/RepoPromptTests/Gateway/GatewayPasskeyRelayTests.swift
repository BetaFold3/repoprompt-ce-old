import CryptoKit
import Foundation
import Logging
import MCP
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

/// Drives the ACTUAL `GatewayPasskeyRelay` over the ACTUAL `AppLinkSession` backed by a recording
/// stub connection, so the conservative failure classification and the request-echo validation are
/// exercised end to end over the principal leg (remote passkey unlock, Step 3).
///
/// Provenance disposition (Step 3 Oracle plan §§1–2): a POSITIVELY identified outage preserves the
/// prior valid policy (`.transportFailure`); an authoritative RPC failure, an uncertain
/// indistinguishable-provenance SDK failure, and any unclassified throw all INVALIDATE (`.invalid`
/// for trust, a generic rejection for a ceremony); cancellation propagates and publishes nothing.
final class GatewayPasskeyRelayTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try GatewayTestHelpers.temporaryRoot("passkey-relay")
    }

    override func tearDown() async throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try await super.tearDown()
    }

    // MARK: Trust fetch

    func testFetchCapabilityTrustParsesValidCapableSnapshot() async throws {
        let hostKey = Self.p256Raw()
        let deviceKey = Self.p256Raw()
        let json = capableListDevicesJSON(deviceID: "remote:1a2b3c4d", hostKey: hostKey, deviceKey: deviceKey, required: true)
        let (relay, connection) = try await makeRelay(responses: [.result(GatewayTestHelpers.toolResult(json: json))])

        let outcome = try await relay.fetchCapabilityTrust()
        guard case let .valid(snapshot) = outcome else {
            return XCTFail("Expected a valid snapshot, got \(outcome)")
        }
        XCTAssertEqual(snapshot.devices["remote:1a2b3c4d"]?.policy.isRequired, true)
        XCTAssertEqual(snapshot.hostPublicKeyRawRepresentation, hostKey)

        // The capable fetch must assert passkey_policy_capability:1 on the wire.
        let calls = await connection.calls
        XCTAssertEqual(calls.first?.arguments["op"]?.stringValue, "list_devices")
        XCTAssertEqual(calls.first?.arguments["passkey_policy_capability"]?.intValue, 1)
    }

    func testFetchCapabilityTrustTreatsIdentifiedOutageAsTransportFailure() async throws {
        let (relay, _) = try await makeRelay(responses: [.appLinkLost("link dropped")])
        let outcome = try await relay.fetchCapabilityTrust()
        XCTAssertEqual(outcome, .transportFailure, "A positively identified outage must preserve prior policy.")
    }

    func testFetchCapabilityTrustTreatsTimeoutAsTransportFailure() async throws {
        let (relay, _) = try await makeRelay(responses: [.timeout(15)])
        let outcome = try await relay.fetchCapabilityTrust()
        XCTAssertEqual(outcome, .transportFailure, "A timeout is a recognized outage and must preserve prior policy.")
    }

    func testFetchCapabilityTrustTreatsOkFalseAsInvalid() async throws {
        let json = JSONValue.object(["ok": .bool(false), "code": .string("registry_unavailable")])
        let (relay, _) = try await makeRelay(responses: [.result(GatewayTestHelpers.toolResult(json: json))])
        let outcome = try await relay.fetchCapabilityTrust()
        XCTAssertEqual(outcome, .invalid, "An authoritative ok:false must invalidate, not preserve.")
    }

    func testFetchCapabilityTrustTreatsMalformedBodyAsInvalid() async throws {
        // A host fingerprint that does not match the host key is an authoritative inconsistency.
        let hostKey = Self.p256Raw()
        let deviceKey = Self.p256Raw()
        var object = try XCTUnwrap(capableListDevicesJSON(deviceID: "remote:1a2b3c4d", hostKey: hostKey, deviceKey: deviceKey, required: true).objectValue)
        object["host_fingerprint"] = .string("sha256:deadbeef")
        let (relay, _) = try await makeRelay(responses: [.result(GatewayTestHelpers.toolResult(json: .object(object)))])
        let outcome = try await relay.fetchCapabilityTrust()
        XCTAssertEqual(outcome, .invalid)
    }

    func testFetchCapabilityTrustTreatsIsErrorResultAsInvalid() async throws {
        let json = JSONValue.object(["ok": .bool(true)])
        let (relay, _) = try await makeRelay(responses: [.result(GatewayTestHelpers.toolResult(json: json, isError: true))])
        let outcome = try await relay.fetchCapabilityTrust()
        XCTAssertEqual(outcome, .invalid)
    }

    func testFetchCapabilityTrustTreatsAuthoritativeRPCFailureAsInvalid() async throws {
        // A server JSON-RPC error whose code no local path produces: authoritative, so invalidate.
        let relay = try await makeThrowingRelay(error: MCPError.serverError(code: -32050, message: "rejected"))
        let outcome = try await relay.fetchCapabilityTrust()
        XCTAssertEqual(outcome, .invalid, "An authoritative RPC failure must invalidate trust.")
    }

    func testFetchCapabilityTrustTreatsUncertainSDKFailureAsInvalid() async throws {
        // A transport-shaped SDK case whose provenance is indistinguishable from a rejected/malformed
        // authoritative response: the name is not provenance, so it must lock conservatively.
        for sdkError in [MCPError.connectionClosed, MCPError.internalError("x"), MCPError.transportError(GatewayTestError(message: "io"))] {
            let relay = try await makeThrowingRelay(error: sdkError)
            let outcome = try await relay.fetchCapabilityTrust()
            XCTAssertEqual(outcome, .invalid, "Uncertain SDK failure \(sdkError) must invalidate conservatively.")
        }
    }

    func testFetchCapabilityTrustTreatsUnclassifiedFailureAsInvalid() async throws {
        // An unknown, non-MCP throw (e.g. a response-decoding failure) normalizes to an unclassified
        // uncertain failure, never a silent outage.
        let (relay, _) = try await makeRelay(responses: [.failure("decode exploded")])
        let outcome = try await relay.fetchCapabilityTrust()
        XCTAssertEqual(outcome, .invalid, "An unclassified failure must invalidate, not preserve.")
    }

    func testFetchCapabilityTrustPropagatesCancellation() async throws {
        let relay = try await makeThrowingRelay(error: CancellationError())
        do {
            _ = try await relay.fetchCapabilityTrust()
            XCTFail("Cancellation must propagate rather than applying a trust transition.")
        } catch is CancellationError {
            // Expected: the caller publishes nothing.
        }
    }

    // MARK: Begin

    func testUnlockBeginReturnsCeremonyIDAndForwardsGenerationAsInteger() async throws {
        let json = JSONValue.object([
            "ok": .bool(true),
            "device_id": .string("remote:1a2b3c4d"),
            "ceremony_id": .string("ceremony-abcdef0123456789"),
            "challenge": .string("Y2hhbGxlbmdl"),
            "timeout": .int(60000)
        ])
        let (relay, connection) = try await makeRelay(responses: [.result(GatewayTestHelpers.toolResult(json: json))])

        let outcome = try await relay.unlockBegin(deviceID: "remote:1a2b3c4d", connectionGeneration: 7)
        guard case let .began(result) = outcome else {
            return XCTFail("Expected began, got \(outcome)")
        }
        XCTAssertEqual(result.appCeremonyID, "ceremony-abcdef0123456789")
        XCTAssertEqual(result.optionsPayload.objectValue?["challenge"]?.stringValue, "Y2hhbGxlbmdl")

        let calls = await connection.calls
        XCTAssertEqual(calls.first?.arguments["op"]?.stringValue, "passkey_unlock_begin")
        XCTAssertEqual(calls.first?.arguments["device_id"]?.stringValue, "remote:1a2b3c4d")
        XCTAssertEqual(calls.first?.arguments["connection_generation"]?.intValue, 7)
    }

    func testUnlockBeginTransportFailure() async throws {
        let (relay, _) = try await makeRelay(responses: [.timeout(15)])
        let outcome = try await relay.unlockBegin(deviceID: "remote:1a2b3c4d", connectionGeneration: 1)
        guard case .transportFailure = outcome else {
            return XCTFail("Expected transportFailure, got \(outcome)")
        }
    }

    func testUnlockBeginRejectedSurfacesAppCode() async throws {
        let json = JSONValue.object(["ok": .bool(false), "code": .string("enrollment_required")])
        let (relay, _) = try await makeRelay(responses: [.result(GatewayTestHelpers.toolResult(json: json))])
        let outcome = try await relay.unlockBegin(deviceID: "remote:1a2b3c4d", connectionGeneration: 1)
        guard case let .rejected(code) = outcome else {
            return XCTFail("Expected rejected, got \(outcome)")
        }
        XCTAssertEqual(code, "enrollment_required")
    }

    func testUnlockBeginUncertainFailureIsGenericRejection() async throws {
        // An uncertain SDK failure during a ceremony is a generic non-success, never a preserved
        // outage and never a success.
        let relay = try await makeThrowingRelay(error: MCPError.connectionClosed)
        let outcome = try await relay.unlockBegin(deviceID: "remote:1a2b3c4d", connectionGeneration: 1)
        guard case let .rejected(code) = outcome else {
            return XCTFail("Expected rejected, got \(outcome)")
        }
        XCTAssertEqual(code, "passkey_begin_failed")
    }

    func testBeginPropagatesCancellation() async throws {
        let relay = try await makeThrowingRelay(error: CancellationError())
        do {
            _ = try await relay.registerBegin(deviceID: "remote:1a2b3c4d", connectionGeneration: 1)
            XCTFail("Cancellation must propagate from a ceremony begin.")
        } catch is CancellationError {}
    }

    // MARK: Complete

    func testUnlockCompleteVerifiedWhenEchoMatchesRequest() async throws {
        let json = JSONValue.object([
            "ok": .bool(true),
            "verified": .bool(true),
            "device_id": .string("remote:1a2b3c4d"),
            "epoch": .string("5"),
            "ceremony_id": .string("ceremony-abcdef0123456789"),
            "connection_generation": .int(7)
        ])
        let (relay, _) = try await makeRelay(responses: [.result(GatewayTestHelpers.toolResult(json: json))])
        let outcome = try await relay.unlockComplete(
            deviceID: "remote:1a2b3c4d",
            appCeremonyID: "ceremony-abcdef0123456789",
            connectionGeneration: 7,
            credentialJSON: "{\"id\":\"x\"}"
        )
        guard case let .verified(result) = outcome else {
            return XCTFail("Expected verified, got \(outcome)")
        }
        XCTAssertEqual(result.epoch, 5)
        XCTAssertEqual(result.connectionGeneration, 7)
    }

    func testUnlockCompleteRejectsMismatchedConnectionGeneration() async throws {
        let json = JSONValue.object([
            "ok": .bool(true),
            "verified": .bool(true),
            "device_id": .string("remote:1a2b3c4d"),
            "epoch": .string("5"),
            "ceremony_id": .string("ceremony-abcdef0123456789"),
            "connection_generation": .int(8)
        ])
        let (relay, _) = try await makeRelay(responses: [.result(GatewayTestHelpers.toolResult(json: json))])
        let outcome = try await relay.unlockComplete(
            deviceID: "remote:1a2b3c4d",
            appCeremonyID: "ceremony-abcdef0123456789",
            connectionGeneration: 7,
            credentialJSON: "{\"id\":\"x\"}"
        )
        guard case let .rejected(code) = outcome else {
            return XCTFail("Expected rejected, got \(outcome)")
        }
        XCTAssertEqual(code, "passkey_stale_ceremony", "An echoed generation that does not match the request is a stale ceremony.")
    }

    func testUnlockCompleteRejectsWhenNotVerified() async throws {
        let json = JSONValue.object(["ok": .bool(false), "code": .string("verification_failed")])
        let (relay, _) = try await makeRelay(responses: [.result(GatewayTestHelpers.toolResult(json: json))])
        let outcome = try await relay.unlockComplete(
            deviceID: "remote:1a2b3c4d",
            appCeremonyID: "ceremony-abcdef0123456789",
            connectionGeneration: 7,
            credentialJSON: "{\"id\":\"x\"}"
        )
        guard case .rejected = outcome else {
            return XCTFail("Expected rejected, got \(outcome)")
        }
    }

    func testUnlockCompleteUncertainFailureIsGenericRejection() async throws {
        // Completion may have occurred on the app; an uncertain failure is still a generic
        // non-success here, with no automatic retry and no rollback claim.
        let relay = try await makeThrowingRelay(error: MCPError.internalError("boom"))
        let outcome = try await relay.unlockComplete(
            deviceID: "remote:1a2b3c4d",
            appCeremonyID: "ceremony-abcdef0123456789",
            connectionGeneration: 7,
            credentialJSON: "{\"id\":\"x\"}"
        )
        guard case let .rejected(code) = outcome else {
            return XCTFail("Expected rejected, got \(outcome)")
        }
        XCTAssertEqual(code, "passkey_complete_failed")
    }

    // MARK: Acknowledge

    func testAcknowledgeTrustSucceedsOnOkTrue() async throws {
        let (relay, connection) = try await makeRelay(responses: [.result(GatewayTestHelpers.toolResult(json: .object(["ok": .bool(true)])))])
        let ok = await relay.acknowledgeTrust(launch: "launch", revision: 3, issuance: "iss-xyz")
        XCTAssertTrue(ok)
        let calls = await connection.calls
        XCTAssertEqual(calls.first?.arguments["op"]?.stringValue, "acknowledge_trust")
        XCTAssertEqual(calls.first?.arguments["trust_revision"]?.stringValue, "3")
        XCTAssertEqual(calls.first?.arguments["trust_issuance"]?.stringValue, "iss-xyz")
    }

    func testAcknowledgeTrustFailsOnTransport() async throws {
        let (relay, _) = try await makeRelay(responses: [.appLinkLost("dropped")])
        let ok = await relay.acknowledgeTrust(launch: "launch", revision: 3, issuance: "iss-xyz")
        XCTAssertFalse(ok)
    }

    // MARK: Helpers

    private func makeRelay(
        responses: [RecordingAppLinkConnection.Response]
    ) async throws -> (GatewayPasskeyRelay, RecordingAppLinkConnection) {
        let configuration = try GatewayTestHelpers.configuration(root: root)
        let connection = RecordingAppLinkConnection(responses: responses)
        let session = AppLinkSession(config: configuration, connector: StaticAppLinkConnector(connection: connection))
        try await session.connect()
        return (GatewayPasskeyRelay(appLink: session), connection)
    }

    /// Build a relay whose principal leg throws `error` on EVERY tool call, so the relay's
    /// classification of a specific thrown error can be asserted without touching the shared doubles.
    private func makeThrowingRelay(error: Error) async throws -> GatewayPasskeyRelay {
        let configuration = try GatewayTestHelpers.configuration(root: root)
        let connection = ThrowingAppLinkConnection(error: error)
        let session = AppLinkSession(config: configuration, connector: ThrowingAppLinkConnector(connection: connection))
        try await session.connect()
        return GatewayPasskeyRelay(appLink: session)
    }

    private func capableListDevicesJSON(deviceID: String, hostKey: Data, deviceKey: Data, required: Bool) -> JSONValue {
        .object([
            "ok": .bool(true),
            "passkey_policy_version": .int(1),
            "trust_revision": .object([
                "launch": .string("launch"),
                "revision": .string("3"),
                "issuance": .string("iss-xyz")
            ]),
            "origin": .string("https://mac.example-tailnet.ts.net:8443"),
            "origin_revision": .string("2"),
            "host_public_key": .string(hostKey.base64EncodedString()),
            "host_fingerprint": .string(Self.fingerprint(hostKey)),
            "devices": .array([
                .object([
                    "schema_version": .int(1),
                    "id": .string(deviceID),
                    "display_name": .string("Phone"),
                    "public_key": .string(deviceKey.base64EncodedString()),
                    "public_key_fingerprint": .string(Self.fingerprint(deviceKey)),
                    "scopes": .array([.string("remote.control")]),
                    "created_at": .string("2026-01-01T00:00:00.000Z"),
                    "counter_floor": .int(0),
                    "revoked": .bool(false),
                    "last_seen_at": .null,
                    "revoked_at": .null,
                    "has_push_subscription": .bool(false),
                    "passkey_policy": .object([
                        "version": .int(1),
                        "state": .string(required ? "required" : "off"),
                        "enrolled": .bool(required),
                        "epoch": .string("5"),
                        "enrollment_open": .bool(false),
                        "needs_reenrollment": .bool(false)
                    ])
                ])
            ])
        ])
    }

    private static func p256Raw() -> Data {
        P256.Signing.PrivateKey().publicKey.rawRepresentation
    }

    private static func fingerprint(_ key: Data) -> String {
        let hex = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }
}

/// A principal-leg connection that throws a fixed error on every tool call. Local to this suite so the
/// relay's per-error classification can be exercised without modifying the shared gateway doubles.
private actor ThrowingAppLinkConnection: AppLinkConnection {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func callTool(
        name _: String,
        arguments _: [String: Value],
        timeout _: TimeInterval?
    ) async throws -> MCPToolResult {
        throw error
    }

    func disconnect() async {}
}

private struct ThrowingAppLinkConnector: AppLinkConnecting {
    let connection: ThrowingAppLinkConnection

    func connect(
        configuration _: GatewayConfiguration,
        clientName _: String,
        logger _: Logger
    ) async throws -> any AppLinkConnection {
        connection
    }
}
