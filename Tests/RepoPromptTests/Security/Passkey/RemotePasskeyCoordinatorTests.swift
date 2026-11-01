import Crypto
import Foundation
@testable import RepoPromptApp
import XCTest

/// Coordinator coverage (remote passkey unlock, Step 2c): enrollment windows, one-use challenges,
/// binding re-checks across the verifier await (including an A→B→A origin change caught by the
/// generation, not a string compare), Mac actions, trust/enforcement status, and a full
/// register→unlock through the real verifier. Uses an injected monotonic clock and origin snapshot,
/// and both a suspending fake verifier and the production `WebAuthnRemotePasskeyVerifier`.
@MainActor
final class RemotePasskeyCoordinatorTests: XCTestCase {
    // MARK: Test doubles

    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        func now() -> ContinuousClock.Instant {
            lock.lock()
            defer { lock.unlock() }
            return instant
        }

        func advance(by duration: Duration) {
            lock.lock()
            instant = instant.advanced(by: duration)
            lock.unlock()
        }
    }

    private final class OriginBox: @unchecked Sendable {
        var state: RemotePasskeyCoordinator.OriginState
        init(_ state: RemotePasskeyCoordinator.OriginState) {
            self.state = state
        }
    }

    /// Thread-safe mutable liveness flag so a test can model a principal that is live at enable time
    /// but torn down (or credential-rotated) by the time a ceremony completes.
    private final class LiveBox: @unchecked Sendable {
        private let lock = NSLock()
        private var live: Bool
        init(_ live: Bool) {
            self.live = live
        }

        var value: Bool {
            get { lock.lock()
                defer { lock.unlock() }
                return live
            }
            set { lock.lock()
                live = newValue
                lock.unlock()
            }
        }
    }

    /// Two-phase gate: the verifier parks inside `enter()` until the test calls `release()`, and the
    /// test can wait until the verifier has actually parked.
    private actor VerifierGate {
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var released = false
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func enter() async {
            if !entered {
                entered = true
                enteredWaiter?.resume()
                enteredWaiter = nil
            }
            if released { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private final class GatedFakeVerifier: RemotePasskeyVerifying, @unchecked Sendable {
        let registration: RemotePasskeyVerifiedRegistration
        let gate: VerifierGate?
        let shouldFail: Bool

        init(
            registration: RemotePasskeyVerifiedRegistration = .init(
                credentialID: Array("canned-credential".utf8),
                publicKeyCOSE: [0xA5, 0x01, 0x02, 0x03, 0x04],
                signCount: 0,
                backupEligible: true,
                backedUp: true
            ),
            gate: VerifierGate? = nil,
            shouldFail: Bool = false
        ) {
            self.registration = registration
            self.gate = gate
            self.shouldFail = shouldFail
        }

        func verifyRegistration(_: RemotePasskeyRegistrationInput) async throws -> RemotePasskeyVerifiedRegistration {
            if let gate { await gate.enter() }
            if shouldFail { throw RemotePasskeyVerificationError.verificationFailed }
            return registration
        }

        func verifyAssertion(_: RemotePasskeyAssertionInput) async throws {
            if let gate { await gate.enter() }
            if shouldFail { throw RemotePasskeyVerificationError.verificationFailed }
        }
    }

    // MARK: Fixtures

    private let deviceID = "remote:1234abcd"
    private let principal = "gateway-connection-1"

    private func exampleOrigin(generation: UInt64 = 1, discoverable: Bool = true) -> RemotePasskeyCoordinator.OriginState {
        .init(origin: RemotePasskeyOrigin(httpsURLString: "https://example.com"), generation: generation, discoverable: discoverable)
    }

    private func makeStore() throws -> RemotePairingIdentityStore {
        let directory = try RemotePairingTestSupport.temporaryDirectory(testCase: self)
        let url = RemotePairingTestSupport.registryURL(in: directory)
        let (_, keychain) = RemotePairingTestSupport.hostKeychain()
        let store = RemotePairingIdentityStore(url: url, keychain: keychain)
        try store.upsertDevice(RemotePairingTestSupport.deviceRecord(id: deviceID))
        return store
    }

    private func beginContext(connectionGeneration: UInt64 = 5) -> RemotePasskeyBeginContext {
        .init(deviceID: deviceID, connectionGeneration: connectionGeneration, principalConnectionID: principal)
    }

    private func completeContext(ceremonyID: String, connectionGeneration: UInt64 = 5) -> RemotePasskeyCeremonyContext {
        .init(deviceID: deviceID, ceremonyID: ceremonyID, connectionGeneration: connectionGeneration, principalConnectionID: principal)
    }

    private func b64urlDecode(_ string: String) -> [UInt8] {
        var normalized = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 {
            normalized += "="
        }
        return Array(Data(base64Encoded: normalized) ?? Data())
    }

    // MARK: - Mac actions and capability gating

    func testEnableRequiresGatewayCapabilityInStepTwo() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        // No capable gateway principal has been recorded (none exists until Step 3).
        await assertFailure(.gatewayUnsupported) {
            try await coordinator.enable(deviceID: self.deviceID)
        }
        XCTAssertEqual(try store.device(id: deviceID)?.passkey.state, .off)
    }

    /// S2-01: capability cached from a now-dead principal (it disconnected / was replaced, and a
    /// legacy gateway is discoverable) must NOT authorize Enable. The async live-principal check is
    /// the authoritative launch/lifetime binding: a non-live principal leaves the policy off.
    func testEnableRejectedWhenCapablePrincipalNoLongerLive() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in false } // the capable principal has disconnected / been replaced
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        await assertFailure(.gatewayUnsupported) {
            try await coordinator.enable(deviceID: self.deviceID)
        }
        XCTAssertEqual(try store.device(id: deviceID)?.passkey.state, .off, "a dead capable principal leaves policy off")
    }

    func testEnableWithSimulatedCapabilityMovesToRequiredAndOpensWindow() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let clock = FakeClock()
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { clock.now() }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        XCTAssertEqual(try store.device(id: deviceID)?.passkey.state, .required)
        XCTAssertNil(try store.device(id: deviceID)?.passkey.credential)
        let status = try coordinator.status(for: deviceID)
        XCTAssertEqual(status.persisted, .requiredNotEnrolled)
        XCTAssertNotNil(status.enrollmentOpenUntil)
    }

    func testDisableIsAlwaysAllowedAndAdvancesEpoch() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        let epochAfterEnable = try XCTUnwrap(try store.device(id: deviceID)?.passkey.epoch)
        try coordinator.disable(deviceID: deviceID)
        XCTAssertEqual(try store.device(id: deviceID)?.passkey.state, .off)
        XCTAssertEqual(try store.device(id: deviceID)?.passkey.epoch, epochAfterEnable + 1)
    }

    func testResetClearsCredentialEvenWhenOriginUnavailable() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        try await enrollWithFakeVerifier(store: store, origin: origin, coordinator: coordinator)
        XCTAssertNotNil(try store.device(id: deviceID)?.passkey.credential)

        // Origin goes away; reset must still clear the credential and keep the requirement.
        origin.state = .init(origin: nil, generation: 2, discoverable: false)
        try coordinator.reset(deviceID: deviceID)
        XCTAssertEqual(try store.device(id: deviceID)?.passkey.state, .required)
        XCTAssertNil(try store.device(id: deviceID)?.passkey.credential)
    }

    // MARK: - Registration / unlock binding

    private func enrollWithFakeVerifier(
        store: RemotePairingIdentityStore,
        origin: OriginBox,
        coordinator: RemotePasskeyCoordinator
    ) async throws {
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        let options = try coordinator.registerBegin(beginContext())
        _ = try await coordinator.registerComplete(completeContext(ceremonyID: options.ceremonyID), credentialJSON: Data("{}".utf8))
    }

    func testRegisterBeginRequiresOpenWindow() throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        // Move to required without opening a window (direct store CAS).
        try store.updatePasskeyPolicy(deviceID: deviceID, expectedEpoch: 0) { $0.state = .required }
        XCTAssertThrowsError(try coordinator.registerBegin(beginContext())) { error in
            XCTAssertEqual(error as? RemotePasskeyFailure, .enrollmentClosed)
        }
    }

    func testRegisterCompleteReplayIsRejected() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        let options = try coordinator.registerBegin(beginContext())
        _ = try await coordinator.registerComplete(completeContext(ceremonyID: options.ceremonyID), credentialJSON: Data("{}".utf8))
        // Second attempt with the same ceremony ID: the challenge was consumed.
        await assertFailure(.challengeInvalid) {
            _ = try await coordinator.registerComplete(self.completeContext(ceremonyID: options.ceremonyID), credentialJSON: Data("{}".utf8))
        }
    }

    func testRegisterCompleteRejectsMismatchedPrincipalAndGeneration() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        let options = try coordinator.registerBegin(beginContext(connectionGeneration: 5))

        let wrongGeneration = RemotePasskeyCeremonyContext(deviceID: deviceID, ceremonyID: options.ceremonyID, connectionGeneration: 6, principalConnectionID: principal)
        await assertFailure(.challengeInvalid) {
            _ = try await coordinator.registerComplete(wrongGeneration, credentialJSON: Data("{}".utf8))
        }
    }

    func testChallengeExpiresAfterSixtySeconds() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let clock = FakeClock()
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { clock.now() }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        let options = try coordinator.registerBegin(beginContext())
        clock.advance(by: .seconds(61))
        await assertFailure(.challengeInvalid) {
            _ = try await coordinator.registerComplete(self.completeContext(ceremonyID: options.ceremonyID), credentialJSON: Data("{}".utf8))
        }
    }

    func testOriginGenerationChangeDuringAwaitInvalidatesCeremony() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin(generation: 1))
        let gate = VerifierGate()
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(gate: gate),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        let options = try coordinator.registerBegin(beginContext())

        let task = Task { @MainActor in
            try await coordinator.registerComplete(self.completeContext(ceremonyID: options.ceremonyID), credentialJSON: Data("{}".utf8))
        }
        await gate.waitUntilEntered()
        // Same origin STRING, but the publish generation advanced (A→B→A): a string compare would
        // miss this; the generation must not.
        origin.state = .init(origin: RemotePasskeyOrigin(httpsURLString: "https://example.com"), generation: 3, discoverable: true)
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected challengeInvalid")
        } catch let error as RemotePasskeyFailure {
            XCTAssertEqual(error, .challengeInvalid)
        }
        XCTAssertNil(try store.device(id: deviceID)?.passkey.credential, "no credential should be committed")
    }

    // MARK: - Enforcement / trust

    func testEnforcementReflectsGatewayAndAcknowledgment() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        // Not discoverable → gatewayUnavailable.
        origin.state = .init(origin: nil, generation: 1, discoverable: false)
        XCTAssertEqual(try coordinator.status(for: deviceID).enforcement, .gatewayUnavailable)

        // Discoverable but last trust call not capable → gatewayLacksSupport.
        origin.state = exampleOrigin()
        coordinator.recordTrustCall(capable: false, principalConnectionID: principal)
        XCTAssertEqual(try coordinator.status(for: deviceID).enforcement, .gatewayLacksSupport)

        // Capable and a policy change recorded → pending until an EXPLICIT acknowledgment of the
        // exact issued snapshot (no implicit "applied").
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        XCTAssertEqual(try coordinator.status(for: deviceID).enforcement, .pending)

        // Issue the exact snapshot (as a capable list_devices would) then acknowledge it → applied.
        let revision = try store.trustSnapshot().revision
        let epoch = try XCTUnwrap(try store.device(id: deviceID)?.passkey.epoch)
        let issuance = try XCTUnwrap(coordinator.recordIssuedTrustSnapshot(
            principalConnectionID: principal,
            revision: revision,
            originRevision: origin.state.generation,
            deviceEpochs: [deviceID: epoch]
        ))
        try coordinator.acknowledgeTrust(principalConnectionID: principal, launch: store.launchNonce, revision: revision, issuanceID: issuance)
        XCTAssertEqual(try coordinator.status(for: deviceID).enforcement, .applied)

        // A later origin change (new revision) drops enforcement back to pending until re-acked.
        origin.state = .init(origin: origin.state.origin, generation: origin.state.generation + 1, discoverable: true)
        XCTAssertEqual(try coordinator.status(for: deviceID).enforcement, .pending)
    }

    func testAcknowledgeTrustRejectsWrongLaunchAndFutureRevision() throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        XCTAssertThrowsError(try coordinator.acknowledgeTrust(principalConnectionID: principal, launch: "not-the-launch", revision: 0, issuanceID: "x")) { error in
            XCTAssertEqual(error as? RemotePasskeyFailure, .staleAcknowledgment)
        }
        XCTAssertThrowsError(try coordinator.acknowledgeTrust(principalConnectionID: principal, launch: store.launchNonce, revision: store.saveRevision + 10, issuanceID: "x")) { error in
            XCTAssertEqual(error as? RemotePasskeyFailure, .staleAcknowledgment)
        }
        XCTAssertThrowsError(try coordinator.acknowledgeTrust(principalConnectionID: "other", launch: store.launchNonce, revision: 0, issuanceID: "x")) { error in
            XCTAssertEqual(error as? RemotePasskeyFailure, .staleAcknowledgment)
        }
    }

    /// S2-02: two capable list_devices responses at the SAME store revision but different origins get
    /// distinct issuance IDs. A delayed acknowledgment naming the first issuance (A) must NOT be
    /// accepted for the current issuance (B), even though launch and revision match.
    func testAcknowledgeRejectsSupersededIssuanceAtEqualRevision() throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin(generation: 1))
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        // Issue A at (revision 5, origin generation 1).
        let issuanceA = try XCTUnwrap(coordinator.recordIssuedTrustSnapshot(
            principalConnectionID: principal, revision: 5, originRevision: 1, deviceEpochs: [:]
        ))
        // Origin changes, and a second list_devices issues B at the SAME store revision 5.
        origin.state = .init(origin: origin.state.origin, generation: 2, discoverable: true)
        let issuanceB = try XCTUnwrap(coordinator.recordIssuedTrustSnapshot(
            principalConnectionID: principal, revision: 5, originRevision: 2, deviceEpochs: [:]
        ))
        XCTAssertNotEqual(issuanceA, issuanceB)
        // The delayed ack for A (same launch, same revision 5) is rejected: it does not name B.
        XCTAssertThrowsError(try coordinator.acknowledgeTrust(principalConnectionID: principal, launch: store.launchNonce, revision: 5, issuanceID: issuanceA)) { error in
            XCTAssertEqual(error as? RemotePasskeyFailure, .staleAcknowledgment)
        }
        // Acking the current issuance B succeeds.
        try coordinator.acknowledgeTrust(principalConnectionID: principal, launch: store.launchNonce, revision: 5, issuanceID: issuanceB)
    }

    func testRestartClearsCeremoniesButKeepsSavedState() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let first = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        try await enrollWithFakeVerifier(store: store, origin: origin, coordinator: first)
        XCTAssertEqual(try store.device(id: deviceID)?.passkey.state, .required)

        // A fresh coordinator (simulating a restart) has no window/challenge, but the saved policy
        // and its credential are intact.
        let restarted = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        XCTAssertEqual(try restarted.status(for: deviceID).persisted, .requiredEnrolled)
        XCTAssertThrowsError(try restarted.registerBegin(beginContext())) { error in
            XCTAssertEqual(error as? RemotePasskeyFailure, .passkeyAlreadyEnrolled)
        }
    }

    // MARK: - End-to-end with the production verifier

    func testEndToEndRegisterThenUnlockWithRealVerifier() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: WebAuthnRemotePasskeyVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state }, buildLabel: "RepoPrompt Test",
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)

        let authenticator = SoftwareAuthenticator()
        let registerOptions = try coordinator.registerBegin(beginContext())
        let registrationJSON = authenticator.registrationJSON(challenge: b64urlDecode(registerOptions.challengeBase64URL))
        let outcome = try await coordinator.registerComplete(
            completeContext(ceremonyID: registerOptions.ceremonyID),
            credentialJSON: registrationJSON
        )
        XCTAssertEqual(outcome.deviceID, deviceID)
        let stored = try XCTUnwrap(try store.device(id: deviceID)?.passkey.credential)
        XCTAssertEqual(Array(stored.credentialID), authenticator.credentialID)

        let revisionBeforeUnlock = try store.trustSnapshot().revision
        let unlockOptions = try coordinator.unlockBegin(beginContext())
        let assertionJSON = authenticator.assertionJSON(challenge: b64urlDecode(unlockOptions.challengeBase64URL))
        let verified = try await coordinator.unlockComplete(
            completeContext(ceremonyID: unlockOptions.ceremonyID),
            credentialJSON: assertionJSON
        )
        XCTAssertEqual(verified.deviceID, deviceID)
        // Unlock never writes: no grant is persisted and the sign count is not updated.
        XCTAssertEqual(try store.trustSnapshot().revision, revisionBeforeUnlock)
    }

    // MARK: - In-flight invalidation across the verifier await

    func testCancelDuringAwaitInvalidatesAndPreservesReplacementWindow() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let gate = VerifierGate()
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(gate: gate),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        let stale = try coordinator.registerBegin(beginContext())
        let task = Task { @MainActor in
            try await coordinator.registerComplete(self.completeContext(ceremonyID: stale.ceremonyID), credentialJSON: Data("{}".utf8))
        }
        await gate.waitUntilEntered()
        // Cancel the in-flight enrollment, then open a fresh window + challenge for the same device.
        coordinator.cancelEnrollment(deviceID: deviceID)
        try await coordinator.openEnrollment(deviceID: deviceID)
        _ = try coordinator.registerBegin(beginContext())
        await gate.release()

        await assertTaskFailure(.challengeInvalid, task)
        XCTAssertNil(try store.device(id: deviceID)?.passkey.credential, "stale completion must not commit")
        // The stale completion must NOT have wiped the replacement window.
        XCTAssertNotNil(try coordinator.status(for: deviceID).enrollmentOpenUntil, "replacement window survives")
    }

    func testReplacementBeginInvalidatesOlderInFlightCompletion() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let gate = VerifierGate()
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(gate: gate),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        let first = try coordinator.registerBegin(beginContext())
        let task = Task { @MainActor in
            try await coordinator.registerComplete(self.completeContext(ceremonyID: first.ceremonyID), credentialJSON: Data("{}".utf8))
        }
        await gate.waitUntilEntered()
        let second = try coordinator.registerBegin(beginContext()) // replaces the pending challenge, same window
        await gate.release()
        await assertTaskFailure(.challengeInvalid, task)
        XCTAssertNil(try store.device(id: deviceID)?.passkey.credential)
        // S2-04: the stale completion must NOT have closed the shared window; the replacement B
        // still owns it and completes successfully.
        XCTAssertNotNil(try coordinator.status(for: deviceID).enrollmentOpenUntil, "replacement window survives the stale completion")
        let outcome = try await coordinator.registerComplete(completeContext(ceremonyID: second.ceremonyID), credentialJSON: Data("{}".utf8))
        XCTAssertEqual(outcome.deviceID, deviceID)
        XCTAssertNotNil(try store.device(id: deviceID)?.passkey.credential, "replacement B commits")
    }

    /// S2-03: a begin for an UNRELATED (device, kind) must not invalidate another device's in-flight
    /// ceremony. Device A's registration is parked in verification; beginning a ceremony for device B
    /// advances only B's per-key token, so A still commits on release.
    func testUnrelatedDeviceBeginDoesNotInvalidateInFlightCeremony() async throws {
        let store = try makeStore()
        let deviceID2 = "remote:5678ef01"
        try store.upsertDevice(RemotePairingTestSupport.deviceRecord(id: deviceID2))
        let origin = OriginBox(exampleOrigin())
        let gate = VerifierGate()
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(gate: gate),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        try await coordinator.enable(deviceID: deviceID2)
        let aOptions = try coordinator.registerBegin(beginContext())
        let task = Task { @MainActor in
            try await coordinator.registerComplete(self.completeContext(ceremonyID: aOptions.ceremonyID), credentialJSON: Data("{}".utf8))
        }
        await gate.waitUntilEntered()
        // A begin for device B (a different challenge key) must not disturb device A's in-flight work.
        _ = try coordinator.registerBegin(RemotePasskeyBeginContext(deviceID: deviceID2, connectionGeneration: 5, principalConnectionID: principal))
        await gate.release()
        let outcome = try await task.value
        XCTAssertEqual(outcome.deviceID, deviceID)
        XCTAssertNotNil(try store.device(id: deviceID)?.passkey.credential, "device A commits despite device B's begin")
    }

    /// S2-03: a late `invalidate` for an OLD principal must not cancel a replacement principal's
    /// in-flight ceremony. The pending ceremony is owned by the current principal; invalidating a
    /// different (old) principal advances only that principal's generation.
    func testLateOldPrincipalInvalidationDoesNotAffectReplacement() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let gate = VerifierGate()
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(gate: gate),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        // `principal` is the current (replacement) capable principal.
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        let options = try coordinator.registerBegin(beginContext())
        let task = Task { @MainActor in
            try await coordinator.registerComplete(self.completeContext(ceremonyID: options.ceremonyID), credentialJSON: Data("{}".utf8))
        }
        await gate.waitUntilEntered()
        // A late invalidation for an OLD, now-replaced principal id arrives mid-flight.
        coordinator.invalidate(principalConnectionID: "gateway-connection-0")
        await gate.release()
        let outcome = try await task.value
        XCTAssertEqual(outcome.deviceID, deviceID)
        XCTAssertNotNil(try store.device(id: deviceID)?.passkey.credential, "replacement principal's ceremony commits")
    }

    func testInvalidatePrincipalCancelsInFlightAndWithdrawsCapability() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let gate = VerifierGate()
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(gate: gate),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        let options = try coordinator.registerBegin(beginContext())
        let task = Task { @MainActor in
            try await coordinator.registerComplete(self.completeContext(ceremonyID: options.ceremonyID), credentialJSON: Data("{}".utf8))
        }
        await gate.waitUntilEntered()
        coordinator.invalidate(principalConnectionID: principal) // Step 3 disconnect / Lock
        await gate.release()
        await assertTaskFailure(.challengeInvalid, task)
        XCTAssertNil(try store.device(id: deviceID)?.passkey.credential)
        // Capability was withdrawn with the principal.
        XCTAssertEqual(try coordinator.status(for: deviceID).enforcement, .gatewayLacksSupport)
    }

    func testResetDuringAwaitInvalidates() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let gate = VerifierGate()
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(gate: gate),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        let options = try coordinator.registerBegin(beginContext())
        let task = Task { @MainActor in
            try await coordinator.registerComplete(self.completeContext(ceremonyID: options.ceremonyID), credentialJSON: Data("{}".utf8))
        }
        await gate.waitUntilEntered()
        try coordinator.reset(deviceID: deviceID) // advances the store epoch and clears ceremonies
        await gate.release()
        await assertTaskFailure(.challengeInvalid, task)
        XCTAssertNil(try store.device(id: deviceID)?.passkey.credential)
    }

    func testExpiryDuringAwaitInvalidates() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let clock = FakeClock()
        let gate = VerifierGate()
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(gate: gate),
            now: { clock.now() }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        let options = try coordinator.registerBegin(beginContext())
        let task = Task { @MainActor in
            try await coordinator.registerComplete(self.completeContext(ceremonyID: options.ceremonyID), credentialJSON: Data("{}".utf8))
        }
        await gate.waitUntilEntered()
        clock.advance(by: .seconds(61))
        await gate.release()
        await assertTaskFailure(.challengeInvalid, task)
        XCTAssertNil(try store.device(id: deviceID)?.passkey.credential)
    }

    // MARK: - Live gateway principal re-query after verification

    func testRegisterRejectedWhenPrincipalNotLiveAfterVerification() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        // Live during enable, then torn down / credential-rotated before the ceremony completes.
        let live = LiveBox(true)
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in live.value }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        try await coordinator.enable(deviceID: deviceID)
        let options = try coordinator.registerBegin(beginContext())
        live.value = false // connection torn down / credential rotated mid-flight
        await assertFailure(.challengeInvalid) {
            _ = try await coordinator.registerComplete(self.completeContext(ceremonyID: options.ceremonyID), credentialJSON: Data("{}".utf8))
        }
        XCTAssertNil(try store.device(id: deviceID)?.passkey.credential, "a dead principal yields no enrollment")
    }

    func testUnlockRejectedWhenPrincipalNotLiveAfterVerification() async throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        // Enroll with a live principal.
        let enroller = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        try await enrollWithFakeVerifier(store: store, origin: origin, coordinator: enroller)
        // A second coordinator sees the principal as not live at unlock time.
        let unlocker = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in false }
        )
        unlocker.recordTrustCall(capable: true, principalConnectionID: principal)
        let options = try unlocker.unlockBegin(beginContext())
        await assertFailure(.challengeInvalid) {
            _ = try await unlocker.unlockComplete(self.completeContext(ceremonyID: options.ceremonyID), credentialJSON: Data("{}".utf8))
        }
    }

    // MARK: - Acknowledgment must name the exact issued snapshot

    func testAcknowledgeRejectsUnissuedAndSupersededSnapshot() throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        coordinator.recordTrustCall(capable: true, principalConnectionID: principal)
        // Unissued: a correct-launch, in-range revision with no issued snapshot is rejected.
        XCTAssertThrowsError(try coordinator.acknowledgeTrust(principalConnectionID: principal, launch: store.launchNonce, revision: 0, issuanceID: "x")) { error in
            XCTAssertEqual(error as? RemotePasskeyFailure, .staleAcknowledgment)
        }
        // Issue revision 7, then supersede it with revision 9: acking the stale 7 is rejected.
        let issuance7 = try XCTUnwrap(coordinator.recordIssuedTrustSnapshot(principalConnectionID: principal, revision: 7, originRevision: origin.state.generation, deviceEpochs: [:]))
        let issuance9 = try XCTUnwrap(coordinator.recordIssuedTrustSnapshot(principalConnectionID: principal, revision: 9, originRevision: origin.state.generation, deviceEpochs: [:]))
        XCTAssertThrowsError(try coordinator.acknowledgeTrust(principalConnectionID: principal, launch: store.launchNonce, revision: 7, issuanceID: issuance7)) { error in
            XCTAssertEqual(error as? RemotePasskeyFailure, .staleAcknowledgment)
        }
        // The exact current issued revision + issuance is accepted.
        try coordinator.acknowledgeTrust(principalConnectionID: principal, launch: store.launchNonce, revision: 9, issuanceID: issuance9)
    }

    // MARK: - Policy-off never claims browser access is blocked

    /// S2-05 / B P1-01: a policy-off device still has ordinary browser access. With a discoverable
    /// but legacy (not capable) gateway its enforcement is `gatewayLacksSupport`, but the blocked
    /// reason must describe passkey SETUP needing a capable gateway, NOT claim browser access is
    /// blocked.
    func testOffDeviceDoesNotClaimBrowserAccessBlocked() throws {
        let store = try makeStore()
        let origin = OriginBox(exampleOrigin())
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store, verifier: GatedFakeVerifier(),
            now: { ContinuousClock.now }, originSnapshot: { origin.state },
            isPrincipalLive: { _ in true }
        )
        // Discoverable, legacy (not capable). The device is policy-off (the default fixture state).
        coordinator.recordTrustCall(capable: false, principalConnectionID: principal)
        let status = try coordinator.status(for: deviceID)
        XCTAssertEqual(status.persisted, .off)
        XCTAssertEqual(status.enforcement, .gatewayLacksSupport)
        let reason = try XCTUnwrap(status.enableBlockedReason)
        XCTAssertFalse(
            reason.lowercased().contains("browser access is blocked"),
            "a policy-off device must not claim ordinary browser access is blocked"
        )
    }

    // MARK: Helpers

    private func assertTaskFailure(
        _ expected: RemotePasskeyFailure,
        _ task: Task<RemotePasskeyRegistrationOutcome, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected RemotePasskeyFailure \(expected)", file: file, line: line)
        } catch let error as RemotePasskeyFailure {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }

    private func assertFailure(
        _ expected: RemotePasskeyFailure,
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Expected RemotePasskeyFailure \(expected)", file: file, line: line)
        } catch let error as RemotePasskeyFailure {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
