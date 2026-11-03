import Darwin
import Foundation

/// A process instance: its PID plus its kernel start time, so a reused PID is a different
/// identity.
struct MCPHelperProcessIdentity: Equatable, Hashable {
    let pid: pid_t
    let startSeconds: Int64
    let startMicroseconds: Int32

    var startDescription: String {
        "\(startSeconds).\(String(format: "%06d", startMicroseconds))"
    }
}

/// One process-table lookup.
enum MCPProcessTableEntry: Equatable {
    case present(identity: MCPHelperProcessIdentity, parentPID: pid_t, isZombie: Bool)
    /// No process has this PID.
    case absent
    /// The lookup failed for another reason (permission, sysctl failure); nothing is known.
    case unreadable
}

/// Reads the process table. Injectable so tests can fake process lifetimes.
protocol MCPProcessTableReading: Sendable {
    func entry(for pid: pid_t) -> MCPProcessTableEntry
}

/// The live process table (`sysctl` `KERN_PROC_PID`).
struct MCPSystemProcessTableReader: MCPProcessTableReading {
    func entry(for pid: pid_t) -> MCPProcessTableEntry {
        guard pid > 0 else { return .absent }
        var info = kinfo_proc()
        var size = MemoryLayout.stride(ofValue: info)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
            return errno == ESRCH ? .absent : .unreadable
        }
        // A missing PID succeeds with an empty result.
        guard size > 0, info.kp_proc.p_pid == pid else { return .absent }
        return .present(
            identity: MCPHelperProcessIdentity(
                pid: pid,
                startSeconds: Int64(info.kp_proc.p_starttime.tv_sec),
                startMicroseconds: Int32(info.kp_proc.p_starttime.tv_usec)
            ),
            parentPID: info.kp_eproc.e_ppid,
            isZombie: Int32(info.kp_proc.p_stat) == SZOMB
        )
    }
}

/// Whether a previously captured process instance is still running.
enum MCPHelperProcessLiveness: Equatable {
    /// The same instance (PID and start time) is running and not a zombie.
    case alive(MCPHelperProcessIdentity)
    /// The instance is gone: no such PID, a zombie, or the PID now belongs to a process with a
    /// different start time.
    case exited
    /// The process table could not be read; never treated as exited.
    case unknown

    static func classify(
        _ identity: MCPHelperProcessIdentity,
        reader: any MCPProcessTableReading
    ) -> MCPHelperProcessLiveness {
        switch reader.entry(for: identity.pid) {
        case .absent:
            .exited
        case .unreadable:
            .unknown
        case let .present(current, _, isZombie):
            isZombie || current != identity ? .exited : .alive(current)
        }
    }
}

/// A helper peer's identity and its ancestor chain, captured synchronously at admission while the
/// helper is alive. Later ownership proof uses this chain, so a helper that was reparented (its
/// agent exited first) or has already exited still proves which agent spawned it.
struct MCPHelperPeerProcessSnapshot: Equatable {
    /// Bounded like the live ancestry walk (the peer plus up to `maxDepth - 1` ancestors).
    static let maxDepth = 16

    let peer: MCPHelperProcessIdentity
    /// Nearest-first (the parent first); stops before launchd (PID 1), at an unreadable entry, or
    /// at the depth bound.
    let ancestors: [MCPHelperProcessIdentity]

    /// Captures `peerPID` and its ancestry. `nil` when the peer itself cannot be read.
    static func capture(
        peerPID: pid_t,
        reader: any MCPProcessTableReading
    ) -> MCPHelperPeerProcessSnapshot? {
        guard case let .present(peer, firstParent, _) = reader.entry(for: peerPID) else { return nil }
        var ancestors: [MCPHelperProcessIdentity] = []
        var parent = firstParent
        var current = peerPID
        while ancestors.count < maxDepth - 1, parent > 1, parent != current {
            guard case let .present(identity, nextParent, _) = reader.entry(for: parent) else { break }
            ancestors.append(identity)
            current = parent
            parent = nextParent
        }
        return MCPHelperPeerProcessSnapshot(peer: peer, ancestors: ancestors)
    }

    /// The captured instance of `pid` in the peer-or-ancestor chain, matching the semantics of the
    /// live ancestry check (which also accepts the peer itself).
    func chainIdentity(of pid: pid_t) -> MCPHelperProcessIdentity? {
        if peer.pid == pid { return peer }
        return ancestors.first { $0.pid == pid }
    }

    func chainContains(_ identity: MCPHelperProcessIdentity) -> Bool {
        peer == identity || ancestors.contains(identity)
    }

    var ancestorPIDs: [pid_t] {
        ancestors.map(\.pid)
    }
}
