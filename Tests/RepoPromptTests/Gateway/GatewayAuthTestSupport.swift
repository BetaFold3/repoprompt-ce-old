import CryptoKit
import Foundation
@testable import RepoPromptGateway
import RepoPromptRemoteWire

/// Shared helpers for M4 gateway ticket/signature/scope tests.
enum GatewayAuthTestSupport {
    struct TestDeviceIdentity {
        let signer: P256.Signing.PrivateKey
        let deviceID: String

        var publicKeyRaw: Data {
            signer.publicKey.rawRepresentation
        }
    }

    static func makeDevice(deviceID: String = "remote:abcd1234") -> TestDeviceIdentity {
        TestDeviceIdentity(signer: P256.Signing.PrivateKey(), deviceID: deviceID)
    }

    static func fingerprint(_ key: P256.Signing.PublicKey) -> String {
        let hex = SHA256.hash(data: key.rawRepresentation)
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(hex)"
    }

    static func trustSnapshot(
        hostSigner: P256.Signing.PrivateKey,
        devices: [(identity: TestDeviceIdentity, revoked: Bool)],
        counterFloor: UInt64 = 0
    ) -> GatewayTrustSnapshot {
        var map: [String: GatewayTrustedDevice] = [:]
        for (identity, revoked) in devices {
            map[identity.deviceID] = GatewayTrustedDevice(
                deviceID: identity.deviceID,
                displayName: "Device \(identity.deviceID)",
                publicKeyRawRepresentation: identity.publicKeyRaw,
                isRevoked: revoked,
                counterFloor: counterFloor
            )
        }
        return GatewayTrustSnapshot(
            hostPublicKeyRawRepresentation: hostSigner.publicKey.rawRepresentation,
            hostFingerprint: fingerprint(hostSigner.publicKey),
            devices: map
        )
    }

    // MARK: Capability-1 trust (remote passkey unlock, Step 3)

    /// Build a strict capability-1 snapshot DIRECTLY (bypassing `parseStrict`), so a fixture can put
    /// the access authority into a known policy state without a wire round-trip. With the Step 3
    /// flip, a paired connection binds LOCKED unless a `.valid` capability snapshot authorizes it, so
    /// most server fixtures apply an all-`off` snapshot (paired `.unprotected`, static access allowed)
    /// to preserve their pre-Step-3 assertions.
    static func capabilitySnapshot(
        hostSigner: P256.Signing.PrivateKey,
        devices: [(identity: TestDeviceIdentity, state: GatewayDevicePasskeyPolicy.State, enrolled: Bool, revoked: Bool)],
        scopes: [String] = [],
        epoch: UInt64 = 1,
        launch: String = "launch-1",
        revision: UInt64 = 1,
        issuance: String = "issuance-1",
        origin: String? = "https://mac.example-tailnet.ts.net:8443",
        originRevision: UInt64 = 1
    ) -> GatewayCapabilityTrustSnapshot {
        var map: [String: GatewayCapabilityTrustedDevice] = [:]
        for entry in devices {
            let policy = switch entry.state {
            case .off:
                GatewayDevicePasskeyPolicy(
                    version: 1, state: .off, enrolled: false, epoch: epoch,
                    enrollmentOpen: false, needsReenrollment: false
                )
            case .required:
                GatewayDevicePasskeyPolicy(
                    version: 1, state: .required, enrolled: entry.enrolled, epoch: epoch,
                    enrollmentOpen: !entry.enrolled, needsReenrollment: false
                )
            }
            map[entry.identity.deviceID] = GatewayCapabilityTrustedDevice(
                deviceID: entry.identity.deviceID,
                displayName: "Device \(entry.identity.deviceID)",
                publicKeyRawRepresentation: entry.identity.publicKeyRaw,
                counterFloor: 0,
                isRevoked: entry.revoked,
                scopes: scopes,
                policy: policy
            )
        }
        return GatewayCapabilityTrustSnapshot(
            hostPublicKeyRawRepresentation: hostSigner.publicKey.rawRepresentation,
            hostFingerprint: fingerprint(hostSigner.publicKey),
            trustRevision: GatewayCapabilityTrustSnapshot.Revision(launch: launch, revision: revision, issuance: issuance),
            authoritativeOrigin: origin,
            originRevision: originRevision,
            devices: map
        )
    }

    /// An all-`off` capability-1 snapshot: every device has policy off (paired connections bind
    /// `.unprotected`, static access is allowed). The valid-but-permissive baseline for fixtures that
    /// exercise ordinary runtime behavior.
    static func capabilityOffSnapshot(
        hostSigner: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
        devices: [TestDeviceIdentity] = [],
        launch: String = "launch-1",
        revision: UInt64 = 1,
        issuance: String = "issuance-1"
    ) -> GatewayCapabilityTrustSnapshot {
        capabilitySnapshot(
            hostSigner: hostSigner,
            devices: devices.map { ($0, GatewayDevicePasskeyPolicy.State.off, false, false) },
            launch: launch,
            revision: revision,
            issuance: issuance
        )
    }

    /// A capability-1 snapshot where the given devices carry required (enrolled) policy and all others
    /// are off. Used by the passkey verifier tests that need a connection to bind LOCKED.
    static func capabilityRequiredSnapshot(
        hostSigner: P256.Signing.PrivateKey,
        required: [TestDeviceIdentity],
        off: [TestDeviceIdentity] = [],
        epoch: UInt64 = 1,
        launch: String = "launch-1",
        revision: UInt64 = 1,
        issuance: String = "issuance-1",
        origin: String? = "https://mac.example-tailnet.ts.net:8443",
        originRevision: UInt64 = 1
    ) -> GatewayCapabilityTrustSnapshot {
        var entries = required.map { ($0, GatewayDevicePasskeyPolicy.State.required, true, false) }
        entries.append(contentsOf: off.map { ($0, GatewayDevicePasskeyPolicy.State.off, false, false) })
        return capabilitySnapshot(
            hostSigner: hostSigner,
            devices: entries,
            epoch: epoch,
            launch: launch,
            revision: revision,
            issuance: issuance,
            origin: origin,
            originRevision: originRevision
        )
    }

    static func mintTicket(
        hostSigner: P256.Signing.PrivateKey,
        deviceID: String,
        scopes: Set<String>,
        issuedAt: Date = Date(),
        ttlMs: Int64 = 30000,
        ticketID: UUID = UUID()
    ) throws -> RemoteTicket {
        let issuedAtMs = Int64((issuedAt.timeIntervalSince1970 * 1000).rounded(.down))
        let unsigned = RemoteTicket(
            ticketID: ticketID,
            deviceID: deviceID,
            scopes: scopes,
            issuedAtMs: issuedAtMs,
            expiresAtMs: issuedAtMs + ttlMs,
            hostFingerprint: fingerprint(hostSigner.publicKey),
            hostSignature: Data()
        )
        let signature = try hostSigner.signature(for: unsigned.canonicalPayload).rawRepresentation
        return RemoteTicket(
            ticketID: unsigned.ticketID,
            deviceID: unsigned.deviceID,
            scopes: unsigned.scopes,
            issuedAtMs: unsigned.issuedAtMs,
            expiresAtMs: unsigned.expiresAtMs,
            hostFingerprint: unsigned.hostFingerprint,
            hostSignature: signature
        )
    }

    static func frameObject(
        type: String,
        requestID: String? = nil,
        sessionID: String? = nil,
        payload: JSONValue? = nil
    ) -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "v": .int(RemoteWireProtocol.version),
            "type": .string(type)
        ]
        if let requestID { object["request_id"] = .string(requestID) }
        if let sessionID { object["session_id"] = .string(sessionID) }
        if let payload { object["payload"] = payload }
        return object
    }

    static func helloObject(ticketJSON: JSONValue) -> [String: JSONValue] {
        frameObject(type: "hello", payload: .object(["ticket": ticketJSON]))
    }

    /// Signs the frame object with the device key over the canonical M4 signing payload
    /// and returns the serialized frame bytes as sent on the wire.
    static func signedFrameData(
        object baseObject: [String: JSONValue],
        ticketID: UUID,
        deviceID: String,
        counter: UInt64,
        deviceKey: P256.Signing.PrivateKey,
        algorithm: String = RemoteFrameSignature.requiredAlgorithm,
        tamperAfterSigning: ((inout [String: JSONValue]) -> Void)? = nil
    ) throws -> Data {
        var object = baseObject
        let frameHashHex = try RemoteWireProtocol.sha256Hex(
            of: RemoteWireProtocol.canonicalData(for: .object(object))
        )
        let signingPayload = RemoteWireProtocol.frameSigningPayload(
            ticketID: ticketID,
            deviceID: deviceID,
            counter: counter,
            frameHashHex: frameHashHex
        )
        let signature = try deviceKey.signature(for: signingPayload).rawRepresentation
        object["sig"] = .object([
            "ticket_id": .string(ticketID.uuidString.lowercased()),
            "device_id": .string(deviceID),
            "counter": .int(Int(counter)),
            "algorithm": .string(algorithm),
            "signature": .string(signature.base64EncodedString())
        ])
        tamperAfterSigning?(&object)
        return try RemoteWireProtocol.canonicalData(for: .object(object))
    }

    static func unsignedFrameData(object: [String: JSONValue]) throws -> Data {
        try RemoteWireProtocol.canonicalData(for: .object(object))
    }

    static func decodeFrame(_ data: Data) throws -> RemoteClientFrame {
        try RemoteWireProtocol.decodeClientFrame(from: data)
    }

    static func makeUsedTicketStore(root: URL) throws -> UsedTicketStore {
        try UsedTicketStore(
            fileURL: root
                .appendingPathComponent("auth", isDirectory: true)
                .appendingPathComponent("used-tickets-v1.jsonl")
        )
    }
}
