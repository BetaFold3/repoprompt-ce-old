import Foundation
import RepoPromptAgentCore

struct WebPushSubscriptionRecord: Codable, Equatable {
    var endpoint: String
    var p256dh: String
    var auth: String
    var createdAt: Date

    init(endpoint: String, p256dh: String, auth: String, createdAt: Date = Date()) {
        self.endpoint = endpoint
        self.p256dh = p256dh
        self.auth = auth
        self.createdAt = createdAt
    }
}

struct PairedDeviceRecord: Codable, Identifiable, Equatable {
    /// Schema 2 adds the required `passkey` policy field (remote passkey unlock, Step 2). Version 1
    /// registries are migrated in memory by `RemotePairingRegistryCodec`; this type only ever
    /// encodes/decodes schema 2.
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var id: String
    var displayName: String
    var publicKeyRawRepresentation: Data
    var scopes: Set<RemoteScope>
    var createdAt: Date
    var lastSeenAt: Date?
    var revokedAt: Date?
    var counterFloor: UInt64
    var pushSubscription: WebPushSubscriptionRecord?
    /// Per-device passkey policy. Required key in schema 2 (synthesized `Codable` makes the key
    /// mandatory because the property is non-optional with no default in `init(from:)`). Defaults
    /// to `.off` in the memberwise initializer so existing non-passkey call sites keep compiling.
    var passkey: RemotePasskeyPolicyRecord

    init(
        schemaVersion: Int = PairedDeviceRecord.currentSchemaVersion,
        id: String,
        displayName: String,
        publicKeyRawRepresentation: Data,
        scopes: Set<RemoteScope>,
        createdAt: Date = Date(),
        lastSeenAt: Date? = nil,
        revokedAt: Date? = nil,
        counterFloor: UInt64 = 0,
        pushSubscription: WebPushSubscriptionRecord? = nil,
        passkey: RemotePasskeyPolicyRecord = .off
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.publicKeyRawRepresentation = publicKeyRawRepresentation
        self.scopes = scopes
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
        self.counterFloor = counterFloor
        self.pushSubscription = pushSubscription
        self.passkey = passkey
    }

    var isRevoked: Bool {
        revokedAt != nil
    }

    var publicKeyFingerprint: String? {
        RemotePairingCrypto.fingerprint(forRawPublicKey: publicKeyRawRepresentation)
    }
}

struct PairedDeviceRegistry: Codable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var hostPublicKeyFingerprint: String
    var devices: [PairedDeviceRecord]

    init(
        schemaVersion: Int = PairedDeviceRegistry.currentSchemaVersion,
        hostPublicKeyFingerprint: String,
        devices: [PairedDeviceRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.hostPublicKeyFingerprint = hostPublicKeyFingerprint
        self.devices = devices
    }
}

struct RemoteHostPublicKeyInfo: Equatable {
    var rawRepresentation: Data
    var fingerprint: String
}
