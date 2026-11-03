import Foundation

/// Per-invocation timing and work counters for one `history` tool call.
///
/// One instance belongs to exactly one call: the long-lived ``HistorySessionScanner``
/// never stores it, it only receives it as an argument. Phases are exclusive — entering
/// a phase closes the current one and accumulates its duration — so alternating phases
/// (e.g. `transcriptLoad`/`transcriptTraversal` per session) sum correctly.
///
/// The optional phase observer is invoked synchronously, under the instance lock, in
/// transition order. It must be non-blocking and must not call back into this object.
/// It is the bridge the app provider uses to surface the current phase to the MCP
/// execution watchdog without hopping actors.
///
/// The summary never contains query text, transcript content, or filesystem paths.
package final class HistoryExecutionDiagnostics: @unchecked Sendable {
    package enum Phase: String, CaseIterable {
        case inventoryWait = "inventory_wait"
        case inventoryEnumeration = "inventory_enumeration"
        case inventoryIndexScan = "inventory_index_scan"
        case filtering
        case sorting
        case transcriptLoad = "transcript_load"
        case transcriptTraversal = "transcript_traversal"
        case aggregation
        case replyConstruction = "reply_construction"
    }

    package enum PhaseTransition: String {
        case started
        case completed
    }

    package typealias PhaseObserver = @Sendable (Phase, PhaseTransition) -> Void

    package struct Counters: Equatable {
        package var workspaceDirsVisited = 0
        package var indexCacheHits = 0
        package var indexDecodes = 0
        package var recordsConsidered = 0
        package var recordsRetained = 0
        package var transcriptAttempts = 0
        package var transcriptCacheHits = 0
        package var transcriptDecodes = 0
        package var inventoryFromTTLCache = false

        package init() {}
    }

    package struct Snapshot: Equatable {
        package let operation: String
        package let elapsed: Duration
        package let currentPhase: Phase?
        /// The most recently entered phase, even after it was closed — where a
        /// cancelled or failed call last was.
        package let lastPhase: Phase?
        package let phaseDurations: [Phase: Duration]
        package let counters: Counters
    }

    /// Operation labels are restricted to the known ops so arbitrary caller text never
    /// reaches a log line.
    private static let knownOperations: Set<String> = ["list_sessions", "search", "time", "get_session"]

    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private let phaseObserver: PhaseObserver?
    private var operation = "unknown"
    private var currentPhase: Phase?
    private var lastPhase: Phase?
    private var currentPhaseStartedAt: ContinuousClock.Instant?
    private var phaseDurations: [Phase: Duration] = [:]
    private var counters = Counters()

    package init(phaseObserver: PhaseObserver? = nil) {
        start = clock.now
        self.phaseObserver = phaseObserver
    }

    /// Record the requested op. Unknown ops are labelled `invalid` rather than echoed.
    package func setOperation(_ op: String?) {
        let label = op.map { Self.knownOperations.contains($0) ? $0 : "invalid" } ?? "invalid"
        lock.withLock { operation = label }
    }

    /// Enter `phase`, closing the current phase. Re-entering the current phase is a no-op.
    package func enter(_ phase: Phase) {
        lock.withLock {
            guard currentPhase != phase else { return }
            let now = clock.now
            closeCurrentPhaseLocked(at: now)
            currentPhase = phase
            lastPhase = phase
            currentPhaseStartedAt = now
            phaseObserver?(phase, .started)
        }
    }

    /// Close the current phase, if any.
    package func endPhase() {
        lock.withLock {
            closeCurrentPhaseLocked(at: clock.now)
        }
    }

    package func updateCounters(_ update: (inout Counters) -> Void) {
        lock.withLock { update(&counters) }
    }

    package func snapshot() -> Snapshot {
        lock.withLock {
            let now = clock.now
            var durations = phaseDurations
            if let currentPhase, let currentPhaseStartedAt {
                durations[currentPhase, default: .zero] += currentPhaseStartedAt.duration(to: now)
            }
            return Snapshot(
                operation: operation,
                elapsed: start.duration(to: now),
                currentPhase: currentPhase,
                lastPhase: lastPhase,
                phaseDurations: durations,
                counters: counters
            )
        }
    }

    /// One-line, privacy-safe summary: op, outcome, elapsed, last phase, per-phase
    /// milliseconds (declaration order, only phases that ran), and counters.
    package func summaryLine(outcome: String) -> String {
        let snapshot = snapshot()
        let phases = Phase.allCases.compactMap { phase -> String? in
            guard let duration = snapshot.phaseDurations[phase] else { return nil }
            return "\(phase.rawValue):\(Self.milliseconds(duration))"
        }
        let counters = snapshot.counters
        return [
            "history_call",
            "op=\(snapshot.operation)",
            "outcome=\(outcome)",
            "elapsed_ms=\(Self.milliseconds(snapshot.elapsed))",
            "last_phase=\(snapshot.lastPhase?.rawValue ?? "none")",
            "phases_ms=\(phases.isEmpty ? "none" : phases.joined(separator: ","))",
            "inventory_from_ttl_cache=\(counters.inventoryFromTTLCache)",
            "workspace_dirs_visited=\(counters.workspaceDirsVisited)",
            "index_cache_hits=\(counters.indexCacheHits)",
            "index_decodes=\(counters.indexDecodes)",
            "records_considered=\(counters.recordsConsidered)",
            "records_retained=\(counters.recordsRetained)",
            "transcript_attempts=\(counters.transcriptAttempts)",
            "transcript_cache_hits=\(counters.transcriptCacheHits)",
            "transcript_decodes=\(counters.transcriptDecodes)"
        ].joined(separator: " ")
    }

    private func closeCurrentPhaseLocked(at now: ContinuousClock.Instant) {
        guard let phase = currentPhase, let startedAt = currentPhaseStartedAt else { return }
        phaseDurations[phase, default: .zero] += startedAt.duration(to: now)
        currentPhase = nil
        currentPhaseStartedAt = nil
        phaseObserver?(phase, .completed)
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let ms = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.1f", ms)
    }
}
