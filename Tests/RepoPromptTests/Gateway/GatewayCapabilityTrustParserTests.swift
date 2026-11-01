import CryptoKit
import Foundation
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

/// Strict capability-1 trust parser (remote passkey unlock, Step 3). Field names and encodings mirror
/// the capable `remote_pairing list_devices` branch and `deviceValue` in `MCPRemotePairingToolProvider`
/// exactly; the parser defaults nothing and rejects the whole snapshot on any violation.
final class GatewayCapabilityTrustParserTests: XCTestCase {
    private let hostKeyRaw = P256.Signing.PrivateKey().publicKey.rawRepresentation
    private let deviceKeyBase64 = P256.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()

    private var hostKeyBase64: String {
        hostKeyRaw.base64EncodedString()
    }

    /// The canonical `sha256:<hex>` fingerprint of the host key, matching the app projection.
    private var hostFingerprint: String {
        let hex = SHA256.hash(data: hostKeyRaw).map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }

    // MARK: Accept

    func testParsesValidRequiredSnapshot() throws {
        let snapshot = try GatewayCapabilityTrustSnapshot.parseStrict(from: .object(makeValidPayload()))
        XCTAssertEqual(snapshot.hostFingerprint, hostFingerprint)
        XCTAssertEqual(snapshot.trustRevision.launch, "launch-nonce")
        XCTAssertEqual(snapshot.trustRevision.revision, 7)
        XCTAssertEqual(snapshot.trustRevision.issuance, "iss-123")
        XCTAssertEqual(snapshot.authoritativeOrigin, "https://example.com")
        XCTAssertEqual(snapshot.originRevision, 3)
        XCTAssertTrue(snapshot.hasAnyRequiredPolicy)
        let device = try XCTUnwrap(snapshot.devices["device-1"])
        XCTAssertEqual(device.counterFloor, 0)
        XCTAssertFalse(device.isRevoked)
        XCTAssertTrue(device.policy.isRequired)
        XCTAssertEqual(device.policy.epoch, 4)
        XCTAssertEqual(device.scopes, ["sessions:observe"])
    }

    func testNullOriginIsValidLockedState() throws {
        var payload = makeValidPayload()
        payload["origin"] = .null
        let snapshot = try GatewayCapabilityTrustSnapshot.parseStrict(from: .object(payload))
        XCTAssertNil(snapshot.authoritativeOrigin)
        XCTAssertTrue(snapshot.hasAnyRequiredPolicy)
    }

    func testOffPolicyHasNoRequiredFlag() throws {
        var payload = makeValidPayload()
        payload["devices"] = .array([makeDevice(required: false)])
        let snapshot = try GatewayCapabilityTrustSnapshot.parseStrict(from: .object(payload))
        XCTAssertFalse(snapshot.hasAnyRequiredPolicy)
    }

    // MARK: Reject

    func testRejectsOkFalse() {
        var payload = makeValidPayload()
        payload["ok"] = .bool(false)
        assertRejected(payload)
    }

    func testRejectsUnsupportedVersion() {
        var payload = makeValidPayload()
        payload["passkey_policy_version"] = .int(2)
        assertRejected(payload)
    }

    func testRejectsInvalidHostKey() {
        var payload = makeValidPayload()
        payload["host_public_key"] = .string(Data([1, 2, 3]).base64EncodedString())
        assertRejected(payload)
    }

    func testRejectsMissingOriginKey() {
        var payload = makeValidPayload()
        payload["origin"] = nil
        assertRejected(payload)
    }

    func testRejectsNonHTTPSOrigin() {
        var payload = makeValidPayload()
        payload["origin"] = .string("http://example.com")
        assertRejected(payload)
    }

    func testRejectsOriginWithPath() {
        var payload = makeValidPayload()
        payload["origin"] = .string("https://example.com/app")
        assertRejected(payload)
    }

    func testRejectsEmptyIssuance() {
        var payload = makeValidPayload()
        payload["trust_revision"] = .object([
            "launch": .string("launch-nonce"),
            "revision": .string("7"),
            "issuance": .string("")
        ])
        assertRejected(payload)
    }

    func testRejectsNonDecimalRevision() {
        var payload = makeValidPayload()
        payload["trust_revision"] = .object([
            "launch": .string("launch-nonce"),
            "revision": .string("not-a-number"),
            "issuance": .string("iss-123")
        ])
        assertRejected(payload)
    }

    func testRejectsNegativeCounterFloor() {
        var payload = makeValidPayload()
        payload["devices"] = .array([makeDevice(required: true, counterFloor: .int(-1))])
        assertRejected(payload)
    }

    func testRejectsMissingRevokedFlag() {
        var device = makeDeviceObject(required: true)
        device["revoked"] = nil
        var payload = makeValidPayload()
        payload["devices"] = .array([.object(device)])
        assertRejected(payload)
    }

    func testRejectsDuplicateDeviceIDs() {
        var payload = makeValidPayload()
        payload["devices"] = .array([makeDevice(required: true), makeDevice(required: false)])
        assertRejected(payload)
    }

    func testRejectsUnknownPolicyState() {
        var device = makeDeviceObject(required: true)
        if case var .object(policy)? = device["passkey_policy"] {
            policy["state"] = .string("paused")
            device["passkey_policy"] = .object(policy)
        }
        var payload = makeValidPayload()
        payload["devices"] = .array([.object(device)])
        assertRejected(payload)
    }

    func testRejectsMissingPolicy() {
        var device = makeDeviceObject(required: true)
        device["passkey_policy"] = nil
        var payload = makeValidPayload()
        payload["devices"] = .array([.object(device)])
        assertRejected(payload)
    }

    func testRejectsHostFingerprintMismatch() {
        var payload = makeValidPayload()
        // Well-formed sha256 fingerprint, but not of this host key.
        payload["host_fingerprint"] = .string("sha256:" + String(repeating: "0", count: 64))
        assertRejected(payload)
    }

    func testRejectsOffPolicyThatClaimsEnrolled() {
        var device = makeDeviceObject(required: false)
        if case var .object(policy)? = device["passkey_policy"] {
            policy["enrolled"] = .bool(true)
            device["passkey_policy"] = .object(policy)
        }
        var payload = makeValidPayload()
        payload["devices"] = .array([.object(device)])
        assertRejected(payload)
    }

    func testRejectsOffPolicyWithOpenEnrollment() {
        var device = makeDeviceObject(required: false)
        if case var .object(policy)? = device["passkey_policy"] {
            policy["enrollment_open"] = .bool(true)
            device["passkey_policy"] = .object(policy)
        }
        var payload = makeValidPayload()
        payload["devices"] = .array([.object(device)])
        assertRejected(payload)
    }

    func testRejectsEnrolledDeviceWithOpenEnrollment() {
        var device = makeDeviceObject(required: true)
        if case var .object(policy)? = device["passkey_policy"] {
            policy["enrolled"] = .bool(true)
            policy["enrollment_open"] = .bool(true)
            device["passkey_policy"] = .object(policy)
        }
        var payload = makeValidPayload()
        payload["devices"] = .array([.object(device)])
        assertRejected(payload)
    }

    func testStrictHTTPSOriginHelper() {
        XCTAssertTrue(GatewayCapabilityTrustSnapshot.isStrictHTTPSOrigin("https://example.com"))
        XCTAssertTrue(GatewayCapabilityTrustSnapshot.isStrictHTTPSOrigin("https://example.com:8443"))
        XCTAssertFalse(GatewayCapabilityTrustSnapshot.isStrictHTTPSOrigin("https://example.com/"))
        XCTAssertFalse(GatewayCapabilityTrustSnapshot.isStrictHTTPSOrigin("http://example.com"))
        XCTAssertFalse(GatewayCapabilityTrustSnapshot.isStrictHTTPSOrigin("https://user:pass@example.com"))
        XCTAssertFalse(GatewayCapabilityTrustSnapshot.isStrictHTTPSOrigin("ftp://example.com"))
    }

    // MARK: Helpers

    private func assertRejected(_ payload: [String: JSONValue], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try GatewayCapabilityTrustSnapshot.parseStrict(from: .object(payload)), file: file, line: line) { error in
            guard case DeviceAuthenticationError.invalidTrustSnapshot = error else {
                XCTFail("Expected invalidTrustSnapshot, got \(error)", file: file, line: line)
                return
            }
        }
    }

    private func makeValidPayload() -> [String: JSONValue] {
        [
            "ok": .bool(true),
            "passkey_policy_version": .int(1),
            "host_public_key": .string(hostKeyBase64),
            "host_fingerprint": .string(hostFingerprint),
            "trust_revision": .object([
                "launch": .string("launch-nonce"),
                "revision": .string("7"),
                "issuance": .string("iss-123")
            ]),
            "origin": .string("https://example.com"),
            "origin_revision": .string("3"),
            "devices": .array([makeDevice(required: true)])
        ]
    }

    private func makeDevice(required: Bool, id: String = "device-1", counterFloor: JSONValue = .int(0)) -> JSONValue {
        .object(makeDeviceObject(required: required, id: id, counterFloor: counterFloor))
    }

    private func makeDeviceObject(required: Bool, id: String = "device-1", counterFloor: JSONValue = .int(0)) -> [String: JSONValue] {
        [
            "schema_version": .int(2),
            "id": .string(id),
            "display_name": .string("Phone"),
            "public_key": .string(deviceKeyBase64),
            "public_key_fingerprint": .string("dfp"),
            "scopes": .array([.string("sessions:observe")]),
            "created_at": .string("2026-01-01T00:00:00.000Z"),
            "counter_floor": counterFloor,
            "revoked": .bool(false),
            "last_seen_at": .null,
            "revoked_at": .null,
            "has_push_subscription": .bool(false),
            "passkey_policy": .object([
                "version": .int(1),
                "state": .string(required ? "required" : "off"),
                "enrolled": .bool(required),
                "epoch": .string("4"),
                "enrollment_open": .bool(false),
                "needs_reenrollment": .bool(false)
            ])
        ]
    }
}
