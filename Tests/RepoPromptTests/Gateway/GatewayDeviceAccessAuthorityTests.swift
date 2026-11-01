import Foundation
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

/// Deterministic authority tests for the gateway's single device-access authority (remote passkey
/// unlock, Step 3). Every test drives the ACTUAL `DeviceAuthenticator` authority extension over the
/// ACTUAL production sink on a real NIO embedded channel, with an injected `ManualAccessClock` so no
/// test waits on real time. Access decisions are verified two ways: the authority's own read
/// accessors, and whether a protected frame published to the sink is actually delivered or dropped.
///
/// Awaited authority reads are always bound to a local before an `XCTAssert`/`XCTUnwrap` because those
/// take non-concurrency autoclosures.
final class GatewayDeviceAccessAuthorityTests: XCTestCase {
    private var root: URL!
    private var clock: ManualAccessClock!
    private var authority: DeviceAuthenticator!
    private var channels: [NIOAsyncTestingChannel] = []

    override func setUp() async throws {
        try await super.setUp()
        root = try GatewayTestHelpers.temporaryRoot("device-access-authority")
        let store = try GatewayAuthTestSupport.makeUsedTicketStore(root: root)
        clock = ManualAccessClock()
        authority = DeviceAuthenticator(usedTicketStore: store, trust: nil, accessClock: clock)
    }

    override func tearDown() async throws {
        for channel in channels {
            _ = try? await channel.finish(acceptAlreadyClosed: true)
        }
        channels = []
        authority = nil
        clock = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try await super.tearDown()
    }

    // MARK: Cross-tab / cross-device / reconnect

    func testCommittedAssertionUnlocksAllTabsOfSameDevice() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab1 = try await bind(device: "device")
        let tab2 = try await bind(device: "device")

        try await commitAssertion(device: "device", via: tab1)

        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertTrue(hasGrant)
        try await assertDelivers(tab1, "The initiating tab must deliver protected content once unlocked.")
        try await assertDelivers(tab2, "A sibling tab of the same paired device must share the grant.")
    }

    func testGrantIsScopedToItsDevice() async throws {
        var devices = makeDevice(id: "deviceA", required: true)
        devices["deviceB"] = makeTrustedDevice(id: "deviceB", required: true)
        await authority.applyCapabilityTrust(makeTrustSnapshot(devices: devices)).settle()
        let a = try await bind(device: "deviceA")
        let b = try await bind(device: "deviceB")

        try await commitAssertion(device: "deviceA", via: a)

        try await assertDelivers(a, "deviceA is unlocked.")
        try await assertDrops(b, "deviceB has no grant and must stay locked.")
    }

    func testReconnectInheritsEstablishedGrant() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let first = try await bind(device: "device")
        try await commitAssertion(device: "device", via: first)

        // A new connection binding later inherits the live shared grant at bind time.
        let reconnect = try await bind(device: "device")
        try await assertDelivers(reconnect, "A reconnecting tab must inherit the live shared grant.")
    }

    // MARK: Expiry equality / stale timer

    func testExpireGrantRequiresExactIDAndDeadline() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)
        let maybeDeadline = await authority.grantDeadline(forDevice: "device")
        let deadline = try XCTUnwrap(maybeDeadline)
        let maybeGrantID = await authority.grantID(forDevice: "device")
        let grantID = try XCTUnwrap(maybeGrantID)

        // Wrong deadline: no-op.
        await authority.expireGrant(deviceID: "device", grantID: grantID, expectedDeadline: deadline.advanced(by: .nanoseconds(-1))).settle()
        var hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertTrue(hasGrant, "A mismatched deadline must not expire the grant.")
        // Wrong id: no-op.
        await authority.expireGrant(deviceID: "device", grantID: "stale", expectedDeadline: deadline).settle()
        hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertTrue(hasGrant, "A mismatched grant id must not expire the grant.")
        // Exact match: locks.
        await authority.expireGrant(deviceID: "device", grantID: grantID, expectedDeadline: deadline).settle()
        hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(hasGrant, "An exact id+deadline match must expire the grant.")
        try await assertDrops(tab, "An expired grant must lock the connection.")
    }

    func testRenewedGrantSurvivesStaleExpiryTimer() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)
        let maybeOriginal = await authority.grantDeadline(forDevice: "device")
        let originalDeadline = try XCTUnwrap(maybeOriginal)
        let maybeGrantID = await authority.grantID(forDevice: "device")
        let grantID = try XCTUnwrap(maybeGrantID)

        // Activity renewal extends the SAME grant id to a later deadline.
        clock.advance(by: GatewayAccessTiming.renewalMinInterval)
        guard case let .accepted(renewalToken) = await authority.beginActivityRenewal(deviceID: "device", grantID: grantID, connectionID: tab.id, at: clock.now()) else {
            return XCTFail("Renewal should be admitted after the minimum interval.")
        }
        await authority.commitActivityRenewal(deviceID: "device", token: renewalToken, refreshSucceeded: true).settle()
        let maybeRenewed = await authority.grantDeadline(forDevice: "device")
        let renewedDeadline = try XCTUnwrap(maybeRenewed)
        XCTAssertGreaterThan(renewedDeadline, originalDeadline, "A successful renewal must extend the deadline.")

        // The old scheduled expiry (original deadline) must not expire the renewed grant.
        await authority.expireGrant(deviceID: "device", grantID: grantID, expectedDeadline: originalDeadline).settle()
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertTrue(hasGrant, "A stale timer from the pre-renewal deadline must not expire the renewed grant.")
    }

    // MARK: Lock / epoch / origin / trust-invalid stale verification

    func testLockBumpsGenerationClearsGrantAndBlocks() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        let maybeBefore = await authority.lockGeneration(forDevice: "device")
        let generationBefore = try XCTUnwrap(maybeBefore)
        try await commitAssertion(device: "device", via: tab)

        await authority.lockDevice("device").settle()
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(hasGrant)
        let maybeAfter = await authority.lockGeneration(forDevice: "device")
        let generationAfter = try XCTUnwrap(maybeAfter)
        XCTAssertEqual(generationAfter, generationBefore + 1, "Locking must advance the lock generation.")
        try await assertDrops(tab, "A locked device must drop protected content.")

        // A safe control is still deliverable while locked.
        let delivered = await tab.sink.sendSafeControl(.lockState(access: GatewayAccessMetadata(
            policyState: .required,
            locked: true,
            enrolled: true,
            enrollmentOpen: false,
            reason: .locked,
            grantID: nil,
            epoch: 0,
            lockGeneration: 0,
            deadlineSecondsRemaining: nil
        )))
        XCTAssertTrue(delivered)
        let control = try await nextServerFrame(tab.channel)
        XCTAssertEqual(control?.type, "lock_state")
    }

    func testAssertionBegunBeforeLockCannotCommitAfterLock() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        let maybeToken = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let token = try XCTUnwrap(maybeToken)
        await authority.lockDevice("device").settle()

        // The pending assertion was bound to the pre-lock generation; committing it must not grant.
        await authority.commitAssertion(deviceID: "device", token: token, result: .assertionVerified(epoch: 1), committedAt: clock.now()).settle()
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(hasGrant, "A verification bound to a stale generation cannot revive access.")
        try await assertDrops(tab, "The device must remain locked.")
    }

    func testEpochChangeInvalidatesGrantAndPending() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true, epoch: 1)).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)
        var hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertTrue(hasGrant)

        // A new epoch is an identity change: grant cleared, generation bumped.
        await authority.applyCapabilityTrust(makeTrust(required: true, epoch: 2)).settle()
        hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(hasGrant, "A policy epoch change must invalidate the grant.")
        try await assertDrops(tab, "A device must relock after an epoch change.")
    }

    func testOriginRevisionChangeInvalidatesGrant() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true, originRevision: 1)).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)

        await authority.applyCapabilityTrust(makeTrust(required: true, originRevision: 2)).settle()
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(hasGrant, "An authoritative origin revision change must invalidate the grant.")
        try await assertDrops(tab, "A device must relock after an origin change.")
    }

    func testAuthoritativeTrustInvalidationClearsGrant() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)

        await authority.invalidateTrust().settle()
        let availability = await authority.accessTrustAvailability()
        XCTAssertEqual(availability, .invalid)
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(hasGrant)
        try await assertDrops(tab, "Authoritative trust invalidity must lock every connection.")
    }

    // MARK: Required/null origin, no-valid-trust, static required

    func testRequiredPolicyWithNullOriginIsValidLockedNotInvalid() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true, origin: nil)).settle()
        let tab = try await bind(device: "device")
        // This is a valid, published, locked state — not authoritative invalidity.
        let availability = await authority.accessTrustAvailability()
        XCTAssertEqual(availability, .valid(makeTrustSnapshot(devices: makeDevice(id: "device", required: true), origin: nil)))
        try await assertDrops(tab, "Required policy with a null origin is a valid locked state.")
    }

    func testPairedConnectionWithoutValidTrustStaysLocked() async throws {
        // No trust applied yet: capability trust is unavailable.
        let tab = try await bind(device: "device")
        try await assertDrops(tab, "A paired connection with no valid trust must be locked.")
    }

    func testStaticDeveloperBlockedWhenAnyRequiredPolicyPresent() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let allowed = await authority.staticAccessAllowed()
        XCTAssertFalse(allowed)
        let staticTab = try await bind(principal: .staticDeveloper)
        try await assertDrops(staticTab, "Static developer access must be blocked while any required policy exists.")
    }

    func testStaticDeveloperAllowedWhenNoRequiredPolicy() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: false)).settle()
        let allowed = await authority.staticAccessAllowed()
        XCTAssertTrue(allowed)
        let staticTab = try await bind(principal: .staticDeveloper)
        try await assertDelivers(staticTab, "Static developer access is permitted when no device requires passkey policy.")
    }

    // MARK: Disconnect ordering

    func testEstablishedGrantSurvivesRoutineDisconnect() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)

        await authority.detachConnection(tab.id)
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertTrue(hasGrant, "A routine disconnect must not revoke an established shared grant.")
    }

    func testPendingAssertionCannotCommitAfterInitiatorDisconnects() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        let maybeToken = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let token = try XCTUnwrap(maybeToken)

        await authority.detachConnection(tab.id)
        await authority.commitAssertion(deviceID: "device", token: token, result: .assertionVerified(epoch: 1), committedAt: clock.now()).settle()
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(hasGrant, "A pending assertion from a disconnected initiator cannot establish a grant.")
    }

    func testPendingAssertionCannotCommitAfterInitiatorFenceCloses() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        let maybeToken = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let token = try XCTUnwrap(maybeToken)

        // Close the connection's sink (fence closes) without detaching from the authority.
        await tab.sink.close()
        await authority.commitAssertion(deviceID: "device", token: token, result: .assertionVerified(epoch: 1), committedAt: clock.now()).settle()
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(hasGrant, "A late commit must reject when the initiating fence has closed.")
    }

    // MARK: Renewal semantics

    func testRenewalThrottledByOneInFlightAndMinInterval() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)
        let maybeGrantID = await authority.grantID(forDevice: "device")
        let grantID = try XCTUnwrap(maybeGrantID)

        guard case let .accepted(first) = await authority.beginActivityRenewal(deviceID: "device", grantID: grantID, connectionID: tab.id, at: clock.now()) else {
            return XCTFail("First renewal should be admitted.")
        }
        // One in flight: a second request is throttled.
        let whileInFlight = await authority.beginActivityRenewal(deviceID: "device", grantID: grantID, connectionID: tab.id, at: clock.now())
        XCTAssertEqual(whileInFlight, .throttled)
        await authority.commitActivityRenewal(deviceID: "device", token: first, refreshSucceeded: true).settle()

        // Within the minimum interval: still throttled.
        clock.advance(by: .seconds(5))
        let withinInterval = await authority.beginActivityRenewal(deviceID: "device", grantID: grantID, connectionID: tab.id, at: clock.now())
        XCTAssertEqual(withinInterval, .throttled)
        // Past the minimum interval: admitted again.
        clock.advance(by: GatewayAccessTiming.renewalMinInterval)
        guard case .accepted = await authority.beginActivityRenewal(deviceID: "device", grantID: grantID, connectionID: tab.id, at: clock.now()) else {
            return XCTFail("A renewal past the minimum interval should be admitted.")
        }
    }

    /// The success-path completion signal: a renewal admitted against the live grant and committed
    /// after its fresh refresh EXTENDS the deadline to captured-activity-time + idle lifetime and
    /// republishes authorization, so protected delivery survives PAST the original deadline. This is
    /// the deterministic authority/injected-clock counterpart to the handler's `completeActivity`,
    /// whose only client-visible completion signal is the extended-deadline authorization publication
    /// (there is no separate renewal-ack frame on the success path).
    func testRenewalSuccessExtendsDeadlineAndKeepsDeliveryPastOriginalDeadline() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)
        let maybeOriginalDeadline = await authority.grantDeadline(forDevice: "device")
        let originalDeadline = try XCTUnwrap(maybeOriginalDeadline)
        let maybeGrantID = await authority.grantID(forDevice: "device")
        let grantID = try XCTUnwrap(maybeGrantID)

        // Foreground activity arrives part-way through the idle window (past the minimum interval).
        clock.advance(by: GatewayAccessTiming.renewalMinInterval)
        let activityTime = clock.now()
        guard case let .accepted(token) = await authority.beginActivityRenewal(deviceID: "device", grantID: grantID, connectionID: tab.id, at: activityTime) else {
            return XCTFail("Renewal should be admitted against the live grant.")
        }
        await authority.commitActivityRenewal(deviceID: "device", token: token, refreshSucceeded: true).settle()

        let maybeRenewed = await authority.grantDeadline(forDevice: "device")
        let renewed = try XCTUnwrap(maybeRenewed)
        XCTAssertEqual(renewed, activityTime.advanced(by: GatewayAccessTiming.idleGrantLifetime), "Renewal sets the deadline to captured-activity-time + idle lifetime.")
        XCTAssertGreaterThan(renewed.nanosecondsSinceBase, originalDeadline.nanosecondsSinceBase, "A successful renewal extends the deadline.")

        // Just PAST the original deadline but before the renewed one: the published renewal keeps
        // protected delivery alive — the completion signal took effect on the actual sink.
        clock.advance(by: GatewayAccessTiming.idleGrantLifetime - .seconds(1))
        XCTAssertGreaterThan(clock.now().nanosecondsSinceBase, originalDeadline.nanosecondsSinceBase, "The probe time is past the original deadline.")
        XCTAssertLessThan(clock.now().nanosecondsSinceBase, renewed.nanosecondsSinceBase, "The probe time is before the renewed deadline.")
        try await assertDelivers(tab, "Protected delivery survives past the original deadline after a successful renewal.")
    }

    func testRenewalFailurePreservesDeadline() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)
        let maybeDeadline = await authority.grantDeadline(forDevice: "device")
        let deadline = try XCTUnwrap(maybeDeadline)
        let maybeGrantID = await authority.grantID(forDevice: "device")
        let grantID = try XCTUnwrap(maybeGrantID)

        guard case let .accepted(renewalToken) = await authority.beginActivityRenewal(deviceID: "device", grantID: grantID, connectionID: tab.id, at: clock.now()) else {
            return XCTFail("Renewal should be admitted.")
        }
        await authority.commitActivityRenewal(deviceID: "device", token: renewalToken, refreshSucceeded: false).settle()
        let afterFailure = await authority.grantDeadline(forDevice: "device")
        XCTAssertEqual(afterFailure, deadline, "A failed refresh must preserve the original deadline unchanged.")
    }

    func testRenewalCannotFinishAfterOriginalDeadline() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)
        let maybeDeadline = await authority.grantDeadline(forDevice: "device")
        let deadline = try XCTUnwrap(maybeDeadline)
        let maybeGrantID = await authority.grantID(forDevice: "device")
        let grantID = try XCTUnwrap(maybeGrantID)

        // A renewal is admitted against the live grant.
        guard case let .accepted(renewalToken) = await authority.beginActivityRenewal(deviceID: "device", grantID: grantID, connectionID: tab.id, at: clock.now()) else {
            return XCTFail("Renewal should be admitted.")
        }
        // The idle timer fires and locks the device (modeled deterministically; the real timer is a
        // detached Task). This also cancels the scheduled expiry.
        await authority.expireGrant(deviceID: "device", grantID: grantID, expectedDeadline: deadline).settle()
        let lockedDuringRefresh = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(lockedDuringRefresh, "The grant must be gone once the idle timer fires.")

        // The in-flight refresh now completes successfully, but it must not revive the expired grant.
        await authority.commitActivityRenewal(deviceID: "device", token: renewalToken, refreshSucceeded: true).settle()
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(hasGrant, "A refresh that finishes after the grant expired cannot revive it.")
        try await assertDrops(tab, "The device must remain locked after a late refresh.")
    }

    // MARK: Publication ordering

    func testLockAfterCommitWinsRegardlessOfSettleOrder() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        let maybeToken = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let token = try XCTUnwrap(maybeToken)

        // Schedule the unlock publication, then the lock publication, before settling either. The
        // lock carries the newer revision, so the sink must end locked.
        let unlockBarrier = await authority.commitAssertion(deviceID: "device", token: token, result: .assertionVerified(epoch: 1), committedAt: clock.now())
        let lockBarrier = await authority.lockDevice("device")
        await lockBarrier.settle()
        await unlockBarrier.settle()
        try await assertDrops(tab, "A lock published after an unlock must win on the sink via the newer revision.")
    }

    // MARK: Routine-poll stability (no spurious invalidation)

    func testUnchangedOffPolicyDoesNotAdvanceLockGeneration() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: false)).settle()
        let maybeGen = await authority.lockGeneration(forDevice: "device")
        let gen0 = try XCTUnwrap(maybeGen)
        // Several identical ~15s polls must not advance the generation (which would invalidate the
        // admission binding of an ordinary long-running response under unchanged off policy).
        for _ in 0 ..< 5 {
            await authority.applyCapabilityTrust(makeTrust(required: false)).settle()
        }
        let genN = await authority.lockGeneration(forDevice: "device")
        XCTAssertEqual(genN, gen0, "An unchanged policy-off device must keep a stable lock generation across polls.")
    }

    func testUnchangedRequiredPolicyPreservesGrantAndGenerationAcrossPolls() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)
        let maybeGen = await authority.lockGeneration(forDevice: "device")
        let gen0 = try XCTUnwrap(maybeGen)
        let maybeDeadline = await authority.grantDeadline(forDevice: "device")
        let deadline0 = try XCTUnwrap(maybeDeadline)

        for _ in 0 ..< 3 {
            await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        }
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertTrue(hasGrant, "An identical required-policy refresh must preserve a live grant.")
        let genN = await authority.lockGeneration(forDevice: "device")
        XCTAssertEqual(genN, gen0, "An identical required-policy refresh must not advance the lock generation.")
        let deadlineN = await authority.grantDeadline(forDevice: "device")
        XCTAssertEqual(deadlineN, deadline0, "An identical required-policy refresh must not change the deadline.")
        try await assertDelivers(tab, "The device must stay unlocked across identical refreshes.")
    }

    func testRequiredToOffTransitionInvalidatesGrant() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)
        let maybeGen = await authority.lockGeneration(forDevice: "device")
        let gen0 = try XCTUnwrap(maybeGen)

        await authority.applyCapabilityTrust(makeTrust(required: false)).settle()
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(hasGrant, "A required→off transition must clear the grant.")
        let maybeGenN = await authority.lockGeneration(forDevice: "device")
        let genN = try XCTUnwrap(maybeGenN)
        XCTAssertGreaterThan(genN, gen0, "A policy transition must advance the lock generation.")
        try await assertDelivers(tab, "An off device returns to pairing-only delivery.")
    }

    func testKeyRotationSameDeviceInvalidatesGrant() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true, key: Data([0x01, 0x02, 0x03]))).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)
        let maybeGen = await authority.lockGeneration(forDevice: "device")
        let gen0 = try XCTUnwrap(maybeGen)

        await authority.applyCapabilityTrust(makeTrust(required: true, key: Data([0x09, 0x09, 0x09]))).settle()
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(hasGrant, "A device-key rotation under the same id must invalidate the grant.")
        let maybeGenN = await authority.lockGeneration(forDevice: "device")
        let genN = try XCTUnwrap(maybeGenN)
        XCTAssertGreaterThan(genN, gen0, "A key rotation must advance the lock generation.")
        try await assertDrops(tab, "A key rotation relocks the device.")
    }

    // MARK: Ceremony admission against authority validity

    func testBeginAssertionRejectedWhenTrustInvalid() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        await authority.invalidateTrust().settle()
        let token = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        XCTAssertNil(token, "No ceremony may begin against invalid authority even if the record was enforced.")
    }

    func testBeginAssertionRejectedWithNullOrigin() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true, origin: nil)).settle()
        let tab = try await bind(device: "device")
        let token = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        XCTAssertNil(token, "A required-but-null-origin device cannot begin a ceremony until an origin is published.")
    }

    func testBeginAssertionRejectedWhenTrustUnavailable() async throws {
        let tab = try await bind(device: "device")
        let token = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        XCTAssertNil(token, "No ceremony may begin before any valid trust is applied.")
    }

    // MARK: Renewal initiating-connection binding

    func testRenewalRejectedAfterInitiatorDisconnect() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)
        let maybeDeadline = await authority.grantDeadline(forDevice: "device")
        let deadline = try XCTUnwrap(maybeDeadline)
        let maybeGrantID = await authority.grantID(forDevice: "device")
        let grantID = try XCTUnwrap(maybeGrantID)

        guard case let .accepted(renewalToken) = await authority.beginActivityRenewal(deviceID: "device", grantID: grantID, connectionID: tab.id, at: clock.now()) else {
            return XCTFail("Renewal should be admitted.")
        }
        await authority.detachConnection(tab.id)
        await authority.commitActivityRenewal(deviceID: "device", token: renewalToken, refreshSucceeded: true).settle()
        let afterDisconnect = await authority.grantDeadline(forDevice: "device")
        XCTAssertEqual(afterDisconnect, deadline, "A renewal cannot extend after its initiating connection disconnects.")
    }

    func testRenewalRejectedAfterInitiatorFenceCloses() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        try await commitAssertion(device: "device", via: tab)
        let maybeDeadline = await authority.grantDeadline(forDevice: "device")
        let deadline = try XCTUnwrap(maybeDeadline)
        let maybeGrantID = await authority.grantID(forDevice: "device")
        let grantID = try XCTUnwrap(maybeGrantID)

        guard case let .accepted(renewalToken) = await authority.beginActivityRenewal(deviceID: "device", grantID: grantID, connectionID: tab.id, at: clock.now()) else {
            return XCTFail("Renewal should be admitted.")
        }
        // Close the initiating fence (without detaching the handle): the atomic fence-held install
        // must refuse to extend the grant.
        await tab.sink.close()
        await authority.commitActivityRenewal(deviceID: "device", token: renewalToken, refreshSucceeded: true).settle()
        let afterClose = await authority.grantDeadline(forDevice: "device")
        XCTAssertEqual(afterClose, deadline, "A renewal cannot extend once the initiating fence has closed.")
    }

    // MARK: Two-phase relay ceremony (consume-before-verify / commit-rechecks-binding)

    func testTwoPhaseAssertionUnlocksAllTabs() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab1 = try await bind(device: "device")
        let tab2 = try await bind(device: "device")

        try await commitVerifiedAssertion(device: "device", via: tab1)

        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertTrue(hasGrant)
        try await assertDelivers(tab1, "The initiating tab must deliver once unlocked via the two-phase path.")
        try await assertDelivers(tab2, "A sibling tab must share the two-phase grant.")
    }

    func testTakePendingIsOneShotSoConcurrentReplayCannotDispatchTwice() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        let maybeToken = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let token = try XCTUnwrap(maybeToken)
        let attached = await authority.attachAssertionCeremonyAppID(deviceID: "device", token: token, appCeremonyID: "app-ceremony")
        XCTAssertTrue(attached)

        let first = await authority.takePendingAssertion(deviceID: "device", appCeremonyID: "app-ceremony", connectionGeneration: tab.generation)
        XCTAssertNotNil(first, "The first take consumes the eligibility.")
        let second = await authority.takePendingAssertion(deviceID: "device", appCeremonyID: "app-ceremony", connectionGeneration: tab.generation)
        XCTAssertNil(second, "A concurrent replay cannot consume the same eligibility twice.")
    }

    func testTakePendingRejectsMismatchedAppCeremonyID() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        let maybeToken = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let token = try XCTUnwrap(maybeToken)
        _ = await authority.attachAssertionCeremonyAppID(deviceID: "device", token: token, appCeremonyID: "app-ceremony")

        let wrong = await authority.takePendingAssertion(deviceID: "device", appCeremonyID: "not-the-ceremony", connectionGeneration: tab.generation)
        XCTAssertNil(wrong, "A completion for a different app ceremony id must not consume the pending.")
    }

    func testTakePendingRejectsMismatchedConnectionGeneration() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        let maybeToken = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let token = try XCTUnwrap(maybeToken)
        _ = await authority.attachAssertionCeremonyAppID(deviceID: "device", token: token, appCeremonyID: "app-ceremony")

        let wrong = await authority.takePendingAssertion(deviceID: "device", appCeremonyID: "app-ceremony", connectionGeneration: tab.generation &+ 99)
        XCTAssertNil(wrong, "A completion echoing a different connection generation must not consume the pending.")
    }

    func testTakePendingRejectedBeforeAppCeremonyIDAttached() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        let maybeToken = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        _ = try XCTUnwrap(maybeToken)

        // No attach yet: the pending has no app ceremony id, so no completion can consume it.
        let premature = await authority.takePendingAssertion(deviceID: "device", appCeremonyID: "app-ceremony", connectionGeneration: tab.generation)
        XCTAssertNil(premature)
    }

    func testAttachRejectedAfterLockGenerationChange() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        let maybeToken = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let token = try XCTUnwrap(maybeToken)

        // A lock advances the generation; the begun ceremony is now stale.
        await authority.lockDevice("device").settle()

        let attached = await authority.attachAssertionCeremonyAppID(deviceID: "device", token: token, appCeremonyID: "app-ceremony")
        XCTAssertFalse(attached, "Attaching an app ceremony id to a ceremony whose generation changed must fail.")
    }

    func testCommitVerifiedAssertionRejectsEpochMismatch() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true, epoch: 7)).settle()
        let tab = try await bind(device: "device")
        let maybeToken = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let token = try XCTUnwrap(maybeToken)
        _ = await authority.attachAssertionCeremonyAppID(deviceID: "device", token: token, appCeremonyID: "app-ceremony")
        let maybePending = await authority.takePendingAssertion(deviceID: "device", appCeremonyID: "app-ceremony", connectionGeneration: tab.generation)
        let pending = try XCTUnwrap(maybePending)

        // The app verified a stale epoch; the authority refuses to install a grant.
        let outcome = await authority.commitVerifiedAssertion(deviceID: "device", pending: pending, verifiedEpoch: 6, committedAt: clock.now())
        await outcome.barrier.settle()
        XCTAssertFalse(outcome.installedGrant, "A non-current epoch commit reports its own non-install.")
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(hasGrant, "A verified assertion for a non-current epoch must not grant access.")
    }

    func testCommitVerifiedAssertionRejectsStaleSuccessAfterReplacementLock() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        let maybeToken = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let token = try XCTUnwrap(maybeToken)
        _ = await authority.attachAssertionCeremonyAppID(deviceID: "device", token: token, appCeremonyID: "app-ceremony")
        let maybePending = await authority.takePendingAssertion(deviceID: "device", appCeremonyID: "app-ceremony", connectionGeneration: tab.generation)
        let pending = try XCTUnwrap(maybePending)

        // A lock lands during verification: the binding the pending captured is no longer current.
        await authority.lockDevice("device").settle()

        let outcome = await authority.commitVerifiedAssertion(deviceID: "device", pending: pending, verifiedEpoch: 1, committedAt: clock.now())
        await outcome.barrier.settle()
        XCTAssertFalse(outcome.installedGrant, "A stale success after a replacement lock reports its own non-install.")
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(hasGrant, "A verification that finishes after a replacement lock cannot clobber it.")
    }

    func testCommitVerifiedRegistrationNeverGrants() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        let maybeToken = await authority.beginRegistrationCeremony(deviceID: "device", connectionID: tab.id)
        let token = try XCTUnwrap(maybeToken)
        let attached = await authority.attachRegistrationCeremonyAppID(deviceID: "device", token: token, appCeremonyID: "reg-ceremony")
        XCTAssertTrue(attached)
        let maybePending = await authority.takePendingRegistration(deviceID: "device", appCeremonyID: "reg-ceremony", connectionGeneration: tab.generation)
        let pending = try XCTUnwrap(maybePending)

        let accepted = await authority.commitVerifiedRegistration(deviceID: "device", pending: pending)
        XCTAssertTrue(accepted, "A valid registration is accepted...")
        let hasGrant = await authority.hasGrant(forDevice: "device")
        XCTAssertFalse(hasGrant, "...but registration NEVER installs a grant; a fresh assertion is still required.")
    }

    // MARK: Lock publication ordering & pending-ceremony lifetime (S3-I02, S3-I06)

    /// S3-I02: a lock publishes authorization to every tab of the device AND notifies every tab with a
    /// `lock_state` carrying the CURRENT (post-lock) generation. The notice is emitted after the
    /// authorization barrier settles, so by the time `lockDevice().settle()` returns every tab is both
    /// relocked (protected content dropped) and notified with the current lock generation.
    func testLockNotifiesEveryTabWithCurrentLockedMetadata() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab1 = try await bind(device: "device")
        let tab2 = try await bind(device: "device")
        try await commitVerifiedAssertion(device: "device", via: tab1)
        try await assertDelivers(tab1, "unlocked initiating tab")
        try await assertDelivers(tab2, "unlocked sibling tab shares the grant")

        await authority.lockDevice("device").settle()

        let maybeGeneration = await authority.lockGeneration(forDevice: "device")
        let generation = try XCTUnwrap(maybeGeneration)
        for tab in [tab1, tab2] {
            let notice = try await nextServerFrame(tab.channel)
            XCTAssertEqual(notice?.type, "lock_state", "Every tab is notified of the lock.")
            let payload = notice?.payload?.objectValue
            XCTAssertEqual(payload?["reason"]?.stringValue, "passkey_locked")
            XCTAssertEqual(payload?["locked"]?.boolValue, true)
            XCTAssertNil(payload?["grant_id"], "A locked notice carries no grant reference.")
            XCTAssertEqual(
                payload?["lock_generation"]?.stringValue, String(generation),
                "The notice carries the current (post-lock) generation, not a stale one."
            )
        }
        try await assertDrops(tab1, "A relocked tab drops protected content after the notice.")
        try await assertDrops(tab2, "A relocked sibling drops protected content after the notice.")
    }

    /// S3-I02: an access-state notice is bound to the EXACT authorization revision it was captured at,
    /// and is dropped if a NEWER transition has been applied to the sink before the notice is flushed.
    /// This independently exercises the revision gate without relying on wall-clock interleaving: the
    /// unlock's notice is captured but withheld; a superseding Lock then applies its own newer revision
    /// and its own locked notice; flushing the stale unlocked notice afterward must be a NO-OP so it can
    /// never overwrite the Lock, and the sink stays locked. A re-read of current state under the older
    /// receipt (which would see the post-unlock grant) is exactly what the gate forbids.
    func testStaleUnlockedNoticeCapturedBeforeALockIsDroppedAndCannotOverwriteIt() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")

        // Drive the two-phase unlock manually so the captured unlocked notice is HELD, not delivered.
        let maybeToken = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let token = try XCTUnwrap(maybeToken)
        let attached = await authority.attachAssertionCeremonyAppID(deviceID: "device", token: token, appCeremonyID: "app-a")
        XCTAssertTrue(attached)
        let maybePending = await authority.takePendingAssertion(deviceID: "device", appCeremonyID: "app-a", connectionGeneration: tab.generation)
        let pending = try XCTUnwrap(maybePending)
        let outcome = await authority.commitVerifiedAssertion(deviceID: "device", pending: pending, verifiedEpoch: 1, committedAt: clock.now())
        await outcome.barrier.settle()
        XCTAssertTrue(outcome.installedGrant, "The unlock installed the grant and applied its authorization.")
        XCTAssertFalse(outcome.capturedNotices.isEmpty, "The unlock captured an access-state notice to flush later.")

        // A superseding LOCK applies a NEWER revision and delivers its OWN locked notice.
        await authority.lockDevice("device").settle()
        let lockNotice = try await nextServerFrame(tab.channel)
        XCTAssertEqual(lockNotice?.type, "lock_state")
        XCTAssertEqual(lockNotice?.payload?.objectValue?["locked"]?.boolValue, true, "The Lock's own notice reports locked.")

        // Flushing the stale unlocked notice (captured at the older unlock revision) must be dropped by
        // the revision gate — it cannot land after, nor overwrite, the Lock.
        await authority.deliverGatedNotices(outcome.capturedNotices).settle()
        let afterStale = try await nextServerFrame(tab.channel)
        XCTAssertNil(afterStale, "A stale unlocked notice captured before the Lock is dropped, never delivered after it.")

        // The sink remains LOCKED: the stale notice did not revive access.
        try await assertDrops(tab, "The superseding Lock still holds; the stale unlocked notice did not unlock the sink.")
    }

    /// S3-I02 regression (exact-revision notice fix): an UNCHANGED periodic trust refresh republishes
    /// authorization at a NEWER revision to every sink — which would otherwise drop an in-flight
    /// captured unlock notice via the revision gate while emitting nothing. The fix captures CURRENT
    /// metadata for every bound paired connection at the refresh revision, so the browser still learns
    /// the current unlocked state and grant references; the stale held unlock notice, now superseded, is
    /// discarded. The grant/deadline are preserved (the refresh does not renew).
    func testUnchangedRefreshSupersedesHeldUnlockNoticeButStillEmitsCurrentUnlockedMetadata() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")

        // Drive the unlock manually so its captured notice is HELD, not delivered.
        let maybeToken = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let token = try XCTUnwrap(maybeToken)
        let attached = await authority.attachAssertionCeremonyAppID(deviceID: "device", token: token, appCeremonyID: "app-a")
        XCTAssertTrue(attached)
        let maybePending = await authority.takePendingAssertion(deviceID: "device", appCeremonyID: "app-a", connectionGeneration: tab.generation)
        let pending = try XCTUnwrap(maybePending)
        let outcome = await authority.commitVerifiedAssertion(deviceID: "device", pending: pending, verifiedEpoch: 1, committedAt: clock.now())
        await outcome.barrier.settle()
        XCTAssertTrue(outcome.installedGrant)
        XCTAssertFalse(outcome.capturedNotices.isEmpty)

        // An identical ~15s refresh republishes authorization at a NEWER revision AND re-emits the
        // CURRENT metadata to the paired connection (no "silent refresh" optimization).
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let refreshNotice = try await nextServerFrame(tab.channel)
        XCTAssertEqual(refreshNotice?.type, "lock_state")
        XCTAssertEqual(
            refreshNotice?.payload?.objectValue?["locked"]?.boolValue, false,
            "The unchanged refresh re-emits the CURRENT unlocked state, not silence."
        )
        XCTAssertNotNil(
            refreshNotice?.payload?.objectValue?["grant_id"]?.stringValue,
            "and carries the current grant reference so the browser is never left locked-looking."
        )

        // Flushing the OLD held unlock notice is now a no-op: the refresh's newer revision superseded it.
        await authority.deliverGatedNotices(outcome.capturedNotices).settle()
        let afterStale = try await nextServerFrame(tab.channel)
        XCTAssertNil(afterStale, "The stale held unlock notice is dropped; the refresh already delivered current metadata.")

        // The grant survived the unchanged refresh (no renewal needed); the connection keeps delivering.
        try await assertDelivers(tab, "The grant survived the unchanged refresh and the dropped stale notice.")
    }

    /// S3-I13: a lock against a POLICY-OFF (unprotected) device is a no-op — it has no grant to drop,
    /// and advancing its generation would spuriously settle its in-flight unprotected responses as
    /// locked. The connection keeps delivering unprotected content and receives no lock notice.
    func testLockOfPolicyOffDeviceIsANoOp() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: false)).settle()
        let tab = try await bind(device: "device")
        try await assertDelivers(tab, "policy-off is unprotected")
        let before = await authority.lockGeneration(forDevice: "device")

        await authority.lockDevice("device").settle()

        let after = await authority.lockGeneration(forDevice: "device")
        XCTAssertEqual(before, after, "Locking a policy-off device must not advance its generation.")
        try await assertDelivers(tab, "A policy-off device keeps delivering unprotected content after a (no-op) lock.")
    }

    /// S3-I06 (a): a begin with NO completion is immediately replaceable by a fresh begin — no lock,
    /// disconnect, clock advance, or invented wait. Safe replacement caps one pending per kind and
    /// supersedes the old begin's token.
    func testBeginWithoutCompletionIsImmediatelyReplaceableByAFreshBegin() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        let maybeFirst = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let first = try XCTUnwrap(maybeFirst)
        // No completion, no clock advance: a fresh begin succeeds AT ONCE (previously this was rejected
        // until a 2-minute lifetime elapsed).
        let maybeSecond = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let second = try XCTUnwrap(maybeSecond)
        XCTAssertNotEqual(first, second, "A fresh begin immediately replaces an uncompleted pending (no wait).")

        let staleAttach = await authority.attachAssertionCeremonyAppID(deviceID: "device", token: first, appCeremonyID: "app-stale")
        XCTAssertFalse(staleAttach, "The superseded begin token cannot attach after replacement.")
        let freshAttach = await authority.attachAssertionCeremonyAppID(deviceID: "device", token: second, appCeremonyID: "app-fresh")
        XCTAssertTrue(freshAttach, "The replacement begin attaches normally.")
    }

    /// S3-I06 (b): an OLD assertion taken and held in flight (its app reply already verified/held)
    /// cannot commit once a fresh begin has replaced it — the per-kind ceremony generation advanced, so
    /// the held completion is rejected at commit. The rejection does NOT clear the replacement, which
    /// still commits normally.
    func testHeldOldAssertionCommitIsRejectedAfterReplacementAndReplacementStillCommits() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")
        let maybeOld = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let old = try XCTUnwrap(maybeOld)
        _ = await authority.attachAssertionCeremonyAppID(deviceID: "device", token: old, appCeremonyID: "app-old")
        let maybeHeld = await authority.takePendingAssertion(deviceID: "device", appCeremonyID: "app-old", connectionGeneration: tab.generation)
        let held = try XCTUnwrap(maybeHeld, "the old pending is taken and held in flight")

        // Fresh begin replaces the (already-taken) ceremony while the old reply is still held.
        let maybeNew = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let new = try XCTUnwrap(maybeNew)
        XCTAssertNotEqual(old, new)

        // The held OLD completion now commits → rejected: its ceremony generation was superseded, even
        // though binding and lock generation are unchanged.
        let staleOutcome = await authority.commitVerifiedAssertion(deviceID: "device", pending: held, verifiedEpoch: 1, committedAt: clock.now())
        await staleOutcome.barrier.settle()
        XCTAssertFalse(staleOutcome.installedGrant, "A held completion for a superseded begin cannot install a grant.")

        // The replacement is untouched by that rejection and still completes normally.
        _ = await authority.attachAssertionCeremonyAppID(deviceID: "device", token: new, appCeremonyID: "app-new")
        let maybeFresh = await authority.takePendingAssertion(deviceID: "device", appCeremonyID: "app-new", connectionGeneration: tab.generation)
        let fresh = try XCTUnwrap(maybeFresh, "the replacement pending is preserved and takeable")
        let freshOutcome = await authority.commitVerifiedAssertion(deviceID: "device", pending: fresh, verifiedEpoch: 1, committedAt: clock.now())
        await freshOutcome.barrier.settle()
        XCTAssertTrue(freshOutcome.installedGrant, "The replacement begin commits and installs the grant.")
    }

    /// S3-I06 (c): the held-pending expiry matches the app's WebAuthn challenge timeout on the injected
    /// clock — both challenges last 60s, independently of the app's 120s enrollment authorization.
    func testHeldPendingExpiryMatchesSixtySecondAssertionAndRegistrationChallenges() async throws {
        await authority.applyCapabilityTrust(makeTrust(required: true)).settle()
        let tab = try await bind(device: "device")

        let maybeAssertion = await authority.beginAssertionCeremony(deviceID: "device", connectionID: tab.id)
        let assertion = try XCTUnwrap(maybeAssertion)
        _ = await authority.attachAssertionCeremonyAppID(deviceID: "device", token: assertion, appCeremonyID: "app-a")
        clock.advance(by: .seconds(61))
        let expiredAssertion = await authority.takePendingAssertion(deviceID: "device", appCeremonyID: "app-a", connectionGeneration: tab.generation)
        XCTAssertNil(expiredAssertion, "An assertion pending older than the 60s app challenge is not completable.")

        let maybeRegistration = await authority.beginRegistrationCeremony(deviceID: "device", connectionID: tab.id)
        let registration = try XCTUnwrap(maybeRegistration)
        _ = await authority.attachRegistrationCeremonyAppID(deviceID: "device", token: registration, appCeremonyID: "app-r")
        clock.advance(by: .seconds(61))
        let expiredRegistration = await authority.takePendingRegistration(deviceID: "device", appCeremonyID: "app-r", connectionGeneration: tab.generation)
        XCTAssertNil(expiredRegistration, "The 120s enrollment authorization does not extend a 60s registration challenge.")
    }

    // MARK: Connection helper

    private struct Connection {
        let id: UUID
        let sink: GatewayWebSocketFrameSink
        let channel: NIOAsyncTestingChannel
        let generation: UInt64
    }

    private func bind(device deviceID: String) async throws -> Connection {
        try await bind(principal: .pairedDevice(deviceID: deviceID))
    }

    private func bind(principal: GatewayAccessPrincipal) async throws -> Connection {
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).get()
        channels.append(channel)
        let sink = GatewayWebSocketFrameSink(channel: channel, clock: clock)
        let id = UUID()
        let generation = UInt64(channels.count)
        await authority.bindConnection(connectionID: id, sink: sink, principal: principal, connectionGeneration: generation).settle()
        return Connection(id: id, sink: sink, channel: channel, generation: generation)
    }

    /// Drive the two-phase relay path: begin → attach app ceremony id → take eligibility →
    /// commit the verified assertion, publishing the grant.
    private func commitVerifiedAssertion(
        device deviceID: String,
        via connection: Connection,
        appCeremonyID: String = "app-ceremony",
        epoch: UInt64 = 1
    ) async throws {
        let maybeToken = await authority.beginAssertionCeremony(deviceID: deviceID, connectionID: connection.id)
        let token = try XCTUnwrap(maybeToken)
        let attached = await authority.attachAssertionCeremonyAppID(deviceID: deviceID, token: token, appCeremonyID: appCeremonyID)
        XCTAssertTrue(attached, "attach must succeed for a live, unchanged ceremony")
        let maybePending = await authority.takePendingAssertion(deviceID: deviceID, appCeremonyID: appCeremonyID, connectionGeneration: connection.generation)
        let pending = try XCTUnwrap(maybePending, "take must consume the eligibility exactly once")
        let outcome = await authority.commitVerifiedAssertion(deviceID: deviceID, pending: pending, verifiedEpoch: epoch, committedAt: clock.now())
        await outcome.barrier.settle()
        // Mirror the production handler: after the unlock authorization's all-sink barrier settles (and,
        // in production, after `ceremony_complete`), flush the captured revision-bound access-state
        // notices (S3-I02).
        await authority.deliverGatedNotices(outcome.capturedNotices).settle()
        XCTAssertTrue(outcome.installedGrant, "the helper drives a successful commit that installs a grant")
    }

    /// Begin and commit a verified assertion for `device` via `connection`, publishing the grant.
    private func commitAssertion(device deviceID: String, via connection: Connection) async throws {
        let maybeToken = await authority.beginAssertionCeremony(deviceID: deviceID, connectionID: connection.id)
        let token = try XCTUnwrap(maybeToken)
        await authority.commitAssertion(deviceID: deviceID, token: token, result: .assertionVerified(epoch: 1), committedAt: clock.now()).settle()
    }

    private func assertDelivers(_ connection: Connection, _ message: String) async throws {
        await connection.sink.send(.commandResult(requestID: "probe", payload: .object([:])))
        // A policy/enrollment change, unlock, lock, or grant expiry legitimately enqueues a content-free
        // `lock_state` access-state notice ahead of the probe (S3-I02/I03); skip those and assert the
        // protected probe response itself IS delivered. A withheld probe still fails (nil requestID).
        var frame = try await nextServerFrame(connection.channel)
        while frame?.type == "lock_state" {
            frame = try await nextServerFrame(connection.channel)
        }
        XCTAssertEqual(frame?.requestID, "probe", message)
    }

    private func assertDrops(_ connection: Connection, _ message: String) async throws {
        await connection.sink.send(.commandResult(requestID: "probe", payload: .object([:])))
        // A lock or grant expiry legitimately enqueues a content-free `lock_state` notification ahead
        // of the dropped probe; skip those and assert the protected probe response itself never
        // arrives (and that nothing else does).
        while let frame = try await nextServerFrame(connection.channel) {
            if frame.type == "lock_state" { continue }
            XCTFail("\(message) (unexpected \(frame.type) frame, requestID=\(frame.requestID ?? "nil"))")
            return
        }
    }

    private func nextServerFrame(_ channel: NIOAsyncTestingChannel) async throws -> RemoteServerFrame? {
        guard let ws = try await channel.readOutbound(as: WebSocketFrame.self) else { return nil }
        var buffer = ws.data
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return nil }
        return try JSONDecoder().decode(RemoteServerFrame.self, from: Data(bytes))
    }

    // MARK: Trust fixtures

    private func makeTrust(
        required: Bool,
        epoch: UInt64 = 1,
        origin: String? = "https://example.com",
        originRevision: UInt64 = 1,
        launch: String = "launch",
        key: Data = Data([0x01, 0x02, 0x03])
    ) -> GatewayCapabilityTrustSnapshot {
        makeTrustSnapshot(
            devices: makeDevice(id: "device", required: required, epoch: epoch, key: key),
            origin: origin,
            originRevision: originRevision,
            launch: launch
        )
    }

    private func makeDevice(id: String, required: Bool, epoch: UInt64 = 1, key: Data = Data([0x01, 0x02, 0x03])) -> [String: GatewayCapabilityTrustedDevice] {
        [id: makeTrustedDevice(id: id, required: required, epoch: epoch, key: key)]
    }

    private func makeTrustedDevice(id: String, required: Bool, epoch: UInt64 = 1, revoked: Bool = false, key: Data = Data([0x01, 0x02, 0x03])) -> GatewayCapabilityTrustedDevice {
        GatewayCapabilityTrustedDevice(
            deviceID: id,
            displayName: id,
            publicKeyRawRepresentation: key,
            counterFloor: 0,
            isRevoked: revoked,
            scopes: ["remote.control"],
            policy: GatewayDevicePasskeyPolicy(
                version: 1,
                state: required ? .required : .off,
                enrolled: true,
                epoch: epoch,
                enrollmentOpen: false,
                needsReenrollment: false
            )
        )
    }

    private func makeTrustSnapshot(
        devices: [String: GatewayCapabilityTrustedDevice],
        origin: String? = "https://example.com",
        originRevision: UInt64 = 1,
        launch: String = "launch"
    ) -> GatewayCapabilityTrustSnapshot {
        GatewayCapabilityTrustSnapshot(
            hostPublicKeyRawRepresentation: Data([0x09, 0x08, 0x07]),
            hostFingerprint: "fingerprint",
            trustRevision: GatewayCapabilityTrustSnapshot.Revision(launch: launch, revision: 1, issuance: "issuance"),
            authoritativeOrigin: origin,
            originRevision: originRevision,
            devices: devices
        )
    }
}
