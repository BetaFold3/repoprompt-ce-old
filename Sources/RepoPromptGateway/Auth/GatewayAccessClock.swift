import Foundation

// MARK: - Monotonic access clock (remote passkey unlock, Step 3)

// Security deadlines for passkey grants are measured on a MONOTONIC clock, never wall-clock time: a
// wall-clock adjustment (NTP, manual change, DST) must never extend or shorten a grant. Wall-clock
// instants remain available only as display metadata for the browser. The clock is injected so the
// authority actor and every per-connection outbound sink share one time source, and so tests advance
// time explicitly instead of sleeping. (Step 3 plan §7.)

/// An opaque monotonic instant. Only meaningful relative to other instants produced by the same
/// clock lineage. Backed by `ContinuousClock` in production.
struct GatewayMonotonicInstant: Comparable, Hashable {
    /// Monotonic nanoseconds since the owning clock's fixed base. Never compared across clocks.
    let nanosecondsSinceBase: Int64

    static func < (lhs: GatewayMonotonicInstant, rhs: GatewayMonotonicInstant) -> Bool {
        lhs.nanosecondsSinceBase < rhs.nanosecondsSinceBase
    }

    /// The instant reached `duration` after `self`. Used to derive a grant deadline from a captured
    /// activity-acceptance instant (`activity time + 30 minutes`).
    func advanced(by duration: Duration) -> GatewayMonotonicInstant {
        GatewayMonotonicInstant(nanosecondsSinceBase: nanosecondsSinceBase &+ Self.nanoseconds(from: duration))
    }

    static func nanoseconds(from duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds &* 1_000_000_000 &+ components.attoseconds / 1_000_000_000
    }
}

/// A cancellable one-shot timer handle. Cancelling guarantees the callback will not fire afterward.
protocol GatewayExpiryTimer: Sendable {
    func cancel()
}

/// Minimal injected monotonic clock dependency shared by the gateway access authority and the
/// per-connection outbound sinks. Production is backed by `ContinuousClock`; tests supply a clock
/// they advance explicitly so no test waits on real time.
protocol GatewayAccessClock: Sendable {
    /// Monotonic "now". Never moves backward and is unaffected by wall-clock changes.
    func now() -> GatewayMonotonicInstant

    /// Schedule `fire` to run once at or after `deadline`, returning a cancellable handle. The
    /// callback MUST re-check grant id and expected deadline before acting, so a stale timer cannot
    /// expire a renewed grant. Production sleeps on the monotonic clock; tests fire deterministically
    /// when their virtual time is advanced past `deadline` (no real sleep).
    func scheduleExpiry(at deadline: GatewayMonotonicInstant, fire: @escaping @Sendable () -> Void) -> GatewayExpiryTimer
}

/// A `GatewayExpiryTimer` backed by a cancellable `Task` sleeping on the monotonic clock.
final class GatewayTaskExpiryTimer: GatewayExpiryTimer, @unchecked Sendable {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

/// Production monotonic clock backed by `ContinuousClock`.
final class GatewayContinuousAccessClock: GatewayAccessClock, @unchecked Sendable {
    private let clock = ContinuousClock()
    private let base: ContinuousClock.Instant

    init() {
        base = ContinuousClock().now
    }

    func now() -> GatewayMonotonicInstant {
        GatewayMonotonicInstant(nanosecondsSinceBase: GatewayMonotonicInstant.nanoseconds(from: base.duration(to: clock.now)))
    }

    func scheduleExpiry(at deadline: GatewayMonotonicInstant, fire: @escaping @Sendable () -> Void) -> GatewayExpiryTimer {
        let remainingNanoseconds = max(0, deadline.nanosecondsSinceBase &- now().nanosecondsSinceBase)
        let delay = Duration.nanoseconds(remainingNanoseconds)
        let task = Task {
            try? await Task.sleep(for: delay)
            if !Task.isCancelled {
                fire()
            }
        }
        return GatewayTaskExpiryTimer(task: task)
    }
}

/// Fixed, owner-decided access timing constants (remote passkey unlock, Step 3).
enum GatewayAccessTiming {
    /// A passkey grant expires after this much CONTINUOUS idle time, measured monotonically. Shared
    /// across paired-identity tabs and reconnects, with no absolute cap. Renewal requires an explicit
    /// signed foreground-activity frame plus a fresh successful principal trust refresh. (Owner
    /// decision; supersedes all historical timer prose.)
    static let idleGrantLifetime: Duration = .seconds(30 * 60)

    /// Minimum spacing between accepted activity-renewal attempts for one device: at most one attempt
    /// per 30 seconds, with at most one in flight. Throttled frames consume their signed counter but
    /// neither renew nor queue a future renewal. (Oracle-suggested bound; does not change the idle
    /// duration.)
    static let renewalMinInterval: Duration = .seconds(30)

    /// Maximum monotonic lifetime of a PREFETCHED pending ASSERTION ceremony (begin with no completion
    /// yet), bounded CONSERVATIVELY to the app's WebAuthn assertion-challenge timeout (~60s) captured at
    /// begin time: once it elapses the pending can no longer be TAKEN for completion — the expiry is
    /// checked when a completion tries to take the pending (`takePendingCeremony` via
    /// `pendingCeremonyExpired`), because the app challenge it rode would itself have expired. (A
    /// completion whose pending was already taken is instead rejected at commit by the per-kind
    /// generation check, not by this lifetime.) This expiry is only a safety net — a fresh begin SAFELY
    /// REPLACES any pending of the same kind immediately (advancing the per-kind ceremony generation),
    /// so a cancelled native prompt retries at once without a lock, disconnect, or an invented wait
    /// (S3-I06).
    static let assertionPendingLifetime: Duration = .seconds(60)

    /// Registration challenges also last 60 seconds. The app's separate 120-second Mac enrollment
    /// authorization window does not extend an individual challenge (S3-I06).
    static let registrationPendingLifetime: Duration = .seconds(60)
}
