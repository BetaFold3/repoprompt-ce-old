import Foundation
@testable import RepoPromptGateway

/// A deterministic monotonic clock advanced explicitly by tests (never backed by real time). It also
/// drives `scheduleExpiry` deterministically: a scheduled callback fires exactly when virtual time is
/// advanced to or past its deadline (or immediately if already due), and never after `cancel()`.
final class ManualAccessClock: GatewayAccessClock, @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: Int64
    private var timers: [UUID: (deadline: Int64, fire: @Sendable () -> Void)] = [:]

    init(startNanoseconds: Int64 = 0) {
        nanoseconds = startNanoseconds
    }

    func now() -> GatewayMonotonicInstant {
        lock.lock()
        defer { lock.unlock() }
        return GatewayMonotonicInstant(nanosecondsSinceBase: nanoseconds)
    }

    func scheduleExpiry(at deadline: GatewayMonotonicInstant, fire: @escaping @Sendable () -> Void) -> GatewayExpiryTimer {
        lock.lock()
        let id = UUID()
        timers[id] = (deadline.nanosecondsSinceBase, fire)
        lock.unlock()
        fireDueTimers()
        return Handle(clock: self, id: id)
    }

    /// Advance virtual time and fire any timers that have become due.
    func advance(by duration: Duration) {
        lock.lock()
        nanoseconds &+= GatewayMonotonicInstant.nanoseconds(from: duration)
        lock.unlock()
        fireDueTimers()
    }

    /// Number of timers currently scheduled (test observation).
    var scheduledTimerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return timers.count
    }

    private func fireDueTimers() {
        lock.lock()
        let current = nanoseconds
        let due = timers.filter { $0.value.deadline <= current }
        for id in due.keys {
            timers.removeValue(forKey: id)
        }
        lock.unlock()
        for entry in due.values {
            entry.fire()
        }
    }

    private func cancelTimer(_ id: UUID) {
        lock.lock()
        timers.removeValue(forKey: id)
        lock.unlock()
    }

    private final class Handle: GatewayExpiryTimer, @unchecked Sendable {
        private let clock: ManualAccessClock
        private let id: UUID

        init(clock: ManualAccessClock, id: UUID) {
            self.clock = clock
            self.id = id
        }

        func cancel() {
            clock.cancelTimer(id)
        }
    }
}
