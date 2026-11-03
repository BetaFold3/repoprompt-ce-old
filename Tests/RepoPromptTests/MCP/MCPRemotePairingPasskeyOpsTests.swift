import CryptoKit
import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import RepoPromptRemoteWire
import XCTest

/// MCP wiring for the passkey ceremony operations and the capability-gated trust projection
/// (remote passkey unlock, Step 2d). The coordinator itself is covered by
/// `RemotePasskeyCoordinatorTests`; this suite proves the tool provider derives the principal from
/// request metadata (never arguments), gates `list_devices`, and drives a real register→unlock.
@MainActor
final class MCPRemotePairingPasskeyOpsTests: XCTestCase {
    private final class NoopApprovalRouter: RemotePairingApprovalRouting {
        func requestApproval(deviceID _: String, displayName _: String, devicePublicKeyFingerprint _: String, requestedScopes _: Set<RemoteScope>, hostFingerprint _: String) async throws -> Set<RemoteScope>? {
            nil
        }
    }

    private final class OriginBox: @unchecked Sendable {
        var state: RemotePasskeyCoordinator.OriginState
        init(_ state: RemotePasskeyCoordinator.OriginState) {
            self.state = state
        }
    }

    private let deviceID = "remote:1234abcd"
    private let context = MCPWindowToolContext(toolName: MCPWindowToolName.remotePairing, windowID: 1)

    private struct Harness {
        let store: RemotePairingIdentityStore
        let coordinator: RemotePasskeyCoordinator
        let deps: MCPRemotePairingToolProvider.ExecutionDependencies
        let connectionID: UUID
        var principal: String {
            connectionID.uuidString
        }
    }

    private func makeHarness(isGateway: Bool = true) throws -> Harness {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        let store = RemotePairingIdentityStore(url: url, keychain: keychain)
        try store.upsertDevice(RemotePairingTestSupport.deviceRecord(id: deviceID))

        let origin = OriginBox(.init(origin: RemotePasskeyOrigin(httpsURLString: "https://example.com"), generation: 1, discoverable: true))
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store,
            verifier: WebAuthnRemotePasskeyVerifier(),
            now: { ContinuousClock.now },
            originSnapshot: { origin.state },
            buildLabel: "RepoPrompt Test",
            // The real live-principal query targets ServerNetworkManager, which has no such
            // connection in a unit test; the provider wiring is proven elsewhere.
            isPrincipalLive: { _ in true }
        )
        let connectionID = UUID()
        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: connectionID,
            clientName: "repoprompt-gateway",
            windowID: 1,
            actorRoutedRunTab: nil
        )
        let deps = MCPRemotePairingToolProvider.ExecutionDependencies(
            captureRequestMetadata: { metadata },
            isGatewayPrincipalConnection: { candidate in isGateway && candidate == connectionID },
            identityStore: store,
            approvalRouter: NoopApprovalRouter(),
            passkeyCoordinator: coordinator
        )
        return Harness(store: store, coordinator: coordinator, deps: deps, connectionID: connectionID)
    }

    /// Runs the production CallTool argument normalizer before the provider, as the app's MCP
    /// handler does, so the credential JSON string contract is exercised end to end.
    private func execute(_ args: [String: Value], _ deps: MCPRemotePairingToolProvider.ExecutionDependencies) async throws -> Value {
        let normalized = MCPToolArgsNormalizer.normalize(
            params: args,
            originalToolName: MCPWindowToolName.remotePairing,
            canonicalToolName: MCPWindowToolName.remotePairing
        )
        return try await MCPRemotePairingToolProvider.execute(args: normalized.payload, context: context, dependencies: deps)
    }

    private func b64urlDecode(_ string: String) -> [UInt8] {
        var normalized = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 {
            normalized += "="
        }
        return Array(Data(base64Encoded: normalized) ?? Data())
    }

    // MARK: - list_devices gating

    func testListDevicesWithoutCapabilityMasksRequiredDeviceAsRevoked() async throws {
        let harness = try makeHarness()
        harness.coordinator.recordTrustCall(capable: true, principalConnectionID: harness.principal)
        try await harness.coordinator.enable(deviceID: deviceID) // device is now required-not-enrolled

        let result = try await execute(["op": .string(RemotePairingOperation.listDevices.rawValue)], harness.deps)
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertNil(object["passkey_policy_version"], "legacy view must omit policy fields")
        let device = try XCTUnwrap(object["devices"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(device["revoked"]?.boolValue, true, "a required device is masked revoked for a legacy gateway")
        XCTAssertNil(device["passkey_policy"])
        // The store itself was NOT durably revoked.
        XCTAssertNil(try harness.store.device(id: deviceID)?.revokedAt)
    }

    func testListDevicesWithCapabilityReturnsFullPolicyAndRevision() async throws {
        let harness = try makeHarness()
        harness.coordinator.recordTrustCall(capable: true, principalConnectionID: harness.principal)
        try await harness.coordinator.enable(deviceID: deviceID)

        let result = try await execute([
            "op": .string(RemotePairingOperation.listDevices.rawValue),
            "passkey_policy_capability": .int(1)
        ], harness.deps)
        let object = try XCTUnwrap(result.objectValue)
        XCTAssertEqual(object["passkey_policy_version"]?.intValue, 1)
        let trust = try XCTUnwrap(object["trust_revision"]?.objectValue)
        XCTAssertEqual(trust["launch"]?.stringValue, harness.store.launchNonce)
        XCTAssertFalse(try XCTUnwrap(trust["revision"]?.stringValue).isEmpty)
        XCTAssertFalse(try XCTUnwrap(trust["issuance"]?.stringValue).isEmpty, "a capable response carries an issuance identity")
        let device = try XCTUnwrap(object["devices"]?.arrayValue?.first?.objectValue)
        let policy = try XCTUnwrap(device["passkey_policy"]?.objectValue)
        XCTAssertEqual(policy["state"]?.stringValue, "required")
        XCTAssertEqual(policy["enrolled"]?.boolValue, false)
        XCTAssertEqual(device["revoked"]?.boolValue, false)
    }

    // MARK: - acknowledge_trust

    func testAcknowledgeTrustSucceedsForCurrentPrincipalAndRevision() async throws {
        let harness = try makeHarness()
        // Establish the capable principal and read back the EXACT issued snapshot identity the
        // response advertised (decimal-string revision + unguessable issuance id).
        let listed = try await execute([
            "op": .string(RemotePairingOperation.listDevices.rawValue),
            "passkey_policy_capability": .int(1)
        ], harness.deps)
        let trust = try XCTUnwrap(listed.objectValue?["trust_revision"]?.objectValue)
        let revisionString = try XCTUnwrap(trust["revision"]?.stringValue)
        let issuance = try XCTUnwrap(trust["issuance"]?.stringValue)
        XCTAssertFalse(issuance.isEmpty)

        // Echo the decimal-string revision (P2-04 round-trip) and the exact issuance id.
        let ack = try await execute([
            "op": .string(RemotePairingOperation.acknowledgeTrust.rawValue),
            "trust_launch": .string(harness.store.launchNonce),
            "trust_revision": .string(revisionString),
            "trust_issuance": .string(issuance)
        ], harness.deps)
        XCTAssertEqual(ack.objectValue?["ok"]?.boolValue, true)

        // A wrong launch is rejected even with the correct revision and issuance.
        let stale = try await execute([
            "op": .string(RemotePairingOperation.acknowledgeTrust.rawValue),
            "trust_launch": .string("wrong-launch"),
            "trust_revision": .string(revisionString),
            "trust_issuance": .string(issuance)
        ], harness.deps)
        XCTAssertEqual(stale.objectValue?["ok"]?.boolValue, false)
        XCTAssertEqual(stale.objectValue?["code"]?.stringValue, "stale_acknowledgment")
    }

    // MARK: - principal binding

    func testPasskeyBeginDerivesPrincipalFromMetadataNotArguments() async throws {
        let harness = try makeHarness()
        harness.coordinator.recordTrustCall(capable: true, principalConnectionID: harness.principal)
        try await harness.coordinator.enable(deviceID: deviceID)

        // The ceremony is bound to the metadata connection. A begin via the provider then a
        // complete carrying a DIFFERENT (spoofed) principal cannot bind — but the provider always
        // uses metadata, so the spoof in args is simply ignored and the real principal is used.
        let begin = try await execute([
            "op": .string(RemotePairingOperation.passkeyUnlockBegin.rawValue),
            "device_id": .string(deviceID),
            "connection_generation": .int(3),
            "principal_connection_id": .string("attacker-supplied")
        ], harness.deps)
        // Device has no credential yet, so unlock begin fails — but with the ceremony's own code,
        // proving the op ran through the coordinator with the metadata principal.
        XCTAssertEqual(begin.objectValue?["ok"]?.boolValue, false)
        XCTAssertEqual(begin.objectValue?["code"]?.stringValue, "passkey_not_enrolled")
    }

    // MARK: - End-to-end through the provider

    func testRegisterThenUnlockThroughProvider() async throws {
        let harness = try makeHarness()
        harness.coordinator.recordTrustCall(capable: true, principalConnectionID: harness.principal)
        try await harness.coordinator.enable(deviceID: deviceID)

        let authenticator = SoftwareAuthenticator()
        let begin = try await execute([
            "op": .string(RemotePairingOperation.passkeyRegisterBegin.rawValue),
            "device_id": .string(deviceID),
            "connection_generation": .int(9)
        ], harness.deps)
        let beginObject = try XCTUnwrap(begin.objectValue)
        XCTAssertEqual(beginObject["attestation"]?.stringValue, "none")
        let ceremonyID = try XCTUnwrap(beginObject["ceremony_id"]?.stringValue)
        let challenge = try XCTUnwrap(beginObject["challenge"]?.stringValue)
        let registrationJSON = authenticator.registrationJSON(challenge: b64urlDecode(challenge))

        let complete = try await execute([
            "op": .string(RemotePairingOperation.passkeyRegisterComplete.rawValue),
            "device_id": .string(deviceID),
            "connection_generation": .int(9),
            "ceremony_id": .string(ceremonyID),
            "credential": .string(String(decoding: registrationJSON, as: UTF8.self))
        ], harness.deps)
        XCTAssertEqual(complete.objectValue?["enrolled"]?.boolValue, true)
        XCTAssertNotNil(try harness.store.device(id: deviceID)?.passkey.credential)

        let unlockBegin = try await execute([
            "op": .string(RemotePairingOperation.passkeyUnlockBegin.rawValue),
            "device_id": .string(deviceID),
            "connection_generation": .int(9)
        ], harness.deps)
        let unlockObject = try XCTUnwrap(unlockBegin.objectValue)
        let unlockCeremony = try XCTUnwrap(unlockObject["ceremony_id"]?.stringValue)
        let unlockChallenge = try XCTUnwrap(unlockObject["challenge"]?.stringValue)
        let assertionJSON = authenticator.assertionJSON(challenge: b64urlDecode(unlockChallenge))

        let revisionBeforeUnlock = try harness.store.trustSnapshot().revision
        let unlockComplete = try await execute([
            "op": .string(RemotePairingOperation.passkeyUnlockComplete.rawValue),
            "device_id": .string(deviceID),
            "connection_generation": .int(9),
            "ceremony_id": .string(unlockCeremony),
            "credential": .string(String(decoding: assertionJSON, as: UTF8.self))
        ], harness.deps)
        XCTAssertEqual(unlockComplete.objectValue?["verified"]?.boolValue, true)
        // Unlock performs no disk write.
        XCTAssertEqual(try harness.store.trustSnapshot().revision, revisionBeforeUnlock)
    }

    func testPasskeyOpsRejectNonGatewayCaller() async throws {
        let harness = try makeHarness(isGateway: false)
        do {
            _ = try await execute([
                "op": .string(RemotePairingOperation.passkeyUnlockBegin.rawValue),
                "device_id": .string(deviceID),
                "connection_generation": .int(1)
            ], harness.deps)
            XCTFail("Expected a non-gateway caller to be rejected")
        } catch {
            // Expected: requireGatewayPrincipal rejects before any ceremony work.
        }
    }
}
