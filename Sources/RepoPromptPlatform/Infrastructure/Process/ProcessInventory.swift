import Darwin
import Foundation

/// One bounded same-user process inventory (lossless restart R6). Read-only: it never signals,
/// polls, caches or decides ownership. Callers run it off the main actor (system queries block).
package struct ProcessInventorySnapshot: Equatable {
    /// Why an inventory cannot claim it saw every candidate process.
    package enum Incompleteness: Equatable {
        /// The PID listing itself failed.
        case listingFailed(errno: Int32)
        /// More PIDs exist than the inventory bound allows.
        case truncated
        /// At least one listed PID produced no birth identity (denied, malformed or racing).
        case inspectionUnavailable(count: Int)
    }

    /// Consistent samples of the listed processes that were still present.
    package let observations: [ProcessObservation]
    /// Empty when every listed PID was either observed or confirmed absent. A complete inventory
    /// still only covers processes of the current user: a descendant that changed user is never
    /// listed, so completeness is meaningful only for a qualified process family.
    package let incompleteness: [Incompleteness]

    package var isComplete: Bool {
        incompleteness.isEmpty
    }

    package init(observations: [ProcessObservation], incompleteness: [Incompleteness]) {
        self.observations = observations
        self.incompleteness = incompleteness
    }
}

package struct ProcessInventory {
    /// The default bound on listed processes; larger listings are reported truncated.
    package static let defaultLimit = 8192

    /// A failed PID listing and its errno.
    struct ListingFailure: Error, Equatable {
        let errno: Int32
    }

    struct Backend {
        /// PIDs of processes owned by the current user, or the listing failure.
        var listUserPIDs: @Sendable (_ limit: Int) -> Result<(pids: [pid_t], truncated: Bool), ListingFailure>
        var inspect: @Sendable (pid_t) -> ProcessInspectionResult
    }

    private let backend: Backend
    private let limit: Int

    init(backend: Backend, limit: Int = ProcessInventory.defaultLimit) {
        self.backend = backend
        self.limit = max(limit, 1)
    }

    package static func snapshot(limit: Int = ProcessInventory.defaultLimit) -> ProcessInventorySnapshot {
        ProcessInventory(backend: .live, limit: limit).snapshot()
    }

    func snapshot() -> ProcessInventorySnapshot {
        let listing: (pids: [pid_t], truncated: Bool)
        switch backend.listUserPIDs(limit) {
        case let .success(value): listing = value
        case let .failure(failure):
            return ProcessInventorySnapshot(observations: [], incompleteness: [.listingFailed(errno: failure.errno)])
        }
        var observations: [ProcessObservation] = []
        var unavailable = 0
        for pid in Set(listing.pids).sorted() where pid > 0 {
            switch backend.inspect(pid) {
            case let .observed(observation): observations.append(observation)
            case .notFound: continue
            case .unavailable: unavailable += 1
            }
        }
        var incompleteness: [ProcessInventorySnapshot.Incompleteness] = []
        if listing.truncated { incompleteness.append(.truncated) }
        if unavailable > 0 { incompleteness.append(.inspectionUnavailable(count: unavailable)) }
        return ProcessInventorySnapshot(observations: observations, incompleteness: incompleteness)
    }
}

extension ProcessInventory.Backend {
    static let live = ProcessInventory.Backend(
        listUserPIDs: { limit in
            let uid = geteuid()
            // One extra slot distinguishes "exactly full" from "more exist".
            var buffer = [pid_t](repeating: 0, count: limit + 1)
            errno = 0
            let bytes = buffer.withUnsafeMutableBytes { raw in
                proc_listpids(UInt32(PROC_UID_ONLY), uid, raw.baseAddress, Int32(raw.count))
            }
            let capturedErrno = errno
            guard bytes > 0 else { return .failure(ProcessInventory.ListingFailure(errno: capturedErrno == 0 ? EIO : capturedErrno)) }
            let count = Int(bytes) / MemoryLayout<pid_t>.size
            let pids = Array(buffer.prefix(min(count, limit)))
            return .success((pids: pids, truncated: count > limit))
        },
        inspect: { pid in ProcessInspection.inspect(pid: pid) }
    )
}

/// One exit watch on a process lifetime (`EVFILT_PROC`/`NOTE_EXIT` through Dispatch). The handler
/// runs at most once, on an arbitrary queue; `cancel()` withdraws it unless it already started, so
/// owners still fence delivered events by their own generation. A watch installed
/// on a process that already exited may never fire, so owners must re-verify identity after
/// installing it rather than assume the process is alive.
package final class ProcessExitWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var source: DispatchSourceProcess?
    private var handler: (@Sendable () -> Void)?

    package init(pid: pid_t, queue: DispatchQueue = .global(qos: .utility), handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        self.source = source
        source.setEventHandler { [weak self] in
            self?.fire()
        }
        source.resume()
    }

    deinit {
        source?.cancel()
    }

    private func fire() {
        lock.lock()
        let handler = handler
        self.handler = nil
        let source = source
        self.source = nil
        lock.unlock()
        source?.cancel()
        handler?()
    }

    package func cancel() {
        lock.lock()
        handler = nil
        let source = source
        self.source = nil
        lock.unlock()
        source?.cancel()
    }
}
