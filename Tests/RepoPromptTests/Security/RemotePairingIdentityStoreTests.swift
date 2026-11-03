import CryptoKit
import Darwin
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class RemotePairingIdentityStoreTests: XCTestCase {
    func testLoadReportsMissingFile() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let missing = RemotePairingTestSupport.registryURL(in: directory)

        XCTAssertEqual(RemotePairingIdentityStore.load(from: missing), .failure(.missing))
    }

    func testRejectsWrongOwnerInsecureModeAndInvalidSchema() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let hostKey = P256.Signing.PrivateKey()
        let registry = RemotePairingTestSupport.validRegistry(hostSigner: hostKey)
        try RemotePairingTestSupport.writeRegistry(registry, to: url)

        XCTAssertEqual(
            RemotePairingIdentityStore.load(from: url, expectedOwnerID: getuid() + 1),
            .failure(.wrongOwner)
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(RemotePairingIdentityStore.load(from: url), .failure(.insecurePermissions))

        var invalid = registry
        invalid.schemaVersion = 999
        try RemotePairingTestSupport.writeRegistry(invalid, to: url)
        // Schema 2 contract: a version newer than this build understands is reported distinctly as
        // `.unsupportedSchemaVersion` (not the generic `.invalidRegistry`) so recovery guidance can
        // differ. A truly malformed/garbage file still maps to `.invalidRegistry`.
        XCTAssertEqual(RemotePairingIdentityStore.load(from: url), .failure(.unsupportedSchemaVersion(999)))
    }

    func testValidRoundTripAndRevokeClearsPushMetadata() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (hostKey, keychain) = RemotePairingTestSupport.hostKeychain()
        let store = RemotePairingIdentityStore(url: url, keychain: keychain)

        let push = WebPushSubscriptionRecord(endpoint: "https://push.example/device", p256dh: "p256dh", auth: "auth")
        let record = RemotePairingTestSupport.deviceRecord(pushSubscription: push)
        try store.upsertDevice(record)

        let loaded = try RemotePairingIdentityStore.load(from: url).get()
        XCTAssertEqual(loaded.schemaVersion, PairedDeviceRegistry.currentSchemaVersion)
        XCTAssertEqual(loaded.hostPublicKeyFingerprint, RemotePairingCrypto.fingerprint(for: hostKey.publicKey))
        XCTAssertEqual(loaded.devices.map(\.id), [record.id])
        XCTAssertEqual(loaded.devices.first?.pushSubscription, push)

        let revoked = try store.revokeDevice(id: record.id, revokedAt: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertNotNil(revoked.revokedAt)
        XCTAssertNil(revoked.pushSubscription)

        let devices = try store.listDevices(includeRevoked: true)
        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices[0].isRevoked)
        XCTAssertNil(devices[0].pushSubscription)
    }

    func testUpsertDeviceRefreshesCachedRegistryForDeviceLookup() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        let store = RemotePairingIdentityStore(url: url, keychain: keychain)

        let record = RemotePairingTestSupport.deviceRecord(displayName: "Fresh Client")
        XCTAssertNil(try store.device(id: record.id))

        try store.upsertDevice(record)

        let loaded = try XCTUnwrap(store.device(id: record.id))
        XCTAssertEqual(loaded.displayName, "Fresh Client")
        XCTAssertEqual(loaded.id, record.id)
    }

    func testRevokeDeviceRefreshesCachedRegistryForListDevices() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        let store = RemotePairingIdentityStore(url: url, keychain: keychain)

        let push = WebPushSubscriptionRecord(endpoint: "https://push.example/device", p256dh: "p256dh", auth: "auth")
        let record = RemotePairingTestSupport.deviceRecord(pushSubscription: push)
        try store.upsertDevice(record)
        XCTAssertFalse(try XCTUnwrap(store.listDevices(includeRevoked: true).first).isRevoked)

        let revokedAt = Date(timeIntervalSince1970: 1_700_000_200)
        try store.revokeDevice(id: record.id, revokedAt: revokedAt)

        let devices = try store.listDevices(includeRevoked: true)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].revokedAt, revokedAt)
        XCTAssertNil(devices[0].pushSubscription)
    }

    func testRegistryReadUsesCachedValueWhenBackingFileChangesExternally() throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (hostKey, keychain) = RemotePairingTestSupport.hostKeychain()
        let store = RemotePairingIdentityStore(url: url, keychain: keychain)

        let original = RemotePairingTestSupport.deviceRecord(displayName: "Original Client")
        let originalRegistry = RemotePairingTestSupport.validRegistry(hostSigner: hostKey, devices: [original])
        try RemotePairingTestSupport.writeRegistry(originalRegistry, to: url)
        XCTAssertEqual(try XCTUnwrap(store.device(id: original.id)).displayName, "Original Client")

        let external = RemotePairingTestSupport.deviceRecord(id: original.id, displayName: "External Client")
        let externalRegistry = RemotePairingTestSupport.validRegistry(hostSigner: hostKey, devices: [external])
        try RemotePairingTestSupport.writeRegistry(externalRegistry, to: url)
        XCTAssertEqual(
            try RemotePairingIdentityStore.load(from: url).get().devices.first?.displayName,
            "External Client"
        )

        let cached = try XCTUnwrap(store.device(id: original.id))
        XCTAssertEqual(cached.displayName, "Original Client")
    }
}
