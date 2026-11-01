import Foundation
@testable import RepoPromptGateway
import XCTest

/// Access-state value semantics, the monotonic clock, the lifecycle fence, and the typed safe-control
/// builders (remote passkey unlock, Step 3).
final class GatewayAccessStateTests: XCTestCase {
    func testMonotonicInstantAdvanceAndOrdering() {
        let base = GatewayMonotonicInstant(nanosecondsSinceBase: 0)
        let later = base.advanced(by: .seconds(30 * 60))
        XCTAssertTrue(base < later)
        XCTAssertEqual(later.nanosecondsSinceBase, 30 * 60 * 1_000_000_000)
    }

    func testContinuousClockIsNonDecreasing() {
        let clock = GatewayContinuousAccessClock()
        let first = clock.now()
        let second = clock.now()
        XCTAssertFalse(second < first, "A monotonic clock must never move backward.")
    }

    func testUnprotectedAccessAlwaysAuthorizes() {
        let snapshot = GatewayAuthorizationSnapshot(
            publicationRevision: .initial.next(),
            principal: .unbound,
            access: .unprotected,
            grant: nil,
            binding: nil
        )
        XCTAssertTrue(snapshot.authorizesProtectedContent(now: GatewayMonotonicInstant(nanosecondsSinceBase: 999)))
    }

    func testLockedAccessNeverAuthorizes() {
        let snapshot = GatewayAuthorizationSnapshot(
            publicationRevision: .initial.next(),
            principal: .pairedDevice(deviceID: "d"),
            access: .locked,
            grant: nil,
            binding: nil
        )
        XCTAssertFalse(snapshot.authorizesProtectedContent(now: GatewayMonotonicInstant(nanosecondsSinceBase: 0)))
    }

    func testGrantDeadlineIsExclusive() {
        let deadline = GatewayMonotonicInstant(nanosecondsSinceBase: 1000)
        let snapshot = GatewayAuthorizationSnapshot(
            publicationRevision: .initial.next(),
            principal: .pairedDevice(deviceID: "d"),
            access: .unlockedUntilGrantDeadline,
            grant: GatewayDeviceGrant(id: "g", deadline: deadline),
            binding: nil
        )
        XCTAssertTrue(snapshot.authorizesProtectedContent(now: GatewayMonotonicInstant(nanosecondsSinceBase: 999)))
        XCTAssertFalse(snapshot.authorizesProtectedContent(now: deadline), "Exact deadline equality must deny.")
        XCTAssertFalse(snapshot.authorizesProtectedContent(now: GatewayMonotonicInstant(nanosecondsSinceBase: 1001)))
    }

    func testUnlockedWithoutGrantDenies() {
        let snapshot = GatewayAuthorizationSnapshot(
            publicationRevision: .initial.next(),
            principal: .pairedDevice(deviceID: "d"),
            access: .unlockedUntilGrantDeadline,
            grant: nil,
            binding: nil
        )
        XCTAssertFalse(snapshot.authorizesProtectedContent(now: GatewayMonotonicInstant(nanosecondsSinceBase: 0)))
    }

    func testPublicationRevisionMonotonicOrdering() {
        let a = GatewayPublicationRevision.initial
        let b = a.next()
        let c = b.next()
        XCTAssertTrue(a < b)
        XCTAssertTrue(b < c)
        XCTAssertEqual(c.value, 2)
    }

    func testLifecycleFenceClosesOnce() {
        let fence = GatewayConnectionLifecycleFence()
        XCTAssertTrue(fence.isActive)
        XCTAssertEqual(fence.withActive { 42 }, 42)
        XCTAssertTrue(fence.close())
        XCTAssertFalse(fence.close(), "Second close is a no-op.")
        XCTAssertFalse(fence.isActive)
        XCTAssertNil(fence.withActive { 42 }, "withActive must not run after close.")
    }

    func testIdleGrantLifetimeIsThirtyMinutes() {
        XCTAssertEqual(GatewayAccessTiming.idleGrantLifetime, .seconds(30 * 60))
    }

    func testSafeControlBuildersAreContentFree() {
        let access = GatewayAccessMetadata(
            policyState: .required,
            locked: true,
            enrolled: true,
            enrollmentOpen: false,
            reason: .locked,
            grantID: nil,
            epoch: 0,
            lockGeneration: 0,
            deadlineSecondsRemaining: nil
        )
        let lockState = GatewaySafeControlEnvelope.lockState(access: access).frame
        XCTAssertEqual(lockState.type, "lock_state")
        XCTAssertEqual(lockState.payload?.objectValue?["locked"]?.boolValue, true)
        XCTAssertEqual(lockState.payload?.objectValue?["reason"]?.stringValue, "passkey_locked")

        let settlement = GatewaySafeControlEnvelope.lockSettlement(requestID: "r").frame
        XCTAssertEqual(settlement.type, "command_error")
        XCTAssertEqual(settlement.requestID, "r")
        XCTAssertEqual(settlement.payload?.objectValue?["code"]?.stringValue, "passkey_locked")
        XCTAssertNil(settlement.payload?.objectValue?["details"], "Settlement must carry no runtime/app error detail.")
    }
}
