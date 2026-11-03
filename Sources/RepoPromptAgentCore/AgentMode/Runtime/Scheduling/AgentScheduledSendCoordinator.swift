import Foundation

struct SchedulerClockProbe: Equatable {
    static let none = SchedulerClockProbe()

    var suspendedGap: TimeInterval
    var wallClockAdjustment: TimeInterval

    init(
        suspendedGap: TimeInterval = 0,
        wallClockAdjustment: TimeInterval = 0
    ) {
        self.suspendedGap = suspendedGap
        self.wallClockAdjustment = wallClockAdjustment
    }
}

@MainActor
package struct SchedulerClock {
    let now: () -> Date
    private let sleepUntil: (Date) async throws -> Void
    private let probeClock: () -> SchedulerClockProbe

    init(
        now: @escaping () -> Date,
        sleepUntil: @escaping (Date) async throws -> Void,
        probe: @escaping () -> SchedulerClockProbe
    ) {
        self.now = now
        self.sleepUntil = sleepUntil
        probeClock = probe
    }

    func sleep(until deadline: Date) async throws {
        try await sleepUntil(deadline)
    }

    func probe() -> SchedulerClockProbe {
        probeClock()
    }

    static func system() -> SchedulerClock {
        let continuousClock = ContinuousClock()
        let probeState = SystemSchedulerClockProbeState()
        return SchedulerClock(
            now: Date.init,
            sleepUntil: { deadline in
                let delay = max(0, deadline.timeIntervalSinceNow)
                guard delay > 0 else { return }
                try await continuousClock.sleep(
                    until: continuousClock.now.advanced(by: .seconds(delay)),
                    tolerance: nil
                )
            },
            probe: {
                probeState.probe()
            }
        )
    }
}

@MainActor
private final class SystemSchedulerClockProbeState {
    private let continuousClock = ContinuousClock()
    private let suspendingClock = SuspendingClock()
    private var lastWallTime: Date
    private var lastContinuous: ContinuousClock.Instant
    private var lastSuspending: SuspendingClock.Instant

    init() {
        lastWallTime = Date()
        lastContinuous = continuousClock.now
        lastSuspending = suspendingClock.now
    }

    func probe() -> SchedulerClockProbe {
        let wallTime = Date()
        let continuous = continuousClock.now
        let suspending = suspendingClock.now
        let wallElapsed = wallTime.timeIntervalSince(lastWallTime)
        let continuousElapsed = Self.timeInterval(lastContinuous.duration(to: continuous))
        let suspendingElapsed = Self.timeInterval(lastSuspending.duration(to: suspending))

        lastWallTime = wallTime
        lastContinuous = continuous
        lastSuspending = suspending

        return SchedulerClockProbe(
            suspendedGap: max(0, continuousElapsed - suspendingElapsed),
            wallClockAdjustment: wallElapsed - continuousElapsed
        )
    }

    private static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

package struct AgentScheduledSendCandidate: Equatable {
    package let sessionID: UUID
    package let tabID: UUID
    package let workspaceID: UUID
    package let scheduledSend: AgentScheduledSendPersist
    package let isHydrated: Bool

    package init(
        sessionID: UUID,
        tabID: UUID,
        workspaceID: UUID,
        scheduledSend: AgentScheduledSendPersist,
        isHydrated: Bool
    ) {
        self.sessionID = sessionID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.scheduledSend = scheduledSend
        self.isHydrated = isHydrated
    }
}

/// One schedule awaiting explicit user confirmation (durable `needsConfirmation`, or a confirmation
/// obligation not yet durable), for the recovery catalog. Read-only: confirmation, dispatch, and
/// cancellation stay on the existing scheduled-message actions. A summary read from a workspace's
/// metadata index (a session no window hosts) may lack a tab; it carries the attempt the index
/// recorded (none for an entry written before the index carried it).
package struct AgentScheduledSendConfirmationSummary: Equatable {
    package let sessionID: UUID
    package let tabID: UUID?
    package let workspaceID: UUID
    package let scheduleID: UUID
    /// The schedule attempt the confirmation is about, when it has one.
    package let attemptID: UUID?
    package let reason: AgentScheduledSendPersist.ConfirmationReason?
    package let notBefore: Date
    package let previewText: String
    /// Saved session name, when the source knows it (index-read summaries).
    package let sessionName: String?
    /// An index-read summary without its occurrence identity (no attempt: an entry written before the
    /// index carried it, indistinguishable from one without an attempt). Review R1 (A F08 residual):
    /// its acknowledgement could not survive hydration supplying the attempt, so it offers no Dismiss
    /// until opened (the hydrating window's scheduler then presents it).
    package let requiresOpenBeforeDismiss: Bool

    package init(
        sessionID: UUID,
        tabID: UUID?,
        workspaceID: UUID,
        scheduleID: UUID,
        attemptID: UUID?,
        reason: AgentScheduledSendPersist.ConfirmationReason?,
        notBefore: Date,
        previewText: String,
        sessionName: String? = nil,
        requiresOpenBeforeDismiss: Bool = false
    ) {
        self.requiresOpenBeforeDismiss = requiresOpenBeforeDismiss
        self.sessionID = sessionID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.scheduleID = scheduleID
        self.attemptID = attemptID
        self.reason = reason
        self.notBefore = notBefore
        self.previewText = previewText
        self.sessionName = sessionName
    }
}

/// Read-only dashboard projection. Mutations still go through the owning host's existing
/// durable scheduled-send actions, never through this discovery snapshot.
package struct AgentScheduledSendDashboardCandidate {
    package let candidate: AgentScheduledSendCandidate
    package let host: any AgentScheduledSendCoordinatorHost
    package let pendingConfirmation: AgentScheduledSendPendingConfirmationStatus?
    package let recovery: AgentScheduledSendRecoveryStatus?
    package let hasActiveAdmission: Bool

    package init(
        candidate: AgentScheduledSendCandidate,
        host: any AgentScheduledSendCoordinatorHost,
        pendingConfirmation: AgentScheduledSendPendingConfirmationStatus?,
        recovery: AgentScheduledSendRecoveryStatus?,
        hasActiveAdmission: Bool
    ) {
        self.candidate = candidate
        self.host = host
        self.pendingConfirmation = pendingConfirmation
        self.recovery = recovery
        self.hasActiveAdmission = hasActiveAdmission
    }
}

package struct AgentScheduledSendBusyState: Equatable {
    var runID: UUID?
    var runState: AgentSessionRunState
    var hasPendingApproval: Bool
    var hasPendingAskUser: Bool
    var hasPendingUserInputRequest: Bool
    var hasPendingPermissionsRequest: Bool
    var hasPendingInstructions: Bool
    var cancellationIsSettling: Bool
    var hasStartOrDispatchReservation: Bool
    /// Lossless-restart recovery for this session is unresolved (an unconfirmed crash hold, an
    /// unresolved schedule receipt transfer, or missing mandatory recovery dependencies).
    var hasUnresolvedRecovery: Bool

    package init(
        runID: UUID? = nil,
        runState: AgentSessionRunState = .idle,
        hasPendingApproval: Bool = false,
        hasPendingAskUser: Bool = false,
        hasPendingUserInputRequest: Bool = false,
        hasPendingPermissionsRequest: Bool = false,
        hasPendingInstructions: Bool = false,
        cancellationIsSettling: Bool = false,
        hasStartOrDispatchReservation: Bool = false,
        hasUnresolvedRecovery: Bool = false
    ) {
        self.runID = runID
        self.runState = runState
        self.hasPendingApproval = hasPendingApproval
        self.hasPendingAskUser = hasPendingAskUser
        self.hasPendingUserInputRequest = hasPendingUserInputRequest
        self.hasPendingPermissionsRequest = hasPendingPermissionsRequest
        self.hasPendingInstructions = hasPendingInstructions
        self.cancellationIsSettling = cancellationIsSettling
        self.hasStartOrDispatchReservation = hasStartOrDispatchReservation
        self.hasUnresolvedRecovery = hasUnresolvedRecovery
    }

    package var isBusy: Bool {
        runState.isActive
            || hasPendingApproval
            || hasPendingAskUser
            || hasPendingUserInputRequest
            || hasPendingPermissionsRequest
            || hasPendingInstructions
            || cancellationIsSettling
            || hasStartOrDispatchReservation
            || hasUnresolvedRecovery
    }
}

/// Startup admission of the scheduler (lossless-restart barrier). Production composition closes
/// it at construction, before any host registers, and opens it only after recovery startup
/// reconciliation is ready. While closed, nothing evaluates candidates, starts hydration, writes
/// confirmations, arms timers, or dispatches.
package enum AgentScheduledSendStartupAdmission: Equatable {
    case open
    case awaitingRecovery
    case recoveryFailed(String)
}

/// Why a `.dispatching` schedule attempt is held instead of becoming a delivery-unknown
/// confirmation: its R9 receipt transfer to a durable recovery intent is not yet resolved.
package enum AgentScheduledSendTransferHoldReason: Equatable {
    /// Repair has not run yet (startup barrier, recovery lane, or hydration pending).
    case awaitingRecovery
    /// This process handed the linked intent to a provider route whose affirmative evidence
    /// arrives after dispatch returns (non-Codex acceptance, or a direct send whose evidence is
    /// still being written). The intent is `dispatching`; repair re-runs when the run settles and
    /// transfers only on `providerAccepted` or a settled `queued` state.
    case awaitingProviderEvidence
    /// Conflicting or unknown evidence, or a failed transfer write; never confirmed automatically.
    case unresolved(String)
}

package struct AgentScheduledSendTransferHold: Equatable {
    package let sessionID: UUID
    package let scheduleID: UUID
    package let scheduleAttemptID: UUID
    package let reason: AgentScheduledSendTransferHoldReason

    package init(
        sessionID: UUID,
        scheduleID: UUID,
        scheduleAttemptID: UUID,
        reason: AgentScheduledSendTransferHoldReason
    ) {
        self.sessionID = sessionID
        self.scheduleID = scheduleID
        self.scheduleAttemptID = scheduleAttemptID
        self.reason = reason
    }
}

package struct AgentScheduledSendAdmissionLease: Equatable {
    package let id: UUID
    package let sessionID: UUID
    let scheduleID: UUID
    package let workspaceID: UUID
    let admittedUpdatedAt: Date
    let admittedNotBefore: Date
    let effectiveDueAt: Date
    package let allowsNeedsConfirmation: Bool
    package let runAlongsideOtherSessions: Bool
    /// Admission policy carried to the final handoff: only a workspace-gated new-session start
    /// (`isNewSessionStart && !runAlongsideOtherSessions`) requires other sessions in the
    /// workspace to be idle. Follow-ups wait only on their own destination session.
    let requiresWorkspaceGate: Bool
    /// New-session starts wait for unresolved recovery anywhere in the workspace, even when they
    /// run alongside other sessions.
    let blocksOnUnresolvedRecovery: Bool

    fileprivate init(
        id: UUID,
        sessionID: UUID,
        scheduleID: UUID,
        workspaceID: UUID,
        admittedUpdatedAt: Date,
        admittedNotBefore: Date,
        effectiveDueAt: Date,
        allowsNeedsConfirmation: Bool,
        runAlongsideOtherSessions: Bool,
        requiresWorkspaceGate: Bool,
        blocksOnUnresolvedRecovery: Bool
    ) {
        self.id = id
        self.sessionID = sessionID
        self.scheduleID = scheduleID
        self.workspaceID = workspaceID
        self.admittedUpdatedAt = admittedUpdatedAt
        self.admittedNotBefore = admittedNotBefore
        self.effectiveDueAt = effectiveDueAt
        self.allowsNeedsConfirmation = allowsNeedsConfirmation
        self.runAlongsideOtherSessions = runAlongsideOtherSessions
        self.requiresWorkspaceGate = requiresWorkspaceGate
        self.blocksOnUnresolvedRecovery = blocksOnUnresolvedRecovery
    }
}

/// Retry budget for process-owned accepted-send recovery: one immediate attempt plus these delays.
package enum AgentScheduledSendRecoveryPolicy {
    static let defaultRetryDelays: [TimeInterval] = [0.5, 2, 5, 15]
}

package struct AgentScheduledSendFinalHandoffValidator: Equatable {
    let lease: AgentScheduledSendAdmissionLease
    fileprivate let registrationID: UUID
    fileprivate let tabID: UUID
}

package enum ScheduledDispatchOutcome: Equatable {
    case accepted
    case deferredBusy
    case failedBeforeHandoff
    case unknownAfterHandoff
    /// Mandatory recovery: the host placed a transfer hold on this exact attempt (uncertain or
    /// unprovable delivery evidence). The pending schedule, its payload, and any user bubble stay as
    /// they are until explicit resolution; never a pre-handoff failure, confirmation, or re-drive.
    case heldForRecovery
}

/// Why unresolved lossless-restart recovery keeps a due schedule from being admitted (lossless
/// restart F2). Reported by hosts from the same predicates as `hasUnresolvedRecoverySession` and
/// recorded by the scheduler at the admission branch that applied it; presentation only.
package struct AgentScheduledSendRecoveryBlocker: Equatable {
    /// Other sessions in the workspace with an interrupted turn whose crash hold is unconfirmed.
    /// Only It stopped for that exact hold lifts it; Dismiss does not.
    package var interruptedSessionIDs: Set<UUID> = []
    /// Other sessions restricted by the startup recovery check (held transfer, unknown status,
    /// duplicate destination). Lifted by resolving the held transfer or by the next launch's check.
    package var restrictedSessionIDs: Set<UUID> = []
    /// Other open sessions whose recovery is unresolved for any reason.
    package var unresolvedOpenSessionIDs: Set<UUID> = []
    /// The workspace itself could not be read for recovery.
    package var workspaceRestriction: String?
    /// An explicit recovery action in the workspace has not recorded its outcome yet.
    package var recoveryActionInProgress = false
    /// Agent processes from an earlier launch may still be writing in this workspace (R6).
    package var runtimeOwnershipUnresolved = false
    /// The schedule's own session has unresolved recovery.
    package var destinationUnresolved = false
    /// A host reported unresolved recovery without itemizing it.
    package var unattributed = false

    package init(
        interruptedSessionIDs: Set<UUID> = [],
        restrictedSessionIDs: Set<UUID> = [],
        unresolvedOpenSessionIDs: Set<UUID> = [],
        workspaceRestriction: String? = nil,
        recoveryActionInProgress: Bool = false,
        runtimeOwnershipUnresolved: Bool = false,
        destinationUnresolved: Bool = false,
        unattributed: Bool = false
    ) {
        self.interruptedSessionIDs = interruptedSessionIDs
        self.restrictedSessionIDs = restrictedSessionIDs
        self.unresolvedOpenSessionIDs = unresolvedOpenSessionIDs
        self.workspaceRestriction = workspaceRestriction
        self.recoveryActionInProgress = recoveryActionInProgress
        self.runtimeOwnershipUnresolved = runtimeOwnershipUnresolved
        self.destinationUnresolved = destinationUnresolved
        self.unattributed = unattributed
    }

    package var isBlocking: Bool {
        !interruptedSessionIDs.isEmpty
            || !restrictedSessionIDs.isEmpty
            || !unresolvedOpenSessionIDs.isEmpty
            || workspaceRestriction != nil
            || recoveryActionInProgress
            || runtimeOwnershipUnresolved
            || destinationUnresolved
            || unattributed
    }

    /// Open sessions that are unresolved for a reason other than a crash hold or restriction.
    package var otherUnresolvedSessionIDs: Set<UUID> {
        unresolvedOpenSessionIDs.subtracting(interruptedSessionIDs).subtracting(restrictedSessionIDs)
    }

    package mutating func merge(_ other: AgentScheduledSendRecoveryBlocker) {
        interruptedSessionIDs.formUnion(other.interruptedSessionIDs)
        restrictedSessionIDs.formUnion(other.restrictedSessionIDs)
        unresolvedOpenSessionIDs.formUnion(other.unresolvedOpenSessionIDs)
        workspaceRestriction = workspaceRestriction ?? other.workspaceRestriction
        recoveryActionInProgress = recoveryActionInProgress || other.recoveryActionInProgress
        runtimeOwnershipUnresolved = runtimeOwnershipUnresolved || other.runtimeOwnershipUnresolved
        destinationUnresolved = destinationUnresolved || other.destinationUnresolved
        unattributed = unattributed || other.unattributed
    }
}

/// Why Send now installed no consent. Each case is one early return of `confirmAndSendNow`.
package enum AgentScheduledSendNowRefusal: Equatable {
    /// Recovery startup has not opened scheduler admission (still checking, or failed).
    case startupAdmissionClosed(AgentScheduledSendStartupAdmission)
    /// The schedule's last attempt is held for an unresolved receipt transfer.
    case transferHeld
    /// A newer confirmation decision (clock or wake change) must be confirmed first.
    case confirmationPending
    /// No registered host projects the schedule.
    case scheduleNotFound
}

/// Per-schedule scheduler disposition (lossless restart F2).
package enum AgentScheduledSendDisposition: Equatable {
    /// Send now was refused: no consent applies, and Send now must be repeated once the refusal
    /// clears.
    case rejected(AgentScheduledSendNowRefusal)
    /// Due (or consented) but held by unresolved recovery; consent, if any, stays recorded for
    /// this revision and applies once the blocker clears.
    case blocked(AgentScheduledSendRecoveryBlocker)
    /// Nothing recovery-related is holding it: waiting for its time or a busy session, or sending.
    case progressing
}

@MainActor
package protocol AgentScheduledSendCoordinatorHost: AnyObject {
    func scheduledSendCandidates() -> [AgentScheduledSendCandidate]
    func scheduledSendBusyState(tabID: UUID) -> AgentScheduledSendBusyState
    func isBusy(tabID: UUID) -> Bool
    func hasBusySession(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> Bool
    func scheduledSendBusyStateExcludingDispatchReservation(
        tabID: UUID
    ) -> AgentScheduledSendBusyState
    func hasBusySessionForScheduledSendHandoff(
        inWorkspace workspaceID: UUID,
        excludingDispatchReservationForTabID tabID: UUID?
    ) -> Bool
    func scheduledSendProjectionNeedsRefresh(tabID: UUID, sessionID: UUID)
    func scheduledSendSessionName(tabID: UUID) -> String?
    func scheduledSendBusySessionName(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> String?
    func hasUnresolvedRecoverySession(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> Bool
    /// What `hasUnresolvedRecoverySession` found: non-nil exactly when it returns `true`. The
    /// scheduler's new-session admission gate is this value being non-nil on any host.
    func scheduledSendRecoveryBlocker(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> AgentScheduledSendRecoveryBlocker?
    func ownsScheduledSendDestination(tabID: UUID, sessionID: UUID) -> Bool
    /// Whether any tab on this host bound to the durable `sessionID` is busy. The owning host's
    /// dispatching tab is evaluated without its own dispatch reservation; foreign hosts pass `nil`.
    func scheduledSendDestinationIsBusy(
        sessionID: UUID,
        excludingDispatchReservationForTabID tabID: UUID?
    ) -> Bool
    func ensureHydrated(tabID: UUID) async -> Bool
    /// One exact, acknowledged schedule mutation: the host validates ownership and the expected
    /// record, commits the replacement through its durable CAS path inside its serialized
    /// action, adopts the durable result only if it is still the owner, and reports the precise
    /// outcome. The host never projects the replacement optimistically.
    func persistScheduledSendMutation(
        tabID: UUID,
        request: AgentScheduledSendHostMutationRequest
    ) async -> AgentScheduledSendHostMutationOutcome
    func dispatchScheduledSend(
        tabID: UUID,
        scheduleID: UUID,
        lease: AgentScheduledSendAdmissionLease
    ) async -> ScheduledDispatchOutcome
}

extension AgentScheduledSendCoordinatorHost {
    package func isBusy(tabID: UUID) -> Bool {
        scheduledSendBusyState(tabID: tabID).isBusy
    }

    func scheduledSendSessionName(tabID: UUID) -> String? {
        nil
    }

    func scheduledSendBusySessionName(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> String? {
        nil
    }

    /// Whether any session in the workspace (other than `sessionID`) has unresolved lossless-restart
    /// recovery. Blocks new-session starts even when they run alongside other sessions.
    /// Hosts answer for their open sessions and, through the shared recovery coordinator's startup
    /// results, for restricted or crash-held sessions no window has opened. Derived from
    /// `scheduledSendRecoveryBlocker`, so the gate and the itemized reason are one predicate.
    package func hasUnresolvedRecoverySession(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> Bool {
        scheduledSendRecoveryBlocker(inWorkspace: workspaceID, excluding: sessionID) != nil
    }
}

/// Immutable coordinator-issued schedule mutation with exact request identity. `expected` is the
/// complete record the owner must currently project and persist; `replacement` is committed
/// verbatim and retained for retries.
package struct AgentScheduledSendHostMutationRequest: Equatable {
    let id: UUID
    package let sessionID: UUID
    package let scheduleID: UUID
    package let expected: AgentScheduledSendPersist
    package let replacement: AgentScheduledSendPersist
}

package enum AgentScheduledSendHostMutationOutcome: Equatable {
    /// The session-file commit succeeded (index degradation is still a commit). Carries the
    /// durable revision when the data service reported it.
    case committed(committedUpdatedAt: Date?)
    /// The expected record no longer matches; the host refreshed from authority. Not an ack.
    case conflict
    /// Owner gone, unhydrated, or owning a live attempt. No write attempted.
    case unavailable
    /// The captured session lifetime was revoked (explicit deletion). Terminal for the request.
    case destinationDeleted
    /// Read/encode/write failure. No durable acknowledgement is claimed.
    case failed(String)
}

package enum AgentScheduledSendPendingConfirmationPhase: Equatable {
    /// No hydrated owner is available yet; nothing has been attempted.
    case waitingForOwner
    case saving(attemptNumber: Int)
    case waitingToRetry(nextAttemptNumber: Int, notBefore: Date)
    /// Bounded automatic attempts ended; the dispatch block stays until a manual retry or
    /// explicit user supersession.
    case needsAttention(lastFailure: String?)
}

/// Coordinator-owned status of a confirmation obligation that is not durable yet. Automatic
/// sending is blocked for the schedule while this exists.
package struct AgentScheduledSendPendingConfirmationStatus: Equatable {
    package let sessionID: UUID
    package let scheduleID: UUID
    let decisionID: UUID
    package let reason: AgentScheduledSendPersist.ConfirmationReason
    package let phase: AgentScheduledSendPendingConfirmationPhase
    let attemptCount: Int
}

/// Opaque reservation for a user action that supersedes a pending confirmation decision.
package struct AgentScheduledSendUserSupersessionToken: Equatable {
    let id: UUID
    let sessionID: UUID
    let scheduleID: UUID
    fileprivate let decisionID: UUID?
    fileprivate let epoch: UInt64
}

package extension Notification.Name {
    /// A pending confirmation obligation was installed, retried, exhausted, or cleared.
    /// `userInfo`: `sessionID`, `scheduleID`. Observers read `pendingConfirmationStatus`.
    static let agentScheduledSendPendingConfirmationDidChange =
        Notification.Name("AgentScheduledSendCoordinator.pendingConfirmationDidChange")
    /// Coalesced when the coordinator's dashboard-visible projection actually changes.
    static let agentScheduledSendDashboardDidChange =
        Notification.Name("AgentScheduledSendCoordinator.dashboardDidChange")
    /// The scheduler's startup admission changed (`object` is the coordinator). Hosts resume
    /// deferred hydration normalization and receipt-transfer repair once it reports `open`.
    static let agentScheduledSendStartupAdmissionDidChange =
        Notification.Name("AgentScheduledSendCoordinator.startupAdmissionDidChange")
    /// A schedule's recorded recovery blocker appeared, changed, or cleared (lossless restart F2).
    /// `userInfo`: `sessionID`, `scheduleID`. Observers read `recoveryBlocker(scheduleID:)`.
    static let agentScheduledSendDispositionDidChange =
        Notification.Name("AgentScheduledSendCoordinator.dispositionDidChange")
}

@MainActor
package final class AgentScheduledSendCoordinator {
    private enum ArmingEpochReason {
        case launch
        case wake
        case clockChanged
    }

    private enum CapturedRunDisposition {
        case waiting
        case completed
        case invalid
    }

    private struct ArmedRecord {
        let scheduleID: UUID
        let sessionID: UUID
        var notBefore: Date
        var epoch: UInt64
        var armedAt: Date
        var observedDueAwakeAt: Date?
        var capturedRunID: UUID?
        var capturedRunDisposition: CapturedRunDisposition?
    }

    private struct ConfirmedOverride {
        var admittedUpdatedAt: Date
        let effectiveNotBefore: Date
        let runAlongsideOtherSessions: Bool?
    }

    private struct Admission {
        let lease: AgentScheduledSendAdmissionLease
        let registrationID: UUID
        let tabID: UUID
        let armingEpoch: UInt64
        var workspaceReservationHeld: Bool
    }

    /// Retained confirmation obligation: a decision that the record requires user confirmation
    /// remains a dispatch block until its exact durable acknowledgement or a successful user
    /// supersession. Process-local; survives hydration, timer, and epoch churn.
    private struct PendingConfirmation {
        let sessionID: UUID
        let workspaceID: UUID
        let scheduleID: UUID
        let decisionID: UUID
        let epoch: UInt64
        let reason: AgentScheduledSendPersist.ConfirmationReason
        var attemptCount: Int = 0
        var nextRetryAt: Date?
        var lastFailure: String?
        var inFlightRequestID: UUID?
        var needsAttention = false
        /// Exact replacement retained across retries for the same expected record.
        var retainedRequest: (expected: AgentScheduledSendPersist, replacement: AgentScheduledSendPersist)?
    }

    /// Process-owned retained attempt: duplicate protection plus (once accepted) the immutable
    /// payload and the single bounded persistence worker. Never retains a view model.
    private struct RetainedAttempt {
        let lease: AgentScheduledSendAdmissionLease
        let key: AgentScheduledSendRecoveryKey
        let context: AgentScheduledSendRecoveryContext?
        var payload: AgentScheduledSendAcceptedPayload?
        var phase: AgentScheduledSendRecoveryPhase
        var attemptCount: Int = 0
        var lastFailure: String?
        var workerID: UUID?
        var workerTask: Task<Void, Never>?
        var dispatchOutcomeOutstanding: Bool
        /// Conflicting acceptance reports ignored under first-evidence-wins (observability only).
        var ignoredConflictingAcceptanceReports: Int = 0
    }

    private struct StaleProjectionRevision: Hashable {
        let registrationID: UUID
        let sessionID: UUID
        let tabID: UUID
        let scheduleID: UUID
        let updatedAt: Date
    }

    private struct ScheduleRevision: Hashable {
        let scheduleID: UUID
        let updatedAt: Date

        init(record: AgentScheduledSendPersist) {
            scheduleID = record.id
            updatedAt = record.updatedAt
        }

        init(lease: AgentScheduledSendAdmissionLease) {
            scheduleID = lease.scheduleID
            updatedAt = lease.admittedUpdatedAt
        }

        init(scheduleID: UUID, updatedAt: Date) {
            self.scheduleID = scheduleID
            self.updatedAt = updatedAt
        }
    }

    private final class HostRegistration {
        let id: UUID
        let order: UInt64
        weak var host: (any AgentScheduledSendCoordinatorHost)?

        init(id: UUID, order: UInt64, host: any AgentScheduledSendCoordinatorHost) {
            self.id = id
            self.order = order
            self.host = host
        }
    }

    private struct OwnedCandidate {
        let registrationID: UUID
        let registrationOrder: UInt64
        let host: any AgentScheduledSendCoordinatorHost
        let candidate: AgentScheduledSendCandidate
    }

    private struct AuthoritativeCandidate {
        let representative: OwnedCandidate
        let matchingEntries: [OwnedCandidate]
    }

    private let clock: SchedulerClock
    private let launchAt: Date
    private let discontinuityThreshold: TimeInterval

    private var registrations: [HostRegistration] = []
    private var nextRegistrationOrder: UInt64 = 0
    private var armingEpoch: UInt64 = 1
    private var armingEpochReason: ArmingEpochReason = .launch
    private var armedRecords: [UUID: ArmedRecord] = [:]
    private var confirmedOverrides: [UUID: ConfirmedOverride] = [:]
    private var admissionsBySessionID: [UUID: Admission] = [:]
    private var retainedAttemptsBySessionID: [UUID: RetainedAttempt] = [:]
    private var hydratingSessionIDs: Set<UUID> = []
    private var hydrationFailures: Set<UUID> = []
    private var retiredRevisions: Set<ScheduleRevision> = []
    private var completedFinalizationRevisions: Set<ScheduleRevision> = []
    private var requestedProjectionRefreshes: Set<StaleProjectionRevision> = []
    /// Confirmation obligations awaiting exact durable acknowledgement, keyed by schedule id.
    private var pendingConfirmationsByScheduleID: [UUID: PendingConfirmation] = [:]
    /// One coordinator-issued host mutation in flight per durable session.
    private var inFlightHostMutationSessionIDs: Set<UUID> = []
    /// Callers waiting for the in-flight host mutation of a session to complete (user actions
    /// that must observe the durable outcome before superseding a decision).
    private var hostMutationDrainWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    /// Token-owned, counting reservations per durable session: while any user action holds one,
    /// no coordinator mutation (confirmation or first-eligibility) is issued for that session.
    /// Each token releases only itself, so concurrent user actions never release each other.
    private var userActionReservationTokensBySessionID: [UUID: [UUID]] = [:]
    /// Informational first-eligibility writes that failed: `(revision, notBefore)` per schedule.
    /// The same revision is not retried before `notBefore`; a genuine revision change resets it.
    private var firstEligibilityRetryByScheduleID: [UUID: (revision: Date, notBefore: Date)] = [:]
    private static let firstEligibilityRetryDelay: TimeInterval = 1
    /// Automatic confirmation persistence: one immediate attempt plus these delays.
    private static let confirmationRetryDelays: [TimeInterval] = [1, 2]
    private let recoveryRetryDelays: [TimeInterval]
    private var deletionObserver: NSObjectProtocol?

    private var timerTask: Task<Void, Never>?
    private var timerDeadline: Date?
    private var timerGeneration: UInt64 = 0

    private var isEvaluating = false
    private var needsRerun = false
    private var lastEvaluationAt: Date
    private var dashboardNotificationScheduled = false
    private var lastPublishedDashboardSignature: [String] = []

    /// Lossless-restart startup barrier. `.open` by default (inactive cutover); production
    /// composition passes `.awaitingRecovery` so it is closed before any host registers.
    package private(set) var startupAdmission: AgentScheduledSendStartupAdmission
    private var startupAdmissionWaiters: [CheckedContinuation<Bool, Never>] = []
    /// Unresolved R9 receipt transfers keyed by schedule id. A held schedule is never turned into
    /// a delivery-unknown confirmation, admitted, or dispatched.
    private var transferHoldsByScheduleID: [UUID: AgentScheduledSendTransferHold] = [:]
    private struct RecordedRecoveryBlocker: Equatable {
        let sessionID: UUID
        let blocker: AgentScheduledSendRecoveryBlocker
    }

    /// Recovery blockers recorded by the last evaluation pass at the admission branch that held
    /// each schedule (the new-session recovery gate, or its own session's unresolved recovery).
    /// Presentation only; admission never reads it.
    private var recoveryBlockersByScheduleID: [UUID: RecordedRecoveryBlocker] = [:]
    /// When true (mandatory recovery), a `.dispatching` record nobody owns is resolved by its
    /// hydrated host (receipt-transfer repair) instead of becoming a confirmation obligation from
    /// an unhydrated projection.
    package var dispatchingRecordsRequireTransferResolution = false

    package init(
        clock: SchedulerClock? = nil,
        discontinuityThreshold: TimeInterval = 30,
        recoveryRetryDelays: [TimeInterval] = AgentScheduledSendRecoveryPolicy.defaultRetryDelays,
        startupAdmission: AgentScheduledSendStartupAdmission = .open
    ) {
        self.startupAdmission = startupAdmission
        let resolvedClock = clock ?? .system()
        self.clock = resolvedClock
        launchAt = resolvedClock.now()
        lastEvaluationAt = launchAt
        self.discontinuityThreshold = discontinuityThreshold
        self.recoveryRetryDelays = recoveryRetryDelays
        deletionObserver = NotificationCenter.default.addObserver(
            forName: .agentSessionDeletionDidCommit,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let fileKey = notification.userInfo?["fileKey"] as? URL,
                  let generation = notification.userInfo?["generation"] as? UInt64
            else { return }
            Task { @MainActor [weak self] in
                self?.handleExplicitDeletionCommit(fileKey: fileKey, generation: generation)
            }
        }
    }

    deinit {
        if let deletionObserver {
            NotificationCenter.default.removeObserver(deletionObserver)
        }
    }

    // MARK: Startup admission (lossless-restart barrier)

    package var isStartupAdmissionOpen: Bool {
        startupAdmission == .open
    }

    /// Closes startup admission synchronously. Composition must call this (or construct with
    /// `.awaitingRecovery`) before the first `register`; returns `false` when a host is already
    /// registered so the caller can treat the ordering violation as a wiring failure. Closing never
    /// revokes an admission or retained attempt that already exists.
    @discardableResult
    package func closeStartupAdmission() -> Bool {
        pruneRegistrations()
        let wasUnregistered = registrations.isEmpty
        guard startupAdmission != .awaitingRecovery else { return wasUnregistered }
        startupAdmission = .awaitingRecovery
        armTimer(for: nil)
        postStartupAdmissionChange()
        return wasUnregistered
    }

    /// Recovery startup reconciliation is ready: release evaluation, hydration normalization, and
    /// receipt-transfer repair.
    package func openStartupAdmission() {
        guard startupAdmission != .open else { return }
        startupAdmission = .open
        resumeStartupAdmissionWaiters(open: true)
        postStartupAdmissionChange()
        evaluate()
    }

    /// Recovery startup failed: admission stays closed with a persistent reason. Retry closes
    /// (`closeStartupAdmission`) and opens again after a successful reconciliation.
    package func failStartupAdmission(_ message: String) {
        startupAdmission = .recoveryFailed(message)
        armTimer(for: nil)
        resumeStartupAdmissionWaiters(open: false)
        postStartupAdmissionChange()
    }

    /// Suspends until admission is open (`true`) or startup failed (`false`).
    package func awaitStartupAdmission() async -> Bool {
        switch startupAdmission {
        case .open:
            true
        case .recoveryFailed:
            false
        case .awaitingRecovery:
            await withCheckedContinuation { continuation in
                startupAdmissionWaiters.append(continuation)
            }
        }
    }

    private func resumeStartupAdmissionWaiters(open: Bool) {
        let waiters = startupAdmissionWaiters
        startupAdmissionWaiters = []
        for waiter in waiters {
            waiter.resume(returning: open)
        }
    }

    private func postStartupAdmissionChange() {
        NotificationCenter.default.post(name: .agentScheduledSendStartupAdmissionDidChange, object: self)
    }

    // MARK: Receipt-transfer holds (R9)

    /// Installs or updates the hold for one schedule attempt. A pending delivery-unknown
    /// confirmation for the same schedule is withdrawn: the transfer repair owns the decision, so
    /// no duplicate confirmation is offered for input a recovery intent may already own.
    package func holdTransfer(_ hold: AgentScheduledSendTransferHold) {
        let previous = transferHoldsByScheduleID[hold.scheduleID]
        transferHoldsByScheduleID[hold.scheduleID] = hold
        if let pending = pendingConfirmationsByScheduleID[hold.scheduleID],
           pending.reason == .deliveryUnknown,
           pending.inFlightRequestID == nil
        {
            pendingConfirmationsByScheduleID.removeValue(forKey: hold.scheduleID)
            postPendingConfirmationChange(pending)
        }
        if previous != hold {
            evaluate()
        }
    }

    /// Releases exactly this attempt's hold (repair completed, or no linked intent exists).
    package func releaseTransferHold(scheduleID: UUID, scheduleAttemptID: UUID) {
        guard transferHoldsByScheduleID[scheduleID]?.scheduleAttemptID == scheduleAttemptID else { return }
        transferHoldsByScheduleID.removeValue(forKey: scheduleID)
        evaluate()
    }

    package func transferHold(scheduleID: UUID) -> AgentScheduledSendTransferHold? {
        transferHoldsByScheduleID[scheduleID]
    }

    package func transferHold(sessionID: UUID) -> AgentScheduledSendTransferHold? {
        transferHoldsByScheduleID.values.first { $0.sessionID == sessionID }
    }

    @discardableResult
    package func register(_ host: any AgentScheduledSendCoordinatorHost) -> UUID {
        pruneRegistrations()
        if let existing = registrations.first(where: { $0.host === host }) {
            evaluate()
            return existing.id
        }

        nextRegistrationOrder &+= 1
        let registration = HostRegistration(
            id: UUID(),
            order: nextRegistrationOrder,
            host: host
        )
        registrations.append(registration)
        evaluate()
        return registration.id
    }

    package func unregister(registrationID: UUID) {
        registrations.removeAll { $0.id == registrationID }
        let releasedSessionIDs = admissionsBySessionID.compactMap { sessionID, admission in
            admission.registrationID == registrationID ? sessionID : nil
        }
        for sessionID in releasedSessionIDs {
            admissionsBySessionID.removeValue(forKey: sessionID)
            // Ownership reserved at the handoff stays; a provider outcome that never arrives
            // is an attention state, not a reason to drop duplicate protection.
            if var retained = retainedAttemptsBySessionID[sessionID],
               retained.payload == nil,
               retained.phase == .awaitingProviderOutcome
            {
                retained.phase = .needsAttention(.unresolvedProviderOutcome)
                retainedAttemptsBySessionID[sessionID] = retained
                postRecoveryChange(.needsAttention, sessionID: sessionID, workspaceID: retained.lease.workspaceID, key: retained.key)
            }
        }
        evaluate()
    }

    /// One representative per durable session, using the same revision ordering as admission.
    /// An index-only candidate is a discovery hint, not an actionable or sending state.
    package func dashboardCandidates(in workspaceID: UUID) -> [AgentScheduledSendDashboardCandidate] {
        authoritativeCandidates(from: collectCandidates())
            .filter { $0.representative.candidate.workspaceID == workspaceID }
            .sorted { candidatePrecedes($0.representative, $1.representative) }
            .map { authority in
                let owner = authority.matchingEntries.first(where: { $0.candidate.isHydrated })
                    ?? authority.representative
                let candidate = owner.candidate
                return AgentScheduledSendDashboardCandidate(
                    candidate: candidate,
                    host: owner.host,
                    pendingConfirmation: pendingConfirmationStatus(scheduleID: candidate.scheduledSend.id),
                    recovery: recoveryStatus(sessionID: candidate.sessionID),
                    hasActiveAdmission: activeAdmission(sessionID: candidate.sessionID) != nil
                )
            }
    }

    /// Every registered host's schedule awaiting explicit confirmation, across workspaces (one per
    /// durable session, the same authority as the dashboard). A confirmation obligation not yet
    /// durable counts too. Observers refresh on `agentScheduledSendDashboardDidChange`.
    package func confirmationSummaries() -> [AgentScheduledSendConfirmationSummary] {
        authoritativeCandidates(from: collectCandidates())
            .compactMap { authority -> AgentScheduledSendConfirmationSummary? in
                let owner = authority.matchingEntries.first(where: { $0.candidate.isHydrated })
                    ?? authority.representative
                let candidate = owner.candidate
                let record = candidate.scheduledSend
                let pending = pendingConfirmationsByScheduleID[record.id]
                guard record.state == .needsConfirmation || pending != nil else { return nil }
                return AgentScheduledSendConfirmationSummary(
                    sessionID: candidate.sessionID,
                    tabID: candidate.tabID,
                    workspaceID: candidate.workspaceID,
                    scheduleID: record.id,
                    attemptID: record.attempt?.attemptID,
                    reason: record.confirmationReason ?? pending?.reason,
                    notBefore: record.notBefore,
                    previewText: String(record.rawText.prefix(AgentSessionScheduledSendSummary.previewTextLimit))
                )
            }
            .sorted { ($0.notBefore, $0.scheduleID.uuidString) < ($1.notBefore, $1.scheduleID.uuidString) }
    }

    /// Names an active blocker only; an old first-eligibility timestamp is not proof
    /// that the destination remains busy.
    package func dashboardBlockingSessionName(for snapshot: AgentScheduledSendDashboardCandidate) -> String? {
        let candidate = snapshot.candidate
        let record = candidate.scheduledSend
        guard record.firstEligibleAt != nil else { return nil }
        if !record.isNewSessionStart {
            guard snapshot.host.scheduledSendBusyState(tabID: candidate.tabID).isBusy else { return nil }
            return snapshot.host.scheduledSendSessionName(tabID: candidate.tabID)
        }
        guard !record.runAlongsideOtherSessions else { return nil }
        return registrations.compactMap { registration in
            registration.host?.scheduledSendBusySessionName(
                inWorkspace: candidate.workspaceID,
                excluding: candidate.sessionID
            )
        }.first
    }

    /// Retained accepted attempts may outlive their live or index record. Keep them discoverable
    /// without reopening a provider handoff or claiming a completed send.
    package func dashboardRecoveryStatuses(in workspaceID: UUID) -> [AgentScheduledSendRecoveryStatus] {
        retainedAttemptsBySessionID.keys.compactMap { sessionID in
            guard let status = recoveryStatus(sessionID: sessionID),
                  status.lease.workspaceID == workspaceID
            else { return nil }
            return status
        }
    }

    package func workspaceDidLoad() {
        evaluate()
    }

    package func recordDidChange() {
        evaluate()
    }

    package func tabDidClose(sessionID: UUID) {
        admissionsBySessionID.removeValue(forKey: sessionID)
        hydratingSessionIDs.remove(sessionID)
        hydrationFailures.remove(sessionID)
        requestedProjectionRefreshes = Set(
            requestedProjectionRefreshes.filter { $0.sessionID != sessionID }
        )

        let scheduleIDs = armedRecords.values
            .filter { $0.sessionID == sessionID }
            .map(\.scheduleID)
        for scheduleID in scheduleIDs {
            armedRecords.removeValue(forKey: scheduleID)
            confirmedOverrides.removeValue(forKey: scheduleID)
        }
        evaluate()
    }

    package func didWake() {
        advanceArmingEpoch(reason: .wake)
        evaluate()
    }

    package func runStateDidChange(
        sessionID: UUID,
        runID: UUID?,
        state: AgentSessionRunState
    ) {
        if var admission = admissionsBySessionID[sessionID],
           admission.workspaceReservationHeld
        {
            admission.workspaceReservationHeld = false
            admissionsBySessionID[sessionID] = admission
        }

        for scheduleID in armedRecords.keys {
            guard var armed = armedRecords[scheduleID],
                  armed.sessionID == sessionID,
                  let capturedRunID = armed.capturedRunID
            else {
                continue
            }

            if runID == capturedRunID {
                switch state {
                case .completed:
                    armed.capturedRunDisposition = .completed
                case .cancelled, .failed, .idle:
                    armed.capturedRunDisposition = .invalid
                case .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
                    armed.capturedRunDisposition = .waiting
                }
            } else if runID != nil || state == .idle || state == .cancelled || state == .failed {
                armed.capturedRunDisposition = .invalid
            }
            armedRecords[scheduleID] = armed
        }

        evaluate()
    }

    /// Installs the user's Send-now consent for the schedule's durable revision. A pending
    /// confirmation obligation is never bypassed: the caller must first complete a user
    /// supersession (`completeUserSupersession`) for that decision. Returns why no consent was
    /// installed (`rejected`), or the disposition after the evaluation it triggers: `blocked` when
    /// unresolved recovery still holds the schedule (the consent stays recorded for this revision;
    /// `runAlongsideOtherSessions` never bypasses the recovery gate).
    @discardableResult
    package func confirmAndSendNow(
        scheduleID: UUID,
        runAlongsideOtherSessions: Bool? = nil,
        committedRevision: Date? = nil
    ) -> AgentScheduledSendDisposition {
        // No pre-barrier consent, and never for an attempt whose receipt transfer is unresolved.
        if let refusal = sendNowRefusal(scheduleID: scheduleID) {
            return .rejected(refusal)
        }
        let currentRecords = collectCandidates()
            .map(\.candidate.scheduledSend)
            .filter { $0.id == scheduleID }
        guard let currentRecord = currentRecords.max(by: { $0.updatedAt < $1.updatedAt }) else {
            return .rejected(.scheduleNotFound)
        }

        retiredRevisions = Set(retiredRevisions.filter { $0.scheduleID != scheduleID })
        confirmedOverrides[scheduleID] = ConfirmedOverride(
            admittedUpdatedAt: committedRevision ?? currentRecord.updatedAt,
            effectiveNotBefore: clock.now(),
            runAlongsideOtherSessions: runAlongsideOtherSessions
        )
        if var armed = armedRecords[scheduleID] {
            armed.epoch = armingEpoch
            armed.armedAt = clock.now()
            armed.observedDueAwakeAt = clock.now()
            armed.capturedRunID = nil
            armed.capturedRunDisposition = nil
            armedRecords[scheduleID] = armed
        }
        evaluate()
        return disposition(scheduleID: scheduleID)
    }

    /// The schedule's current disposition, from the same state admission uses: a Send-now refusal
    /// that would apply now, the recovery blocker recorded by the last evaluation, or `progressing`.
    /// Never looks schedules up in hosts; a schedule no host projects reads `progressing`.
    package func disposition(scheduleID: UUID) -> AgentScheduledSendDisposition {
        if let refusal = sendNowRefusal(scheduleID: scheduleID) {
            return .rejected(refusal)
        }
        if let recorded = recoveryBlockersByScheduleID[scheduleID] {
            return .blocked(recorded.blocker)
        }
        return .progressing
    }

    /// The recorded recovery blocker of a schedule that is otherwise admissible (banner projection).
    package func recoveryBlocker(scheduleID: UUID) -> AgentScheduledSendRecoveryBlocker? {
        guard case let .blocked(blocker) = disposition(scheduleID: scheduleID) else { return nil }
        return blocker
    }

    private func sendNowRefusal(scheduleID: UUID) -> AgentScheduledSendNowRefusal? {
        guard isStartupAdmissionOpen else { return .startupAdmissionClosed(startupAdmission) }
        guard transferHoldsByScheduleID[scheduleID] == nil else { return .transferHeld }
        guard pendingConfirmationsByScheduleID[scheduleID] == nil else { return .confirmationPending }
        return nil
    }

    package func activeAdmission(sessionID: UUID) -> AgentScheduledSendAdmissionLease? {
        admissionsBySessionID[sessionID]?.lease
            ?? retainedAttemptsBySessionID[sessionID]?.lease
    }

    // MARK: Pending confirmation obligations (durable acknowledgement)

    package func dashboardPendingConfirmations(in workspaceID: UUID) -> [AgentScheduledSendPendingConfirmationStatus] {
        pendingConfirmationsByScheduleID.values
            .filter { $0.workspaceID == workspaceID }
            .map(status(for:))
    }

    package func pendingConfirmationStatus(sessionID: UUID) -> AgentScheduledSendPendingConfirmationStatus? {
        guard let pending = pendingConfirmationsByScheduleID.values.first(where: { $0.sessionID == sessionID }) else {
            return nil
        }
        return status(for: pending)
    }

    func pendingConfirmationStatus(scheduleID: UUID) -> AgentScheduledSendPendingConfirmationStatus? {
        pendingConfirmationsByScheduleID[scheduleID].map(status(for:))
    }

    private func status(for pending: PendingConfirmation) -> AgentScheduledSendPendingConfirmationStatus {
        let phase: AgentScheduledSendPendingConfirmationPhase = if pending.needsAttention {
            .needsAttention(lastFailure: pending.lastFailure)
        } else if pending.inFlightRequestID != nil {
            .saving(attemptNumber: pending.attemptCount)
        } else if let nextRetryAt = pending.nextRetryAt {
            .waitingToRetry(nextAttemptNumber: pending.attemptCount + 1, notBefore: nextRetryAt)
        } else {
            .waitingForOwner
        }
        return AgentScheduledSendPendingConfirmationStatus(
            sessionID: pending.sessionID,
            scheduleID: pending.scheduleID,
            decisionID: pending.decisionID,
            reason: pending.reason,
            phase: phase,
            attemptCount: pending.attemptCount
        )
    }

    /// Manual, persistence-only retry of an exhausted confirmation obligation. Resets the bounded
    /// budget for the same decision; never authorizes dispatch.
    @discardableResult
    package func retryPendingConfirmation(sessionID: UUID) -> Bool {
        guard let scheduleID = pendingConfirmationsByScheduleID.first(where: { $0.value.sessionID == sessionID })?.key,
              var pending = pendingConfirmationsByScheduleID[scheduleID],
              pending.needsAttention,
              pending.inFlightRequestID == nil
        else { return false }
        pending.needsAttention = false
        pending.attemptCount = 0
        pending.nextRetryAt = nil
        pendingConfirmationsByScheduleID[scheduleID] = pending
        postPendingConfirmationChange(pending)
        evaluate()
        return true
    }

    /// Reserves the durable session for a user action and captures the schedule's current
    /// decision: no coordinator mutation of any kind is issued for the session while the token is
    /// held (so a mutation can never queue behind the action in its own serializer). Always paired
    /// with `completeUserSupersession` or `releaseUserSupersession` on every exit path.
    package func beginUserSupersession(sessionID: UUID, scheduleID: UUID) -> AgentScheduledSendUserSupersessionToken {
        let token = AgentScheduledSendUserSupersessionToken(
            id: UUID(),
            sessionID: sessionID,
            scheduleID: scheduleID,
            decisionID: pendingConfirmationsByScheduleID[scheduleID]?.decisionID,
            epoch: armingEpoch
        )
        userActionReservationTokensBySessionID[sessionID, default: []].append(token.id)
        return token
    }

    private func isReservedByUserAction(sessionID: UUID) -> Bool {
        !(userActionReservationTokensBySessionID[sessionID]?.isEmpty ?? true)
    }

    /// Suspends until no coordinator-issued host mutation is outstanding for the durable session.
    /// User actions call this (outside their per-tab serializer) before superseding a decision so
    /// an older automatic write cannot commit after the user's consent was installed.
    package func drainOutstandingHostMutation(sessionID: UUID) async {
        while inFlightHostMutationSessionIDs.contains(sessionID) {
            await withCheckedContinuation { continuation in
                hostMutationDrainWaiters[sessionID, default: []].append(continuation)
            }
        }
    }

    /// The user action committed durably at `committedRevision`. Clears the obligation only when
    /// the token still names the current decision, no newer epoch transition happened, and no
    /// coordinator mutation is still outstanding for the session (its durable outcome must be
    /// observed first); otherwise the decision stays and the caller must not treat the record as
    /// confirmed. Returns `true` when no pending obligation blocks the schedule afterwards.
    @discardableResult
    package func completeUserSupersession(_ token: AgentScheduledSendUserSupersessionToken, committedRevision _: Date?) -> Bool {
        defer { releaseUserSupersession(token) }
        guard !inFlightHostMutationSessionIDs.contains(token.sessionID) else { return false }
        guard let pending = pendingConfirmationsByScheduleID[token.scheduleID] else { return true }
        guard pending.decisionID == token.decisionID, token.epoch == armingEpoch else { return false }
        pendingConfirmationsByScheduleID.removeValue(forKey: token.scheduleID)
        // The user acknowledged this decision under the current epoch: the armed observation is
        // consumed so the same transition cannot re-install the obligation it just superseded.
        if var armed = armedRecords[token.scheduleID] {
            let now = clock.now()
            armed.epoch = armingEpoch
            armed.armedAt = now
            armed.observedDueAwakeAt = now
            armed.capturedRunID = nil
            armed.capturedRunDisposition = nil
            armedRecords[token.scheduleID] = armed
        }
        postPendingConfirmationChange(pending)
        evaluate()
        return true
    }

    /// Releases exactly this token's reservation without clearing anything (failure or
    /// cancellation of the action). Idempotent; other actions' reservations are untouched.
    package func releaseUserSupersession(_ token: AgentScheduledSendUserSupersessionToken) {
        guard var tokens = userActionReservationTokensBySessionID[token.sessionID],
              let index = tokens.firstIndex(of: token.id)
        else { return }
        tokens.remove(at: index)
        if tokens.isEmpty {
            userActionReservationTokensBySessionID.removeValue(forKey: token.sessionID)
        } else {
            userActionReservationTokensBySessionID[token.sessionID] = tokens
        }
        evaluate()
    }

    /// A host rolled its persisted `.dispatching` attempt back to the pre-attempt content at
    /// `revertedUpdatedAt` without any user edit (late blocker, revoked handoff). The user's
    /// Send-now consent and the armed observation travel to that revision; only edits withdraw them.
    package func admissionRolledBack(
        lease: AgentScheduledSendAdmissionLease,
        revertedUpdatedAt: Date
    ) {
        guard admissionsBySessionID[lease.sessionID]?.lease == lease else { return }
        if var override = confirmedOverrides[lease.scheduleID],
           override.admittedUpdatedAt == lease.admittedUpdatedAt
        {
            override.admittedUpdatedAt = revertedUpdatedAt
            confirmedOverrides[lease.scheduleID] = override
        }
    }

    // MARK: Process-owned accepted recovery

    /// Final guarded handoff: validates the process-wide gates and, in the same synchronous
    /// step, reserves process ownership (`awaitingProviderOutcome`) for the attempt named by
    /// `context` so a provider result arriving after host teardown still has an owner. Returns
    /// `false` (no reservation) when the handoff is revoked.
    package func authorizeProviderHandoff(
        _ validator: AgentScheduledSendFinalHandoffValidator,
        context: AgentScheduledSendRecoveryContext,
        attempt: AgentScheduledSendPersist.Attempt
    ) -> Bool {
        let lease = validator.lease
        guard isValid(validator), context.sessionID == lease.sessionID else { return false }
        let key = AgentScheduledSendRecoveryKey(
            sessionID: lease.sessionID,
            leaseID: lease.id,
            attemptID: attempt.attemptID
        )
        if let existing = retainedAttemptsBySessionID[lease.sessionID] {
            return existing.key == key
        }
        retainedAttemptsBySessionID[lease.sessionID] = RetainedAttempt(
            lease: lease,
            key: key,
            context: context,
            payload: nil,
            phase: .awaitingProviderOutcome,
            dispatchOutcomeOutstanding: true
        )
        postRecoveryChange(.reserved, sessionID: lease.sessionID, workspaceID: lease.workspaceID, key: key)
        return true
    }

    /// Synchronous acceptance transfer: the immutable payload is retained and the single
    /// persistence worker starts before the caller can suspend. First evidence wins: the first
    /// payload reported for a key is canonical; identical duplicates are no-ops and conflicting
    /// reports are ignored (counted for observability) without touching the phase or the active
    /// worker, so the canonical attempt always reaches its terminal settlement.
    package func reportAcceptance(
        key: AgentScheduledSendRecoveryKey,
        payload: AgentScheduledSendAcceptedPayload
    ) {
        guard var retained = retainedAttemptsBySessionID[key.sessionID], retained.key == key else { return }
        if let existing = retained.payload {
            if existing.receipt != payload.receipt || existing.acceptedItem.id != payload.acceptedItem.id {
                retained.ignoredConflictingAcceptanceReports += 1
                retainedAttemptsBySessionID[key.sessionID] = retained
            }
            return
        }
        retained.payload = payload
        retained.phase = .saving(attemptNumber: 1)
        retainedAttemptsBySessionID[key.sessionID] = retained
        postRecoveryChange(.accepted, sessionID: key.sessionID, workspaceID: retained.lease.workspaceID, key: key)
        startRecoveryWorker(sessionID: key.sessionID, key: key, budget: recoveryRetryDelays)
    }

    /// The provider did not accept (failed, stale, cancelled) after ownership was reserved: no
    /// acceptance evidence exists, so the reservation is released.
    package func reportProviderOutcomeNotAccepted(key: AgentScheduledSendRecoveryKey) {
        guard let retained = retainedAttemptsBySessionID[key.sessionID],
              retained.key == key,
              retained.payload == nil
        else { return }
        retainedAttemptsBySessionID.removeValue(forKey: key.sessionID)
        postRecoveryChange(.released, sessionID: key.sessionID, workspaceID: retained.lease.workspaceID, key: key)
    }

    /// Immutable acceptance evidence of the retained attempt, for hosts that build their own
    /// presentation of a process-owned recovery (peer windows, reopened tabs). `nil` until
    /// acceptance is reported or once the attempt settled.
    package func acceptedPayload(sessionID: UUID) -> AgentScheduledSendAcceptedPayload? {
        retainedAttemptsBySessionID[sessionID]?.payload
    }

    /// Number of conflicting acceptance reports ignored for the retained attempt (first evidence wins).
    func ignoredConflictingAcceptanceReportCount(sessionID: UUID) -> Int {
        retainedAttemptsBySessionID[sessionID]?.ignoredConflictingAcceptanceReports ?? 0
    }

    package func recoveryStatus(sessionID: UUID) -> AgentScheduledSendRecoveryStatus? {
        guard let retained = retainedAttemptsBySessionID[sessionID] else { return nil }
        return AgentScheduledSendRecoveryStatus(
            key: retained.key,
            lease: retained.lease,
            phase: retained.phase,
            attemptCount: retained.attemptCount,
            hasAcceptedPayload: retained.payload != nil
        )
    }

    /// Persistence-only retry of a retained accepted attempt in attention state. Never a provider
    /// action. Repeated calls while a worker is active are no-ops.
    @discardableResult
    package func retryRecovery(sessionID: UUID) -> Bool {
        guard let retained = retainedAttemptsBySessionID[sessionID],
              retained.payload != nil,
              retained.workerTask == nil,
              case .needsAttention = retained.phase
        else { return false }
        startRecoveryWorker(sessionID: sessionID, key: retained.key, budget: recoveryRetryDelays)
        return true
    }

    /// Exact-lease completion reported by a host that finalized through the legacy direct path.
    func scheduledSendFinalizationDidComplete(lease: AgentScheduledSendAdmissionLease) {
        scheduledSendFinalizationDidComplete(
            sessionID: lease.sessionID,
            scheduleID: lease.scheduleID,
            admittedUpdatedAt: lease.admittedUpdatedAt
        )
    }

    package func finalHandoffValidator(
        for lease: AgentScheduledSendAdmissionLease
    ) -> AgentScheduledSendFinalHandoffValidator? {
        guard let admission = admissionsBySessionID[lease.sessionID],
              admission.lease == lease
        else {
            return nil
        }
        let validator = AgentScheduledSendFinalHandoffValidator(
            lease: lease,
            registrationID: admission.registrationID,
            tabID: admission.tabID
        )
        return isValid(validator) ? validator : nil
    }

    func isValid(_ validator: AgentScheduledSendFinalHandoffValidator) -> Bool {
        let lease = validator.lease
        guard isStartupAdmissionOpen,
              transferHoldsByScheduleID[lease.scheduleID] == nil,
              isValid(lease),
              let admission = admissionsBySessionID[lease.sessionID],
              admission.registrationID == validator.registrationID,
              admission.tabID == validator.tabID,
              let ownerRegistration = registrations.first(where: {
                  $0.id == validator.registrationID
              }),
              let ownerHost = ownerRegistration.host,
              ownerHost.ownsScheduledSendDestination(
                  tabID: validator.tabID,
                  sessionID: lease.sessionID
              ),
              !ownerHost.scheduledSendBusyStateExcludingDispatchReservation(
                  tabID: validator.tabID
              ).isBusy
        else {
            return false
        }

        // The destination session must be idle on every host (a peer window or tab may hold the
        // same durable session); the override never bypasses this.
        let destinationBusyElsewhere = registrations.contains { registration in
            guard let host = registration.host else { return false }
            let excludedTabID = registration.id == validator.registrationID
                ? validator.tabID
                : nil
            return host.scheduledSendDestinationIsBusy(
                sessionID: lease.sessionID,
                excludingDispatchReservationForTabID: excludedTabID
            )
        }
        guard !destinationBusyElsewhere else { return false }

        // Unresolved recovery anywhere in the workspace blocks every new-session start, including
        // one that runs alongside other sessions.
        if lease.blocksOnUnresolvedRecovery,
           registrations.contains(where: { registration in
               registration.host?.hasUnresolvedRecoverySession(
                   inWorkspace: lease.workspaceID,
                   excluding: lease.sessionID
               ) == true
           })
        {
            return false
        }

        // Other sessions in the workspace block only a workspace-gated new-session start.
        guard lease.requiresWorkspaceGate else { return true }
        return !registrations.contains { registration in
            guard let host = registration.host else { return false }
            let excludedTabID = registration.id == validator.registrationID
                ? validator.tabID
                : nil
            return host.hasBusySessionForScheduledSendHandoff(
                inWorkspace: lease.workspaceID,
                excludingDispatchReservationForTabID: excludedTabID
            )
        }
    }

    func scheduledSendFinalizationDidComplete(
        sessionID: UUID,
        scheduleID: UUID,
        admittedUpdatedAt: Date
    ) {
        let revision = ScheduleRevision(
            scheduleID: scheduleID,
            updatedAt: admittedUpdatedAt
        )
        if let retained = retainedAttemptsBySessionID[sessionID],
           retained.lease.scheduleID == scheduleID,
           retained.lease.admittedUpdatedAt == admittedUpdatedAt
        {
            settleRetainedAttempt(sessionID: sessionID, key: retained.key, workerID: nil, disposition: .committed)
            return
        }
        guard admissionsBySessionID[sessionID]?.lease.scheduleID == scheduleID,
              admissionsBySessionID[sessionID]?.lease.admittedUpdatedAt == admittedUpdatedAt
        else {
            return
        }
        completedFinalizationRevisions.insert(revision)
    }

    func isValid(_ lease: AgentScheduledSendAdmissionLease) -> Bool {
        guard let admission = admissionsBySessionID[lease.sessionID] else {
            return false
        }
        return admission.lease == lease
            && admission.armingEpoch == armingEpoch
            && lease.effectiveDueAt <= clock.now()
    }

    package func isValid(
        _ lease: AgentScheduledSendAdmissionLease,
        for record: AgentScheduledSendPersist
    ) -> Bool {
        guard isValid(lease),
              record.id == lease.scheduleID,
              record.updatedAt == lease.admittedUpdatedAt,
              record.notBefore == lease.admittedNotBefore
        else {
            return false
        }
        return record.state == .scheduled
            || (
                lease.allowsNeedsConfirmation
                    && (record.state == .needsConfirmation || record.state == .failed)
            )
    }

    func evaluate() {
        // Startup barrier: no candidate evaluation, hydration, confirmation write, timer, or
        // dispatch until recovery reconciliation released admission.
        guard isStartupAdmissionOpen else {
            armTimer(for: nil)
            requestDashboardNotification()
            return
        }
        guard !isEvaluating else {
            needsRerun = true
            return
        }

        isEvaluating = true
        repeat {
            needsRerun = false
            evaluatePass()
        } while needsRerun
        isEvaluating = false
        requestDashboardNotification()
    }

    private func requestDashboardNotification() {
        guard !dashboardNotificationScheduled else { return }
        dashboardNotificationScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            dashboardNotificationScheduled = false
            let signature = dashboardSignature()
            guard signature != lastPublishedDashboardSignature else { return }
            lastPublishedDashboardSignature = signature
            NotificationCenter.default.post(name: .agentScheduledSendDashboardDidChange, object: self)
        }
    }

    private func dashboardSignature() -> [String] {
        var parts = authoritativeCandidates(from: collectCandidates()).map { authority in
            let owner = authority.matchingEntries.first(where: { $0.candidate.isHydrated })
                ?? authority.representative
            let candidate = owner.candidate
            let record = candidate.scheduledSend
            let snapshot = AgentScheduledSendDashboardCandidate(
                candidate: candidate,
                host: owner.host,
                pendingConfirmation: pendingConfirmationStatus(scheduleID: record.id),
                recovery: recoveryStatus(sessionID: candidate.sessionID),
                hasActiveAdmission: activeAdmission(sessionID: candidate.sessionID) != nil
            )
            return "candidate:\(candidate.workspaceID):\(candidate.sessionID):\(record.id):\(record.updatedAt):\(record.state.rawValue):\(record.notBefore):\(String(describing: record.firstEligibleAt)):\(candidate.isHydrated):\(ObjectIdentifier(owner.host)):\(dashboardBlockingSessionName(for: snapshot) ?? "")"
        }
        parts += pendingConfirmationsByScheduleID.values.map { pending in
            "confirmation:\(pending.workspaceID):\(String(describing: status(for: pending)))"
        }
        parts += retainedAttemptsBySessionID.keys.compactMap { sessionID in
            recoveryStatus(sessionID: sessionID).map { "recovery:\(String(describing: $0))" }
        }
        parts += admissionsBySessionID.values.map { admission in
            "admission:\(admission.lease.sessionID):\(admission.lease.scheduleID):\(admission.lease.id)"
        }
        // Observers that present schedules by identity (the recovery catalog) exclude held attempts.
        parts += transferHoldsByScheduleID.values.map { hold in
            "hold:\(hold.scheduleID):\(hold.scheduleAttemptID)"
        }
        return parts.sorted()
    }

    private func evaluatePass() {
        let now = clock.now()
        let probe = clock.probe()
        if abs(probe.wallClockAdjustment) > discontinuityThreshold {
            advanceArmingEpoch(reason: .clockChanged)
        } else if probe.suspendedGap > discontinuityThreshold {
            advanceArmingEpoch(reason: .wake)
        }

        pruneRegistrations()
        let ownedCandidates = collectCandidates()
        let authoritative = authoritativeCandidates(from: ownedCandidates)
        let authorityBySession = Dictionary(
            uniqueKeysWithValues: authoritative.map {
                ($0.representative.candidate.sessionID, $0)
            }
        )
        reconcileAdmissions(with: authorityBySession)

        let activeScheduleIDs = Set(ownedCandidates.map(\.candidate.scheduledSend.id))
        armedRecords = armedRecords.filter { scheduleID, armed in
            activeScheduleIDs.contains(scheduleID)
                || admissionsBySessionID[armed.sessionID] != nil
        }
        // A dispatching owner suppresses its candidate while the handoff is in flight; the user's
        // Send-now consent must survive that window so a rollback can carry it to the reverted
        // revision (`admissionRolledBack`). Only records without any admission are pruned.
        confirmedOverrides = confirmedOverrides.filter { scheduleID, _ in
            activeScheduleIDs.contains(scheduleID)
                || admissionsBySessionID.values.contains { $0.lease.scheduleID == scheduleID }
        }

        let orderedCandidates = authoritative.sorted {
            candidatePrecedes($0.representative, $1.representative)
        }
        var workspaceGatedAdmissionsThisPass: Set<UUID> = []
        var earliestFutureDeadline: Date?
        var recoveryBlockers: [UUID: RecordedRecoveryBlocker] = [:]
        defer { publishRecoveryBlockers(recoveryBlockers) }

        for authoritativeCandidate in orderedCandidates {
            let owned = authoritativeCandidate.representative
            let candidate = owned.candidate
            let record = candidate.scheduledSend
            let matchingEntries = authoritativeCandidate.matchingEntries

            guard admissionsBySessionID[candidate.sessionID] == nil,
                  retainedAttemptsBySessionID[candidate.sessionID] == nil
            else {
                continue
            }

            let revision = ScheduleRevision(record: record)
            let dispatchOwner = matchingEntries.first(where: { $0.candidate.isHydrated })
                ?? owned

            // An unresolved R9 receipt transfer: the recovery intent may already own this input.
            // Neither a confirmation obligation nor a dispatch may be created for it.
            if transferHoldsByScheduleID[record.id] != nil {
                continue
            }

            // A pending confirmation obligation blocks admission regardless of the projected
            // state, hydration, timers, or epoch refreshes, until its exact durable
            // acknowledgement (or user supersession). It is driven ahead of any logic that could
            // skip or re-arm the revision. A newer epoch transition may replace it with a new
            // decision (new identity and budget) but never lifts the block.
            if pendingConfirmationsByScheduleID[record.id] != nil {
                var armed = arm(record: record, sessionID: candidate.sessionID, at: now)
                if armed.epoch != armingEpoch {
                    _ = applyEpochTransition(to: &armed, record: record, now: now, entries: matchingEntries)
                    armedRecords[record.id] = armed
                }
                driveConfirmationPersistence(
                    scheduleID: record.id,
                    candidate: candidate,
                    dispatchOwner: dispatchOwner,
                    now: now,
                    earliestFutureDeadline: &earliestFutureDeadline
                )
                continue
            }

            // A coordinator mutation is unresolved for this session: never admit against a
            // revision that write is about to replace.
            guard !inFlightHostMutationSessionIDs.contains(candidate.sessionID) else {
                // Keep the presentation stable across the scheduler's own first-eligibility write.
                recoveryBlockers[record.id] = recoveryBlockersByScheduleID[record.id]
                continue
            }

            if record.state == .dispatching {
                guard !retiredRevisions.contains(revision) else { continue }
                if dispatchingRecordsRequireTransferResolution {
                    // Mandatory recovery: only the hydrated host may decide (repair the linked
                    // transfer, hold conflicting evidence, or normalize when nothing is linked).
                    if !dispatchOwner.candidate.isHydrated,
                       !hydrationFailures.contains(candidate.sessionID)
                    {
                        startHydrationIfNeeded(for: dispatchOwner)
                    }
                    continue
                }
                // A `.dispatching` record nobody in this process owns: delivery is unknown. The
                // revision is retired once the confirmation is durable.
                requireConfirmation(matchingEntries, reason: .deliveryUnknown)
                continue
            }

            guard !retiredRevisions.contains(revision) else { continue }

            let storedOverride = confirmedOverrides[record.id]
            let confirmedOverride: ConfirmedOverride? = if storedOverride?.admittedUpdatedAt == record.updatedAt {
                storedOverride
            } else {
                nil
            }
            if storedOverride != nil, confirmedOverride == nil {
                confirmedOverrides.removeValue(forKey: record.id)
            }
            let isUserConfirmed = confirmedOverride != nil
            let eligibleState = record.state == .scheduled
                || (isUserConfirmed && (record.state == .needsConfirmation || record.state == .failed))
            guard eligibleState else { continue }

            var armed = arm(record: record, sessionID: candidate.sessionID, at: now)
            let effectiveNotBefore = confirmedOverride?.effectiveNotBefore ?? record.notBefore
            if effectiveNotBefore > now {
                if armed.epoch != armingEpoch {
                    _ = applyEpochTransition(
                        to: &armed,
                        record: record,
                        now: now,
                        entries: matchingEntries
                    )
                }
                earliestFutureDeadline = minDate(earliestFutureDeadline, effectiveNotBefore)
                armedRecords[record.id] = armed
                continue
            }

            guard dispatchOwner.candidate.isHydrated else {
                armedRecords[record.id] = armed
                if !hydrationFailures.contains(candidate.sessionID) {
                    startHydrationIfNeeded(for: dispatchOwner)
                }
                continue
            }
            hydrationFailures.remove(candidate.sessionID)

            if armed.epoch != armingEpoch {
                guard applyEpochTransition(
                    to: &armed,
                    record: record,
                    now: now,
                    entries: matchingEntries
                ) else {
                    armedRecords[record.id] = armed
                    continue
                }
            }

            if armed.observedDueAwakeAt == nil {
                if isUserConfirmed {
                    armed.observedDueAwakeAt = now
                } else if record.createdAt <= launchAt, record.notBefore <= launchAt {
                    armedRecords[record.id] = armed
                    requireConfirmation(matchingEntries, reason: .missedWhileClosed)
                    continue
                } else if armed.epoch == armingEpoch, armed.armedAt <= record.notBefore {
                    armed.observedDueAwakeAt = now
                } else {
                    armedRecords[record.id] = armed
                    requireConfirmation(matchingEntries, reason: .destinationUnavailable)
                    continue
                }
            }

            let busyStates = matchingEntries.map {
                $0.host.scheduledSendBusyState(tabID: $0.candidate.tabID)
            }
            // Admission uses the same process-wide durable-destination predicate as the final
            // handoff gate: any host bound to this session (including one projecting an older or
            // absent schedule revision) blocks before any `.dispatching` attempt is written.
            let ownSessionIsBusy = matchingEntries.contains {
                $0.host.isBusy(tabID: $0.candidate.tabID)
            } || registrations.contains { registration in
                registration.host?.scheduledSendDestinationIsBusy(
                    sessionID: candidate.sessionID,
                    excludingDispatchReservationForTabID: nil
                ) == true
            }
            let representativeBusyState = busyStates.first(where: { $0.runState.isActive })
                ?? busyStates.first
                ?? AgentScheduledSendBusyState()

            if !record.isNewSessionStart,
               let capturedRunID = armed.capturedRunID
            {
                if representativeBusyState.runID == capturedRunID {
                    switch representativeBusyState.runState {
                    case .completed:
                        armed.capturedRunDisposition = .completed
                    case .cancelled, .failed, .idle:
                        armed.capturedRunDisposition = .invalid
                    case .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
                        break
                    }
                } else if representativeBusyState.runID != nil {
                    armed.capturedRunDisposition = .invalid
                }

                if armed.capturedRunDisposition == .invalid {
                    armedRecords[record.id] = armed
                    requireConfirmation(matchingEntries, reason: .runNotCompleted)
                    continue
                }
            }

            if ownSessionIsBusy {
                if busyStates.contains(where: \.hasUnresolvedRecovery) {
                    var blocker = workspaceRecoveryBlocker(
                        workspaceID: candidate.workspaceID,
                        excluding: candidate.sessionID
                    ) ?? AgentScheduledSendRecoveryBlocker()
                    blocker.destinationUnresolved = true
                    recoveryBlockers[record.id] = RecordedRecoveryBlocker(sessionID: candidate.sessionID, blocker: blocker)
                }
                setFirstEligibleAtIfNeeded(dispatchOwner: dispatchOwner, at: now, earliestFutureDeadline: &earliestFutureDeadline)
                if !record.isNewSessionStart,
                   armed.capturedRunID == nil,
                   representativeBusyState.runState.isActive,
                   let runID = representativeBusyState.runID
                {
                    armed.capturedRunID = runID
                    armed.capturedRunDisposition = .waiting
                }
                armedRecords[record.id] = armed
                continue
            }

            if !record.isNewSessionStart,
               armed.capturedRunID != nil,
               armed.capturedRunDisposition != .completed
            {
                armedRecords[record.id] = armed
                requireConfirmation(matchingEntries, reason: .runNotCompleted)
                continue
            }

            let runAlongside = confirmedOverride?.runAlongsideOtherSessions
                ?? record.runAlongsideOtherSessions
            let requiresWorkspaceGate = record.isNewSessionStart && !runAlongside
            // One host walk: the merged blocker is both the gate and what the banner shows.
            if record.isNewSessionStart,
               let blocker = workspaceRecoveryBlocker(
                   workspaceID: candidate.workspaceID,
                   excluding: candidate.sessionID
               )
            {
                recoveryBlockers[record.id] = RecordedRecoveryBlocker(sessionID: candidate.sessionID, blocker: blocker)
                setFirstEligibleAtIfNeeded(dispatchOwner: dispatchOwner, at: now, earliestFutureDeadline: &earliestFutureDeadline)
                armedRecords[record.id] = armed
                continue
            }
            if requiresWorkspaceGate {
                let workspaceID = candidate.workspaceID
                let hasCoordinatorReservation = admissionsBySessionID.values.contains {
                    $0.workspaceReservationHeld
                        && $0.lease.workspaceID == workspaceID
                        && $0.lease.sessionID != candidate.sessionID
                }
                let workspaceBusy = registrations.contains { registration in
                    registration.host?.hasBusySession(
                        inWorkspace: workspaceID,
                        excluding: candidate.sessionID
                    ) == true
                }
                guard !workspaceGatedAdmissionsThisPass.contains(workspaceID),
                      !hasCoordinatorReservation,
                      !workspaceBusy
                else {
                    setFirstEligibleAtIfNeeded(dispatchOwner: dispatchOwner, at: now, earliestFutureDeadline: &earliestFutureDeadline)
                    armedRecords[record.id] = armed
                    continue
                }
            }

            armedRecords[record.id] = armed
            let lease = AgentScheduledSendAdmissionLease(
                id: UUID(),
                sessionID: candidate.sessionID,
                scheduleID: record.id,
                workspaceID: candidate.workspaceID,
                admittedUpdatedAt: record.updatedAt,
                admittedNotBefore: record.notBefore,
                effectiveDueAt: effectiveNotBefore,
                allowsNeedsConfirmation: isUserConfirmed,
                runAlongsideOtherSessions: runAlongside,
                requiresWorkspaceGate: requiresWorkspaceGate,
                blocksOnUnresolvedRecovery: record.isNewSessionStart
            )
            admissionsBySessionID[candidate.sessionID] = Admission(
                lease: lease,
                registrationID: dispatchOwner.registrationID,
                tabID: dispatchOwner.candidate.tabID,
                armingEpoch: armingEpoch,
                workspaceReservationHeld: requiresWorkspaceGate
            )
            if requiresWorkspaceGate {
                workspaceGatedAdmissionsThisPass.insert(candidate.workspaceID)
            }
            startDispatch(on: dispatchOwner, lease: lease)
        }

        armTimer(for: earliestFutureDeadline)
        lastEvaluationAt = now
    }

    /// Every host's itemized recovery blocker for `workspaceID`, merged; `nil` when none reports one.
    private func workspaceRecoveryBlocker(
        workspaceID: UUID,
        excluding sessionID: UUID
    ) -> AgentScheduledSendRecoveryBlocker? {
        let blockers = registrations.compactMap {
            $0.host?.scheduledSendRecoveryBlocker(inWorkspace: workspaceID, excluding: sessionID)
        }
        guard var merged = blockers.first else { return nil }
        for blocker in blockers.dropFirst() {
            merged.merge(blocker)
        }
        return merged
    }

    private func publishRecoveryBlockers(_ blockers: [UUID: RecordedRecoveryBlocker]) {
        guard blockers != recoveryBlockersByScheduleID else { return }
        let previous = recoveryBlockersByScheduleID
        recoveryBlockersByScheduleID = blockers
        for scheduleID in Set(previous.keys).union(blockers.keys) where previous[scheduleID] != blockers[scheduleID] {
            guard let sessionID = blockers[scheduleID]?.sessionID ?? previous[scheduleID]?.sessionID else { continue }
            NotificationCenter.default.post(
                name: .agentScheduledSendDispositionDidChange,
                object: self,
                userInfo: ["sessionID": sessionID, "scheduleID": scheduleID]
            )
        }
    }

    private func collectCandidates() -> [OwnedCandidate] {
        registrations.flatMap { registration -> [OwnedCandidate] in
            guard let host = registration.host else { return [] }
            return host.scheduledSendCandidates().map {
                OwnedCandidate(
                    registrationID: registration.id,
                    registrationOrder: registration.order,
                    host: host,
                    candidate: $0
                )
            }
        }
    }

    private func authoritativeCandidates(
        from candidates: [OwnedCandidate]
    ) -> [AuthoritativeCandidate] {
        Dictionary(grouping: candidates, by: { $0.candidate.sessionID }).values.compactMap { entries in
            guard let representative = entries.sorted(by: projectionIsMoreAuthoritative).first else {
                return nil
            }
            let authority = representative.candidate
            let authorityRecord = authority.scheduledSend
            let matchingEntries = entries.filter { entry in
                let candidate = entry.candidate
                let record = candidate.scheduledSend
                return candidate.workspaceID == authority.workspaceID
                    && record.id == authorityRecord.id
                    && record.updatedAt == authorityRecord.updatedAt
                    && record.notBefore == authorityRecord.notBefore
            }
            return AuthoritativeCandidate(
                representative: representative,
                matchingEntries: matchingEntries
            )
        }
    }

    private func projectionIsMoreAuthoritative(
        _ lhs: OwnedCandidate,
        _ rhs: OwnedCandidate
    ) -> Bool {
        let lhsRecord = lhs.candidate.scheduledSend
        let rhsRecord = rhs.candidate.scheduledSend
        if lhsRecord.updatedAt != rhsRecord.updatedAt {
            return lhsRecord.updatedAt > rhsRecord.updatedAt
        }
        if lhsRecord.createdAt != rhsRecord.createdAt {
            return lhsRecord.createdAt > rhsRecord.createdAt
        }
        if lhs.candidate.isHydrated != rhs.candidate.isHydrated {
            return lhs.candidate.isHydrated
        }
        if lhsRecord.id != rhsRecord.id {
            return lhsRecord.id.uuidString > rhsRecord.id.uuidString
        }
        return lhs.registrationOrder < rhs.registrationOrder
    }

    private func reconcileAdmissions(
        with authorityBySession: [UUID: AuthoritativeCandidate]
    ) {
        let supersededSessionIDs: [UUID] = admissionsBySessionID.compactMap { sessionID, admission in
            guard let authoritative = authorityBySession[sessionID] else {
                // A dispatching owner may intentionally suppress its candidate while the
                // provider handoff is in flight. Absence alone cannot revoke that lease.
                return nil
            }
            let candidate = authoritative.representative.candidate
            let record = candidate.scheduledSend
            let lease = admission.lease

            if record.updatedAt < lease.admittedUpdatedAt {
                requestRefreshForStaleProjections(
                    authoritative.matchingEntries,
                    olderThan: lease.admittedUpdatedAt
                )
                return nil
            }

            guard candidate.workspaceID == lease.workspaceID,
                  record.id == lease.scheduleID,
                  record.notBefore == lease.admittedNotBefore
            else {
                return sessionID
            }

            if record.state == .dispatching {
                return nil
            }

            let sameRevision = record.updatedAt == lease.admittedUpdatedAt
            let eligibleState = record.state == .scheduled
                || (
                    lease.allowsNeedsConfirmation
                        && (record.state == .needsConfirmation || record.state == .failed)
                )
            return sameRevision && eligibleState ? nil : sessionID
        }

        for sessionID in supersededSessionIDs {
            admissionsBySessionID.removeValue(forKey: sessionID)
        }
    }

    private func requestRefreshForStaleProjections(
        _ entries: [OwnedCandidate],
        olderThan admittedUpdatedAt: Date
    ) {
        for entry in entries
            where !entry.candidate.isHydrated
            && entry.candidate.scheduledSend.updatedAt < admittedUpdatedAt
        {
            let projection = StaleProjectionRevision(
                registrationID: entry.registrationID,
                sessionID: entry.candidate.sessionID,
                tabID: entry.candidate.tabID,
                scheduleID: entry.candidate.scheduledSend.id,
                updatedAt: entry.candidate.scheduledSend.updatedAt
            )
            guard requestedProjectionRefreshes.insert(projection).inserted else {
                continue
            }
            entry.host.scheduledSendProjectionNeedsRefresh(
                tabID: entry.candidate.tabID,
                sessionID: entry.candidate.sessionID
            )
        }
    }

    private func candidatePrecedes(_ lhs: OwnedCandidate, _ rhs: OwnedCandidate) -> Bool {
        let lhsRecord = lhs.candidate.scheduledSend
        let rhsRecord = rhs.candidate.scheduledSend
        let lhsDate = confirmedOverrides[lhsRecord.id]?.effectiveNotBefore ?? lhsRecord.notBefore
        let rhsDate = confirmedOverrides[rhsRecord.id]?.effectiveNotBefore ?? rhsRecord.notBefore
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        if lhsRecord.createdAt != rhsRecord.createdAt {
            return lhsRecord.createdAt < rhsRecord.createdAt
        }
        if lhsRecord.id != rhsRecord.id {
            return lhsRecord.id.uuidString < rhsRecord.id.uuidString
        }
        if lhs.candidate.isHydrated != rhs.candidate.isHydrated {
            return lhs.candidate.isHydrated
        }
        return lhs.registrationOrder < rhs.registrationOrder
    }

    private func arm(
        record: AgentScheduledSendPersist,
        sessionID: UUID,
        at now: Date
    ) -> ArmedRecord {
        if var existing = armedRecords[record.id],
           existing.sessionID == sessionID,
           existing.notBefore == record.notBefore
        {
            return existing
        }

        let armed = ArmedRecord(
            scheduleID: record.id,
            sessionID: sessionID,
            notBefore: record.notBefore,
            epoch: armingEpoch,
            armedAt: now,
            observedDueAwakeAt: nil,
            capturedRunID: nil,
            capturedRunDisposition: nil
        )
        armedRecords[record.id] = armed
        return armed
    }

    /// Applies an arming-epoch change to one armed record. Returns `true` when the record may
    /// proceed under the new epoch. A transition that requires confirmation installs a retained
    /// obligation and never consumes the epoch itself: the record stays blocked until the
    /// confirmation is durably acknowledged, so a later deadline can never auto-dispatch past an
    /// uncertain crossing.
    private func applyEpochTransition(
        to armed: inout ArmedRecord,
        record: AgentScheduledSendPersist,
        now: Date,
        entries: [OwnedCandidate]
    ) -> Bool {
        func proceed() -> Bool {
            armed.epoch = armingEpoch
            armed.armedAt = now
            return true
        }
        func requireConfirmation(_ reason: AgentScheduledSendPersist.ConfirmationReason) -> Bool {
            self.requireConfirmation(entries, reason: reason)
            return false
        }

        switch armingEpochReason {
        case .launch:
            return proceed()

        case .wake:
            guard record.notBefore <= now else {
                armed.observedDueAwakeAt = nil
                armed.capturedRunID = nil
                armed.capturedRunDisposition = nil
                return proceed()
            }
            guard armed.observedDueAwakeAt != nil else {
                return requireConfirmation(.missedDuringSleep)
            }
            if record.isNewSessionStart {
                return proceed()
            }
            guard armed.capturedRunID != nil else {
                return requireConfirmation(.runNotCompleted)
            }
            return proceed()

        case .clockChanged:
            let couldHaveCrossed = record.notBefore <= max(lastEvaluationAt, now)
            guard couldHaveCrossed || armed.observedDueAwakeAt != nil else {
                armed.observedDueAwakeAt = nil
                armed.capturedRunID = nil
                armed.capturedRunDisposition = nil
                return proceed()
            }
            return requireConfirmation(.clockChanged)
        }
    }

    private func startHydrationIfNeeded(for owned: OwnedCandidate) {
        let sessionID = owned.candidate.sessionID
        guard hydratingSessionIDs.insert(sessionID).inserted else { return }

        let host = owned.host
        let tabID = owned.candidate.tabID
        Task { @MainActor [weak self, weak host] in
            guard let self, let host else { return }
            let hydrated = await host.ensureHydrated(tabID: tabID)
            hydratingSessionIDs.remove(sessionID)
            if !hydrated {
                hydrationFailures.insert(sessionID)
            }
            evaluate()
        }
    }

    private func startDispatch(
        on owned: OwnedCandidate,
        lease: AgentScheduledSendAdmissionLease
    ) {
        let host = owned.host
        let tabID = owned.candidate.tabID
        Task { @MainActor [weak self, weak host] in
            guard let self, let host else { return }
            guard isValid(lease) else {
                if admissionsBySessionID[lease.sessionID]?.lease == lease {
                    admissionsBySessionID.removeValue(forKey: lease.sessionID)
                    evaluate()
                }
                return
            }
            let outcome = await host.dispatchScheduledSend(
                tabID: tabID,
                scheduleID: lease.scheduleID,
                lease: lease
            )
            finishDispatch(lease: lease, outcome: outcome)
        }
    }

    private func finishDispatch(
        lease: AgentScheduledSendAdmissionLease,
        outcome: ScheduledDispatchOutcome
    ) {
        let revision = ScheduleRevision(lease: lease)
        if admissionsBySessionID[lease.sessionID]?.lease == lease {
            admissionsBySessionID.removeValue(forKey: lease.sessionID)
        }

        switch outcome {
        case .deferredBusy:
            break
        case .accepted:
            completedFinalizationRevisions.remove(revision)
            retiredRevisions.insert(revision)
            removeConfirmedOverride(matching: lease)
            if let retained = retainedAttemptsBySessionID[lease.sessionID], retained.lease == lease {
                // The host completed durable finalization itself (legacy direct path).
                settleRetainedAttempt(sessionID: lease.sessionID, key: retained.key, workerID: nil, disposition: .committed)
            }
        case .failedBeforeHandoff, .heldForRecovery:
            // `.heldForRecovery`: the admitted revision never re-drives; the transfer hold (not a
            // retained attempt) owns presentation, so no `needsAttention` record is created.
            retiredRevisions.insert(revision)
            removeConfirmedOverride(matching: lease)
            if let retained = retainedAttemptsBySessionID[lease.sessionID],
               retained.lease == lease,
               retained.payload == nil
            {
                retainedAttemptsBySessionID.removeValue(forKey: lease.sessionID)
            }
        case .unknownAfterHandoff:
            retiredRevisions.insert(revision)
            removeConfirmedOverride(matching: lease)
            if var retained = retainedAttemptsBySessionID[lease.sessionID], retained.lease == lease {
                // A populated record already owns the work; never replace it or restart its worker.
                retained.dispatchOutcomeOutstanding = false
                if retained.payload == nil, retained.phase == .awaitingProviderOutcome {
                    retained.phase = .needsAttention(.unresolvedProviderOutcome)
                }
                retainedAttemptsBySessionID[lease.sessionID] = retained
                completedFinalizationRevisions.remove(revision)
            } else if completedFinalizationRevisions.remove(revision) == nil {
                // Host reported acceptance without a process reservation (no payload available):
                // keep exact duplicate protection until the host reports completion.
                retainedAttemptsBySessionID[lease.sessionID] = RetainedAttempt(
                    lease: lease,
                    key: AgentScheduledSendRecoveryKey(sessionID: lease.sessionID, leaseID: lease.id, attemptID: UUID()),
                    context: nil,
                    payload: nil,
                    phase: .needsAttention(.unresolvedProviderOutcome),
                    dispatchOutcomeOutstanding: false
                )
            }
        }
        evaluate()
    }

    private enum RetainedDisposition {
        case committed
        case explicitlyDeleted
    }

    /// Single terminal operation for durable success (ordinary, reconstructed, or idempotent)
    /// and authorized explicit deletion: verifies the exact retained identity and worker, retires
    /// the admitted revision, records early completion while the dispatch outcome is outstanding,
    /// removes only the matching ownership, re-evaluates, and publishes for UI reconciliation.
    private func settleRetainedAttempt(
        sessionID: UUID,
        key: AgentScheduledSendRecoveryKey,
        workerID: UUID?,
        disposition: RetainedDisposition
    ) {
        guard let retained = retainedAttemptsBySessionID[sessionID], retained.key == key else { return }
        if let workerID, retained.workerID != workerID { return }
        let revision = ScheduleRevision(lease: retained.lease)
        retiredRevisions.insert(revision)
        if let payload = retained.payload {
            // The persisted `.dispatching` revision is terminal too: a peer still projecting it
            // must adopt the file, never normalize it (which could recreate a deleted session).
            retiredRevisions.insert(ScheduleRevision(scheduleID: retained.lease.scheduleID, updatedAt: payload.expectedUpdatedAt))
        }
        if retained.dispatchOutcomeOutstanding {
            completedFinalizationRevisions.insert(revision)
        }
        retainedAttemptsBySessionID.removeValue(forKey: sessionID)
        retained.workerTask?.cancel()
        let kind: AgentScheduledSendRecoveryChangeKind = switch disposition {
        case .committed: .committed
        case .explicitlyDeleted: .explicitlyDeleted
        }
        postRecoveryChange(kind, sessionID: sessionID, workspaceID: retained.lease.workspaceID, key: key)
        evaluate()
    }

    /// One bounded, persistence-only worker per retained attempt. Lifecycle teardown never
    /// cancels it; cancellation is never treated as proof that a write failed; a durable result
    /// returned after cancellation is still processed.
    private func startRecoveryWorker(
        sessionID: UUID,
        key: AgentScheduledSendRecoveryKey,
        budget: [TimeInterval]
    ) {
        guard var retained = retainedAttemptsBySessionID[sessionID],
              retained.key == key,
              retained.payload != nil,
              retained.workerTask == nil
        else { return }
        let workerID = UUID()
        retained.workerID = workerID
        let baseAttempt = retained.attemptCount
        retained.phase = .saving(attemptNumber: baseAttempt + 1)
        let clock = clock
        retained.workerTask = Task { @MainActor [weak self] in
            var delays = budget
            var attemptNumber = baseAttempt
            while true {
                guard let coordinator = self,
                      var current = coordinator.retainedAttemptsBySessionID[sessionID],
                      current.key == key,
                      current.workerID == workerID,
                      let payload = current.payload
                else { return }
                attemptNumber += 1
                current.attemptCount = attemptNumber
                current.phase = .saving(attemptNumber: attemptNumber)
                coordinator.retainedAttemptsBySessionID[sessionID] = current
                coordinator.postRecoveryChange(.saving, sessionID: sessionID, workspaceID: current.lease.workspaceID, key: key)

                let outcome: Result<AgentScheduledSendRecoveryOutcome, Error>
                do {
                    outcome = try await .success(payload.context.dataService.finalizeScheduledSend(recovery: payload))
                } catch {
                    outcome = .failure(error)
                }

                guard let coordinator = self,
                      var latest = coordinator.retainedAttemptsBySessionID[sessionID],
                      latest.key == key,
                      latest.workerID == workerID
                else { return }

                switch outcome {
                case .success(.committed(_)):
                    coordinator.settleRetainedAttempt(sessionID: sessionID, key: key, workerID: workerID, disposition: .committed)
                    return
                case .success(.explicitlyDeleted):
                    coordinator.settleRetainedAttempt(sessionID: sessionID, key: key, workerID: workerID, disposition: .explicitlyDeleted)
                    return
                case let .failure(error):
                    latest.lastFailure = String(describing: error)
                    if let attention = Self.attentionReason(for: error) {
                        latest.phase = .needsAttention(attention)
                        latest.workerTask = nil
                        latest.workerID = nil
                        coordinator.retainedAttemptsBySessionID[sessionID] = latest
                        coordinator.postRecoveryChange(.needsAttention, sessionID: sessionID, workspaceID: latest.lease.workspaceID, key: key)
                        return
                    }
                    guard !delays.isEmpty else {
                        latest.phase = .needsAttention(.persistenceExhausted(lastFailure: latest.lastFailure ?? ""))
                        latest.workerTask = nil
                        latest.workerID = nil
                        coordinator.retainedAttemptsBySessionID[sessionID] = latest
                        coordinator.postRecoveryChange(.needsAttention, sessionID: sessionID, workspaceID: latest.lease.workspaceID, key: key)
                        return
                    }
                    let delay = delays.removeFirst()
                    let notBefore = clock.now().addingTimeInterval(delay)
                    latest.phase = .waitingToRetry(nextAttemptNumber: attemptNumber + 1, notBefore: notBefore)
                    coordinator.retainedAttemptsBySessionID[sessionID] = latest
                    coordinator.postRecoveryChange(.waitingToRetry, sessionID: sessionID, workspaceID: latest.lease.workspaceID, key: key)
                    try? await clock.sleep(until: notBefore)
                }
            }
        }
        retainedAttemptsBySessionID[sessionID] = retained
    }

    /// Errors that stop automatic work immediately while retaining payload and protection.
    private static func attentionReason(for error: Error) -> AgentScheduledSendRecoveryAttentionReason? {
        if let recoveryError = error as? AgentScheduledSendRecoveryError {
            switch recoveryError {
            case .destinationUnavailable:
                return .destinationUnavailable
            case .snapshotUndecodable:
                return .invalidAcceptanceEvidence("reconstruction snapshot undecodable")
            case .lifecycleAuthorityUnavailable:
                return .destinationUnavailable
            }
        }
        if let mutationError = error as? AgentScheduledSendMutationError {
            switch mutationError {
            case .invalidAcceptedUserItem, .acceptedItemNotUser, .invalidDispatchReceipt:
                return .invalidAcceptanceEvidence(String(describing: mutationError))
            case .staleExpectedAttempt, .scheduledSendNotDispatching, .staleExpectedUpdatedAt,
                 .staleExpectedScheduledSendMember, .unreadableScheduledSend:
                // Residual attempt/state conflicts: never restore `.dispatching`, change attempts,
                // or authorize another provider submission.
                return .invalidAcceptanceEvidence(String(describing: mutationError))
            case .sessionNotFound:
                return nil
            default:
                return nil
            }
        }
        return nil
    }

    private func handleExplicitDeletionCommit(fileKey: URL, generation: UInt64) {
        let matches = retainedAttemptsBySessionID.filter { _, retained in
            guard let context = retained.context else { return false }
            // Both sides are the DataService's canonical key; a raw spelling (`/var` vs
            // `/private/var`) would silently miss the deletion and strand the retained attempt.
            return context.fileKey == fileKey && context.deletionGeneration < generation
        }
        for (sessionID, retained) in matches {
            // A worker mid-attempt learns the same fact from the gated finalizer; a dormant or
            // exhausted record terminates here without another retry.
            settleRetainedAttempt(sessionID: sessionID, key: retained.key, workerID: nil, disposition: .explicitlyDeleted)
        }
    }

    private func postRecoveryChange(
        _ kind: AgentScheduledSendRecoveryChangeKind,
        sessionID: UUID,
        workspaceID: UUID,
        key: AgentScheduledSendRecoveryKey
    ) {
        requestDashboardNotification()
        NotificationCenter.default.post(
            name: .agentScheduledSendRecoveryDidChange,
            object: nil,
            userInfo: [
                "sessionID": sessionID,
                "workspaceID": workspaceID,
                "leaseID": key.leaseID,
                "attemptID": key.attemptID,
                "changeKind": kind.rawValue
            ]
        )
    }

    private func removeConfirmedOverride(
        matching lease: AgentScheduledSendAdmissionLease
    ) {
        guard confirmedOverrides[lease.scheduleID]?.admittedUpdatedAt
            == lease.admittedUpdatedAt
        else {
            return
        }
        confirmedOverrides.removeValue(forKey: lease.scheduleID)
    }

    /// Installs (or replaces with a new decision) the confirmation obligation for the schedule
    /// and withdraws any Send-now consent. The record is not mutated here: persistence happens
    /// through one acknowledged host mutation driven by `evaluatePass`.
    private func requireConfirmation(
        _ entries: [OwnedCandidate],
        reason: AgentScheduledSendPersist.ConfirmationReason
    ) {
        guard let first = entries.first else { return }
        let scheduleID = first.candidate.scheduledSend.id
        confirmedOverrides.removeValue(forKey: scheduleID)
        if let existing = pendingConfirmationsByScheduleID[scheduleID],
           existing.reason == reason,
           existing.epoch == armingEpoch
        {
            return
        }
        // A newer decision keeps the block and gets a fresh identity and budget; a completion of
        // the older in-flight request becomes stale and can clear nothing. A user action that
        // reserved the session keeps its (session-scoped) reservation, but its token can no
        // longer clear this newer decision.
        let pending = PendingConfirmation(
            sessionID: first.candidate.sessionID,
            workspaceID: first.candidate.workspaceID,
            scheduleID: scheduleID,
            decisionID: UUID(),
            epoch: armingEpoch,
            reason: reason
        )
        pendingConfirmationsByScheduleID[scheduleID] = pending
        postPendingConfirmationChange(pending)
        needsRerun = true
    }

    /// Drives one pending obligation: selects the hydrated owner, issues at most one exact
    /// request per durable session, honors the bounded retry schedule on the coordinator clock,
    /// and parks in attention after exhaustion. Never admits the schedule.
    private func driveConfirmationPersistence(
        scheduleID: UUID,
        candidate: AgentScheduledSendCandidate,
        dispatchOwner: OwnedCandidate,
        now: Date,
        earliestFutureDeadline: inout Date?
    ) {
        guard var pending = pendingConfirmationsByScheduleID[scheduleID],
              pending.sessionID == candidate.sessionID,
              pending.inFlightRequestID == nil,
              !isReservedByUserAction(sessionID: candidate.sessionID),
              !pending.needsAttention
        else { return }
        if let nextRetryAt = pending.nextRetryAt, nextRetryAt > now {
            earliestFutureDeadline = minDate(earliestFutureDeadline, nextRetryAt)
            return
        }
        guard dispatchOwner.candidate.isHydrated else {
            if !hydrationFailures.contains(candidate.sessionID) {
                startHydrationIfNeeded(for: dispatchOwner)
            }
            return
        }
        guard !inFlightHostMutationSessionIDs.contains(candidate.sessionID) else { return }
        hydrationFailures.remove(candidate.sessionID)

        let expected = dispatchOwner.candidate.scheduledSend
        let replacement: AgentScheduledSendPersist
        if let retained = pending.retainedRequest, retained.expected == expected {
            replacement = retained.replacement
        } else {
            var built = expected
            built.state = .needsConfirmation
            built.confirmationReason = pending.reason
            built.updatedAt = Self.nextRevision(after: expected.updatedAt, now: now)
            replacement = built
            pending.retainedRequest = (expected, built)
        }
        let request = AgentScheduledSendHostMutationRequest(
            id: UUID(),
            sessionID: candidate.sessionID,
            scheduleID: scheduleID,
            expected: expected,
            replacement: replacement
        )
        pending.inFlightRequestID = request.id
        pending.attemptCount += 1
        pending.nextRetryAt = nil
        pendingConfirmationsByScheduleID[scheduleID] = pending
        postPendingConfirmationChange(pending)
        let decisionID = pending.decisionID
        issueHostMutation(owner: dispatchOwner, request: request) { [weak self] outcome in
            self?.completeConfirmationPersistence(
                scheduleID: scheduleID,
                decisionID: decisionID,
                request: request,
                owner: dispatchOwner,
                outcome: outcome
            )
        }
    }

    private func completeConfirmationPersistence(
        scheduleID: UUID,
        decisionID: UUID,
        request: AgentScheduledSendHostMutationRequest,
        owner: OwnedCandidate,
        outcome: AgentScheduledSendHostMutationOutcome
    ) {
        guard var pending = pendingConfirmationsByScheduleID[scheduleID],
              pending.decisionID == decisionID,
              pending.inFlightRequestID == request.id
        else {
            // Stale completion (newer decision or supersession): its durable write, if any, is
            // real but clears nothing; the current obligation is re-driven against authority.
            evaluate()
            return
        }
        pending.inFlightRequestID = nil
        switch outcome {
        case .committed:
            pendingConfirmationsByScheduleID.removeValue(forKey: scheduleID)
            // The revision that was eligible before the decision is retired exactly; the durable
            // `.needsConfirmation` record stays ineligible without explicit user confirmation.
            retiredRevisions.insert(ScheduleRevision(record: request.expected))
            for entry in collectCandidates()
                where entry.candidate.scheduledSend.id == scheduleID
                && entry.candidate.scheduledSend.updatedAt == request.expected.updatedAt
                && !(entry.registrationID == owner.registrationID && entry.candidate.tabID == owner.candidate.tabID)
            {
                entry.host.scheduledSendProjectionNeedsRefresh(
                    tabID: entry.candidate.tabID,
                    sessionID: entry.candidate.sessionID
                )
            }
            postPendingConfirmationChange(pending)
        case .conflict:
            // The owner adopted authority; a new exact request forms on the next pass. Repeated
            // conflicts consume the same bounded budget so a moving target ends in attention.
            if pending.attemptCount > Self.confirmationRetryDelays.count {
                pending.lastFailure = "The scheduled message kept changing while its confirmation was being saved."
                pending.needsAttention = true
                postPendingConfirmationChange(pending)
            }
            pendingConfirmationsByScheduleID[scheduleID] = pending
        case .unavailable:
            // No write was attempted: not counted against the budget; resumes on a genuine
            // owner/hydration transition.
            pending.attemptCount = max(0, pending.attemptCount - 1)
            pendingConfirmationsByScheduleID[scheduleID] = pending
            postPendingConfirmationChange(pending)
        case .destinationDeleted:
            pendingConfirmationsByScheduleID.removeValue(forKey: scheduleID)
            postPendingConfirmationChange(pending)
        case let .failed(message):
            pending.lastFailure = message
            let delays = Self.confirmationRetryDelays
            if pending.attemptCount > delays.count {
                pending.needsAttention = true
            } else {
                pending.nextRetryAt = clock.now().addingTimeInterval(delays[pending.attemptCount - 1])
            }
            pendingConfirmationsByScheduleID[scheduleID] = pending
            postPendingConfirmationChange(pending)
        }
        evaluate()
    }

    /// Marks the first eligibility instant on the durable record through one acknowledged
    /// mutation. Send-now consent advances to the committed revision only after acknowledgement;
    /// admission is never attempted against the unresolved replacement.
    private func setFirstEligibleAtIfNeeded(
        dispatchOwner: OwnedCandidate,
        at now: Date,
        earliestFutureDeadline: inout Date?
    ) {
        let record = dispatchOwner.candidate.scheduledSend
        let sessionID = dispatchOwner.candidate.sessionID
        guard dispatchOwner.candidate.isHydrated,
              record.firstEligibleAt == nil,
              pendingConfirmationsByScheduleID[record.id] == nil,
              !inFlightHostMutationSessionIDs.contains(sessionID),
              !isReservedByUserAction(sessionID: sessionID)
        else { return }
        // Bounded backoff for this informational write: a failed attempt against the same
        // revision is retried on the coordinator clock, never in a tight evaluate/failure loop.
        if let retry = firstEligibilityRetryByScheduleID[record.id] {
            if retry.revision == record.updatedAt {
                if retry.notBefore > now {
                    earliestFutureDeadline = minDate(earliestFutureDeadline, retry.notBefore)
                    return
                }
            } else {
                firstEligibilityRetryByScheduleID.removeValue(forKey: record.id)
            }
        }
        var replacement = record
        replacement.firstEligibleAt = now
        replacement.updatedAt = Self.nextRevision(after: record.updatedAt, now: now)
        let request = AgentScheduledSendHostMutationRequest(
            id: UUID(),
            sessionID: sessionID,
            scheduleID: record.id,
            expected: record,
            replacement: replacement
        )
        issueHostMutation(owner: dispatchOwner, request: request) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case let .committed(committedUpdatedAt):
                firstEligibilityRetryByScheduleID.removeValue(forKey: record.id)
                if var confirmedOverride = confirmedOverrides[record.id],
                   confirmedOverride.admittedUpdatedAt == record.updatedAt
                {
                    confirmedOverride.admittedUpdatedAt = committedUpdatedAt ?? replacement.updatedAt
                    confirmedOverrides[record.id] = confirmedOverride
                }
            case .failed, .conflict, .unavailable:
                firstEligibilityRetryByScheduleID[record.id] = (
                    revision: record.updatedAt,
                    notBefore: clock.now().addingTimeInterval(Self.firstEligibilityRetryDelay)
                )
            case .destinationDeleted:
                firstEligibilityRetryByScheduleID.removeValue(forKey: record.id)
            }
            evaluate()
        }
    }

    /// One coordinator-issued host mutation per durable session; the completion always runs on
    /// the main actor after the in-flight marker is cleared.
    private func issueHostMutation(
        owner: OwnedCandidate,
        request: AgentScheduledSendHostMutationRequest,
        completion: @escaping @MainActor (AgentScheduledSendHostMutationOutcome) -> Void
    ) {
        guard inFlightHostMutationSessionIDs.insert(request.sessionID).inserted else { return }
        let host = owner.host
        let tabID = owner.candidate.tabID
        Task { @MainActor [weak self, weak host] in
            let outcome: AgentScheduledSendHostMutationOutcome = if let host {
                await host.persistScheduledSendMutation(tabID: tabID, request: request)
            } else {
                .unavailable
            }
            guard let self else { return }
            inFlightHostMutationSessionIDs.remove(request.sessionID)
            completion(outcome)
            let waiters = hostMutationDrainWaiters.removeValue(forKey: request.sessionID) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    /// A replacement revision that differs from the expected one even when wall time is
    /// stationary or moved backwards.
    private static func nextRevision(after revision: Date, now: Date) -> Date {
        max(now, revision.addingTimeInterval(0.001))
    }

    private func postPendingConfirmationChange(_ pending: PendingConfirmation) {
        requestDashboardNotification()
        NotificationCenter.default.post(
            name: .agentScheduledSendPendingConfirmationDidChange,
            object: nil,
            userInfo: ["sessionID": pending.sessionID, "scheduleID": pending.scheduleID]
        )
    }

    private func armTimer(for deadline: Date?) {
        guard timerDeadline != deadline else { return }

        timerTask?.cancel()
        timerTask = nil
        timerDeadline = deadline
        timerGeneration &+= 1
        guard let deadline else { return }

        let generation = timerGeneration
        let clock = clock
        timerTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self,
                  timerGeneration == generation,
                  timerDeadline == deadline
            else {
                return
            }
            timerTask = nil
            timerDeadline = nil
            evaluate()
        }
    }

    private func advanceArmingEpoch(reason: ArmingEpochReason) {
        armingEpoch &+= 1
        armingEpochReason = reason
    }

    private func pruneRegistrations() {
        registrations.removeAll { $0.host == nil }
    }

    private func minDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return min(lhs, rhs)
    }
}
