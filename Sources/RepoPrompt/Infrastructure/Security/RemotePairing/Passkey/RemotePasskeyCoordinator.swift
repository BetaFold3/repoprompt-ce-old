import Foundation
import RepoPromptAgentCore
import RepoPromptRemoteWire
import Security

/// App-owned passkey ceremony authority (remote passkey unlock, Step 2c).
///
/// `@MainActor` on purpose: it reads `RemoteGatewayStatusStore` synchronously and publishes status
/// to Settings in one isolation domain, which avoids ordering problems between an actor and the UI.
/// Ceremonies are rare and the ECDSA verification work is delegated to an injected verifier.
///
/// All ceremony state is in-memory and lost on restart BY DESIGN: a restart keeps the saved
/// `required` policy but has no open windows or live challenges. Durable policy/credential state
/// lives only in `RemotePairingIdentityStore`.
///
/// Invalidation is generation-based, not string-based: each ceremony captures the origin-change
/// revision at `begin` and re-checks it at `complete` (before AND after the verifier
/// await), so an A→B→A origin change during the await — which a bare origin-string comparison would
/// miss — still invalidates the ceremony. Policy changes are caught by the per-device epoch, and a
/// reconnect by the connection generation.
@MainActor
final class RemotePasskeyCoordinator: ObservableObject {
    static let shared = RemotePasskeyCoordinator()

    /// A single synchronous snapshot of the published browser origin and its generation, read from
    /// the one origin authority (`RemoteGatewayStatusStore`). Taken atomically on the main actor so
    /// the origin and its generation cannot tear.
    struct OriginState: Equatable {
        let origin: RemotePasskeyOrigin?
        /// The browser origin's monotonic change-revision (`RemoteGatewayStatusStore`'s
        /// `currentOriginRevision`), not its activation generation. It advances on every real origin
        /// change so an A→B→A change during a verifier await — which a bare origin-string comparison
        /// (and the activation generation) would both miss — still invalidates a ceremony.
        let generation: UInt64
        let discoverable: Bool
    }

    static let enrollmentWindow: Duration = .seconds(120)
    static let challengeLifetime: Duration = .seconds(60)
    static let challengeTimeoutMilliseconds = 60000

    // MARK: Injected dependencies

    private let identityStore: RemotePairingIdentityStore
    private let verifier: any RemotePasskeyVerifying
    private let now: () -> ContinuousClock.Instant
    private let originSnapshot: () -> OriginState
    private let randomBytes: (Int) -> [UInt8]
    private let buildLabel: String
    /// Live re-query of the authenticated gateway principal, by its captured (old) connection ID.
    /// Returns false for a principal that is missing, being removed, or whose launch credential has
    /// been rotated. Called AFTER the verifier await so a connection that was torn down (or a
    /// credential rotation) during verification cannot produce a committed enrollment or a verified
    /// unlock. Keyed by the OLD id captured at begin, so a late answer can never affect a
    /// replacement principal.
    private let isPrincipalLive: (String) async -> Bool

    // MARK: In-memory ceremony state

    private struct ChallengeKey: Hashable {
        let deviceID: String
        let kind: RemotePasskeyCeremonyKind
    }

    private struct EnrollmentWindowRecord {
        /// Process-unique identity of this exact authorization window. A ceremony captures it at
        /// begin and re-checks it at complete, so a stale completion can neither commit against a
        /// replacement window nor clear it.
        let id: UInt64
        let epoch: UInt64
        let origin: RemotePasskeyOrigin
        let originGeneration: UInt64
        let expiresAt: ContinuousClock.Instant
    }

    private struct PendingChallenge {
        let kind: RemotePasskeyCeremonyKind
        let deviceID: String
        let ceremonyID: String
        let challenge: [UInt8]
        let epoch: UInt64
        let origin: RemotePasskeyOrigin
        let originGeneration: UInt64
        let principalConnectionID: String
        let connectionGeneration: UInt64
        let expiresAt: ContinuousClock.Instant
        /// Per-`(deviceID, kind)` in-flight validity token captured at begin. A replace/cancel/
        /// reset/disable/enable on THIS challenge key advances `ceremonyTokenByKey[key]`, so a
        /// completion whose captured value no longer matches is rejected even after it already
        /// consumed its challenge and suspended in the verifier. Scoped per key so an unrelated
        /// device/kind ceremony cannot invalidate this one.
        let ceremonyToken: UInt64
        /// Per-principal invalidation generation captured at begin. `invalidate(principal)` (Step 3
        /// disconnect/Lock) advances only that principal's generation, so a late invalidation for an
        /// old principal cannot cancel a replacement principal's in-flight ceremony.
        let principalGen: UInt64
        /// Registration-only: the `EnrollmentWindowRecord.id` this challenge was minted under.
        let windowID: UInt64?
        // Registration-only: freshly minted user handle.
        let userHandle: Data?
        // Assertion-only: the stored credential snapshot taken at begin.
        let credentialID: [UInt8]?
        let publicKeyCOSE: [UInt8]?
        let storedUserHandle: Data?
        let backupEligible: Bool?
    }

    private var windows: [String: EnrollmentWindowRecord] = [:]
    private var challenges: [ChallengeKey: PendingChallenge] = [:]
    /// Monotonic source of `EnrollmentWindowRecord.id`.
    private var windowSequence: UInt64 = 0
    /// Per-`(deviceID, kind)` in-flight ceremony validity tokens. A replace/cancel/reset/disable/
    /// enable on a challenge key advances only that key's token, so a consumed, suspended completion
    /// whose captured value no longer matches is rejected without disturbing other devices/kinds.
    /// In-memory and reset on restart (all ceremony state is).
    private var ceremonyTokenByKey: [ChallengeKey: UInt64] = [:]
    /// Per-principal invalidation generations. `invalidate(principal)` advances only that principal's
    /// generation; a late invalidation for an old principal therefore cannot cancel a replacement.
    private var principalGenByPrincipal: [String: UInt64] = [:]

    // MARK: Trust / capability state (bound to the current capable gateway principal)

    private var capablePrincipalConnectionID: String?
    private var lastTrustCallCapable: Bool?

    /// A trust snapshot the coordinator issued to the current capable principal on a capable
    /// `list_devices`. An acknowledgment is only accepted when it names exactly this snapshot.
    private struct IssuedTrustSnapshot: Equatable {
        /// Unguessable per-issuance identity. Two capable `list_devices` responses at the SAME store
        /// revision but different origins get different issuance IDs, so an acknowledgment for one
        /// can never be accepted for the other.
        let issuanceID: String
        let principalConnectionID: String
        let revision: UInt64
        let originRevision: UInt64
        let deviceEpochs: [String: UInt64]
    }

    /// The most recent snapshot issued to the current capable principal (nil until a capable call).
    private var issuedTrustSnapshot: IssuedTrustSnapshot?
    /// The exact issued snapshot the current principal has acknowledged. Enforcement is `applied`
    /// only when this is present AND still matches the current principal, origin revision and the
    /// device's current epoch; there is no implicit "applied" without an explicit acknowledgment.
    private var ackedTrustSnapshot: IssuedTrustSnapshot?

    /// Bumped on every state change so SwiftUI views refresh.
    @Published private(set) var revision: UInt64 = 0

    // MARK: Init

    init(
        identityStore: RemotePairingIdentityStore = .shared,
        verifier: any RemotePasskeyVerifying = WebAuthnRemotePasskeyVerifier(),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        originSnapshot: (() -> OriginState)? = nil,
        randomBytes: @escaping (Int) -> [UInt8] = RemotePasskeyCoordinator.secureRandomBytes,
        buildLabel: String = RemotePasskeyCoordinator.defaultBuildLabel(),
        isPrincipalLive: (@Sendable (String) async -> Bool)? = nil
    ) {
        self.identityStore = identityStore
        self.verifier = verifier
        self.now = now
        self.randomBytes = randomBytes
        self.buildLabel = buildLabel
        self.isPrincipalLive = isPrincipalLive ?? { connectionID in
            // The ONE live-principal authority: the network actor that owns connection lifetime.
            guard let uuid = UUID(uuidString: connectionID) else { return false }
            return await ServerNetworkManager.shared.isGatewayPrincipalConnectionLive(uuid)
        }
        self.originSnapshot = originSnapshot ?? {
            // The ONE origin authority. `activeBrowserOrigin` is non-nil only while discoverable.
            let store = RemoteGatewayStatusStore.shared
            let gateway = store.activeBrowserOrigin
            let origin = gateway.flatMap(RemotePasskeyOrigin.init(_:))
            return OriginState(
                origin: origin,
                // Origin-change revision, NOT the activation generation: it advances on every real
                // change to the effective browser origin, including an A→B→A change within one
                // activation generation that `currentGeneration` would miss.
                generation: store.currentOriginRevision,
                discoverable: gateway != nil
            )
        }
    }

    // MARK: - Mac actions (synchronous; each rechecks state)

    /// Enable the passkey requirement for a device, or reopen an enrollment window for a device
    /// that is required-without-credential. In Step 2 there is no capable gateway principal, so the
    /// capability precondition always fails (`gatewayUnsupported`); the method is still correct so
    /// Step 3 can light it up.
    func enable(deviceID: String) async throws {
        prune()
        let device = try requireDevice(deviceID)
        guard !device.isRevoked else { throw RemotePasskeyFailure.deviceRevoked }
        switch (device.passkey.state, device.passkey.credential) {
        case (.off, _):
            try await requireEnrollableLive()
            try casPolicy(deviceID, expectedEpoch: device.passkey.epoch) { policy in
                policy.state = .required
                policy.credential = nil
            }
            try openWindow(deviceID)
        case (.required, .none):
            try await requireEnrollableLive()
            try openWindow(deviceID)
        case (.required, .some):
            throw RemotePasskeyFailure.passkeyAlreadyEnrolled
        }
        invalidateCeremonies(forDevice: deviceID)
        bump()
    }

    /// Reopen the enrollment window for a device that is required-without-credential.
    func openEnrollment(deviceID: String) async throws {
        prune()
        let device = try requireDevice(deviceID)
        guard !device.isRevoked else { throw RemotePasskeyFailure.deviceRevoked }
        guard device.passkey.state == .required else { throw RemotePasskeyFailure.passkeyNotRequired }
        guard device.passkey.credential == nil else { throw RemotePasskeyFailure.passkeyAlreadyEnrolled }
        try await requireEnrollableLive()
        try openWindow(deviceID)
        invalidateCeremonies(forDevice: deviceID)
        bump()
    }

    /// Close an open enrollment window and drop any pending registration challenge.
    func cancelEnrollment(deviceID: String) {
        windows[deviceID] = nil
        challenges[ChallengeKey(deviceID: deviceID, kind: .registration)] = nil
        // Invalidate any already-consumed, in-flight registration completion for this device.
        bumpCeremonyToken(for: ChallengeKey(deviceID: deviceID, kind: .registration))
        bump()
    }

    /// Clear a device's enrolled credential while keeping the requirement. This is a trusted local
    /// recovery path: it must succeed even when the HTTPS origin is unavailable, and it preserves
    /// durable state if the store write fails. A window is reopened only when enrollment is
    /// actually possible.
    func reset(deviceID: String) throws {
        prune()
        let device = try requireDevice(deviceID)
        guard device.passkey.state == .required else { throw RemotePasskeyFailure.passkeyNotRequired }
        do {
            try casPolicy(deviceID, expectedEpoch: device.passkey.epoch) { policy in
                policy.state = .required
                policy.credential = nil
            }
        } catch {
            // Durable state is preserved on failure (no partial write); report storage failure.
            throw RemotePasskeyFailure.storageFailed
        }
        windows[deviceID] = nil
        challenges[ChallengeKey(deviceID: deviceID, kind: .registration)] = nil
        challenges[ChallengeKey(deviceID: deviceID, kind: .assertion)] = nil
        invalidateCeremonies(forDevice: deviceID)
        if isEnrollmentPossible(), let updated = try? identityStore.device(id: deviceID) ?? nil {
            try? openWindow(deviceID, epoch: updated.passkey.epoch)
        }
        bump()
    }

    /// Turn the requirement off entirely. Always allowed as the recovery path, including for a
    /// revoked device. Preserves durable state if the store write fails.
    func disable(deviceID: String) throws {
        prune()
        let device = try requireDevice(deviceID)
        do {
            try casPolicy(deviceID, expectedEpoch: device.passkey.epoch) { policy in
                policy.state = .off
                policy.credential = nil
            }
        } catch {
            throw RemotePasskeyFailure.storageFailed
        }
        windows[deviceID] = nil
        challenges[ChallengeKey(deviceID: deviceID, kind: .registration)] = nil
        challenges[ChallengeKey(deviceID: deviceID, kind: .assertion)] = nil
        invalidateCeremonies(forDevice: deviceID)
        bump()
    }

    // MARK: - Principal ceremony operations

    func registerBegin(_ context: RemotePasskeyBeginContext) throws -> RemotePasskeyRegistrationOptions {
        prune()
        let device = try requireDevice(context.deviceID)
        guard !device.isRevoked else { throw RemotePasskeyFailure.deviceRevoked }
        guard device.passkey.state == .required else { throw RemotePasskeyFailure.passkeyNotRequired }
        guard device.passkey.credential == nil else { throw RemotePasskeyFailure.passkeyAlreadyEnrolled }
        guard let window = windows[context.deviceID], now() < window.expiresAt else {
            windows[context.deviceID] = nil
            throw RemotePasskeyFailure.enrollmentClosed
        }
        let snapshot = originSnapshot()
        guard let origin = snapshot.origin else { throw RemotePasskeyFailure.originUnavailable }
        guard window.epoch == device.passkey.epoch,
              window.origin == origin,
              window.originGeneration == snapshot.generation
        else {
            throw RemotePasskeyFailure.enrollmentClosed
        }

        // A new begin invalidates any already-consumed, in-flight completion for this (device, kind).
        let key = ChallengeKey(deviceID: context.deviceID, kind: .registration)
        bumpCeremonyToken(for: key)
        let ceremonyID = makeCeremonyID()
        let challengeBytes = randomBytes(32)
        let userHandle = Data(randomBytes(16))
        let expiresAt = min(now().advanced(by: Self.challengeLifetime), window.expiresAt)
        challenges[key] = PendingChallenge(
            kind: .registration,
            deviceID: context.deviceID,
            ceremonyID: ceremonyID,
            challenge: challengeBytes,
            epoch: device.passkey.epoch,
            origin: origin,
            originGeneration: snapshot.generation,
            principalConnectionID: context.principalConnectionID,
            connectionGeneration: context.connectionGeneration,
            expiresAt: expiresAt,
            ceremonyToken: token(for: key),
            principalGen: principalGen(for: context.principalConnectionID),
            windowID: window.id,
            userHandle: userHandle,
            credentialID: nil,
            publicKeyCOSE: nil,
            storedUserHandle: nil,
            backupEligible: nil
        )
        bump()
        return RemotePasskeyRegistrationOptions(
            ceremonyID: ceremonyID,
            challengeBase64URL: Base64URL.encode(challengeBytes),
            relyingPartyID: origin.rpID,
            relyingPartyName: buildLabel,
            userHandleBase64URL: Base64URL.encode(userHandle),
            userName: "\(buildLabel) · \(device.displayName)",
            userDisplayName: "\(buildLabel) · \(device.displayName)",
            timeoutMilliseconds: Self.challengeTimeoutMilliseconds
        )
    }

    func registerComplete(_ context: RemotePasskeyCeremonyContext, credentialJSON: Data) async throws -> RemotePasskeyRegistrationOutcome {
        let key = ChallengeKey(deviceID: context.deviceID, kind: .registration)
        // One-use: consume the challenge up front so a replay cannot reuse it.
        guard let pending = challenges[key], pending.ceremonyID == context.ceremonyID else {
            throw RemotePasskeyFailure.challengeInvalid
        }
        challenges[key] = nil
        bump()
        try validateBinding(pending, context: context)

        let input = RemotePasskeyRegistrationInput(
            challenge: pending.challenge,
            origin: pending.origin,
            relyingPartyName: buildLabel,
            credentialJSON: credentialJSON,
            isCredentialIDUnused: { [identityStore] idBytes in
                guard let registry = try? identityStore.registry() else { return false }
                let data = Data(idBytes)
                return !registry.devices.contains { $0.passkey.credential?.credentialID == data }
            }
        )
        let verified: RemotePasskeyVerifiedRegistration
        do {
            verified = try await verifier.verifyRegistration(input)
        } catch {
            clearCeremonyArtifacts(pending)
            bump()
            throw RemotePasskeyFailure.verificationFailed
        }

        // Re-check every binding after the await (an A→B→A origin change is caught by the origin
        // revision), re-query the ACTUAL live gateway principal by its captured id, then re-check
        // once more after that suspension. A principal removed or whose credential rotated during
        // verification yields no committed enrollment.
        do {
            try validateBinding(pending, context: context)
            guard await isPrincipalLive(pending.principalConnectionID) else {
                throw RemotePasskeyFailure.challengeInvalid
            }
            try validateBinding(pending, context: context)
        } catch {
            clearCeremonyArtifacts(pending)
            bump()
            throw error
        }

        let credential = RemotePasskeyCredentialRecord(
            credentialID: Data(verified.credentialID),
            publicKeyCOSE: Data(verified.publicKeyCOSE),
            rpID: pending.origin.rpID,
            userHandle: pending.userHandle ?? Data(),
            signCountAtRegistration: verified.signCount,
            backupEligible: verified.backupEligible,
            backedUpAtRegistration: verified.backedUp,
            createdAt: Date()
        )
        let record: PairedDeviceRecord
        do {
            record = try identityStore.updatePasskeyPolicy(deviceID: context.deviceID, expectedEpoch: pending.epoch) { policy in
                policy.state = .required
                policy.credential = credential
            }
        } catch let storeError as RemotePairingIdentityStoreError {
            clearCeremonyArtifacts(pending)
            bump()
            switch storeError {
            case .policyConflict, .duplicateCredentialID, .deviceNotFound:
                throw RemotePasskeyFailure.challengeInvalid
            default:
                throw RemotePasskeyFailure.storageFailed
            }
        }
        clearCeremonyArtifacts(pending)
        bump()
        // Registration NEVER grants access.
        return RemotePasskeyRegistrationOutcome(
            deviceID: context.deviceID,
            epoch: record.passkey.epoch,
            ceremonyID: context.ceremonyID,
            connectionGeneration: context.connectionGeneration
        )
    }

    func unlockBegin(_ context: RemotePasskeyBeginContext) throws -> RemotePasskeyAssertionOptions {
        prune()
        let device = try requireDevice(context.deviceID)
        guard !device.isRevoked else { throw RemotePasskeyFailure.deviceRevoked }
        guard device.passkey.state == .required else { throw RemotePasskeyFailure.passkeyNotRequired }
        guard let credential = device.passkey.credential else { throw RemotePasskeyFailure.passkeyNotEnrolled }
        let snapshot = originSnapshot()
        guard let origin = snapshot.origin else { throw RemotePasskeyFailure.originUnavailable }
        // A hostname change requires re-enrollment; a port-only change is tolerated (rpID is host).
        guard credential.rpID == origin.rpID else { throw RemotePasskeyFailure.reenrollmentRequired }

        // A new begin invalidates any already-consumed, in-flight completion for this (device, kind).
        let key = ChallengeKey(deviceID: context.deviceID, kind: .assertion)
        bumpCeremonyToken(for: key)
        let ceremonyID = makeCeremonyID()
        let challengeBytes = randomBytes(32)
        let expiresAt = now().advanced(by: Self.challengeLifetime)
        challenges[key] = PendingChallenge(
            kind: .assertion,
            deviceID: context.deviceID,
            ceremonyID: ceremonyID,
            challenge: challengeBytes,
            epoch: device.passkey.epoch,
            origin: origin,
            originGeneration: snapshot.generation,
            principalConnectionID: context.principalConnectionID,
            connectionGeneration: context.connectionGeneration,
            expiresAt: expiresAt,
            ceremonyToken: token(for: key),
            principalGen: principalGen(for: context.principalConnectionID),
            windowID: nil,
            userHandle: nil,
            credentialID: Array(credential.credentialID),
            publicKeyCOSE: Array(credential.publicKeyCOSE),
            storedUserHandle: credential.userHandle,
            backupEligible: credential.backupEligible
        )
        bump()
        return RemotePasskeyAssertionOptions(
            ceremonyID: ceremonyID,
            challengeBase64URL: Base64URL.encode(challengeBytes),
            relyingPartyID: origin.rpID,
            allowedCredentialBase64URL: Base64URL.encode(credential.credentialID),
            timeoutMilliseconds: Self.challengeTimeoutMilliseconds
        )
    }

    func unlockComplete(_ context: RemotePasskeyCeremonyContext, credentialJSON: Data) async throws -> RemotePasskeyUnlockOutcome {
        let key = ChallengeKey(deviceID: context.deviceID, kind: .assertion)
        guard let pending = challenges[key], pending.ceremonyID == context.ceremonyID else {
            throw RemotePasskeyFailure.challengeInvalid
        }
        challenges[key] = nil
        bump()
        try validateBinding(pending, context: context)

        guard let credentialID = pending.credentialID, let publicKeyCOSE = pending.publicKeyCOSE else {
            throw RemotePasskeyFailure.challengeInvalid
        }
        let input = RemotePasskeyAssertionInput(
            challenge: pending.challenge,
            origin: pending.origin,
            credentialID: credentialID,
            publicKeyCOSE: publicKeyCOSE,
            userHandle: pending.storedUserHandle,
            backupEligible: pending.backupEligible ?? false,
            credentialJSON: credentialJSON
        )
        do {
            try await verifier.verifyAssertion(input)
        } catch {
            throw RemotePasskeyFailure.verificationFailed
        }
        // Re-check after the await, re-query the ACTUAL live gateway principal by its captured id,
        // then re-check once more. No disk write and no sign-count update: the gateway issues the
        // grant from this verified fact in Step 3.
        try validateBinding(pending, context: context)
        guard await isPrincipalLive(pending.principalConnectionID) else {
            throw RemotePasskeyFailure.challengeInvalid
        }
        try validateBinding(pending, context: context)
        return RemotePasskeyUnlockOutcome(
            deviceID: context.deviceID,
            epoch: pending.epoch,
            ceremonyID: context.ceremonyID,
            connectionGeneration: context.connectionGeneration
        )
    }

    // MARK: - Trust / capability

    /// Record the capability a gateway reported on a `list_devices` call and bind it to the current
    /// principal. A capable call from a NEW principal connection resets any prior acknowledgment and
    /// drops challenges bound to a different connection; a non-capable (legacy) call on the current
    /// capable principal withdraws its capability, since a legacy gateway cannot enforce the policy.
    func recordTrustCall(capable: Bool, principalConnectionID: String) {
        lastTrustCallCapable = capable
        if capable {
            if capablePrincipalConnectionID != principalConnectionID {
                capablePrincipalConnectionID = principalConnectionID
                issuedTrustSnapshot = nil
                ackedTrustSnapshot = nil
                // A different principal's pending challenges can no longer complete (the completing
                // connection id will not match); drop them. Per-key tokens and per-principal
                // generations are left untouched so a principal change never invalidates another
                // principal's or device's in-flight ceremony.
                challenges = challenges.filter { $0.value.principalConnectionID == principalConnectionID }
            }
        } else if capablePrincipalConnectionID == principalConnectionID {
            capablePrincipalConnectionID = nil
            issuedTrustSnapshot = nil
            ackedTrustSnapshot = nil
        }
        bump()
    }

    /// Record the exact trust snapshot issued to the current capable principal on a capable
    /// `list_devices`. A later `acknowledgeTrust` is accepted only when it names THIS snapshot
    /// (same principal, same revision); enforcement is `applied` only while the acknowledged
    /// snapshot still matches the live origin revision and the device's current epoch.
    @discardableResult
    func recordIssuedTrustSnapshot(
        principalConnectionID: String,
        revision: UInt64,
        originRevision: UInt64,
        deviceEpochs: [String: UInt64]
    ) -> String? {
        guard capablePrincipalConnectionID == principalConnectionID else { return nil }
        let issuanceID = makeCeremonyID()
        issuedTrustSnapshot = IssuedTrustSnapshot(
            issuanceID: issuanceID,
            principalConnectionID: principalConnectionID,
            revision: revision,
            originRevision: originRevision,
            deviceEpochs: deviceEpochs
        )
        bump()
        return issuanceID
    }

    /// Apply a trust acknowledgment. Accepted only for this exact launch, from the current capable
    /// principal, and naming the exact snapshot most recently issued to that principal. An
    /// unissued, superseded (stale) or future revision, or a different principal, is rejected.
    func acknowledgeTrust(principalConnectionID: String, launch: String, revision: UInt64, issuanceID: String) throws {
        guard capablePrincipalConnectionID == principalConnectionID,
              launch == identityStore.launchNonce,
              let issued = issuedTrustSnapshot,
              issued.principalConnectionID == principalConnectionID,
              issued.revision == revision,
              issued.issuanceID == issuanceID
        else {
            throw RemotePasskeyFailure.staleAcknowledgment
        }
        ackedTrustSnapshot = issued
        bump()
    }

    /// Cancel every ceremony bound to a principal connection and withdraw its capability/trust.
    /// This is the app-side cancellation Step 3 calls on a gateway disconnect or Lock (no new
    /// transport). It keys off the OLD connection id and clears capability only when that id is
    /// still the current capable principal, so a late call cannot clear a replacement principal.
    func invalidate(principalConnectionID: String) {
        challenges = challenges.filter { $0.value.principalConnectionID != principalConnectionID }
        if capablePrincipalConnectionID == principalConnectionID {
            capablePrincipalConnectionID = nil
            lastTrustCallCapable = nil
            issuedTrustSnapshot = nil
            ackedTrustSnapshot = nil
        }
        // Invalidate any already-consumed, in-flight completion owned by THIS principal, without
        // touching ceremonies owned by a replacement principal.
        principalGenByPrincipal[principalConnectionID, default: 0] &+= 1
        bump()
    }

    // MARK: - Settings status

    func status(for deviceID: String) throws -> RemotePasskeyDeviceStatus {
        prune()
        let device = try requireDevice(deviceID)
        let snapshot = originSnapshot()
        let persisted: RemotePasskeyDeviceStatus.Persisted = switch (device.passkey.state, device.passkey.credential) {
        case (.off, _):
            .off
        case (.required, .none):
            .requiredNotEnrolled
        case let (.required, .some(credential)):
            if let origin = snapshot.origin, credential.rpID != origin.rpID {
                .requiredNeedsReenrollment
            } else {
                .requiredEnrolled
            }
        }

        let enforcement = enforcement(for: deviceID, snapshot: snapshot)
        let openUntil: Date? = if let window = windows[deviceID], now() < window.expiresAt {
            Date().addingTimeInterval(seconds(from: now(), to: window.expiresAt))
        } else {
            nil
        }
        let blockedReason = enableBlockedReason(persisted: persisted, enforcement: enforcement)
        return RemotePasskeyDeviceStatus(
            persisted: persisted,
            enforcement: enforcement,
            enrollmentOpenUntil: openUntil,
            enableBlockedReason: blockedReason
        )
    }

    private func enforcement(for deviceID: String, snapshot: OriginState) -> RemotePasskeyDeviceStatus.Enforcement {
        guard snapshot.discoverable else { return .gatewayUnavailable }
        guard capabilityIsCurrent(), let principal = capablePrincipalConnectionID else {
            return .gatewayLacksSupport
        }
        // Applied requires an EXPLICIT acknowledgment of a still-current snapshot: there is no
        // implicit "applied" for a pre-existing policy or a fresh app launch that never issued and
        // had acknowledged a snapshot. The acknowledged snapshot must still match the current
        // principal, the live origin revision, and the device's current epoch.
        guard let ack = ackedTrustSnapshot,
              ack.principalConnectionID == principal,
              ack.originRevision == snapshot.generation,
              let device = (try? identityStore.device(id: deviceID)) ?? nil,
              ack.deviceEpochs[deviceID] == device.passkey.epoch
        else {
            return .pending
        }
        return .applied
    }

    /// Authoritative origin projection for the capable `list_devices` trust response: the live
    /// origin serialization and its monotonic change-revision (never a request header or client
    /// input). Step 3 reconciles enforcement against these.
    struct TrustProjection: Equatable {
        let originSerialized: String?
        let originRevision: UInt64
        let discoverable: Bool
    }

    func trustProjection() -> TrustProjection {
        let snapshot = originSnapshot()
        return TrustProjection(
            originSerialized: snapshot.origin?.serialized,
            originRevision: snapshot.generation,
            discoverable: snapshot.discoverable
        )
    }

    /// Per-device enrollment projection needed by Step 3: whether an enrollment window is open and
    /// whether the saved credential needs re-enrollment for the current origin's RP ID.
    func enrollmentProjection(for deviceID: String) -> (enrollmentOpen: Bool, needsReenrollment: Bool) {
        prune()
        let open = windows[deviceID].map { now() < $0.expiresAt } ?? false
        let snapshot = originSnapshot()
        let needsReenrollment: Bool = {
            guard let device = (try? identityStore.device(id: deviceID)) ?? nil,
                  device.passkey.state == .required,
                  let credential = device.passkey.credential,
                  let origin = snapshot.origin
            else { return false }
            return credential.rpID != origin.rpID
        }()
        return (open, needsReenrollment)
    }

    private func enableBlockedReason(
        persisted: RemotePasskeyDeviceStatus.Persisted,
        enforcement: RemotePasskeyDeviceStatus.Enforcement
    ) -> String? {
        switch enforcement {
        case .gatewayUnavailable:
            "Remote Control is not discoverable. Start Remote Control to manage passkeys."
        case .gatewayLacksSupport:
            // A policy-off device still has ordinary browser access; only passkey SETUP is blocked.
            // Only a device that already requires a passkey can describe access as blocked.
            switch persisted {
            case .off:
                "Requiring a passkey needs a passkey-capable gateway. Update Remote Control to set one up."
            case .requiredNotEnrolled, .requiredNeedsReenrollment, .requiredEnrolled:
                "Browser access is blocked until the gateway is updated to support passkeys."
            }
        case .pending, .applied:
            nil
        }
    }

    // MARK: - Helpers

    private func requireDevice(_ deviceID: String) throws -> PairedDeviceRecord {
        let device: PairedDeviceRecord?
        do {
            device = try identityStore.device(id: deviceID)
        } catch {
            // A store read failure is NOT an unknown device: surface it as a storage failure so the
            // gateway maps it to 503 rather than a definitive "no such device".
            throw RemotePasskeyFailure.storageFailed
        }
        guard let device else { throw RemotePasskeyFailure.unknownDevice }
        return device
    }

    /// Whether a capable gateway principal is currently bound. This is the cheap synchronous gate
    /// used for display and the enable precondition; `enable`/`openEnrollment` additionally require
    /// the bound principal to still be LIVE (the authoritative launch/lifetime binding) before
    /// activating policy, so stale capability from a disconnected/replaced/credential-rotated
    /// principal cannot authorize Enable.
    private func capabilityIsCurrent() -> Bool {
        lastTrustCallCapable == true && capablePrincipalConnectionID != nil
    }

    private func requireEnrollable() throws {
        guard capabilityIsCurrent() else {
            throw RemotePasskeyFailure.gatewayUnsupported
        }
        let snapshot = originSnapshot()
        guard snapshot.discoverable else { throw RemotePasskeyFailure.gatewayUnavailable }
        guard snapshot.origin != nil else { throw RemotePasskeyFailure.originUnavailable }
    }

    /// `requireEnrollable` plus the authoritative live-principal query: the capable principal that
    /// established capability must still be live (not disconnected, replaced, or credential-rotated)
    /// at the instant policy is activated. This binds Enable to the current app-owned gateway
    /// launch/lifetime (`isGatewayPrincipalConnectionLive` checks the launch-credential generation,
    /// connection presence and not-being-removed) rather than a cached capability flag, and is keyed
    /// by the captured principal id so a replacement is never mistaken for the original.
    private func requireEnrollableLive() async throws {
        try requireEnrollable()
        guard let principal = capablePrincipalConnectionID else {
            throw RemotePasskeyFailure.gatewayUnsupported
        }
        guard await isPrincipalLive(principal) else {
            throw RemotePasskeyFailure.gatewayUnsupported
        }
        // Re-check the synchronous preconditions after the await: a capability withdrawal or origin
        // change during the query must still block activation, and the bound principal must not have
        // been replaced.
        try requireEnrollable()
        guard capablePrincipalConnectionID == principal else {
            throw RemotePasskeyFailure.gatewayUnsupported
        }
    }

    private func isEnrollmentPossible() -> Bool {
        let snapshot = originSnapshot()
        return capabilityIsCurrent() && snapshot.discoverable && snapshot.origin != nil
    }

    private func openWindow(_ deviceID: String, epoch: UInt64? = nil) throws {
        let snapshot = originSnapshot()
        guard let origin = snapshot.origin else { throw RemotePasskeyFailure.originUnavailable }
        let resolvedEpoch: UInt64 = if let epoch {
            epoch
        } else {
            (try? identityStore.device(id: deviceID))??.passkey.epoch ?? 0
        }
        windowSequence &+= 1
        windows[deviceID] = EnrollmentWindowRecord(
            id: windowSequence,
            epoch: resolvedEpoch,
            origin: origin,
            originGeneration: snapshot.generation,
            expiresAt: now().advanced(by: Self.enrollmentWindow)
        )
    }

    private func casPolicy(
        _ deviceID: String,
        expectedEpoch: UInt64,
        _ transform: @escaping (inout RemotePasskeyPolicyRecord) -> Void
    ) throws {
        _ = try identityStore.updatePasskeyPolicy(deviceID: deviceID, expectedEpoch: expectedEpoch) { policy in
            transform(&policy)
        }
    }

    /// Generic binding re-check. Every mismatch collapses to `challengeInvalid` so a caller cannot
    /// learn which specific guard rejected the ceremony.
    private func validateBinding(_ pending: PendingChallenge, context: RemotePasskeyCeremonyContext) throws {
        guard pending.principalConnectionID == context.principalConnectionID,
              pending.connectionGeneration == context.connectionGeneration
        else {
            throw RemotePasskeyFailure.challengeInvalid
        }
        // Per-key in-flight validity token: a replace/cancel/reset/disable/enable on THIS
        // (device, kind) since the ceremony began invalidates it here, without any unrelated
        // device/kind ceremony being able to.
        let key = ChallengeKey(deviceID: pending.deviceID, kind: pending.kind)
        guard token(for: key) == pending.ceremonyToken else { throw RemotePasskeyFailure.challengeInvalid }
        // Per-principal invalidation generation: `invalidate(principal)` (disconnect/Lock) for THIS
        // principal rejects it, but an invalidation for a different (old) principal does not.
        guard principalGen(for: pending.principalConnectionID) == pending.principalGen else {
            throw RemotePasskeyFailure.challengeInvalid
        }
        guard now() < pending.expiresAt else { throw RemotePasskeyFailure.challengeInvalid }
        let snapshot = originSnapshot()
        guard let origin = snapshot.origin,
              origin == pending.origin,
              snapshot.generation == pending.originGeneration
        else {
            throw RemotePasskeyFailure.challengeInvalid
        }
        guard let device = (try? identityStore.device(id: pending.deviceID)) ?? nil else {
            throw RemotePasskeyFailure.challengeInvalid
        }
        guard !device.isRevoked,
              device.passkey.epoch == pending.epoch,
              device.passkey.state == .required
        else {
            throw RemotePasskeyFailure.challengeInvalid
        }
        switch pending.kind {
        case .registration:
            guard device.passkey.credential == nil else { throw RemotePasskeyFailure.challengeInvalid }
            // Re-check the EXACT authorization window that minted this challenge — not just policy
            // and origin. A cancelled/replaced/expired window (or one at a different epoch/origin)
            // rejects the completion even though the policy still reads required.
            guard let windowID = pending.windowID,
                  let window = windows[pending.deviceID],
                  window.id == windowID,
                  now() < window.expiresAt,
                  window.epoch == pending.epoch,
                  window.origin == pending.origin,
                  window.originGeneration == pending.originGeneration
            else {
                throw RemotePasskeyFailure.challengeInvalid
            }
        case .assertion:
            guard let credential = device.passkey.credential,
                  let boundID = pending.credentialID,
                  credential.credentialID == Data(boundID)
            else {
                throw RemotePasskeyFailure.challengeInvalid
            }
        }
    }

    private func prune() {
        let instant = now()
        windows = windows.filter { $0.value.expiresAt > instant }
        challenges = challenges.filter { $0.value.expiresAt > instant }
    }

    private func bump() {
        revision &+= 1
    }

    /// Current per-key in-flight token (0 if the key has never begun a ceremony).
    private func token(for key: ChallengeKey) -> UInt64 {
        ceremonyTokenByKey[key] ?? 0
    }

    /// Advance a single challenge key's in-flight validity token. Every already-consumed, suspended
    /// completion for that key captured the prior value and is rejected on its next
    /// `validateBinding`; other keys are untouched.
    private func bumpCeremonyToken(for key: ChallengeKey) {
        ceremonyTokenByKey[key, default: 0] &+= 1
    }

    /// Advance both ceremony kinds for one device (used by enable/reset/disable/openEnrollment, which
    /// change the device's policy and must invalidate any in-flight registration and assertion).
    private func invalidateCeremonies(forDevice deviceID: String) {
        bumpCeremonyToken(for: ChallengeKey(deviceID: deviceID, kind: .registration))
        bumpCeremonyToken(for: ChallengeKey(deviceID: deviceID, kind: .assertion))
    }

    /// Current per-principal invalidation generation (0 until the principal is invalidated).
    private func principalGen(for principalConnectionID: String) -> UInt64 {
        principalGenByPrincipal[principalConnectionID] ?? 0
    }

    /// Clear a ceremony's artifacts WITHOUT disturbing a newer ceremony: the challenge slot is
    /// cleared only when it still holds this ceremony, and the enrollment window only when it is
    /// still the exact window this ceremony was minted under. This prevents a stale completion from
    /// wiping a replacement window or challenge.
    private func clearCeremonyArtifacts(_ pending: PendingChallenge) {
        let key = ChallengeKey(deviceID: pending.deviceID, kind: pending.kind)
        if challenges[key]?.ceremonyID == pending.ceremonyID {
            challenges[key] = nil
        }
        // Clear the enrollment window ONLY when this ceremony still owns the latest registration
        // token for the device. A stale registration whose window id still matches but whose token
        // was superseded by a replacement begin must not delete the window the replacement is using.
        if let windowID = pending.windowID,
           windows[pending.deviceID]?.id == windowID,
           pending.ceremonyToken == token(for: key)
        {
            windows[pending.deviceID] = nil
        }
    }

    private func makeCeremonyID() -> String {
        Base64URL.encode(randomBytes(16))
    }

    private func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> TimeInterval {
        let components = start.duration(to: end).components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    /// The WebAuthn relying-party display name. Not security-relevant (RP ID / origin are what bind
    /// a ceremony), but it is surfaced to the authenticator, so it reflects the build channel.
    nonisolated static func defaultBuildLabel() -> String {
        RemoteControlBuildIdentity.current.channel == .debug ? "RepoPrompt Dev" : "RepoPrompt"
    }

    nonisolated static func secureRandomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0 ... 255)
            }
        }
        return bytes
    }

    private enum Base64URL {
        static func encode(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        static func encode(_ bytes: [UInt8]) -> String {
            encode(Data(bytes))
        }
    }
}
