import Foundation
@testable import RepoPromptApp
import XCTest

/// App-side fail-closed launch guard (remote passkey unlock, Step 2 — decision 8): the required
/// passkey policy version is derived from the authoritative registry, an unreadable registry fails
/// closed, the derived version becomes a gateway CLI argument, and it is part of the launch
/// configuration's identity so a change retires a running gateway before a replacement starts.
final class RemoteGatewayPasskeyLaunchCompatibilityTests: XCTestCase {
    private func makeStore() throws -> (RemotePairingIdentityStore, URL) {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        return (RemotePairingIdentityStore(url: url, keychain: keychain), url)
    }

    func testResolvesNilWhenNoDeviceRequiresPasskey() throws {
        let (store, _) = try makeStore()
        try store.upsertDevice(RemotePairingTestSupport.deviceRecord(id: "remote:1234abcd"))
        XCTAssertNil(RemoteGatewayLaunchConfiguration.resolveRequiredPasskeyPolicyVersion(store: store))
    }

    func testResolvesVersionOneWhenADeviceRequiresPasskey() throws {
        let (store, _) = try makeStore()
        try store.upsertDevice(RemotePairingTestSupport.deviceRecord(id: "remote:1234abcd"))
        try store.updatePasskeyPolicy(deviceID: "remote:1234abcd", expectedEpoch: 0) { $0.state = .required }
        XCTAssertEqual(RemoteGatewayLaunchConfiguration.resolveRequiredPasskeyPolicyVersion(store: store), 1)
    }

    func testUnreadableRegistryFailsClosedToVersionOne() throws {
        let (store, url) = try makeStore()
        // A schema version newer than this build understands makes registry() throw rather than
        // return empty — the guard must treat that as "a policy may be required", not "off".
        let future = #"{"schemaVersion":999,"hostPublicKeyFingerprint":"x","devices":[]}"#
        try Data(future.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(RemoteGatewayLaunchConfiguration.resolveRequiredPasskeyPolicyVersion(store: store), 1)
    }

    func testGatewayArgumentsAndIdentityReflectRequiredVersion() {
        let off = RemoteGatewayLaunchConfiguration.production(bindHost: "100.64.0.8", requiredPasskeyPolicyVersion: nil)
        let required = RemoteGatewayLaunchConfiguration.production(bindHost: "100.64.0.8", requiredPasskeyPolicyVersion: 1)

        XCTAssertEqual(off.gatewayProcessArguments, [])
        XCTAssertEqual(required.gatewayProcessArguments, ["--passkey-policy-version=1"])
        // Part of identity: a change in required-ness must relaunch the gateway.
        XCTAssertNotEqual(off, required)
    }
}
