import Foundation
import MCP

/// Final handoff boundary for one `tools/call` result (plan §6.2 delegated-question notices).
///
/// Code that attaches pending state to a result (reserved notices in `MCPServerViewModel.runTool`)
/// registers a participant. The connection handler then:
/// 1. hands completion observers `unannotated(value)`, the result without any participant's
///    attachment, so nothing pending is recorded before it is committed;
/// 2. after the last suspending completion processing, settles the transaction exactly once:
///    each participant revalidates, commits or strips its attachment, and synchronously records
///    what it committed;
/// 3. formats and returns the settled value without any further suspension.
/// The response therefore carries exactly what was committed and recorded at the final
/// handoff. Every other exit (thrown error, early return) abandons the transaction, which
/// releases each participant. Exactly one of `settle` or `abandon` runs per participant;
/// registration after the transaction closed abandons immediately.
final class MCPToolResultDeliveryTransaction: @unchecked Sendable {
    typealias Unannotate = @Sendable (_ value: Value) -> Value
    typealias Settle = @Sendable (_ value: Value, _ handOff: Bool) async -> Value
    typealias Abandon = @Sendable () -> Void

    private struct Participant {
        let unannotate: Unannotate
        let settle: Settle
        let abandon: Abandon
    }

    private let lock = NSLock()
    private var isClosed = false
    private var participants: [Participant] = []

    /// - Parameters:
    ///   - unannotate: Pure and synchronous: returns the value without this participant's
    ///     attachment (the view completion observers record before the final handoff).
    ///   - settle: Final handoff: revalidate, then commit or strip; returns the value to hand off.
    ///   - abandon: Releases the participant when the handler exits without a handoff.
    func register(
        unannotate: @escaping Unannotate = { $0 },
        settle: @escaping Settle,
        abandon: @escaping Abandon
    ) {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            abandon()
            return
        }
        participants.append(Participant(unannotate: unannotate, settle: settle, abandon: abandon))
        lock.unlock()
    }

    /// `value` without any open participant's attachment. Does not close the transaction.
    /// Returns `value` unchanged once the transaction closed.
    func unannotated(_ value: Value) -> Value {
        lock.lock()
        let open = participants
        lock.unlock()
        return open.reduce(value) { partial, participant in participant.unannotate(partial) }
    }

    /// Closes the transaction and threads `value` through every participant in registration
    /// order. `handOff` is false when the handler was cancelled: participants then strip and
    /// release instead of committing, because the SDK still returns a cancelled handler's result.
    /// `handOff` is sampled before any participant suspends, so a participant must also recheck
    /// `Task.isCancelled` at its own commit point (for example after hopping to the main actor).
    /// Callers must not suspend between this call and returning the settled value.
    /// A second settle (or a settle after abandon) returns `value` unchanged.
    func settle(_ value: Value, handOff: Bool) async -> Value {
        var settled = value
        for participant in close() {
            settled = await participant.settle(settled, handOff)
        }
        return settled
    }

    /// In-process `code_mode` child exit (plan §6 D3 notices): closes the transaction, strips
    /// each participant's attachment in registration order, and abandons (releases) every
    /// participant without settling, so a child never commits or acknowledges a notice.
    /// Synchronous: callers format and return the stripped value without suspending.
    /// After the transaction closed, returns `value` unchanged.
    func releaseAttachments(from value: Value) -> Value {
        let closed = close()
        let stripped = closed.reduce(value) { partial, participant in participant.unannotate(partial) }
        for participant in closed {
            participant.abandon()
        }
        return stripped
    }

    /// Releases every participant that never reached `settle`. Idempotent; first close wins.
    func abandon() {
        for participant in close() {
            participant.abandon()
        }
    }

    private func close() -> [Participant] {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return [] }
        isClosed = true
        let closed = participants
        participants.removeAll()
        return closed
    }
}
