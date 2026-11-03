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
final class RemotePairingContextLifecycleTests: XCTestCase {
    func testBeginCapsChallengeAtApprovalContextExpiration() async throws {
        let fixture = try await makeFixture()
        let issuedAt = fixture.clock.date
        let response = try await fixture.authority.discover(.make(channel: .release))
        fixture.clock.date = issuedAt.addingTimeInterval(59.75)

        let begin = try await execute(
            [
                "op": .string(RemotePairingOperation.beginPairing.rawValue),
                "approval_context": .string(response.approvalContext),
                "ttl_seconds": .int(60)
            ],
            fixture: fixture
        )
        let pairingID = try XCTUnwrap(try UUID(uuidString: XCTUnwrap(begin.objectValue?["pairing_id"]?.stringValue)))
        let storedChallenge = await fixture.challengeStore.challenge(pairingID: pairingID)
        let challenge = try XCTUnwrap(storedChallenge)

        XCTAssertEqual(challenge.expiresAt, Date(timeIntervalSince1970: Double(response.expiresAtMs) / 1000))
        XCTAssertLessThanOrEqual(challenge.expiresAt, issuedAt.addingTimeInterval(60))
    }

    func testCompletionRejectsExpiredDisabledReboundAndHostKeyChangedContextsBeforeApproval() async throws {
        for mutation in ContextMutation.allCases {
            let fixture = try await makeFixture()
            let completeArguments = try await beginCompleteArguments(fixture: fixture)
            try await apply(mutation, to: fixture)

            let result = try await execute(completeArguments, fixture: fixture)
            let expectedCode = mutation == .expired
                ? "pairing_challenge_expired"
                : "approval_context_expired"
            XCTAssertEqual(result.objectValue?["code"]?.stringValue, expectedCode, mutation.rawValue)
            XCTAssertEqual(fixture.router.requestCount, 0, mutation.rawValue)
        }
    }

    func testApprovalPauseRevalidatesContextBeforePersistenceForEveryBindingMutation() async throws {
        for mutation in ContextMutation.allCases {
            let fixture = try await makeFixture()
            let completeArguments = try await beginCompleteArguments(fixture: fixture)
            let deviceID = try XCTUnwrap(completeArguments["device_id"]?.stringValue)
            fixture.router.pauseNextApproval()

            let completion = Task {
                try await self.execute(completeArguments, fixture: fixture)
            }
            await fixture.router.waitUntilApprovalIsPaused()
            try await apply(mutation, to: fixture)
            fixture.router.resumeApproval()

            let result = try await completion.value
            XCTAssertEqual(result.objectValue?["code"]?.stringValue, "approval_context_expired", mutation.rawValue)
            XCTAssertEqual(fixture.router.requestCount, 1, mutation.rawValue)
            XCTAssertNil(try fixture.identityStore.device(id: deviceID), mutation.rawValue)
        }
    }

    func testConsumedChallengeCannotBeCompletedTwice() async throws {
        let fixture = try await makeFixture()
        let completeArguments = try await beginCompleteArguments(fixture: fixture)

        let first = try await execute(completeArguments, fixture: fixture)
        XCTAssertEqual(first.objectValue?["ok"]?.boolValue, true)
        XCTAssertEqual(fixture.router.requestCount, 1)

        let replay = try await execute(completeArguments, fixture: fixture)
        XCTAssertEqual(replay.objectValue?["code"]?.stringValue, "pairing_challenge_replayed")
        XCTAssertEqual(fixture.router.requestCount, 1)
    }

    private func beginCompleteArguments(fixture: Fixture) async throws -> [String: Value] {
        let response = try await fixture.authority.discover(.make(channel: .release))
        let begin = try await execute(
            [
                "op": .string(RemotePairingOperation.beginPairing.rawValue),
                "approval_context": .string(response.approvalContext)
            ],
            fixture: fixture
        )
        let pairingID = try XCTUnwrap(try UUID(uuidString: XCTUnwrap(begin.objectValue?["pairing_id"]?.stringValue)))
        let challenge = try XCTUnwrap(begin.objectValue?["challenge"]?.stringValue)
        let deviceKey = P256.Signing.PrivateKey()
        let deviceID = try RemotePairingCrypto.deviceID(forRawPublicKey: deviceKey.publicKey.rawRepresentation)
        let scopes: Set<RemoteScope> = [.sessionsObserve]
        let payload = RemotePairingDeviceProofPayload(
            pairingID: pairingID,
            challenge: challenge,
            deviceID: deviceID,
            displayName: "Context Test Device",
            publicKeyRawRepresentation: deviceKey.publicKey.rawRepresentation,
            scopes: scopes
        )
        let proof = try RemotePairingCrypto.signDeviceChallenge(payload: payload, deviceSigner: deviceKey)
        return [
            "op": .string(RemotePairingOperation.completePairing.rawValue),
            "pairing_id": .string(pairingID.uuidString),
            "display_name": .string(payload.displayName),
            "device_id": .string(deviceID),
            "public_key": .string(deviceKey.publicKey.rawRepresentation.base64EncodedString()),
            "proof": .string(proof.base64EncodedString()),
            "scopes": .array(scopes.map { .string($0.rawValue) })
        ]
    }

    private func execute(_ args: [String: Value], fixture: Fixture) async throws -> Value {
        try await MCPRemotePairingToolProvider.execute(
            args: args,
            context: MCPWindowToolContext(toolName: MCPWindowToolName.remotePairing, windowID: 1),
            dependencies: fixture.dependencies
        )
    }

    private func apply(_ mutation: ContextMutation, to fixture: Fixture) async throws {
        switch mutation {
        case .expired:
            fixture.clock.date = fixture.clock.date.addingTimeInterval(60)
        case .disabled:
            await fixture.authority.clear()
        case .launchChanged:
            try await fixture.authority.configure(configuration(
                launchID: UUID(),
                ip: "100.64.0.8",
                channel: .release
            ))
        case .originChanged:
            try await fixture.authority.configure(configuration(
                launchID: fixture.launchID,
                ip: "100.64.0.9",
                channel: .release
            ))
        case .channelChanged:
            try await fixture.authority.configure(configuration(
                launchID: fixture.launchID,
                ip: "100.64.0.8",
                channel: .debug
            ))
        case .hostKeyChanged:
            fixture.keychain.setValueForTesting(
                P256.Signing.PrivateKey().rawRepresentation.base64EncodedString(),
                for: RemotePairingIdentityStore.hostSigningKeyAccount
            )
        }
    }

    private func makeFixture() async throws -> Fixture {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        let identityStore = RemotePairingIdentityStore(
            url: RemotePairingTestSupport.registryURL(in: directory),
            keychain: keychain
        )
        let clock = ContextLifecycleClock(Date(timeIntervalSince1970: 10000))
        let launchID = UUID()
        let authority = RemotePairingDiscoveryAuthority(identityStore: identityStore, now: { clock.date })
        try await authority.configure(configuration(
            launchID: launchID,
            ip: "100.64.0.8",
            channel: .release
        ))
        let challengeStore = RemotePairingChallengeStore(challengeGenerator: { UUID().uuidString })
        let router = RecordingApprovalRouter()
        let connectionID = UUID()
        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: connectionID,
            clientName: "repoprompt-gateway",
            windowID: nil,
            actorRoutedRunTab: nil
        )
        let dependencies = MCPRemotePairingToolProvider.ExecutionDependencies(
            captureRequestMetadata: { metadata },
            isGatewayPrincipalConnection: { $0 == connectionID },
            identityStore: identityStore,
            approvalRouter: router,
            discoveryAuthority: authority,
            challengeStore: challengeStore,
            now: { clock.date }
        )
        return Fixture(
            launchID: launchID,
            keychain: keychain,
            identityStore: identityStore,
            authority: authority,
            challengeStore: challengeStore,
            router: router,
            dependencies: dependencies,
            clock: clock
        )
    }

    private func configuration(
        launchID: UUID,
        ip: String,
        channel: RemoteControlBuildChannel
    ) throws -> RemotePairingDiscoveryAuthority.Configuration {
        try .init(
            launchID: launchID,
            origin: RemoteGatewayOrigin(tailscaleIPv4: ip, channel: channel),
            buildIdentity: .forTesting(channel: channel),
            hostName: "Context Test Host"
        )
    }

    private struct Fixture {
        let launchID: UUID
        let keychain: InMemoryRemotePairingKeychain
        let identityStore: RemotePairingIdentityStore
        let authority: RemotePairingDiscoveryAuthority
        let challengeStore: RemotePairingChallengeStore
        let router: RecordingApprovalRouter
        let dependencies: MCPRemotePairingToolProvider.ExecutionDependencies
        let clock: ContextLifecycleClock
    }

    private enum ContextMutation: String, CaseIterable {
        case expired
        case disabled
        case launchChanged
        case originChanged
        case channelChanged
        case hostKeyChanged
    }
}

@MainActor
private final class RecordingApprovalRouter: RemotePairingApprovalRouting {
    private(set) var requestCount = 0
    private var shouldPauseNextApproval = false
    private var approvalIsPaused = false
    private var approvalContinuation: CheckedContinuation<Set<RemoteScope>?, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseNextApproval() {
        shouldPauseNextApproval = true
    }

    func waitUntilApprovalIsPaused() async {
        guard !approvalIsPaused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resumeApproval() {
        approvalContinuation?.resume(returning: [.sessionsObserve])
        approvalContinuation = nil
    }

    func requestApproval(
        deviceID _: String,
        displayName _: String,
        devicePublicKeyFingerprint _: String,
        requestedScopes: Set<RemoteScope>,
        hostFingerprint _: String
    ) async throws -> Set<RemoteScope>? {
        requestCount += 1
        if shouldPauseNextApproval {
            shouldPauseNextApproval = false
            approvalIsPaused = true
            pauseWaiters.forEach { $0.resume() }
            pauseWaiters.removeAll()
            return await withCheckedContinuation { continuation in
                approvalContinuation = continuation
            }
        }
        return requestedScopes
    }
}

private final class ContextLifecycleClock: @unchecked Sendable {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }
}
