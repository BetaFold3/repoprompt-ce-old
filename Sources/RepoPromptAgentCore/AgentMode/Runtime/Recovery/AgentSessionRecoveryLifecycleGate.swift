import Foundation

// Foundation integration for the lossless-restart Phase 1b recovery store. Production
// `AgentSessionDataService.shared` is composed with `AgentRecoveryStore.production` (outside
// XCTest), and lanes construct these gates for every editable session.

/// `AgentRecoveryLifecycleGate` backed by `AgentSessionDataService`. Each transaction acquires the
/// session's existing persistence gate, validates the captured persistence state (service stamp
/// and deletion generation, tombstone, existing session file, supported lifecycle envelope,
/// incarnation, current reset generation), awaits the recovery body while still holding the gate,
/// and releases it on every path. Lock order: DataService session gate → recovery store.
package struct AgentSessionRecoveryLifecycleGate: AgentRecoveryLifecycleGate {
    let service: AgentSessionDataService
    let persistenceState: AgentSessionPersistenceState
    package let binding: AgentRecoveryLifecycleBinding

    package func performRecoveryTransaction<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await service.performRecoveryTransaction(persistenceState: persistenceState, body)
    }
}

package enum AgentSessionRecoveryNonactionableReason: Equatable {
    /// No session file for the record in the queried workspace (it may belong to another workspace).
    case sessionFileUnavailable
    /// Legacy or unreadable lifecycle, another incarnation, or a record newer than the session file.
    case authorityMismatch
    /// The tombstone state or session lifecycle could not be read; fail closed.
    case authorityUnreadable
    /// Unreadable or future recovery record bytes, preserved unchanged.
    case unreadableRecord(AgentRecoveryUnreadableReason)
}

/// Authoritative recovery discovery for one workspace. Raw store inventory is classified against
/// the foundation tombstone and lifecycle under each session's gate; nothing is rewritten.
package enum AgentSessionRecoveryDiscovery: Equatable {
    /// Matching authority. Holds are computed against the authoritative reset generation, so input
    /// from before a reset stays held as `staleTarget` and an older-generation composer is visible
    /// by its own generation (never adopted as the current composer).
    case eligible(AgentRecoveryDiscoveredRecord, binding: AgentRecoveryLifecycleBinding)
    /// Retired by a committed or unreadable tombstone: never actionable or restorable, whether or
    /// not deletion cleanup ran.
    case tombstoned(sessionID: UUID)
    /// Preserved and nonactionable.
    case nonactionable(sessionID: UUID?, reason: AgentSessionRecoveryNonactionableReason)
}
