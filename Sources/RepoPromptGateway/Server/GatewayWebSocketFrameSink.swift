import Foundation
import NIOCore
import NIOWebSocket
import RepoPromptRemoteWire

// MARK: - Production WebSocket frame sink (remote passkey unlock, Step 3)

// The single outbound authorization boundary for one connection. Extracted from `GatewayHTTPServer`
// so it can be exercised directly against an embedded channel and an injected clock.
//
// Closed-by-default: a freshly created sink is UNBOUND and will not deliver protected content until
// the authority applies an authorization snapshot (real per-connection policy binding). All
// authorization/queue state is owned exclusively by the connection's NIO event loop (every mutation
// runs inside an `eventLoop.submit` block, or synchronously while already on the loop). A separate
// synchronous lifecycle fence lets a late commit linearize against disconnect. Correlated runtime
// responses settle through `sendResponse(_:for:)`; locks and failures ride the typed safe-control
// builders, which carry no protected content.
final class GatewayWebSocketFrameSink: RemoteFrameSink, @unchecked Sendable {
    static let maximumQueuedFrames = 128

    /// Immutable identity of this connection incarnation.
    let incarnation: UUID
    /// Synchronous liveness fence shared with the authority for commit linearization.
    let fence: GatewayConnectionLifecycleFence

    private let channel: Channel
    private let clock: GatewayAccessClock

    // Event-loop-owned state. Mutated only on `channel.eventLoop`.
    private var authorization: GatewayAuthorizationSnapshot?
    private var appliedRevision: GatewayPublicationRevision = .initial
    private var pendingFrameCount = 0
    private var outstandingSettlements: Set<UUID> = []

    init(
        channel: Channel,
        clock: GatewayAccessClock,
        incarnation: UUID = UUID(),
        fence: GatewayConnectionLifecycleFence = GatewayConnectionLifecycleFence()
    ) {
        self.channel = channel
        self.clock = clock
        self.incarnation = incarnation
        self.fence = fence
    }

    // MARK: RemoteFrameSink (protected, passive)

    /// Protected passive delivery for all frame types, including unknown types. Returns after the
    /// event loop has ENQUEUED or REJECTED the frame; it does not promise network delivery. A frame
    /// is rejected when the sink is unbound, locked, past its grant deadline, closed, or over the
    /// `session_update` queue cap.
    func send(_ frame: RemoteServerFrame) async {
        _ = await runOnLoop { self.enqueueProtectedOnLoop(frame) }
    }

    func close() async {
        fence.close()
        await runOnLoopVoid {
            if self.channel.isActive {
                self.channel.close(promise: nil)
            }
        }
    }

    // MARK: Authorization publication

    /// SYNCHRONOUSLY schedule application of a newer authorization snapshot onto the event loop and
    /// return a barrier receipt that completes after the loop has applied (or ignored) it. The
    /// scheduling itself does not suspend: the authority calls this for every affected connection
    /// BEFORE its first await, so all publications are ordered and in-flight before any suspension.
    /// On the loop the sink ignores the publication unless its incarnation matches `expectedIncarnation`
    /// and the revision is strictly newer than the one already applied, so a stale publication can
    /// never reopen access after a newer one (e.g. a Lock) has landed.
    func scheduleAuthorization(_ snapshot: GatewayAuthorizationSnapshot, expectedIncarnation: UUID) -> GatewayBarrierReceipt {
        let future = channel.eventLoop.submit { [self] in
            guard incarnation == expectedIncarnation else { return }
            guard snapshot.publicationRevision > appliedRevision else { return }
            appliedRevision = snapshot.publicationRevision
            authorization = snapshot
        }
        return GatewayBarrierReceipt(future)
    }

    /// Async convenience over `scheduleAuthorization` using this sink's own incarnation. Awaits the
    /// barrier so callers that do not need cross-connection publication ordering stay simple.
    func applyAuthorization(_ snapshot: GatewayAuthorizationSnapshot) async {
        await scheduleAuthorization(snapshot, expectedIncarnation: incarnation).wait()
    }

    /// SYNCHRONOUSLY schedule a content-free safe-control frame (e.g. a `lock_state` notification) onto
    /// the event loop, returning a barrier receipt. This variant is NOT revision-gated: it enqueues the
    /// frame whenever the incarnation still matches. The authority's own transition notices (lock,
    /// expiry, trust refresh, assertion, renewal) are revision-bound and go through
    /// `scheduleSafeControlIfCurrent`; this plain primitive is for liveness-gated control frames that
    /// have no cross-tab revision-ordering requirement. Only liveness-gated —
    /// `GatewaySafeControlEnvelope` guarantees the frame carries no protected content, so it is allowed
    /// regardless of access state.
    func scheduleSafeControl(_ envelope: GatewaySafeControlEnvelope, expectedIncarnation: UUID) -> GatewayBarrierReceipt {
        let frame = envelope.frame
        let future = channel.eventLoop.submit { [self] in
            guard incarnation == expectedIncarnation else { return }
            _ = enqueueControlOnLoop(frame)
        }
        return GatewayBarrierReceipt(future)
    }

    /// SYNCHRONOUSLY schedule an access-state notice bound to a SPECIFIC authorization revision. On the
    /// loop it is delivered ONLY while this sink's currently-applied authorization revision still equals
    /// `expectedRevision`; if a newer authorization has been applied (a superseding transition landed
    /// first), the notice is DROPPED. The authority schedules the transition's authorization change,
    /// awaits its all-sink barrier, then schedules this notice — so a notice can never precede its own
    /// cross-tab barrier, and a superseded (stale) notice can never overwrite a newer applied state
    /// (S3-I02). Liveness/incarnation gated like the other control path; carries no protected content.
    func scheduleSafeControlIfCurrent(
        _ envelope: GatewaySafeControlEnvelope,
        expectedIncarnation: UUID,
        expectedRevision: GatewayPublicationRevision
    ) -> GatewayBarrierReceipt {
        let frame = envelope.frame
        let future = channel.eventLoop.submit { [self] in
            guard incarnation == expectedIncarnation else { return }
            guard appliedRevision == expectedRevision else { return }
            _ = enqueueControlOnLoop(frame)
        }
        return GatewayBarrierReceipt(future)
    }

    // MARK: Correlated responses

    /// Register an admitted request's one-shot settlement token so its eventual response can be
    /// settled exactly once through `sendResponse(_:for:)`.
    func registerPendingResponse(_ context: GatewayRequestContext) async {
        await runOnLoopVoid { self.outstandingSettlements.insert(context.serverToken) }
    }

    /// Release a registered settlement token WITHOUT enqueuing anything. Used when the admitted
    /// request produced no correlated response (e.g. a streaming frame whose updates ride the passive
    /// path), so the one-shot token is not leaked for the life of the connection.
    func discardPendingResponse(_ context: GatewayRequestContext) async {
        await runOnLoopVoid { _ = self.outstandingSettlements.remove(context.serverToken) }
    }

    /// Settle a correlated runtime response. The original is released only if current authorization
    /// still permits it and its admission binding is unchanged; otherwise a generic, content-free lock
    /// settlement is enqueued in its place. The settlement token is consumed once.
    func sendResponse(_ frame: RemoteServerFrame, for context: GatewayRequestContext) async -> GatewayDeliveryOutcome {
        await runOnLoop { self.settleOnLoop(frame, context) } ?? .notEnqueued
    }

    // MARK: Typed safe controls

    /// Enqueue a bounded, content-free control frame (lock state, settlement, failure, completion).
    /// Allowed regardless of access state because `GatewaySafeControlEnvelope` guarantees by
    /// construction that no protected content rides this path; still gated on liveness. A raw
    /// `RemoteServerFrame` cannot be passed here, so there is no arbitrary-frame control escape.
    @discardableResult
    func sendSafeControl(_ envelope: GatewaySafeControlEnvelope) async -> Bool {
        let frame = envelope.frame
        return await runOnLoop { self.enqueueControlOnLoop(frame) } ?? false
    }

    // MARK: Event-loop-owned implementation

    private func enqueueProtectedOnLoop(_ frame: RemoteServerFrame) -> Bool {
        guard fence.isActive, channel.isActive, let authorization else { return false }
        guard authorization.authorizesProtectedContent(now: clock.now()) else { return false }
        return writeOnLoop(frame, isControl: false)
    }

    private func enqueueControlOnLoop(_ frame: RemoteServerFrame) -> Bool {
        guard fence.isActive, channel.isActive else { return false }
        return writeOnLoop(frame, isControl: true)
    }

    private func settleOnLoop(_ frame: RemoteServerFrame, _ context: GatewayRequestContext) -> GatewayDeliveryOutcome {
        // One-shot: consume the token first so a duplicate/late settlement cannot re-enqueue.
        guard outstandingSettlements.remove(context.serverToken) != nil else { return .notEnqueued }
        guard fence.isActive, channel.isActive else { return .notEnqueued }
        if isResponseAuthorizedOnLoop(context) {
            return writeOnLoop(frame, isControl: false) ? .originalEnqueued : .notEnqueued
        }
        let settlement = GatewaySafeControlEnvelope.lockSettlement(requestID: context.requestID).frame
        return writeOnLoop(settlement, isControl: true) ? .lockReplacementEnqueued : .notEnqueued
    }

    private func isResponseAuthorizedOnLoop(_ context: GatewayRequestContext) -> Bool {
        guard let authorization else { return false }
        guard authorization.authorizesProtectedContent(now: clock.now()) else { return false }
        // An admitted request may only release its original response if the binding it was admitted
        // under is still current: a Lock, epoch, origin, or launch change invalidates it.
        if let admissionBinding = context.admissionBinding {
            guard authorization.binding == admissionBinding else { return false }
        }
        return true
    }

    private func writeOnLoop(_ frame: RemoteServerFrame, isControl: Bool) -> Bool {
        guard let data = try? RemoteWireProtocol.encodeServerFrame(frame) else { return false }
        if !isControl, pendingFrameCount >= Self.maximumQueuedFrames, frame.type == "session_update" {
            return false
        }
        pendingFrameCount += 1
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let wsFrame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        channel.writeAndFlush(wsFrame).whenComplete { [weak self] _ in
            // Runs on the channel's event loop.
            self?.decrementPendingFrameCountOnLoop()
        }
        return true
    }

    private func decrementPendingFrameCountOnLoop() {
        pendingFrameCount = max(0, pendingFrameCount - 1)
    }

    private func runOnLoop<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T? {
        do {
            return try await channel.eventLoop.submit(body).get()
        } catch {
            return nil
        }
    }

    private func runOnLoopVoid(_ body: @escaping @Sendable () -> Void) async {
        _ = await runOnLoop {
            body()
            return true
        }
    }
}

// MARK: - Publication barriers

/// A receipt for one scheduled event-loop publication. `wait()` completes after the loop has applied
/// (or ignored) the publication. Backed by a NIO `EventLoopFuture`, whose completion is internally
/// synchronized by NIO, so awaiting it from the authority actor is safe.
final class GatewayBarrierReceipt: @unchecked Sendable {
    private let future: EventLoopFuture<Void>

    init(_ future: EventLoopFuture<Void>) {
        self.future = future
    }

    func wait() async {
        _ = try? await future.get()
    }
}

/// A set of publication barriers produced by one synchronous authority mutation. The authority
/// schedules every affected connection's publication synchronously (before any await) and returns
/// this barrier; the caller awaits `settle()` so an acknowledgement (e.g. a Lock ack) is emitted only
/// after all publications have crossed their loop barriers. (Step 3 plan §1.)
struct GatewayPublicationBarrier {
    let receipts: [GatewayBarrierReceipt]

    static let empty = GatewayPublicationBarrier(receipts: [])

    func settle() async {
        for receipt in receipts {
            await receipt.wait()
        }
    }
}
