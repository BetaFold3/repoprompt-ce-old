import Foundation

// MARK: - Device access authority (remote passkey unlock, Step 3)

// The gateway's SINGLE access authority. These types and operations extend the existing
// `DeviceAuthenticator` actor (no second actor, no second store): they coordinate shared per-device
// grants, lock generations, strict trust application/invalidation, pending ceremony/renewal bindings,
// and synchronous versioned publications to each connection's event-loop-owned sink.
//
// Each operation performs all of its authoritative work SYNCHRONOUSLY up front: it mutates state,
// allocates the publication revision, schedules every event-loop publication (via
// `sink.scheduleAuthorization`), and captures each transition's access notice at that revision — all
// before the first `await`. After an `await` only those already-captured values are used (an
// operation never re-reads mutable state post-suspension). Operations that publish return a
// `GatewayPublicationBarrier` — and, where a transition carries notices, the captured notices — that
// the caller settles OUTSIDE the mutation, so an acknowledgement is emitted only after every
// publication has crossed its loop barrier and the revision-gated notices are delivered. Network calls
// and the principal relay stay outside the actor; the ceremony/renewal APIs here take already-produced
// typed results and are driven by the live handler.
//
// The handler drives these operations from the live hello/verify/control path.

/// A registered connection: its event-loop-owned sink, immutable incarnation, lifecycle fence, and
/// bound principal. Actor-isolated; only mutated inside `DeviceAuthenticator`.
struct GatewayConnectionHandle {
    let connectionID: UUID
    let sink: GatewayWebSocketFrameSink
    let incarnation: UUID
    let fence: GatewayConnectionLifecycleFence
    /// Process-local, monotonically allocated per connection incarnation. Passed to the app at a
    /// ceremony begin and echoed at complete so a reconnect (fresh generation) cannot complete a
    /// ceremony begun on a prior connection. Never client-supplied.
    let connectionGeneration: UInt64
    var principal: GatewayAccessPrincipal
    var deviceID: String?
}

/// Per-device authoritative access state. The binding is derived from these fields; a lock, epoch,
/// origin, or launch change advances `lockGeneration`, which invalidates any grant/ceremony/renewal
/// bound to the old generation.
struct GatewayDeviceAccessRecord {
    var launchNonce: String
    var policyEpoch: UInt64
    var originRevision: UInt64
    var authoritativeOrigin: String?
    /// The device's registered public key (raw). A grant is bound to this key as well as to
    /// epoch/origin: a key rotation under the same device id is a security transition that must
    /// invalidate any live grant and advance the lock generation.
    var publicKeyRawRepresentation: Data
    /// Raw policy intent (required), independent of revocation. Used for the "any required policy
    /// blocks static access" rule even when the device is revoked.
    var policyRequired: Bool
    /// Projected enrollment state from the current trust snapshot's device policy. Carried so the
    /// hello_ack / lock_state access metadata can report it without re-reading the snapshot.
    var policyEnrolled: Bool
    var policyEnrollmentOpen: Bool
    var isRevoked: Bool
    var lockGeneration: UInt64
    /// Monotonic per-kind ceremony generation. Advanced on EVERY begin of that kind and NEVER cleared
    /// by take/verification, so a held completion for a superseded begin is rejected at commit even
    /// after its pending was consumed from the record: a later begin that replaced it has bumped this
    /// past the held pending's stamped generation (S3-I06 safe replacement).
    var assertionCeremonyGeneration: UInt64 = 0
    var registrationCeremonyGeneration: UInt64 = 0
    var grant: GatewayDeviceGrant?
    var expiryTimer: GatewayExpiryTimer?
    var pendingRegistration: GatewayPendingCeremony?
    var pendingAssertion: GatewayPendingCeremony?
    var pendingRenewal: GatewayPendingRenewal?
    var lastRenewalAttempt: GatewayMonotonicInstant?
    var renewalInFlight: Bool

    /// Grant-gating applies only to a required, non-revoked device.
    var isEnforced: Bool {
        policyRequired && !isRevoked
    }

    var binding: GatewayDeviceAccessBinding {
        GatewayDeviceAccessBinding(
            launchNonce: launchNonce,
            policyEpoch: policyEpoch,
            originRevision: originRevision,
            lockGeneration: lockGeneration,
            authoritativeOrigin: authoritativeOrigin
        )
    }
}

/// A pending principal-link ceremony, bound to the connection that initiated it and to the exact
/// policy/origin/lock generation in force at begin. Late results are validated against this.
struct GatewayPendingCeremony {
    let token: UUID
    let kind: GatewayCeremonyKind
    let initiatingConnectionID: UUID
    let initiatingIncarnation: UUID
    /// The initiating connection's process-local generation. The app echoes it at completion; a
    /// completion whose generation does not match cannot consume this pending.
    let connectionGeneration: UInt64
    let fence: GatewayConnectionLifecycleFence
    let binding: GatewayDeviceAccessBinding
    let lockGeneration: UInt64
    /// Monotonic time the pending was created (begin). Used to bound an abandoned/prefetched ceremony's
    /// lifetime so it cannot permanently occupy the one-pending-per-kind slot (S3-I06).
    let createdAt: GatewayMonotonicInstant
    /// The per-kind ceremony generation in force at begin. `commitVerified*` require this to still
    /// equal the record's CURRENT per-kind generation, so a held completion for a begin that was later
    /// REPLACED by a fresh begin cannot clobber the fresh one (S3-I06 safe replacement).
    let ceremonyGeneration: UInt64
    /// The app-issued ceremony identifier, attached after the principal relay's begin returns. The
    /// gateway dispatches completion by THIS value (plus the internal request context), never by a
    /// client-supplied ceremony id. `nil` until the begin round-trip attaches it.
    var appCeremonyID: String?
}

/// A pending activity renewal: captured activity time, the grant/binding/generation it targets, and
/// the original deadline it may not outlive.
struct GatewayPendingRenewal {
    let token: UUID
    let grantID: String
    let capturedActivityTime: GatewayMonotonicInstant
    let binding: GatewayDeviceAccessBinding
    let lockGeneration: UInt64
    let originalDeadline: GatewayMonotonicInstant
    let initiatingConnectionID: UUID
    let initiatingIncarnation: UUID
}

/// Result of admitting an activity-renewal request.
enum GatewayActivityAdmission: Equatable {
    case accepted(token: UUID)
    case throttled
    case noLiveGrant
}

/// A captured access-state notice (S3-I02): the sanitized `lock_state` metadata built AT a transition's
/// EXACT revision, bound to that revision and target connection. It is delivered only AFTER the
/// transition's all-sink authorization barrier settles, and only while the connection has NOT applied a
/// newer revision — so a notice can never precede its own cross-tab barrier, and a superseded notice is
/// dropped (the superseding transition publishes its own). The metadata is captured SYNCHRONOUSLY at
/// mutation; it is never re-read from newer current state under this older receipt.
struct CapturedAccessNotice {
    let sink: GatewayWebSocketFrameSink
    let incarnation: UUID
    let revision: GatewayPublicationRevision
    let envelope: GatewaySafeControlEnvelope
}

/// One authorization transition captured at a single revision: the authorization receipts for the
/// affected connections plus the revision-bound access-state notices to deliver after the barrier.
struct CapturedTransition {
    let authReceipts: [GatewayBarrierReceipt]
    let notices: [CapturedAccessNotice]
}

/// Result of committing a verified assertion. `installedGrant` is true ONLY when THIS commit installed
/// the fresh grant under the initiating fence; the handler uses it to decide whether to send a
/// ceremony-completion acknowledgement, rather than probing `hasGrant` (which could be true because a
/// different, concurrent ceremony installed a grant while this one was rejected as stale). `barrier`
/// covers only the authorization change; `capturedNotices` are the S3-I02 revision-bound access-state
/// notices the handler flushes via `deliverGatedNotices` AFTER sending `ceremony_complete`, so the
/// correlated completion frame is not skipped as an access-state notice by the initiating socket.
struct GatewayAssertionCommitOutcome {
    let barrier: GatewayPublicationBarrier
    let installedGrant: Bool
    let capturedNotices: [CapturedAccessNotice]

    static let notInstalled = GatewayAssertionCommitOutcome(barrier: .empty, installedGrant: false, capturedNotices: [])
}

/// A read-only view of a connection's CURRENT authorization, used by the handler to apply the
/// inbound lock gate and to stamp a correlated request's admission binding without publishing a new
/// revision.
struct GatewayConnectionAccessView: Equatable {
    let principal: GatewayAccessPrincipal
    let deviceID: String?
    let access: GatewayAccess
    let binding: GatewayDeviceAccessBinding?
    let revision: GatewayPublicationRevision

    /// True when protected content is currently denied (required policy, no live grant).
    var isLocked: Bool {
        access == .locked
    }
}

extension DeviceAuthenticator {
    // MARK: Trust application / invalidation

    /// Apply a strict capability-1 trust snapshot. Unchanged valid refreshes preserve grants and
    /// deadlines; a launch/epoch/origin change (or a device leaving trust, or dropping out of required
    /// policy) invalidates that device's grant and pending work and advances its lock generation. A
    /// valid snapshot with required policy and a null origin is a valid LOCKED state, not malformed.
    func applyCapabilityTrust(_ snapshot: GatewayCapabilityTrustSnapshot) async -> GatewayPublicationBarrier {
        capabilityTrust = .valid(snapshot)
        var seen: Set<String> = []
        for device in snapshot.devices.values {
            seen.insert(device.deviceID)
            let newLaunch = snapshot.trustRevision.launch
            let newEpoch = device.policy.epoch
            let newOriginRevision = snapshot.originRevision
            let newOrigin = snapshot.authoritativeOrigin
            if var record = deviceAccess[device.deviceID] {
                // Invalidate ONLY on an actual security transition. An unchanged policy-off (or any
                // unchanged) device must keep its lock generation stable across every ~15s poll, so a
                // long-running ordinary response admitted under unchanged policy is not spuriously
                // invalidated. Security transitions are: launch/epoch/origin identity change, a
                // required↔off policy flip, a revocation change, or a device-key rotation.
                let identityChanged = record.launchNonce != newLaunch
                    || record.policyEpoch != newEpoch
                    || record.originRevision != newOriginRevision
                    || record.authoritativeOrigin != newOrigin
                let policyRequiredChanged = record.policyRequired != device.policy.isRequired
                let revokedChanged = record.isRevoked != device.isRevoked
                let keyRotated = record.publicKeyRawRepresentation != device.publicKeyRawRepresentation
                record.launchNonce = newLaunch
                record.policyEpoch = newEpoch
                record.originRevision = newOriginRevision
                record.authoritativeOrigin = newOrigin
                record.policyRequired = device.policy.isRequired
                record.policyEnrolled = device.policy.enrolled
                record.policyEnrollmentOpen = device.policy.enrollmentOpen
                record.isRevoked = device.isRevoked
                record.publicKeyRawRepresentation = device.publicKeyRawRepresentation
                if identityChanged || policyRequiredChanged || revokedChanged || keyRotated {
                    invalidateAccess(&record)
                }
                deviceAccess[device.deviceID] = record
            } else {
                deviceAccess[device.deviceID] = GatewayDeviceAccessRecord(
                    launchNonce: newLaunch,
                    policyEpoch: newEpoch,
                    originRevision: newOriginRevision,
                    authoritativeOrigin: newOrigin,
                    publicKeyRawRepresentation: device.publicKeyRawRepresentation,
                    policyRequired: device.policy.isRequired,
                    policyEnrolled: device.policy.enrolled,
                    policyEnrollmentOpen: device.policy.enrollmentOpen,
                    isRevoked: device.isRevoked,
                    lockGeneration: 0,
                    grant: nil,
                    expiryTimer: nil,
                    pendingRegistration: nil,
                    pendingAssertion: nil,
                    pendingRenewal: nil,
                    lastRenewalAttempt: nil,
                    renewalInFlight: false
                )
            }
        }
        for deviceID in deviceAccess.keys where !seen.contains(deviceID) {
            if var record = deviceAccess[deviceID] {
                invalidateAccess(&record)
                deviceAccess[deviceID] = nil
            }
        }
        // S3-I02/I03: republish the authorization to ALL connections at ONE revision, and capture the
        // CURRENT access metadata for EVERY bound PAIRED connection at that SAME revision — before any
        // await. The republish advances every sink's applied revision, which by itself would DROP an
        // older captured unlock/Lock notice via the revision gate; capturing a notice for every paired
        // connection here guarantees a replacement carrying the current state and grant references
        // lands at the same all-sink barrier, so a refresh that overtakes an in-flight transition's
        // notice can never leave the browser locked-looking without grant refs. This mirrors CURRENT
        // state only — it does NOT renew any grant deadline. Consequently an unchanged ~15s refresh
        // re-emits a content-free `lock_state`; that is acceptable ("silent refresh" is explicitly NOT
        // a Step-3 goal — Step 4 will dedupe unchanged state/refs). Static-developer connections are
        // not paired and carry no grant metadata, so they get the authorization republish but no notice.
        let revision = nextPublicationRevision()
        let pairedDeviceIDs = Set(handles.values.compactMap { handle -> String? in
            if case let .pairedDevice(deviceID) = handle.principal { return deviceID }
            return nil
        })
        var notices: [CapturedAccessNotice] = []
        for deviceID in pairedDeviceIDs {
            notices.append(contentsOf: captureNotices(toDevice: deviceID, revision: revision, reason: nil))
        }
        let transition = CapturedTransition(
            authReceipts: scheduleAuthorization(forAllConnectionsAt: revision),
            notices: notices
        )
        return await settleAndPublishGatedNotices(transition)
    }

    /// Authoritative invalidity (malformed/unsupported authoritative response, registry-unavailable
    /// response, or authoritative tool failure). Erases grants/pending work and denies admission. A
    /// transport failure must NOT call this — the caller preserves the last-valid snapshot instead.
    func invalidateTrust() -> GatewayPublicationBarrier {
        capabilityTrust = .invalid
        for (deviceID, var record) in deviceAccess {
            invalidateAccess(&record)
            deviceAccess[deviceID] = record
        }
        return publishToAllConnections()
    }

    // MARK: Connection membership

    /// Register a connection handle and publish its current authorization. Returns the barrier for
    /// that single publication.
    func bindConnection(
        connectionID: UUID,
        sink: GatewayWebSocketFrameSink,
        principal: GatewayAccessPrincipal,
        connectionGeneration: UInt64
    ) -> GatewayPublicationBarrier {
        let deviceID: String? = if case let .pairedDevice(id) = principal {
            id
        } else {
            nil
        }
        let handle = GatewayConnectionHandle(
            connectionID: connectionID,
            sink: sink,
            incarnation: sink.incarnation,
            fence: sink.fence,
            connectionGeneration: connectionGeneration,
            principal: principal,
            deviceID: deviceID
        )
        handles[connectionID] = handle
        let revision = nextPublicationRevision()
        let receipt = handle.sink.scheduleAuthorization(
            authorizationSnapshot(for: handle, revision: revision),
            expectedIncarnation: handle.incarnation
        )
        return GatewayPublicationBarrier(receipts: [receipt])
    }

    /// Remove a connection handle. Invalidates only the pending ceremony/renewal INITIATED by this
    /// connection; an already-established shared device grant SURVIVES a routine disconnect.
    func detachConnection(_ connectionID: UUID) {
        guard let handle = handles.removeValue(forKey: connectionID) else { return }
        guard let deviceID = handle.deviceID, var record = deviceAccess[deviceID] else { return }
        if let pending = record.pendingAssertion, pending.initiatingConnectionID == connectionID {
            record.pendingAssertion = nil
        }
        if let pending = record.pendingRegistration, pending.initiatingConnectionID == connectionID {
            record.pendingRegistration = nil
        }
        if let renewal = record.pendingRenewal, renewal.initiatingConnectionID == connectionID {
            record.pendingRenewal = nil
            record.renewalInFlight = false
        }
        deviceAccess[deviceID] = record
    }

    // MARK: Ceremonies

    /// Begin an assertion ceremony bound to the initiating connection and current policy/generation.
    /// Returns a fresh server token, or nil only when no ceremony can start (trust not valid, the
    /// device not enforced, or no authoritative origin). An already-pending assertion does NOT block a
    /// fresh begin: S3-I06 safe replacement caps one pending per kind and replaces it, advancing the
    /// per-kind generation so the superseded begin's held completion is rejected at commit.
    func beginAssertionCeremony(deviceID: String, connectionID: UUID) -> UUID? {
        beginCeremony(kind: .assertion, deviceID: deviceID, connectionID: connectionID)
    }

    /// Begin a registration ceremony. Registration NEVER installs a grant.
    func beginRegistrationCeremony(deviceID: String, connectionID: UUID) -> UUID? {
        beginCeremony(kind: .registration, deviceID: deviceID, connectionID: connectionID)
    }

    /// Commit a verified assertion. Installs a fresh shared grant (deadline = commit time + idle
    /// lifetime) and publishes to ALL of the device's connections ONLY when every check holds: the
    /// pending token matches, the binding and lock generation are unchanged since begin, the result is
    /// a verified assertion for the current epoch, and the initiating connection's fence is still
    /// active. A new assertion always creates a NEW grant identifier.
    func commitAssertion(
        deviceID: String,
        token: UUID,
        result: GatewayCeremonyResult,
        committedAt: GatewayMonotonicInstant
    ) async -> GatewayPublicationBarrier {
        guard var record = deviceAccess[deviceID],
              let pending = record.pendingAssertion,
              pending.token == token,
              pending.kind == .assertion
        else {
            return .empty
        }
        // Consume eligibility first so a duplicate completion cannot reuse it.
        record.pendingAssertion = nil
        guard pending.binding == record.binding, pending.lockGeneration == record.lockGeneration else {
            deviceAccess[deviceID] = record
            return .empty
        }
        guard case let .assertionVerified(epoch) = result, epoch == record.policyEpoch else {
            deviceAccess[deviceID] = record
            return .empty
        }
        guard let transition = installAssertionGrant(deviceID: deviceID, record: record, pending: pending, committedAt: committedAt) else {
            return .empty
        }
        return await settleAndPublishGatedNotices(transition)
    }

    /// Consume a pending assertion's completion eligibility BEFORE async verification. Matches on the
    /// app-issued ceremony id and the echoing connection generation, so a concurrent replay of the
    /// same completion cannot dispatch a second verification. The removed pending is returned for the
    /// subsequent `commitVerifiedAssertion` after the principal relay confirms the credential.
    func takePendingAssertion(deviceID: String, appCeremonyID: String, connectionGeneration: UInt64) -> GatewayPendingCeremony? {
        takePendingCeremony(kind: .assertion, deviceID: deviceID, appCeremonyID: appCeremonyID, connectionGeneration: connectionGeneration)
    }

    /// Consume a pending registration's completion eligibility (same one-shot rule as assertions).
    func takePendingRegistration(deviceID: String, appCeremonyID: String, connectionGeneration: UInt64) -> GatewayPendingCeremony? {
        takePendingCeremony(kind: .registration, deviceID: deviceID, appCeremonyID: appCeremonyID, connectionGeneration: connectionGeneration)
    }

    /// Commit an assertion the principal app verified. `pending` is the value returned by
    /// `takePendingAssertion` (already removed from the record). Re-validates the binding and lock
    /// generation against the CURRENT record so a replacement that landed during verification is not
    /// clobbered by a stale success, requires the verified epoch to match the current policy epoch,
    /// and installs a fresh grant under the initiating fence.
    func commitVerifiedAssertion(
        deviceID: String,
        pending: GatewayPendingCeremony,
        verifiedEpoch: UInt64,
        committedAt: GatewayMonotonicInstant
    ) async -> GatewayAssertionCommitOutcome {
        guard let record = deviceAccess[deviceID] else { return .notInstalled }
        // S3-I06: the held pending's per-kind ceremony generation must still match the record's CURRENT
        // generation. A fresh begin that replaced this ceremony advanced the generation, so a stale
        // held completion is rejected here and cannot clobber the replacement (binding/lockGeneration
        // alone do not catch a replacement that kept the same binding). Rejection does not touch
        // `record.pendingAssertion`, so the replacement pending is preserved.
        guard pending.kind == .assertion,
              pending.ceremonyGeneration == record.assertionCeremonyGeneration,
              pending.binding == record.binding,
              pending.lockGeneration == record.lockGeneration,
              verifiedEpoch == record.policyEpoch
        else {
            return .notInstalled
        }
        guard let transition = installAssertionGrant(deviceID: deviceID, record: record, pending: pending, committedAt: committedAt) else {
            return .notInstalled
        }
        // S3-I02: settle the unlock authorization's all-sink barrier here, but do NOT deliver the
        // access-state notices yet. The handler sends `ceremony_complete` first, then flushes the
        // captured notices via `deliverGatedNotices`, so the correlated completion frame is not
        // consumed as an access-state notice by the initiating socket. Delivery stays revision-gated,
        // so a transition that supersedes this unlock before the flush drops the stale notice.
        let authBarrier = GatewayPublicationBarrier(receipts: transition.authReceipts)
        await authBarrier.settle()
        return GatewayAssertionCommitOutcome(barrier: authBarrier, installedGrant: true, capturedNotices: transition.notices)
    }

    /// Attach the app-issued ceremony id returned by the relay's begin to the pending ceremony begun
    /// on this connection. Returns false (handler must abort) if the pending is gone, already carries
    /// an id, changed binding/generation since begin, or its initiating fence closed.
    func attachAssertionCeremonyAppID(deviceID: String, token: UUID, appCeremonyID: String) -> Bool {
        attachCeremonyAppID(kind: .assertion, deviceID: deviceID, token: token, appCeremonyID: appCeremonyID)
    }

    func attachRegistrationCeremonyAppID(deviceID: String, token: UUID, appCeremonyID: String) -> Bool {
        attachCeremonyAppID(kind: .registration, deviceID: deviceID, token: token, appCeremonyID: appCeremonyID)
    }

    /// Commit a registration result. Never installs a grant; a subsequent fresh assertion is required.
    /// Returns whether the registration was accepted. The post-registration trust refresh and the
    /// enrollment-confirmed completion are driven by the handler (`runCeremonyComplete`, B17/S3-A-17),
    /// not here — this method only reports acceptance of the ceremony result.
    func commitRegistration(deviceID: String, token: UUID, result: GatewayCeremonyResult) -> Bool {
        guard var record = deviceAccess[deviceID],
              let pending = record.pendingRegistration,
              pending.token == token,
              pending.kind == .registration
        else {
            return false
        }
        record.pendingRegistration = nil
        defer { deviceAccess[deviceID] = record }
        guard pending.binding == record.binding, pending.lockGeneration == record.lockGeneration else {
            return false
        }
        guard pending.fence.isActive else { return false }
        if case .registrationCompleted = result {
            return true
        }
        return false
    }

    /// Commit a registration the principal app verified. `pending` is the value returned by
    /// `takePendingRegistration`. NEVER installs a grant — a fresh assertion is still required — and
    /// re-validates the binding/generation and initiating fence against the current record.
    func commitVerifiedRegistration(deviceID: String, pending: GatewayPendingCeremony) -> Bool {
        guard let record = deviceAccess[deviceID] else { return false }
        // S3-I06: reject a held completion whose per-kind generation was superseded by a later begin.
        // Rejection does not touch `record.pendingRegistration`, so the replacement is preserved.
        guard pending.kind == .registration,
              pending.ceremonyGeneration == record.registrationCeremonyGeneration,
              pending.binding == record.binding,
              pending.lockGeneration == record.lockGeneration,
              pending.fence.isActive
        else {
            return false
        }
        return true
    }

    // MARK: Lock & expiry

    /// Lock a device: advance its lock generation, remove its grant, cancel its expiry timer,
    /// invalidate pending ceremony/renewal, publish the locked state to all of its connections, and
    /// notify each connection with a content-free `lock_state` frame.
    func lockDevice(_ deviceID: String) async -> GatewayPublicationBarrier {
        guard var record = deviceAccess[deviceID] else { return .empty }
        // A lock applies only to an ENFORCED (required, non-revoked) device. A policy-off or revoked
        // device has no grant to drop; advancing its lock generation would spuriously settle its
        // in-flight UNPROTECTED responses as "locked" (S3-A-13). Ignore the lock for such devices.
        guard record.isEnforced else { return .empty }
        invalidateAccess(&record)
        deviceAccess[deviceID] = record
        // S3-I02: publish the lock authorization and the `locked` notice as ONE revision-bound
        // transition — schedule the authorization change to every tab, settle the all-sink barrier,
        // then deliver the notice only to connections still at this revision. A concurrent unlock is a
        // NEWER revision: it supersedes this locked notice (dropped here) and publishes its own.
        return await publishDeviceTransition(deviceID, reason: .locked)
    }

    /// Current authorization view for one connection (no new publication). Returns nil if the
    /// connection is not bound.
    func accessView(forConnection connectionID: UUID) -> GatewayConnectionAccessView? {
        guard let handle = handles[connectionID] else { return nil }
        let snapshot = authorizationSnapshot(for: handle, revision: publicationRevision)
        return GatewayConnectionAccessView(
            principal: snapshot.principal,
            deviceID: handle.deviceID,
            access: snapshot.access,
            binding: snapshot.binding,
            revision: snapshot.publicationRevision
        )
    }

    /// Discard a still-pending ceremony begun by a connection whose relay begin failed, so its slot is
    /// released eagerly instead of lingering until the pending's bounded lifetime expires. (A later
    /// begin of the same kind always replaces the pending via safe replacement, so this is not needed
    /// to unblock a retry; it just frees the stale slot promptly on failure.) No-op unless the token
    /// still matches the live pending.
    func discardPendingAssertion(deviceID: String, token: UUID) {
        guard var record = deviceAccess[deviceID], record.pendingAssertion?.token == token else { return }
        record.pendingAssertion = nil
        deviceAccess[deviceID] = record
    }

    func discardPendingRegistration(deviceID: String, token: UUID) {
        guard var record = deviceAccess[deviceID], record.pendingRegistration?.token == token else { return }
        record.pendingRegistration = nil
        deviceAccess[deviceID] = record
    }

    /// Expire a grant. Guarded by grant id AND expected deadline so a stale timer cannot expire a
    /// renewed grant. On a match: clears the grant, invalidates pending renewal, advances lock
    /// generation, and publishes the locked state.
    func expireGrant(
        deviceID: String,
        grantID: String,
        expectedDeadline: GatewayMonotonicInstant
    ) async -> GatewayPublicationBarrier {
        guard var record = deviceAccess[deviceID],
              let grant = record.grant,
              grant.id == grantID,
              grant.deadline == expectedDeadline
        else {
            return .empty
        }
        invalidateAccess(&record)
        deviceAccess[deviceID] = record
        // A delayed idle-timer expiry is not connection-driven: publish the locked authorization and
        // the `expired` notice as one revision-bound transition (S3-I02). A concurrent unlock is a
        // newer revision and suppresses this stale expiry notice.
        return await publishDeviceTransition(deviceID, reason: .grantExpired)
    }

    // MARK: Activity renewal (authority request/commit)

    /// Admit an activity-renewal request: at most one in flight and at most one per 30 seconds per
    /// device, only against a live current grant. Captures the activity-acceptance time.
    func beginActivityRenewal(
        deviceID: String,
        grantID: String,
        connectionID: UUID,
        at now: GatewayMonotonicInstant
    ) -> GatewayActivityAdmission {
        guard let handle = handles[connectionID], handle.deviceID == deviceID else { return .noLiveGrant }
        guard var record = deviceAccess[deviceID],
              let grant = record.grant,
              grant.id == grantID,
              now < grant.deadline
        else {
            return .noLiveGrant
        }
        if record.renewalInFlight {
            return .throttled
        }
        let minInterval = GatewayMonotonicInstant.nanoseconds(from: GatewayAccessTiming.renewalMinInterval)
        if let last = record.lastRenewalAttempt,
           now.nanosecondsSinceBase &- last.nanosecondsSinceBase < minInterval
        {
            return .throttled
        }
        let token = UUID()
        record.lastRenewalAttempt = now
        record.renewalInFlight = true
        record.pendingRenewal = GatewayPendingRenewal(
            token: token,
            grantID: grantID,
            capturedActivityTime: now,
            binding: record.binding,
            lockGeneration: record.lockGeneration,
            originalDeadline: grant.deadline,
            initiatingConnectionID: connectionID,
            initiatingIncarnation: handle.incarnation
        )
        deviceAccess[deviceID] = record
        return .accepted(token: token)
    }

    /// Commit an activity renewal after its OWN fresh trust refresh. On transport failure the original
    /// deadline is preserved unchanged. On success the deadline becomes captured-activity-time + idle
    /// lifetime (NOT network-response time), and a refresh finishing at or after the old deadline
    /// cannot revive the grant. Binding/generation must be unchanged and the same grant still current.
    func commitActivityRenewal(deviceID: String, token: UUID, refreshSucceeded: Bool) async -> GatewayPublicationBarrier {
        guard var record = deviceAccess[deviceID],
              let pending = record.pendingRenewal,
              pending.token == token
        else {
            return .empty
        }
        record.pendingRenewal = nil
        record.renewalInFlight = false
        guard refreshSucceeded else {
            deviceAccess[deviceID] = record
            return .empty
        }
        guard pending.binding == record.binding,
              pending.lockGeneration == record.lockGeneration,
              let grant = record.grant,
              grant.id == pending.grantID
        else {
            deviceAccess[deviceID] = record
            return .empty
        }
        guard accessClock.now() < pending.originalDeadline else {
            deviceAccess[deviceID] = record
            return .empty
        }
        // The initiating connection must still be bound with the same incarnation, and the renewed
        // deadline is installed ATOMICALLY under its fence (same linearization guarantee as
        // `commitAssertion`): a concurrent disconnect cannot slip between the checks and the install.
        guard let handle = handles[pending.initiatingConnectionID],
              handle.incarnation == pending.initiatingIncarnation
        else {
            deviceAccess[deviceID] = record
            return .empty
        }
        let transition = handle.fence.withActive { () -> CapturedTransition in
            let renewed = GatewayDeviceGrant(
                id: grant.id,
                deadline: pending.capturedActivityTime.advanced(by: GatewayAccessTiming.idleGrantLifetime)
            )
            record.grant = renewed
            record.expiryTimer?.cancel()
            record.expiryTimer = scheduleGrantExpiry(deviceID: deviceID, grant: renewed)
            deviceAccess[deviceID] = record
            // S3-I02: capture the renewal authorization AND notice at one revision under the fence,
            // then settle and deliver the still-current notice below.
            let revision = nextPublicationRevision()
            return CapturedTransition(
                authReceipts: scheduleAuthorization(forDevice: deviceID, revision: revision),
                notices: captureNotices(toDevice: deviceID, revision: revision, reason: nil)
            )
        }
        guard let transition else {
            deviceAccess[deviceID] = record
            return .empty
        }
        return await settleAndPublishGatedNotices(transition)
    }

    // MARK: Test / integration read accessors

    func accessTrustAvailability() -> GatewayCapabilityTrustAvailability {
        capabilityTrust
    }

    func hasGrant(forDevice deviceID: String) -> Bool {
        deviceAccess[deviceID]?.grant != nil
    }

    func grantDeadline(forDevice deviceID: String) -> GatewayMonotonicInstant? {
        deviceAccess[deviceID]?.grant?.deadline
    }

    func grantID(forDevice deviceID: String) -> String? {
        deviceAccess[deviceID]?.grant?.id
    }

    func lockGeneration(forDevice deviceID: String) -> UInt64? {
        deviceAccess[deviceID]?.lockGeneration
    }

    func pendingAssertionToken(forDevice deviceID: String) -> UUID? {
        deviceAccess[deviceID]?.pendingAssertion?.token
    }

    /// Whether the device is enrolled under a currently VALID trust snapshot at or beyond `epoch`
    /// (B17/S3-A-17). A registration completion is reported as success only when the authority's OWN
    /// refreshed state confirms enrollment here at an epoch no older than the committed result; a
    /// stale, lower-epoch, revoked, or not-yet-valid snapshot yields false and the handler reports a
    /// generic unavailable completion instead of a false success.
    func isDeviceEnrolled(deviceID: String, atLeastEpoch epoch: UInt64) -> Bool {
        guard case .valid = capabilityTrust, let record = deviceAccess[deviceID], !record.isRevoked else { return false }
        return record.policyEnrolled && record.policyEpoch >= epoch
    }

    func staticAccessAllowed() -> Bool {
        guard case let .valid(snapshot) = capabilityTrust else { return false }
        return !snapshot.hasAnyRequiredPolicy
    }

    /// Connection IDs the authority can no longer authorize AT ALL and that the server must close:
    /// a static-developer connection once static access is denied (any required policy, or trust not
    /// valid), and a paired connection whose trust is no longer valid, whose device left trust, or
    /// whose device is revoked. A paired connection that is merely LOCKED under a required policy is
    /// NOT included — it can still unlock via a ceremony. Unbound (mid-hello) connections are left
    /// alone. (Step 3: main calls the server's `closeAccessDeniedConnections()` after an invalidation
    /// or required-policy barrier settles.)
    func accessDeniedConnectionIDs() -> [UUID] {
        handles.values.compactMap { handle in
            accessDenied(for: handle) ? handle.connectionID : nil
        }
    }

    /// Whether a single connection can no longer be authorized AT ALL (the hello-time recheck after
    /// `ensureLink`): same rule as `accessDeniedConnectionIDs`, applied to one connection. A merely
    /// LOCKED paired connection under required policy is NOT denied — it can still unlock. Returns
    /// false for an unbound or unknown connection.
    func accessDenied(forConnection connectionID: UUID) -> Bool {
        guard let handle = handles[connectionID] else { return false }
        return accessDenied(for: handle)
    }

    /// Current access metadata for one connection, used to assemble hello_ack / lock_state. `reason`
    /// is attached only for a lock_state notification. Returns nil if the connection is not bound.
    func accessMetadata(forConnection connectionID: UUID, reason: GatewaySafeControlReason? = nil) -> GatewayAccessMetadata? {
        guard let handle = handles[connectionID] else { return nil }
        return accessMetadata(for: handle, reason: reason)
    }

    // MARK: Private helpers

    private func beginCeremony(kind: GatewayCeremonyKind, deviceID: String, connectionID: UUID) -> UUID? {
        // Never begin a ceremony against invalid or not-yet-available authority: `invalidateTrust`
        // clears grants but leaves a record's `policyRequired`/`isRevoked` intact, so `isEnforced`
        // alone can still be true. Require the current authority to be valid first.
        guard case .valid = capabilityTrust else { return nil }
        guard let handle = handles[connectionID], handle.deviceID == deviceID else { return nil }
        guard var record = deviceAccess[deviceID], record.isEnforced else { return nil }
        // A usable authoritative HTTPS origin is required to bind the ceremony's challenge; a
        // required-but-null-origin device is a valid locked state that cannot yet run a ceremony.
        guard record.authoritativeOrigin != nil else { return nil }
        // SAFE REPLACEMENT (S3-I06): a fresh begin ALWAYS replaces any existing pending of this kind
        // (cap one per device/kind) and ADVANCES the per-kind ceremony generation. The generation is
        // stamped on the new pending and survives take/verification, so a held completion for the
        // superseded begin is rejected at commit and can never clobber this one. The gateway therefore
        // never impedes the per-kind app coordinator's own replace: a cancelled native prompt or an
        // expired app challenge retries at once, without a lock, disconnect, or an invented wait.
        let now = accessClock.now()
        let generation: UInt64
        switch kind {
        case .assertion:
            record.assertionCeremonyGeneration &+= 1
            generation = record.assertionCeremonyGeneration
        case .registration:
            record.registrationCeremonyGeneration &+= 1
            generation = record.registrationCeremonyGeneration
        }
        let token = UUID()
        let pending = GatewayPendingCeremony(
            token: token,
            kind: kind,
            initiatingConnectionID: connectionID,
            initiatingIncarnation: handle.incarnation,
            connectionGeneration: handle.connectionGeneration,
            fence: handle.fence,
            binding: record.binding,
            lockGeneration: record.lockGeneration,
            createdAt: now,
            ceremonyGeneration: generation,
            appCeremonyID: nil
        )
        switch kind {
        case .assertion: record.pendingAssertion = pending
        case .registration: record.pendingRegistration = pending
        }
        deviceAccess[deviceID] = record
        return token
    }

    /// Install a fresh shared grant and schedule publications ATOMICALLY under the initiating fence
    /// lock, so a concurrent disconnect of the initiating ceremony (which closes the fence on another
    /// thread) cannot linearize between a liveness check and the install and revive a shared grant.
    /// The fence lock serializes this commit against `close()`: either the disconnect is ordered first
    /// (`withActive` returns nil, no grant) or the commit completes while the connection was still
    /// active. Nothing inside re-acquires this fence's lock, so there is no recursion. The caller has
    /// already consumed the pending from the record; `record` is persisted in both branches.
    private func installAssertionGrant(
        deviceID: String,
        record: GatewayDeviceAccessRecord,
        pending: GatewayPendingCeremony,
        committedAt: GatewayMonotonicInstant
    ) -> CapturedTransition? {
        var record = record
        let transition = pending.fence.withActive { () -> CapturedTransition in
            let grant = GatewayDeviceGrant(
                id: UUID().uuidString,
                deadline: committedAt.advanced(by: GatewayAccessTiming.idleGrantLifetime)
            )
            record.grant = grant
            record.expiryTimer?.cancel()
            record.expiryTimer = scheduleGrantExpiry(deviceID: deviceID, grant: grant)
            deviceAccess[deviceID] = record
            // S3-I02: capture the unlock authorization AND notice at one revision under the fence; the
            // async caller settles the barrier and delivers the still-current notice.
            let revision = nextPublicationRevision()
            return CapturedTransition(
                authReceipts: scheduleAuthorization(forDevice: deviceID, revision: revision),
                notices: captureNotices(toDevice: deviceID, revision: revision, reason: nil)
            )
        }
        if transition == nil {
            // Fence closed: the pending stays consumed and no grant is installed.
            deviceAccess[deviceID] = record
        }
        return transition
    }

    private func takePendingCeremony(
        kind: GatewayCeremonyKind,
        deviceID: String,
        appCeremonyID: String,
        connectionGeneration: UInt64
    ) -> GatewayPendingCeremony? {
        guard var record = deviceAccess[deviceID] else { return nil }
        let pending: GatewayPendingCeremony? = switch kind {
        case .assertion: record.pendingAssertion
        case .registration: record.pendingRegistration
        }
        guard let pending,
              pending.kind == kind,
              let boundID = pending.appCeremonyID,
              boundID == appCeremonyID,
              pending.connectionGeneration == connectionGeneration,
              !pendingCeremonyExpired(pending, now: accessClock.now())
        else {
            return nil
        }
        switch kind {
        case .assertion: record.pendingAssertion = nil
        case .registration: record.pendingRegistration = nil
        }
        deviceAccess[deviceID] = record
        return pending
    }

    private func attachCeremonyAppID(
        kind: GatewayCeremonyKind,
        deviceID: String,
        token: UUID,
        appCeremonyID: String
    ) -> Bool {
        guard var record = deviceAccess[deviceID] else { return false }
        let existing: GatewayPendingCeremony? = switch kind {
        case .assertion: record.pendingAssertion
        case .registration: record.pendingRegistration
        }
        guard var ceremony = existing, ceremony.token == token, ceremony.kind == kind else { return false }
        guard ceremony.appCeremonyID == nil else { return false }
        guard ceremony.binding == record.binding, ceremony.lockGeneration == record.lockGeneration else {
            return false
        }
        guard ceremony.fence.isActive else { return false }
        ceremony.appCeremonyID = appCeremonyID
        switch kind {
        case .assertion: record.pendingAssertion = ceremony
        case .registration: record.pendingRegistration = ceremony
        }
        deviceAccess[deviceID] = record
        return true
    }

    /// Whether a prefetched pending ceremony has outlived its bounded lifetime and is therefore no
    /// longer eligible for completion when it is taken (S3-I06). (Replacement by a newer begin of the
    /// same kind is always allowed regardless; this gate only rejects completing a stale pending.)
    private func pendingCeremonyExpired(_ pending: GatewayPendingCeremony, now: GatewayMonotonicInstant) -> Bool {
        let lifetime: Duration = switch pending.kind {
        case .assertion: GatewayAccessTiming.assertionPendingLifetime
        case .registration: GatewayAccessTiming.registrationPendingLifetime
        }
        return now >= pending.createdAt.advanced(by: lifetime)
    }

    private func invalidateAccess(_ record: inout GatewayDeviceAccessRecord) {
        record.grant = nil
        record.expiryTimer?.cancel()
        record.expiryTimer = nil
        record.pendingRegistration = nil
        record.pendingAssertion = nil
        record.pendingRenewal = nil
        record.renewalInFlight = false
        record.lockGeneration &+= 1
    }

    private func accessDenied(for handle: GatewayConnectionHandle) -> Bool {
        switch handle.principal {
        case .unbound:
            return false
        case .staticDeveloper:
            return !staticAccessAllowed()
        case let .pairedDevice(deviceID):
            guard case .valid = capabilityTrust else { return true }
            guard let record = deviceAccess[deviceID] else { return true }
            return record.isRevoked
        }
    }

    /// Build the bounded, allowlisted access metadata for one connection from its principal and the
    /// current record. Mirrors `authorizationSnapshot`'s access decision so hello_ack / lock_state
    /// report exactly what the sink will enforce.
    private func accessMetadata(for handle: GatewayConnectionHandle, reason: GatewaySafeControlReason?) -> GatewayAccessMetadata {
        switch handle.principal {
        case .unbound:
            return GatewayAccessMetadata(
                policyState: .required, locked: true, enrolled: false, enrollmentOpen: false,
                reason: reason, grantID: nil, epoch: 0, lockGeneration: 0, deadlineSecondsRemaining: nil
            )
        case .staticDeveloper:
            return GatewayAccessMetadata(
                policyState: .unprotected, locked: !staticAccessAllowed(), enrolled: false, enrollmentOpen: false,
                reason: reason, grantID: nil, epoch: 0, lockGeneration: 0, deadlineSecondsRemaining: nil
            )
        case let .pairedDevice(deviceID):
            guard case .valid = capabilityTrust, let record = deviceAccess[deviceID] else {
                return GatewayAccessMetadata(
                    policyState: .required, locked: true, enrolled: false, enrollmentOpen: false,
                    reason: reason, grantID: nil, epoch: 0, lockGeneration: 0, deadlineSecondsRemaining: nil
                )
            }
            let policyState: GatewayAccessMetadata.PolicyState = record.policyRequired ? .required : .off
            if !record.isRevoked, !record.policyRequired {
                return GatewayAccessMetadata(
                    policyState: .off, locked: false, enrolled: record.policyEnrolled, enrollmentOpen: record.policyEnrollmentOpen,
                    reason: reason, grantID: nil, epoch: record.policyEpoch, lockGeneration: record.lockGeneration, deadlineSecondsRemaining: nil
                )
            }
            if !record.isRevoked, let grant = record.grant, accessClock.now() < grant.deadline {
                let remaining = Double(max(0, grant.deadline.nanosecondsSinceBase &- accessClock.now().nanosecondsSinceBase)) / 1_000_000_000
                return GatewayAccessMetadata(
                    policyState: .required, locked: false, enrolled: record.policyEnrolled, enrollmentOpen: record.policyEnrollmentOpen,
                    reason: reason, grantID: grant.id, epoch: record.policyEpoch, lockGeneration: record.lockGeneration, deadlineSecondsRemaining: remaining
                )
            }
            return GatewayAccessMetadata(
                policyState: policyState, locked: true, enrolled: record.policyEnrolled, enrollmentOpen: record.policyEnrollmentOpen,
                reason: reason, grantID: nil, epoch: record.policyEpoch, lockGeneration: record.lockGeneration, deadlineSecondsRemaining: nil
            )
        }
    }

    private func nextPublicationRevision() -> GatewayPublicationRevision {
        publicationRevision = publicationRevision.next()
        return publicationRevision
    }

    private func authorizationSnapshot(
        for handle: GatewayConnectionHandle,
        revision: GatewayPublicationRevision
    ) -> GatewayAuthorizationSnapshot {
        switch handle.principal {
        case .unbound:
            return GatewayAuthorizationSnapshot(publicationRevision: revision, principal: .unbound, access: .locked, grant: nil, binding: nil)
        case .staticDeveloper:
            let access: GatewayAccess = staticAccessAllowed() ? .unprotected : .locked
            return GatewayAuthorizationSnapshot(publicationRevision: revision, principal: .staticDeveloper, access: access, grant: nil, binding: nil)
        case let .pairedDevice(deviceID):
            guard case .valid = capabilityTrust, let record = deviceAccess[deviceID] else {
                return GatewayAuthorizationSnapshot(publicationRevision: revision, principal: handle.principal, access: .locked, grant: nil, binding: nil)
            }
            if record.isRevoked {
                return GatewayAuthorizationSnapshot(publicationRevision: revision, principal: handle.principal, access: .locked, grant: nil, binding: record.binding)
            }
            if !record.policyRequired {
                return GatewayAuthorizationSnapshot(publicationRevision: revision, principal: handle.principal, access: .unprotected, grant: nil, binding: record.binding)
            }
            if let grant = record.grant, accessClock.now() < grant.deadline {
                return GatewayAuthorizationSnapshot(publicationRevision: revision, principal: handle.principal, access: .unlockedUntilGrantDeadline, grant: grant, binding: record.binding)
            }
            return GatewayAuthorizationSnapshot(publicationRevision: revision, principal: handle.principal, access: .locked, grant: nil, binding: record.binding)
        }
    }

    // MARK: Authorization transitions (S3-I02)

    private func scheduleAuthorization(forDevice deviceID: String, revision: GatewayPublicationRevision) -> [GatewayBarrierReceipt] {
        handles.values
            .filter { $0.deviceID == deviceID }
            .map { handle in
                handle.sink.scheduleAuthorization(
                    authorizationSnapshot(for: handle, revision: revision),
                    expectedIncarnation: handle.incarnation
                )
            }
    }

    private func scheduleAuthorization(forAllConnectionsAt revision: GatewayPublicationRevision) -> [GatewayBarrierReceipt] {
        handles.values.map { handle in
            handle.sink.scheduleAuthorization(
                authorizationSnapshot(for: handle, revision: revision),
                expectedIncarnation: handle.incarnation
            )
        }
    }

    /// Capture (do NOT yet schedule) the sanitized `lock_state` notice for every connection of a device
    /// at `revision`. Metadata is read from the CURRENT record synchronously, so it matches the
    /// authorization snapshot scheduled at the same revision for the same transition.
    private func captureNotices(toDevice deviceID: String, revision: GatewayPublicationRevision, reason: GatewaySafeControlReason?) -> [CapturedAccessNotice] {
        handles.values
            .filter { $0.deviceID == deviceID }
            .map { handle in
                CapturedAccessNotice(
                    sink: handle.sink,
                    incarnation: handle.incarnation,
                    revision: revision,
                    envelope: .lockState(access: accessMetadata(for: handle, reason: reason))
                )
            }
    }

    /// S3-I02: settle a transition's all-sink authorization barrier, THEN deliver each captured notice
    /// guarded on that transition's exact revision. A notice whose connection has since applied a newer
    /// revision is dropped; the superseding transition delivers its own metadata. Returns the combined
    /// barrier (authorization receipts + notice receipts). Used by transitions with no correlated frame
    /// to order against; an assertion commit instead returns its captured notices and flushes them via
    /// `deliverGatedNotices` after `ceremony_complete`.
    private func settleAndPublishGatedNotices(_ transition: CapturedTransition) async -> GatewayPublicationBarrier {
        let authBarrier = GatewayPublicationBarrier(receipts: transition.authReceipts)
        await authBarrier.settle()
        let noticeBarrier = deliverGatedNotices(transition.notices)
        return GatewayPublicationBarrier(receipts: transition.authReceipts + noticeBarrier.receipts)
    }

    /// S3-I02: deliver the revision-bound access-state notices captured by a committed transition, each
    /// gated on its own revision so a superseding transition's authorization drops the stale notice. The
    /// caller invokes this AFTER the transition's authorization barrier has settled (and, for an
    /// assertion commit, after `ceremony_complete`), so a notice never precedes its own cross-tab
    /// barrier and the correlated completion frame is not consumed as a notice by the initiating socket.
    func deliverGatedNotices(_ notices: [CapturedAccessNotice]) -> GatewayPublicationBarrier {
        GatewayPublicationBarrier(receipts: notices.map { notice in
            notice.sink.scheduleSafeControlIfCurrent(
                notice.envelope,
                expectedIncarnation: notice.incarnation,
                expectedRevision: notice.revision
            )
        })
    }

    /// Publish ONE device transition as a revision-bound unit (S3-I02): schedule the authorization
    /// change to all of `deviceID`'s connections AND capture each connection's access-state notice at
    /// the SAME revision, then settle the barrier and deliver only the still-current notices. Used by
    /// Lock and idle-grant expiry.
    private func publishDeviceTransition(_ deviceID: String, reason: GatewaySafeControlReason?) async -> GatewayPublicationBarrier {
        let revision = nextPublicationRevision()
        let transition = CapturedTransition(
            authReceipts: scheduleAuthorization(forDevice: deviceID, revision: revision),
            notices: captureNotices(toDevice: deviceID, revision: revision, reason: reason)
        )
        return await settleAndPublishGatedNotices(transition)
    }

    private func publishToAllConnections() -> GatewayPublicationBarrier {
        let revision = nextPublicationRevision()
        return GatewayPublicationBarrier(receipts: scheduleAuthorization(forAllConnectionsAt: revision))
    }

    private func scheduleGrantExpiry(deviceID: String, grant: GatewayDeviceGrant) -> GatewayExpiryTimer {
        accessClock.scheduleExpiry(at: grant.deadline) { [weak self] in
            guard let self else { return }
            Task { await self.handleGrantExpiryFired(deviceID: deviceID, grantID: grant.id, deadline: grant.deadline) }
        }
    }

    private func handleGrantExpiryFired(deviceID: String, grantID: String, deadline: GatewayMonotonicInstant) async {
        _ = await expireGrant(deviceID: deviceID, grantID: grantID, expectedDeadline: deadline)
    }
}
