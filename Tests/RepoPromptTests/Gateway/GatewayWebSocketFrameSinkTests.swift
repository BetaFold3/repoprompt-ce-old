import Foundation
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

/// Drives the ACTUAL production `GatewayWebSocketFrameSink` against a real NIO embedded channel and an
/// injected monotonic clock (remote passkey unlock, Step 3). No test waits on real time: the clock is
/// advanced explicitly. `NIOAsyncTestingEventLoop.execute` self-runs when called off-loop, so the
/// sink's `eventLoop.submit { ... }.get()` round-trips resolve without manual pumping.
final class GatewayWebSocketFrameSinkTests: XCTestCase {
    private var channel: NIOAsyncTestingChannel!
    private var clock: ManualAccessClock!
    private var sink: GatewayWebSocketFrameSink!

    override func setUp() async throws {
        try await super.setUp()
        channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).get()
        clock = ManualAccessClock()
        sink = GatewayWebSocketFrameSink(channel: channel, clock: clock)
    }

    override func tearDown() async throws {
        _ = try? await channel.finish(acceptAlreadyClosed: true)
        channel = nil
        sink = nil
        clock = nil
        try await super.tearDown()
    }

    // MARK: Closed-by-default

    func testUnboundSinkDropsProtectedContent() async throws {
        // No authorization applied: the sink is closed to all protected content.
        await sink.send(.commandResult(requestID: "r", payload: .object(["ok": .bool(true)])))
        let frame = try await nextServerFrame()
        XCTAssertNil(frame, "An unbound sink must not deliver protected content.")
    }

    func testUnprotectedAuthorizationDeliversContent() async throws {
        await sink.applyAuthorization(makeSnapshot(revision: 1, access: .unprotected, principal: .unbound))
        await sink.send(.commandResult(requestID: "r", payload: .object(["ok": .bool(true)])))
        let frame = try await nextServerFrame()
        XCTAssertEqual(frame?.type, "command_result")
        XCTAssertEqual(frame?.requestID, "r")
    }

    // MARK: Locked access

    func testLockedAccessDropsProtectedButAllowsSafeControl() async throws {
        await sink.applyAuthorization(makeSnapshot(revision: 1, access: .locked, binding: bindingA))

        await sink.send(.commandResult(requestID: "r", payload: .object(["secret": .string("x")])))
        let dropped = try await nextServerFrame()
        XCTAssertNil(dropped, "Protected content must be dropped while locked.")

        let delivered = await sink.sendSafeControl(GatewaySafeControlEnvelope.lockState(access: GatewayAccessMetadata(
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
        let control = try await nextServerFrame()
        XCTAssertEqual(control?.type, "lock_state")
        XCTAssertEqual(control?.payload?.objectValue?["reason"]?.stringValue, "passkey_locked")
    }

    // MARK: Grant deadline

    func testGrantDeadlineExactEqualityDenies() async throws {
        let deadline = clock.now().advanced(by: GatewayAccessTiming.idleGrantLifetime)
        let grant = GatewayDeviceGrant(id: "g", deadline: deadline)
        await sink.applyAuthorization(makeSnapshot(revision: 1, access: .unlockedUntilGrantDeadline, grant: grant, binding: bindingA))

        // Strictly before the deadline: delivered.
        await sink.send(.commandResult(requestID: "before", payload: .object([:])))
        let before = try await nextServerFrame()
        XCTAssertEqual(before?.requestID, "before", "expected pre-deadline delivery")

        // Exactly at the deadline: denied (now < deadline is false at equality).
        clock.advance(by: GatewayAccessTiming.idleGrantLifetime)
        await sink.send(.commandResult(requestID: "at", payload: .object([:])))
        let atDeadline = try await nextServerFrame()
        XCTAssertNil(atDeadline, "A frame enqueued exactly at the deadline must be denied.")
    }

    // MARK: Stale publication

    func testStalePublicationIsIgnored() async throws {
        await sink.applyAuthorization(makeSnapshot(revision: 2, access: .locked, binding: bindingA))
        // An older revision cannot reopen access after a newer (locked) publication landed.
        await sink.applyAuthorization(makeSnapshot(revision: 1, access: .unprotected, principal: .unbound))
        await sink.send(.commandResult(requestID: "r", payload: .object([:])))
        let afterStale = try await nextServerFrame()
        XCTAssertNil(afterStale, "A stale publication must not reopen a locked sink.")
    }

    // MARK: Correlated responses

    func testSendResponseOriginalEnqueuedWhenAuthorized() async throws {
        await sink.applyAuthorization(makeSnapshot(revision: 1, access: .unprotected, principal: .unbound))
        let context = makeContext(binding: nil, revision: 1)
        await sink.registerPendingResponse(context)
        let outcome = await sink.sendResponse(.commandResult(requestID: "r", payload: .object(["ok": .bool(true)])), for: context)
        XCTAssertEqual(outcome, .originalEnqueued)
        let frame = try await nextServerFrame()
        XCTAssertEqual(frame?.type, "command_result")
    }

    func testSendResponseLockReplacementWhenLocked() async throws {
        await sink.applyAuthorization(makeSnapshot(revision: 1, access: .locked, binding: bindingA))
        let context = makeContext(binding: bindingA, revision: 1)
        await sink.registerPendingResponse(context)
        let outcome = await sink.sendResponse(.commandResult(requestID: "r", payload: .object(["secret": .string("x")])), for: context)
        XCTAssertEqual(outcome, .lockReplacementEnqueued)
        let frame = try await nextServerFrame()
        XCTAssertEqual(frame?.type, "command_error")
        XCTAssertEqual(frame?.payload?.objectValue?["code"]?.stringValue, "passkey_locked")
    }

    func testSendResponseBindingChangeWithholdsOriginal() async {
        // Admitted under bindingA; a live unlocked grant exists but the current binding is bindingB
        // (a different lock generation), so the admitted original must be withheld.
        let grant = GatewayDeviceGrant(id: "g", deadline: clock.now().advanced(by: GatewayAccessTiming.idleGrantLifetime))
        await sink.applyAuthorization(makeSnapshot(revision: 1, access: .unlockedUntilGrantDeadline, grant: grant, binding: bindingB))
        let context = makeContext(binding: bindingA, revision: 1)
        await sink.registerPendingResponse(context)
        let outcome = await sink.sendResponse(.commandResult(requestID: "r", payload: .object([:])), for: context)
        XCTAssertEqual(outcome, .lockReplacementEnqueued)
    }

    func testSendResponseSettlementTokenIsOneShot() async {
        await sink.applyAuthorization(makeSnapshot(revision: 1, access: .unprotected, principal: .unbound))
        let context = makeContext(binding: nil, revision: 1)
        await sink.registerPendingResponse(context)
        let first = await sink.sendResponse(.commandResult(requestID: "r", payload: .object([:])), for: context)
        XCTAssertEqual(first, .originalEnqueued)
        let second = await sink.sendResponse(.commandResult(requestID: "r", payload: .object([:])), for: context)
        XCTAssertEqual(second, .notEnqueued, "A consumed settlement token must not re-enqueue.")
    }

    func testSendResponseAfterCloseReturnsNotEnqueued() async {
        await sink.applyAuthorization(makeSnapshot(revision: 1, access: .unprotected, principal: .unbound))
        let context = makeContext(binding: nil, revision: 1)
        await sink.registerPendingResponse(context)
        await sink.close()
        XCTAssertFalse(sink.fence.isActive)
        let outcome = await sink.sendResponse(.commandResult(requestID: "r", payload: .object([:])), for: context)
        XCTAssertEqual(outcome, .notEnqueued)
    }

    // MARK: Catch-up convergence after Lock

    /// Scope note: this proves the OUTGOING catch-up boundary at the production sink — the point where
    /// the authorization gate actually drops passive `session_update` catch-up frames once a Lock has
    /// landed. Driving a real `SessionWatchManager` catch-up poll end-to-end through the loopback
    /// server is not deterministically schedulable without real-time waits, so per the Step 3
    /// directive the queue/catch-up convergence is proven here against the actual sink (no sleeps),
    /// while the E2E suite proves the `lock_state` notification and locked settlement over a real
    /// socket. The lock is published exactly as the authority publishes it: the locked authorization
    /// and the content-free `lock_state` are scheduled in ONE synchronous batch (before any await),
    /// and the barrier is awaited before the post-lock catch-up is attempted.
    func testOutgoingCatchUpIsDroppedOnceLockPublicationConverges() async throws {
        let grant = GatewayDeviceGrant(id: "g", deadline: clock.now().advanced(by: GatewayAccessTiming.idleGrantLifetime))
        await sink.applyAuthorization(makeSnapshot(revision: 1, access: .unlockedUntilGrantDeadline, grant: grant, binding: bindingA))

        // A pre-lock outgoing catch-up (passive protected path) is delivered.
        await sink.send(RemoteServerFrame(type: "session_update", sessionID: "session-a", seq: 1, payload: .object(["seq": .int(1)])))
        let delivered = try await nextServerFrame()
        XCTAssertEqual(delivered?.type, "session_update", "A catch-up before the lock is delivered.")

        // The authority's Lock mutation schedules BOTH the locked authorization and the content-free
        // lock_state in one synchronous batch (before any await); settle its barrier.
        let lockedMetadata = GatewayAccessMetadata(
            policyState: .required,
            locked: true,
            enrolled: true,
            enrollmentOpen: false,
            reason: .locked,
            grantID: nil,
            epoch: 1,
            lockGeneration: 2,
            deadlineSecondsRemaining: nil
        )
        let lockBarrier = GatewayPublicationBarrier(receipts: [
            sink.scheduleAuthorization(makeSnapshot(revision: 2, access: .locked, binding: bindingA), expectedIncarnation: sink.incarnation),
            sink.scheduleSafeControl(.lockState(access: lockedMetadata), expectedIncarnation: sink.incarnation)
        ])
        await lockBarrier.settle()

        // The content-free lock_state crossed the gate...
        let lockState = try await nextServerFrame()
        XCTAssertEqual(lockState?.type, "lock_state")
        XCTAssertEqual(lockState?.payload?.objectValue?["reason"]?.stringValue, "passkey_locked")

        // ...but every outgoing catch-up AFTER the lock publication is dropped at the authorization gate.
        await sink.send(RemoteServerFrame(type: "session_update", sessionID: "session-a", seq: 2, payload: .object(["seq": .int(2)])))
        let afterLock = try await nextServerFrame()
        XCTAssertNil(afterLock, "An outgoing catch-up after the Lock publication must be dropped.")
    }

    // MARK: Helpers

    private let bindingA = GatewayDeviceAccessBinding(
        launchNonce: "launch",
        policyEpoch: 1,
        originRevision: 1,
        lockGeneration: 1,
        authoritativeOrigin: "https://example.com"
    )
    private let bindingB = GatewayDeviceAccessBinding(
        launchNonce: "launch",
        policyEpoch: 1,
        originRevision: 1,
        lockGeneration: 2,
        authoritativeOrigin: "https://example.com"
    )

    private func makeSnapshot(
        revision: UInt64,
        access: GatewayAccess,
        grant: GatewayDeviceGrant? = nil,
        binding: GatewayDeviceAccessBinding? = nil,
        principal: GatewayAccessPrincipal = .pairedDevice(deviceID: "device")
    ) -> GatewayAuthorizationSnapshot {
        GatewayAuthorizationSnapshot(
            publicationRevision: GatewayPublicationRevision(value: revision),
            principal: principal,
            access: access,
            grant: grant,
            binding: binding
        )
    }

    private func makeContext(binding: GatewayDeviceAccessBinding?, revision: UInt64) -> GatewayRequestContext {
        GatewayRequestContext(
            principal: .pairedDevice(deviceID: "device"),
            deviceID: "device",
            requestID: "r",
            admissionBinding: binding,
            admissionRevision: GatewayPublicationRevision(value: revision)
        )
    }

    private func nextServerFrame() async throws -> RemoteServerFrame? {
        guard let ws = try await channel.readOutbound(as: WebSocketFrame.self) else { return nil }
        var buffer = ws.data
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return nil }
        return try JSONDecoder().decode(RemoteServerFrame.self, from: Data(bytes))
    }
}
