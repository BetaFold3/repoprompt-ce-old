import Foundation

// Durable passkey-policy types for a paired device (remote passkey unlock, Step 2). Stored inside
// each `PairedDeviceRecord` under schema 2. Private passkey material NEVER lives here — only
// verified public credential material and policy state.

/// Whether a paired browser requires a passkey before receiving protected content. An unknown raw
/// value fails decoding (malformed policy is invalid, never silently "off").
enum RemotePasskeyPolicyState: String, Codable, Equatable {
    case off
    case required
}

/// Verified public credential material for one enrolled browser. No private key, no grant secret.
struct RemotePasskeyCredentialRecord: Codable, Equatable {
    /// Credential ID bytes (authenticator-attested, 1...1023 bytes).
    var credentialID: Data
    /// COSE-encoded public key produced by the verifier (1...1024 bytes).
    var publicKeyCOSE: Data
    /// Relying Party ID (origin hostname) bound at registration. A later hostname change makes the
    /// credential unusable until Mac re-enrollment; a port-only change is tolerated.
    var rpID: String
    /// Random user handle generated at registration.
    var userHandle: Data
    /// Sign count reported at registration. Metadata only — never the sole replay/clone authority
    /// for synced credentials.
    var signCountAtRegistration: UInt32
    /// Backup-eligible flag at registration (immutable across ceremonies).
    var backupEligible: Bool
    /// Backup state reported at registration.
    var backedUpAtRegistration: Bool
    var createdAt: Date
}

/// Per-device passkey policy. `credential` is a required but nullable key in schema 2: a missing
/// key is malformed (not "no credential").
struct RemotePasskeyPolicyRecord: Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var state: RemotePasskeyPolicyState
    /// Monotonically increasing policy epoch. Advanced by the store on every durable policy change
    /// (enable, reset, disable, credential commit, re-pair, revoke). Never wraps.
    var epoch: UInt64
    var credential: RemotePasskeyCredentialRecord?

    init(
        schemaVersion: Int = RemotePasskeyPolicyRecord.currentSchemaVersion,
        state: RemotePasskeyPolicyState,
        epoch: UInt64,
        credential: RemotePasskeyCredentialRecord?
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
        self.epoch = epoch
        self.credential = credential
    }

    /// The default policy for a device with no protection configured.
    static let off = RemotePasskeyPolicyRecord(
        schemaVersion: currentSchemaVersion,
        state: .off,
        epoch: 0,
        credential: nil
    )

    var isRequired: Bool {
        state == .required
    }

    var isEnrolled: Bool {
        credential != nil
    }
}

extension RemotePasskeyPolicyRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case state
        case epoch
        case credential
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        state = try container.decode(RemotePasskeyPolicyState.self, forKey: .state)
        epoch = try container.decode(UInt64.self, forKey: .epoch)
        // `decode` (not `decodeIfPresent`): the key MUST exist. A present `null` decodes to nil; an
        // absent key is malformed. "Missing is not equivalent to null."
        credential = try container.decode(RemotePasskeyCredentialRecord?.self, forKey: .credential)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(state, forKey: .state)
        try container.encode(epoch, forKey: .epoch)
        // Explicit `encode` of an Optional writes an explicit `null` when nil, so the key is always
        // present on disk.
        try container.encode(credential, forKey: .credential)
    }
}
