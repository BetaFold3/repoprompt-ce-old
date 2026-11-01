import CryptoKit
import Darwin
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import XCTest

/// Schema-2 persistence contract (remote passkey unlock, Step 2): v1→off migration, strict v2
/// decoding, old-build refusal, the disk-version writer fence, secure-save failure semantics, and
/// policy-preserving mutations.
final class RemotePairingRegistrySchemaV2Tests: XCTestCase {
    // MARK: - Frozen v1 fixtures (what a pre-passkey build wrote)

    private struct LegacyV1Record: Encodable {
        var schemaVersion = 1
        var id: String
        var displayName: String
        var publicKeyRawRepresentation: Data
        var scopes: Set<RemoteScope>
        var createdAt: Date
        var counterFloor: UInt64 = 0
    }

    private struct LegacyV1Registry: Encodable {
        var schemaVersion = 1
        var hostPublicKeyFingerprint: String
        var devices: [LegacyV1Record]
    }

    /// A frozen copy of the pre-passkey decode+validate, to prove an old build FAILS CLOSED on v2.
    private struct OldBuildRecord: Decodable {
        var schemaVersion: Int
        var id: String
        var displayName: String
        var publicKeyRawRepresentation: Data
        var scopes: Set<RemoteScope>
        var createdAt: Date
        var counterFloor: UInt64
    }

    private struct OldBuildRegistry: Decodable {
        var schemaVersion: Int
        var hostPublicKeyFingerprint: String
        var devices: [OldBuildRecord]

        enum ValidationError: Error, Equatable { case unsupportedSchemaVersion(Int) }

        /// A frozen copy of the pre-passkey build's registry validation: it accepted ONLY
        /// schemaVersion == 1 and rejected anything else, failing closed rather than dropping
        /// protection. Reproduced here so this test exercises the actual old gate, not just a field
        /// comparison.
        func validateRegistry() throws {
            guard schemaVersion == 1 else { throw ValidationError.unsupportedSchemaVersion(schemaVersion) }
        }
    }

    private func legacyRegistryData(hostKey: P256.Signing.PrivateKey, deviceID: String = "remote:1234abcd") throws -> Data {
        let record = LegacyV1Record(
            id: deviceID,
            displayName: "Legacy iPhone",
            publicKeyRawRepresentation: P256.Signing.PrivateKey().publicKey.rawRepresentation,
            scopes: [.sessionsObserve, .interactionsRespond],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let registry = LegacyV1Registry(
            hostPublicKeyFingerprint: RemotePairingCrypto.fingerprint(for: hostKey.publicKey),
            devices: [record]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(registry)
    }

    private func rawSchemaVersion(at url: URL) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return (object?["schemaVersion"] as? Int) ?? -1
    }

    // MARK: - Migration

    func testVersion1MigratesToOffAndStaysV1OnDiskUntilMutation() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (hostKey, keychain) = RemotePairingTestSupport.hostKeychain()
        try legacyRegistryData(hostKey: hostKey).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let store = RemotePairingIdentityStore(url: url, keychain: keychain)
        let registry = try store.registry()
        XCTAssertEqual(registry.schemaVersion, 2)
        XCTAssertEqual(registry.devices.count, 1)
        XCTAssertEqual(registry.devices[0].passkey, .off)

        // Read did not rewrite the file: disk is still v1.
        XCTAssertEqual(try rawSchemaVersion(at: url), 1)

        // The first committed mutation writes v2 with an explicit null credential.
        try store.updateLastSeen(deviceID: "remote:1234abcd", at: Date(timeIntervalSince1970: 1_700_000_500))
        XCTAssertEqual(try rawSchemaVersion(at: url), 2)
        let diskText = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(diskText.contains("\"credential\" : null"), "credential key must be an explicit null")
    }

    // MARK: - Strict v2 decoding (never defaults to off)

    private func validV2RegistryJSON(hostKey: P256.Signing.PrivateKey, mutate: (inout [String: Any]) -> Void) throws -> Data {
        let record = PairedDeviceRecord(
            id: "remote:1234abcd",
            displayName: "iPhone",
            publicKeyRawRepresentation: P256.Signing.PrivateKey().publicKey.rawRepresentation,
            scopes: [.sessionsObserve],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let registry = PairedDeviceRegistry(
            hostPublicKeyFingerprint: RemotePairingCrypto.fingerprint(for: hostKey.publicKey),
            devices: [record]
        )
        let encoded = try JSONEncoder().encode(registry)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func writeSecure(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func mutateFirstDevicePolicy(_ object: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        guard var devices = object["devices"] as? [[String: Any]], var first = devices.first else { return }
        var policy = (first["passkey"] as? [String: Any]) ?? [:]
        change(&policy)
        first["passkey"] = policy
        devices[0] = first
        object["devices"] = devices
    }

    func testStrictDecodingRejectsMissingOrMalformedPolicyWithoutDefaultingOff() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let hostKey = P256.Signing.PrivateKey()

        // passkey key entirely missing on the record.
        let missingPolicy = try validV2RegistryJSON(hostKey: hostKey) { object in
            guard var devices = object["devices"] as? [[String: Any]], var first = devices.first else { return }
            first.removeValue(forKey: "passkey")
            devices[0] = first
            object["devices"] = devices
        }
        try writeSecure(missingPolicy, to: url)
        XCTAssertEqual(RemotePairingIdentityStore.load(from: url), .failure(.invalidRegistry))

        // state key missing.
        let missingState = try validV2RegistryJSON(hostKey: hostKey) { object in
            mutateFirstDevicePolicy(&object) { $0.removeValue(forKey: "state") }
        }
        try writeSecure(missingState, to: url)
        XCTAssertEqual(RemotePairingIdentityStore.load(from: url), .failure(.invalidRegistry))

        // unknown state raw value.
        let unknownState = try validV2RegistryJSON(hostKey: hostKey) { object in
            mutateFirstDevicePolicy(&object) { $0["state"] = "paused" }
        }
        try writeSecure(unknownState, to: url)
        XCTAssertEqual(RemotePairingIdentityStore.load(from: url), .failure(.invalidRegistry))

        // credential key missing (must be an explicit null, not absent).
        let missingCredentialKey = try validV2RegistryJSON(hostKey: hostKey) { object in
            mutateFirstDevicePolicy(&object) { $0.removeValue(forKey: "credential") }
        }
        try writeSecure(missingCredentialKey, to: url)
        XCTAssertEqual(RemotePairingIdentityStore.load(from: url), .failure(.invalidRegistry))

        // off state carrying a credential is an inconsistent state.
        let offWithCredential = try validV2RegistryJSON(hostKey: hostKey) { object in
            mutateFirstDevicePolicy(&object) { policy in
                policy["state"] = "off"
                policy["credential"] = [
                    "credentialID": Data([1, 2, 3]).base64EncodedString(),
                    "publicKeyCOSE": Data([9]).base64EncodedString(),
                    "rpID": "example.com",
                    "userHandle": Data([7]).base64EncodedString(),
                    "signCountAtRegistration": 0,
                    "backupEligible": true,
                    "backedUpAtRegistration": true,
                    "createdAt": 0
                ]
            }
        }
        try writeSecure(offWithCredential, to: url)
        XCTAssertEqual(RemotePairingIdentityStore.load(from: url), .failure(.invalidRegistry))
    }

    func testRegistryVersion3IsUnsupported() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let hostKey = P256.Signing.PrivateKey()
        let future = try validV2RegistryJSON(hostKey: hostKey) { $0["schemaVersion"] = 3 }
        try writeSecure(future, to: url)
        XCTAssertEqual(RemotePairingIdentityStore.load(from: url), .failure(.unsupportedSchemaVersion(3)))
    }

    // MARK: - Old-build refusal

    func testOldBuildDecoderRefusesV2FileFailingClosed() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let hostKey = P256.Signing.PrivateKey()
        let v2 = try validV2RegistryJSON(hostKey: hostKey) { _ in }
        try writeSecure(v2, to: url)

        // The old build's shapes decode (they ignore the unknown `passkey` key) but its validator
        // requires schemaVersion == 1, so it rejects the v2 file rather than silently dropping
        // protection.
        let old = try JSONDecoder().decode(OldBuildRegistry.self, from: Data(contentsOf: url))
        XCTAssertEqual(old.schemaVersion, 2)
        // Run the FROZEN old-build validator: it requires schemaVersion == 1 and so fails closed on
        // the v2 file rather than silently dropping passkey protection.
        XCTAssertThrowsError(try old.validateRegistry()) { error in
            XCTAssertEqual(error as? OldBuildRegistry.ValidationError, .unsupportedSchemaVersion(2))
        }
    }

    // MARK: - Writer fence

    func testWriterFenceRefusesSaveAfterExternalModification() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (hostKey, keychain) = RemotePairingTestSupport.hostKeychain()
        let store = RemotePairingIdentityStore(url: url, keychain: keychain)

        try store.upsertDevice(RemotePairingTestSupport.deviceRecord(id: "remote:1234abcd"))

        // An external writer replaces the file with a different (larger) valid registry.
        let external = RemotePairingTestSupport.validRegistry(
            hostSigner: hostKey,
            devices: [
                RemotePairingTestSupport.deviceRecord(id: "remote:1234abcd"),
                RemotePairingTestSupport.deviceRecord(id: "remote:5678ef90", displayName: "Second")
            ]
        )
        try RemotePairingTestSupport.writeRegistry(external, to: url)

        XCTAssertThrowsError(try store.updateLastSeen(deviceID: "remote:1234abcd")) { error in
            XCTAssertEqual(error as? RemotePairingIdentityStoreError, .concurrentModification)
        }
        // The external bytes are preserved and the fenced instance keeps failing closed.
        XCTAssertThrowsError(try store.registry()) { error in
            XCTAssertEqual(error as? RemotePairingIdentityStoreError, .concurrentModification)
        }
        // A fresh instance loads the external registry cleanly.
        let fresh = RemotePairingIdentityStore(url: url, keychain: keychain)
        XCTAssertEqual(try fresh.registry().devices.count, 2)
    }

    // MARK: - Secure-save failure

    func testSaveFailureLeavesDiskAndCacheUnchanged() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        let store = RemotePairingIdentityStore(url: url, keychain: keychain)

        try store.upsertDevice(RemotePairingTestSupport.deviceRecord(id: "remote:1234abcd"))
        let committedBytes = try Data(contentsOf: url)

        // Make the parent directory read-only so the secure temp create fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        XCTAssertThrowsError(try store.updateLastSeen(deviceID: "remote:1234abcd")) { error in
            guard case .writeFailed = (error as? RemotePairingIdentityStoreError) else {
                return XCTFail("expected writeFailed, got \(error)")
            }
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Disk unchanged, no stray temp files, and the cached value still serves reads.
        XCTAssertEqual(try Data(contentsOf: url), committedBytes)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "no temp files should remain")
        XCTAssertNil(try store.device(id: "remote:1234abcd")?.lastSeenAt)
        var fileStatus = Darwin.stat()
        XCTAssertEqual(lstat(url.path, &fileStatus), 0)
        XCTAssertEqual(fileStatus.st_mode & 0o777, 0o600)
    }

    // MARK: - Policy-preserving mutations

    private func credential(id: [UInt8]) -> RemotePasskeyCredentialRecord {
        RemotePasskeyCredentialRecord(
            credentialID: Data(id),
            publicKeyCOSE: Data([0xA5, 0x01, 0x02]),
            rpID: "example.com",
            userHandle: Data([0x11, 0x22]),
            signCountAtRegistration: 0,
            backupEligible: true,
            backedUpAtRegistration: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testRePairPreservesPolicyAndAdvancesEpochWhileUpsertDoesNot() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        let store = RemotePairingIdentityStore(url: url, keychain: keychain)
        let id = "remote:1234abcd"

        try store.upsertDevice(RemotePairingTestSupport.deviceRecord(id: id))
        try store.updatePasskeyPolicy(deviceID: id, expectedEpoch: 0) { policy in
            policy.state = .required
            policy.credential = self.credential(id: [1, 2, 3])
        }
        XCTAssertEqual(try store.device(id: id)?.passkey.epoch, 1)

        // Re-pair rebuilds the record (default .off policy) but the store preserves requirement +
        // credential and advances the epoch.
        let rebuilt = RemotePairingTestSupport.deviceRecord(id: id, displayName: "Re-paired")
        _ = try store.upsertDevicePreservingCounterFloor(rebuilt)
        let afterRepair = try XCTUnwrap(try store.device(id: id))
        XCTAssertEqual(afterRepair.passkey.state, .required)
        XCTAssertEqual(afterRepair.passkey.credential?.credentialID, Data([1, 2, 3]))
        XCTAssertEqual(afterRepair.passkey.epoch, 2)
        XCTAssertEqual(afterRepair.displayName, "Re-paired")

        // A plain metadata upsert preserves the policy without advancing the epoch.
        let metadataUpdate = RemotePairingTestSupport.deviceRecord(id: id, displayName: "Renamed")
        try store.upsertDevice(metadataUpdate)
        let afterUpsert = try XCTUnwrap(try store.device(id: id))
        XCTAssertEqual(afterUpsert.passkey.epoch, 2)
        XCTAssertEqual(afterUpsert.passkey.credential?.credentialID, Data([1, 2, 3]))
    }

    func testRevokeAdvancesEpochAndKeepsCredential() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        let store = RemotePairingIdentityStore(url: url, keychain: keychain)
        let id = "remote:1234abcd"

        try store.upsertDevice(RemotePairingTestSupport.deviceRecord(id: id))
        try store.updatePasskeyPolicy(deviceID: id, expectedEpoch: 0) { policy in
            policy.state = .required
            policy.credential = self.credential(id: [4, 5, 6])
        }
        let revoked = try store.revokeDevice(id: id)
        XCTAssertNotNil(revoked.revokedAt)
        XCTAssertEqual(revoked.passkey.state, .required)
        XCTAssertEqual(revoked.passkey.credential?.credentialID, Data([4, 5, 6]))
        XCTAssertEqual(revoked.passkey.epoch, 2)
    }

    func testStaleEpochConflictLeavesStateUnchanged() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        let store = RemotePairingIdentityStore(url: url, keychain: keychain)
        let id = "remote:1234abcd"

        try store.upsertDevice(RemotePairingTestSupport.deviceRecord(id: id))
        try store.updatePasskeyPolicy(deviceID: id, expectedEpoch: 0) { $0.state = .required }
        XCTAssertEqual(try store.device(id: id)?.passkey.epoch, 1)

        XCTAssertThrowsError(try store.updatePasskeyPolicy(deviceID: id, expectedEpoch: 0) { $0.state = .off }) { error in
            XCTAssertEqual(error as? RemotePairingIdentityStoreError, .policyConflict)
        }
        XCTAssertEqual(try store.device(id: id)?.passkey.state, .required)
        XCTAssertEqual(try store.device(id: id)?.passkey.epoch, 1)
    }

    func testDuplicateCredentialIDAcrossRecordsRejected() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        let store = RemotePairingIdentityStore(url: url, keychain: keychain)

        try store.upsertDevice(RemotePairingTestSupport.deviceRecord(id: "remote:1234abcd"))
        try store.upsertDevice(RemotePairingTestSupport.deviceRecord(id: "remote:5678ef90", displayName: "Second"))
        try store.updatePasskeyPolicy(deviceID: "remote:1234abcd", expectedEpoch: 0) { policy in
            policy.state = .required
            policy.credential = self.credential(id: [7, 7, 7])
        }
        XCTAssertThrowsError(
            try store.updatePasskeyPolicy(deviceID: "remote:5678ef90", expectedEpoch: 0) { policy in
                policy.state = .required
                policy.credential = self.credential(id: [7, 7, 7])
            }
        ) { error in
            XCTAssertEqual(error as? RemotePairingIdentityStoreError, .duplicateCredentialID)
        }
    }

    func testEpochAtMaxFailsClosedInsteadOfWrapping() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (hostKey, keychain) = RemotePairingTestSupport.hostKeychain()
        let id = "remote:1234abcd"

        // Seed a device whose policy epoch is already at the ceiling.
        var record = RemotePairingTestSupport.deviceRecord(id: id)
        record.passkey = RemotePasskeyPolicyRecord(state: .off, epoch: .max, credential: nil)
        let seeded = RemotePairingTestSupport.validRegistry(hostSigner: hostKey, devices: [record])
        try RemotePairingTestSupport.writeRegistry(seeded, to: url)
        let seededBytes = try Data(contentsOf: url)

        let store = RemotePairingIdentityStore(url: url, keychain: keychain)
        XCTAssertEqual(try store.device(id: id)?.passkey.epoch, .max)

        // Any epoch-advancing mutation refuses rather than wrapping to 0, and leaves disk untouched.
        XCTAssertThrowsError(try store.revokeDevice(id: id)) { error in
            XCTAssertEqual(error as? RemotePairingIdentityStoreError, .epochOverflow)
        }
        XCTAssertThrowsError(try store.updatePasskeyPolicy(deviceID: id, expectedEpoch: .max) { $0.state = .required }) { error in
            XCTAssertEqual(error as? RemotePairingIdentityStoreError, .epochOverflow)
        }
        XCTAssertEqual(try Data(contentsOf: url), seededBytes)
        XCTAssertEqual(try store.device(id: id)?.passkey.epoch, .max)
    }

    func testSaveRevisionIncrementsPerCommittedSave() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        let store = RemotePairingIdentityStore(url: url, keychain: keychain)

        XCTAssertEqual(try store.trustSnapshot().revision, 0)
        try store.upsertDevice(RemotePairingTestSupport.deviceRecord(id: "remote:1234abcd"))
        XCTAssertEqual(try store.trustSnapshot().revision, 1)
        try store.updateLastSeen(deviceID: "remote:1234abcd")
        XCTAssertEqual(try store.trustSnapshot().revision, 2)
    }
}
