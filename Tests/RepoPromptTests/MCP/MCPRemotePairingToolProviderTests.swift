import CryptoKit
import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import RepoPromptRemoteWire
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

@MainActor
final class MCPRemotePairingToolProviderTests: XCTestCase {
    func testNonGatewayCallerIsRejectedEvenWithGatewayClientName() async throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let store = makeStore(url: RemotePairingTestSupport.registryURL(in: directory))
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let deps = makeDependencies(isGateway: false, identityStore: store, approvalManager: manager)

        await XCTAssertThrowsErrorAsync {
            try await MCPRemotePairingToolProvider.execute(
                args: ["op": .string(RemotePairingOperation.listDevices.rawValue)],
                context: MCPWindowToolContext(toolName: MCPWindowToolName.remotePairing, windowID: 1),
                dependencies: deps
            )
        }
    }

    func testCompletePairingRequiresApprovalBeforePersistingDevice() async throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let store = makeStore(url: RemotePairingTestSupport.registryURL(in: directory))
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let challengeStore = RemotePairingChallengeStore(challengeGenerator: { "fixed-challenge" })
        let now = Date(timeIntervalSince1970: 10000)
        let authority = try await makeConfiguredAuthority(identityStore: store, now: { now })
        let approvalContext = try await makeApprovalContext(authority)
        let deps = makeDependencies(
            identityStore: store,
            approvalManager: manager,
            discoveryAuthority: authority,
            challengeStore: challengeStore,
            now: { now }
        )
        let context = MCPWindowToolContext(toolName: MCPWindowToolName.remotePairing, windowID: 7)

        let begin = try await MCPRemotePairingToolProvider.execute(
            args: [
                "op": .string(RemotePairingOperation.beginPairing.rawValue),
                "approval_context": .string(approvalContext)
            ],
            context: context,
            dependencies: deps
        )
        let beginObject = try XCTUnwrap(begin.objectValue)
        let pairingID = try XCTUnwrap(try UUID(uuidString: XCTUnwrap(beginObject["pairing_id"]?.stringValue)))
        let challenge = try XCTUnwrap(beginObject["challenge"]?.stringValue)

        let deviceKey = P256.Signing.PrivateKey()
        let deviceID = try RemotePairingCrypto.deviceID(forRawPublicKey: deviceKey.publicKey.rawRepresentation)
        let requestedScopes: Set<RemoteScope> = [.sessionsObserve, .interactionsRespond]
        let proofPayload = RemotePairingDeviceProofPayload(
            pairingID: pairingID,
            challenge: challenge,
            deviceID: deviceID,
            displayName: "Test Phone",
            publicKeyRawRepresentation: deviceKey.publicKey.rawRepresentation,
            scopes: requestedScopes
        )
        let proof = try RemotePairingCrypto.signDeviceChallenge(payload: proofPayload, deviceSigner: deviceKey)

        let completeTask = Task { @MainActor () throws -> Value in
            try await MCPRemotePairingToolProvider.execute(
                args: [
                    "op": .string(RemotePairingOperation.completePairing.rawValue),
                    "pairing_id": .string(pairingID.uuidString),
                    "display_name": .string("Test Phone"),
                    "device_id": .string(deviceID),
                    "public_key": .string(deviceKey.publicKey.rawRepresentation.base64EncodedString()),
                    "proof": .string(proof.base64EncodedString()),
                    "scopes": .array(requestedScopes.sorted().map { .string($0.rawValue) })
                ],
                context: context,
                dependencies: deps
            )
        }

        await waitUntil { manager.pendingRequest?.deviceID == deviceID }
        XCTAssertNil(try store.device(id: deviceID))
        manager.resolveApproval(allow: true, grantedScopes: [.sessionsObserve])

        let result = try await completeTask.value
        XCTAssertEqual(result.objectValue?["ok"]?.boolValue, true)
        let stored = try XCTUnwrap(try store.device(id: deviceID))
        XCTAssertEqual(stored.scopes, [.sessionsObserve])
        XCTAssertNil(stored.revokedAt)
    }

    func testRecompletePairingPreservesExistingCounterFloor() async throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let store = makeStore(url: RemotePairingTestSupport.registryURL(in: directory))
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let challengeStore = RemotePairingChallengeStore(challengeGenerator: { UUID().uuidString })
        let authority = try await makeConfiguredAuthority(identityStore: store)
        let deps = makeDependencies(
            identityStore: store,
            approvalManager: manager,
            discoveryAuthority: authority,
            challengeStore: challengeStore
        )
        let context = MCPWindowToolContext(toolName: MCPWindowToolName.remotePairing, windowID: 7)
        let deviceKey = P256.Signing.PrivateKey()
        let deviceID = try RemotePairingCrypto.deviceID(forRawPublicKey: deviceKey.publicKey.rawRepresentation)
        let requestedScopes: Set<RemoteScope> = [.sessionsObserve, .interactionsRespond]

        func completePairing(displayName: String) async throws -> Value {
            let approvalContext = try await makeApprovalContext(authority)
            let begin = try await MCPRemotePairingToolProvider.execute(
                args: [
                    "op": .string(RemotePairingOperation.beginPairing.rawValue),
                    "approval_context": .string(approvalContext)
                ],
                context: context,
                dependencies: deps
            )
            let beginObject = try XCTUnwrap(begin.objectValue)
            let pairingID = try XCTUnwrap(try UUID(uuidString: XCTUnwrap(beginObject["pairing_id"]?.stringValue)))
            let challenge = try XCTUnwrap(beginObject["challenge"]?.stringValue)
            let proofPayload = RemotePairingDeviceProofPayload(
                pairingID: pairingID,
                challenge: challenge,
                deviceID: deviceID,
                displayName: displayName,
                publicKeyRawRepresentation: deviceKey.publicKey.rawRepresentation,
                scopes: requestedScopes
            )
            let proof = try RemotePairingCrypto.signDeviceChallenge(payload: proofPayload, deviceSigner: deviceKey)
            let completeTask = Task { @MainActor () throws -> Value in
                try await MCPRemotePairingToolProvider.execute(
                    args: [
                        "op": .string(RemotePairingOperation.completePairing.rawValue),
                        "pairing_id": .string(pairingID.uuidString),
                        "display_name": .string(displayName),
                        "device_id": .string(deviceID),
                        "public_key": .string(deviceKey.publicKey.rawRepresentation.base64EncodedString()),
                        "proof": .string(proof.base64EncodedString()),
                        "scopes": .array(requestedScopes.sorted().map { .string($0.rawValue) })
                    ],
                    context: context,
                    dependencies: deps
                )
            }
            await waitUntil { manager.pendingRequest?.displayName == displayName }
            manager.resolveApproval(allow: true, grantedScopes: [.sessionsObserve])
            return try await completeTask.value
        }

        _ = try await completePairing(displayName: "Test Phone")
        var firstRecord = try XCTUnwrap(try store.device(id: deviceID))
        firstRecord.counterFloor = 123
        try store.upsertDevice(firstRecord)

        let secondResult = try await completePairing(displayName: "Test Phone Again")
        XCTAssertEqual(secondResult.objectValue?["device"]?.objectValue?["counter_floor"]?.intValue, 123)

        let devices = try store.listDevices()
        XCTAssertEqual(devices.map(\.id), [deviceID])
        let stored = try XCTUnwrap(devices.first)
        XCTAssertEqual(stored.displayName, "Test Phone Again")
        XCTAssertEqual(stored.counterFloor, 123)
        XCTAssertNil(stored.revokedAt)
    }

    func testRevokeMarksDeviceRevokedAndClearsPushMetadata() async throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let store = makeStore(url: RemotePairingTestSupport.registryURL(in: directory))
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let now = Date(timeIntervalSince1970: 20000)
        let deps = makeDependencies(identityStore: store, approvalManager: manager, now: { now })
        let push = WebPushSubscriptionRecord(endpoint: "https://push.example", p256dh: "key", auth: "auth")
        let record = RemotePairingTestSupport.deviceRecord(id: "remote:feedface", pushSubscription: push)
        try store.upsertDevice(record)

        let result = try await MCPRemotePairingToolProvider.execute(
            args: [
                "op": .string(RemotePairingOperation.revokeDevice.rawValue),
                "device_id": .string(record.id)
            ],
            context: MCPWindowToolContext(toolName: MCPWindowToolName.remotePairing, windowID: 1),
            dependencies: deps
        )

        XCTAssertEqual(result.objectValue?["ok"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["gateway_sync_required"]?.boolValue, true)
        let revoked = try XCTUnwrap(try store.device(id: record.id))
        XCTAssertEqual(revoked.revokedAt, now)
        XCTAssertNil(revoked.pushSubscription)
    }

    func testMintTicketReturnsStructuredMissingAndRevokedDeviceFailures() async throws {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let store = makeStore(url: RemotePairingTestSupport.registryURL(in: directory))
        let manager = RemoteDeviceApprovalManager(bringWindowToFront: { _ in })
        let deps = makeDependencies(identityStore: store, approvalManager: manager)
        let context = MCPWindowToolContext(toolName: MCPWindowToolName.remotePairing, windowID: 1)

        let missing = try await MCPRemotePairingToolProvider.execute(
            args: [
                "op": .string(RemotePairingOperation.mintTicket.rawValue),
                "device_id": .string("remote:missing")
            ],
            context: context,
            dependencies: deps
        )
        XCTAssertEqual(missing.objectValue?["ok"]?.boolValue, false)
        XCTAssertEqual(missing.objectValue?["code"]?.stringValue, "unknown_device")
        XCTAssertEqual(missing.objectValue?["status"]?.intValue, 404)

        let record = RemotePairingTestSupport.deviceRecord(id: "remote:deadbeef")
        try store.upsertDevice(record)
        _ = try store.revokeDevice(id: record.id, revokedAt: Date())

        let revoked = try await MCPRemotePairingToolProvider.execute(
            args: [
                "op": .string(RemotePairingOperation.mintTicket.rawValue),
                "device_id": .string(record.id)
            ],
            context: context,
            dependencies: deps
        )
        XCTAssertEqual(revoked.objectValue?["ok"]?.boolValue, false)
        XCTAssertEqual(revoked.objectValue?["code"]?.stringValue, "device_revoked")
        XCTAssertEqual(revoked.objectValue?["status"]?.intValue, 403)
    }

    private func makeStore(url: URL) -> RemotePairingIdentityStore {
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        return RemotePairingIdentityStore(url: url, keychain: keychain)
    }

    private func makeDependencies(
        isGateway: Bool = true,
        identityStore: RemotePairingIdentityStore,
        approvalManager: RemoteDeviceApprovalManager,
        discoveryAuthority: RemotePairingDiscoveryAuthority = .shared,
        challengeStore: RemotePairingChallengeStore = RemotePairingChallengeStore(challengeGenerator: { "fixed-challenge" }),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> MCPRemotePairingToolProvider.ExecutionDependencies {
        let connectionID = UUID()
        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: connectionID,
            clientName: "repoprompt-gateway",
            windowID: 1,
            actorRoutedRunTab: nil
        )
        return MCPRemotePairingToolProvider.ExecutionDependencies(
            captureRequestMetadata: { metadata },
            isGatewayPrincipalConnection: { candidate in isGateway && candidate == connectionID },
            identityStore: identityStore,
            approvalRouter: ApprovalManagerRouterStub(manager: approvalManager),
            discoveryAuthority: discoveryAuthority,
            challengeStore: challengeStore,
            now: now
        )
    }

    private func makeConfiguredAuthority(
        identityStore: RemotePairingIdentityStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> RemotePairingDiscoveryAuthority {
        let authority = RemotePairingDiscoveryAuthority(identityStore: identityStore, now: now)
        try await authority.configure(.init(
            launchID: UUID(),
            origin: RemoteGatewayOrigin(tailscaleIPv4: "100.64.0.8", channel: .release),
            buildIdentity: .forTesting(channel: .release),
            hostName: "Studio"
        ))
        return authority
    }

    private func makeApprovalContext(_ authority: RemotePairingDiscoveryAuthority) async throws -> String {
        let request = try RemoteDiscoveryRequest.make(channel: .release)
        return try await authority.discover(request).approvalContext
    }

    private func waitUntil(
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for predicate", file: file, line: line)
    }
}

@MainActor
private final class ApprovalManagerRouterStub: RemotePairingApprovalRouting {
    private let manager: RemoteDeviceApprovalManager

    init(manager: RemoteDeviceApprovalManager) {
        self.manager = manager
    }

    func requestApproval(
        deviceID: String,
        displayName: String,
        devicePublicKeyFingerprint: String,
        requestedScopes: Set<RemoteScope>,
        hostFingerprint: String
    ) async throws -> Set<RemoteScope>? {
        let result = await manager.requestApproval(for: RemoteDeviceApprovalRequest(
            deviceID: deviceID,
            displayName: displayName,
            devicePublicKeyFingerprint: devicePublicKeyFingerprint,
            requestedScopes: requestedScopes,
            hostFingerprint: hostFingerprint,
            windowID: 7
        ))
        switch result {
        case let .approved(scopes):
            return scopes
        case .denied:
            return nil
        case .targetStale:
            throw RemotePairingApprovalRouterError.approvalTargetStale
        case .cancelled:
            throw RemotePairingApprovalRouterError.cancelled
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line,
    errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
