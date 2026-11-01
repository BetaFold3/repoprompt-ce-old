import Foundation
import RepoPromptAgentCore

/// Version-aware decoding for the paired-devices registry (remote passkey unlock, Step 2).
///
/// The on-disk file keeps the same filename. The outer `schemaVersion` is probed first, then:
///   - version 1 is decoded with a FROZEN private copy of the pre-passkey shapes, validated with the
///     original v1 rules, and migrated IN MEMORY to schema 2 with every device's policy set to
///     `.off` (epoch 0). Disk stays v1 until the next committed save, which writes schema 2.
///   - version 2 is decoded strictly (`passkey` and its nested keys are mandatory) and validated.
///   - any other version is rejected: a newer version as `.unsupportedSchemaVersion`, anything else
///     as `.invalidRegistry`.
///
/// A malformed or unknown-version file is never silently treated as an empty/off registry.
enum RemotePairingRegistryCodec {
    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }

    // MARK: Frozen schema-1 shapes (do not evolve; they define what a v1 file is)

    private struct PairedDeviceRecordV1: Decodable {
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
    }

    private struct PairedDeviceRegistryV1: Decodable {
        var schemaVersion: Int
        var hostPublicKeyFingerprint: String
        var devices: [PairedDeviceRecordV1]
    }

    static func decode(_ data: Data) -> Result<PairedDeviceRegistry, RemotePairingIdentityStoreError> {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(SchemaProbe.self, from: data) else {
            return .failure(.invalidRegistry)
        }

        switch probe.schemaVersion {
        case 1:
            return decodeVersion1(data, decoder: decoder)
        case PairedDeviceRegistry.currentSchemaVersion:
            guard let registry = try? decoder.decode(PairedDeviceRegistry.self, from: data),
                  RemotePairingIdentityStore.validateRegistry(registry)
            else {
                return .failure(.invalidRegistry)
            }
            return .success(registry)
        case let version where version > PairedDeviceRegistry.currentSchemaVersion:
            return .failure(.unsupportedSchemaVersion(version))
        default:
            return .failure(.invalidRegistry)
        }
    }

    private static func decodeVersion1(
        _ data: Data,
        decoder: JSONDecoder
    ) -> Result<PairedDeviceRegistry, RemotePairingIdentityStoreError> {
        guard let legacy = try? decoder.decode(PairedDeviceRegistryV1.self, from: data),
              legacy.schemaVersion == 1,
              RemotePairingCrypto.isValidFingerprint(legacy.hostPublicKeyFingerprint)
        else {
            return .failure(.invalidRegistry)
        }

        var migratedDevices: [PairedDeviceRecord] = []
        var seenIDs: Set<String> = []
        for legacyDevice in legacy.devices {
            guard legacyDevice.schemaVersion == 1,
                  RemotePairingCrypto.isValidDeviceID(legacyDevice.id),
                  !legacyDevice.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !legacyDevice.scopes.isEmpty,
                  RemotePairingCrypto.fingerprint(forRawPublicKey: legacyDevice.publicKeyRawRepresentation) != nil,
                  !seenIDs.contains(legacyDevice.id)
            else {
                return .failure(.invalidRegistry)
            }
            seenIDs.insert(legacyDevice.id)
            migratedDevices.append(PairedDeviceRecord(
                id: legacyDevice.id,
                displayName: legacyDevice.displayName,
                publicKeyRawRepresentation: legacyDevice.publicKeyRawRepresentation,
                scopes: legacyDevice.scopes,
                createdAt: legacyDevice.createdAt,
                lastSeenAt: legacyDevice.lastSeenAt,
                revokedAt: legacyDevice.revokedAt,
                counterFloor: legacyDevice.counterFloor,
                pushSubscription: legacyDevice.pushSubscription,
                passkey: .off
            ))
        }

        let migrated = PairedDeviceRegistry(
            hostPublicKeyFingerprint: legacy.hostPublicKeyFingerprint,
            devices: migratedDevices
        )
        return .success(migrated)
    }
}
