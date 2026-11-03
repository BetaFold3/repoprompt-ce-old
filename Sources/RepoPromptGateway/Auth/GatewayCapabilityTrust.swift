import CryptoKit
import Foundation
import RepoPromptRemoteWire

// MARK: - Strict capability-1 trust model (remote passkey unlock, Step 3)

// These types are the STRICT reading of the Step 2 `remote_pairing list_devices` capability-1
// response, consumed by the gateway trust-refresh coordinator. This parser DEFAULTS NOTHING: a
// missing security field, a duplicate device ID, an unsupported version, a malformed value, a
// negative counter, or an unknown policy state invalidates the WHOLE snapshot rather than silently
// substituting a protection-off default. (Step 3 plan §8; field names/encodings taken verbatim from
// MCPRemotePairingToolProvider.deviceValue / the capable list_devices branch.)

/// Per-device passkey policy exactly as projected in a capability-1 response.
struct GatewayDevicePasskeyPolicy: Equatable {
    enum State: String, Equatable {
        case off
        case required
    }

    let version: Int
    let state: State
    let enrolled: Bool
    let epoch: UInt64
    let enrollmentOpen: Bool
    let needsReenrollment: Bool

    var isRequired: Bool {
        state == .required
    }
}

/// A paired device as read from a strict capability-1 snapshot. Holds only public material.
struct GatewayCapabilityTrustedDevice: Equatable {
    let deviceID: String
    let displayName: String
    let publicKeyRawRepresentation: Data
    let counterFloor: UInt64
    let isRevoked: Bool
    let scopes: [String]
    let policy: GatewayDevicePasskeyPolicy
}

/// A fully validated capability-1 trust snapshot.
struct GatewayCapabilityTrustSnapshot: Equatable {
    struct Revision: Equatable {
        let launch: String
        let revision: UInt64
        let issuance: String
    }

    let hostPublicKeyRawRepresentation: Data
    let hostFingerprint: String
    let trustRevision: Revision
    /// `nil` is the valid locked-but-published state (required policy, authoritative origin not yet
    /// available). It is NEVER "no policy".
    let authoritativeOrigin: String?
    let originRevision: UInt64
    let devices: [String: GatewayCapabilityTrustedDevice]

    /// True iff ANY device — including a revoked one — carries required policy. Drives the
    /// "any required policy blocks static access" rule.
    var hasAnyRequiredPolicy: Bool {
        devices.values.contains { $0.policy.isRequired }
    }

    /// Strictly parse a capability-1 `list_devices` response. Throws
    /// `DeviceAuthenticationError.invalidTrustSnapshot` on any violation; the caller treats a throw as
    /// AUTHORITATIVE invalidity (not a transport failure).
    static func parseStrict(from payload: JSONValue) throws -> GatewayCapabilityTrustSnapshot {
        guard let object = payload.objectValue else {
            throw invalid("Response is not an object.")
        }
        guard object["ok"]?.boolValue == true else {
            throw invalid("Missing or non-true `ok`.")
        }
        guard object["passkey_policy_version"]?.intValue == 1 else {
            throw invalid("Missing or unsupported `passkey_policy_version` (only 1 is accepted).")
        }

        let hostKey = try requirePublicKey(object["host_public_key"], field: "host_public_key")
        let hostFingerprint = try requireNonEmptyString(object["host_fingerprint"], field: "host_fingerprint")
        // The host fingerprint must be the SHA-256 of the host key, in the app's exact
        // `sha256:<lowercase-hex>` form. A fingerprint that does not match its own key is an
        // authoritative inconsistency, not an acceptable snapshot.
        guard hostFingerprint == expectedFingerprint(forRawPublicKey: hostKey) else {
            throw invalid("`host_fingerprint` does not match `host_public_key`.")
        }

        guard let revisionObject = object["trust_revision"]?.objectValue else {
            throw invalid("Missing `trust_revision` object.")
        }
        let launch = try requireNonEmptyString(revisionObject["launch"], field: "trust_revision.launch")
        let revision = try requireDecimalUInt64(revisionObject["revision"], field: "trust_revision.revision")
        let issuance = try requireNonEmptyString(revisionObject["issuance"], field: "trust_revision.issuance")

        let origin = try parseOrigin(object["origin"])
        let originRevision = try requireDecimalUInt64(object["origin_revision"], field: "origin_revision")

        guard let deviceValues = object["devices"]?.arrayValue else {
            throw invalid("Missing `devices` array.")
        }
        var devices: [String: GatewayCapabilityTrustedDevice] = [:]
        for deviceValue in deviceValues {
            let device = try parseDevice(deviceValue)
            guard devices[device.deviceID] == nil else {
                throw invalid("Duplicate device id `\(device.deviceID)`.")
            }
            devices[device.deviceID] = device
        }

        return GatewayCapabilityTrustSnapshot(
            hostPublicKeyRawRepresentation: hostKey,
            hostFingerprint: hostFingerprint,
            trustRevision: Revision(launch: launch, revision: revision, issuance: issuance),
            authoritativeOrigin: origin,
            originRevision: originRevision,
            devices: devices
        )
    }

    // MARK: Device

    private static func parseDevice(_ value: JSONValue) throws -> GatewayCapabilityTrustedDevice {
        guard let object = value.objectValue else {
            throw invalid("Malformed device record.")
        }
        let deviceID = try requireNonEmptyString(object["id"], field: "device.id")
        let publicKey = try requirePublicKey(object["public_key"], field: "device.public_key")
        let displayName = object["display_name"]?.stringValue ?? deviceID

        guard let counterFloorInt = object["counter_floor"]?.intValue else {
            throw invalid("device `\(deviceID)` missing integer `counter_floor`.")
        }
        guard counterFloorInt >= 0 else {
            throw invalid("device `\(deviceID)` has a negative `counter_floor`.")
        }
        guard let isRevoked = object["revoked"]?.boolValue else {
            throw invalid("device `\(deviceID)` missing explicit boolean `revoked`.")
        }

        guard let scopeValues = object["scopes"]?.arrayValue else {
            throw invalid("device `\(deviceID)` missing `scopes` array.")
        }
        var scopes: [String] = []
        for scopeValue in scopeValues {
            guard let scope = scopeValue.stringValue else {
                throw invalid("device `\(deviceID)` has a non-string scope.")
            }
            scopes.append(scope)
        }

        let policy = try parsePolicy(object["passkey_policy"], deviceID: deviceID)

        return GatewayCapabilityTrustedDevice(
            deviceID: deviceID,
            displayName: displayName,
            publicKeyRawRepresentation: publicKey,
            counterFloor: UInt64(counterFloorInt),
            isRevoked: isRevoked,
            scopes: scopes,
            policy: policy
        )
    }

    private static func parsePolicy(_ value: JSONValue?, deviceID: String) throws -> GatewayDevicePasskeyPolicy {
        guard let object = value?.objectValue else {
            throw invalid("device `\(deviceID)` missing `passkey_policy` object.")
        }
        guard object["version"]?.intValue == 1 else {
            throw invalid("device `\(deviceID)` has an unsupported `passkey_policy.version`.")
        }
        guard let stateRaw = object["state"]?.stringValue,
              let state = GatewayDevicePasskeyPolicy.State(rawValue: stateRaw)
        else {
            throw invalid("device `\(deviceID)` has a missing or unknown `passkey_policy.state`.")
        }
        guard let enrolled = object["enrolled"]?.boolValue else {
            throw invalid("device `\(deviceID)` missing explicit `passkey_policy.enrolled`.")
        }
        let epoch = try requireDecimalUInt64(object["epoch"], field: "device `\(deviceID)` passkey_policy.epoch")
        guard let enrollmentOpen = object["enrollment_open"]?.boolValue else {
            throw invalid("device `\(deviceID)` missing explicit `passkey_policy.enrollment_open`.")
        }
        guard let needsReenrollment = object["needs_reenrollment"]?.boolValue else {
            throw invalid("device `\(deviceID)` missing explicit `passkey_policy.needs_reenrollment`.")
        }
        // Reject impossible policy combinations the app projection can never emit, so a corrupted or
        // forged authoritative response is invalid rather than silently coerced. An off policy has no
        // credential and no enrollment activity; an enrolled device has no open enrollment window.
        if state == .off {
            guard !enrolled, !enrollmentOpen, !needsReenrollment else {
                throw invalid("device `\(deviceID)` has an off `passkey_policy` with enrollment/credential state set.")
            }
        }
        if enrolled, enrollmentOpen {
            throw invalid("device `\(deviceID)` is enrolled but still reports an open enrollment window.")
        }
        return GatewayDevicePasskeyPolicy(
            version: 1,
            state: state,
            enrolled: enrolled,
            epoch: epoch,
            enrollmentOpen: enrollmentOpen,
            needsReenrollment: needsReenrollment
        )
    }

    // MARK: Field helpers

    private static func requireNonEmptyString(_ value: JSONValue?, field: String) throws -> String {
        guard let string = value?.stringValue, !string.isEmpty else {
            throw invalid("Missing or empty `\(field)`.")
        }
        return string
    }

    /// Parse a lossless decimal-string UInt64 exactly as Step 2 serializes revision/epoch fields.
    /// Rejects empty strings, signs, non-decimal text, and JSON numbers (the wire uses strings).
    private static func requireDecimalUInt64(_ value: JSONValue?, field: String) throws -> UInt64 {
        guard let string = value?.stringValue, !string.isEmpty, let parsed = UInt64(string) else {
            throw invalid("Missing or non-decimal-string `\(field)`.")
        }
        return parsed
    }

    private static func requirePublicKey(_ value: JSONValue?, field: String) throws -> Data {
        guard let base64 = value?.stringValue, let data = Data(base64Encoded: base64) else {
            throw invalid("Missing or non-base64 `\(field)`.")
        }
        guard (try? P256.Signing.PublicKey(rawRepresentation: data)) != nil else {
            throw invalid("`\(field)` is not a valid P-256 public key.")
        }
        return data
    }

    /// `origin` must be an explicitly present key: `null` (valid locked state) or a strict HTTPS
    /// origin string. Absent, wrong type, or a malformed origin invalidates the snapshot.
    private static func parseOrigin(_ value: JSONValue?) throws -> String? {
        guard let value else {
            throw invalid("Missing explicit `origin` key.")
        }
        if case .null = value {
            return nil
        }
        guard let origin = value.stringValue, isStrictHTTPSOrigin(origin) else {
            throw invalid("`origin` must be null or a valid HTTPS origin.")
        }
        return origin
    }

    /// A strict web origin: `https` scheme, nonempty host, optional port, and no userinfo, path,
    /// query, or fragment.
    static func isStrictHTTPSOrigin(_ origin: String) -> Bool {
        guard let components = URLComponents(string: origin),
              components.scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil
        else {
            return false
        }
        return true
    }

    /// The app's canonical public-key fingerprint: `sha256:` + lowercase hex of the SHA-256 of the
    /// raw key. Mirrors `RemotePairingCrypto.fingerprint(forRawPublicKey:)` so the gateway can verify
    /// the host binding without importing the app module.
    private static func expectedFingerprint(forRawPublicKey rawRepresentation: Data) -> String {
        let hex = SHA256.hash(data: rawRepresentation)
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(hex)"
    }

    private static func invalid(_ message: String) -> DeviceAuthenticationError {
        DeviceAuthenticationError.invalidTrustSnapshot(message)
    }
}

/// Authority-facing classification of the latest trust read. A transport failure must NOT replace a
/// previously valid snapshot; authoritative invalidity must. (Step 3 plan §§1, 8.)
enum GatewayCapabilityTrustAvailability: Equatable {
    case unavailable
    case valid(GatewayCapabilityTrustSnapshot)
    case invalid
}
