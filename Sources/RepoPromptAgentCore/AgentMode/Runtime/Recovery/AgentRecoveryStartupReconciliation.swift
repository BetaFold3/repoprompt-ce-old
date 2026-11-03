import Foundation

// Lossless-restart Phase 1b startup reconciliation (spec R1a, R5, R8 startup order, R9). Immutable
// startup results, not new persisted authorities: every mutation goes through the existing
// DataService session gate and recovery store. Lock order: DataService gate -> recovery store.

// MARK: - Inventory

/// One workspace's session storage, as recorded in the workspace index.
package struct AgentRecoveryWorkspaceDestination: AgentWorkspaceStorageReference, Equatable {
    package let id: UUID
    package let name: String
    package let customStoragePath: URL?

    package init(id: UUID, name: String, customStoragePath: URL?) {
        self.id = id
        self.name = name
        self.customStoragePath = customStoragePath
    }
}

/// Recovery-specific workspace inventory. A known workspace that cannot be read is a scoped failure
/// (it blocks only that workspace); an unreadable global index is thrown instead
/// (`AgentRecoveryInventoryIndexFailure`) and keeps startup closed.
package struct AgentRecoveryWorkspaceInventory: Equatable {
    package struct Failure: Equatable {
        package let workspaceID: UUID
        package let location: String
        package let reason: String

        package init(workspaceID: UUID, location: String, reason: String) {
            self.workspaceID = workspaceID
            self.location = location
            self.reason = reason
        }
    }

    package var workspaces: [AgentRecoveryWorkspaceDestination]
    package var failures: [Failure]

    package init(workspaces: [AgentRecoveryWorkspaceDestination], failures: [Failure] = []) {
        self.workspaces = workspaces
        self.failures = failures
    }

    package static let empty = AgentRecoveryWorkspaceInventory(workspaces: [])
}

/// The global workspace index could not be read: the global scope cannot be established.
package struct AgentRecoveryInventoryIndexFailure: Error, Equatable {
    package let reason: String

    package init(reason: String) {
        self.reason = reason
    }
}

/// One normal session file (or durable stub) of a workspace, with its metadata-index hint.
package struct AgentRecoverySessionFile: Equatable {
    package let sessionID: UUID
    package let hint: AgentRecoverySessionFileHint?

    package init(sessionID: UUID, hint: AgentRecoverySessionFileHint?) {
        self.sessionID = sessionID
        self.hint = hint
    }
}

/// Cheap per-session discovery hint from a workspace's metadata index. A session file absent from
/// the index has no hint and is always inspected.
package struct AgentRecoverySessionFileHint: Equatable {
    package let lastRunStateRaw: String?
    package let scheduleStateRaw: String?
    package let scheduleUnreadable: Bool
    /// Whether the saved transcript may hold an unresolved interruption stamped by an earlier launch
    /// (true when the index entry cannot say), so repeated restarts keep its row and crash hold.
    package let mayHaveUnresolvedInterruption: Bool

    package init(
        lastRunStateRaw: String?,
        scheduleStateRaw: String?,
        scheduleUnreadable: Bool,
        mayHaveUnresolvedInterruption: Bool = false
    ) {
        self.lastRunStateRaw = lastRunStateRaw
        self.scheduleStateRaw = scheduleStateRaw
        self.scheduleUnreadable = scheduleUnreadable
        self.mayHaveUnresolvedInterruption = mayHaveUnresolvedInterruption
    }

    /// Whether the saved session may hold an open or unresolved interrupted turn, or an unowned
    /// `.dispatching` schedule.
    package var needsInspection: Bool {
        if scheduleUnreadable || mayHaveUnresolvedInterruption { return true }
        if scheduleStateRaw == AgentScheduledSendPersist.State.dispatching.rawValue { return true }
        guard let lastRunStateRaw else { return false }
        return AgentSessionRunState(rawValue: lastRunStateRaw)?.isActive ?? true
    }
}

// MARK: - Per-session resolution

/// A saved turn cold restore found open, with its R5 record and R1a status.
package struct AgentRecoveryInterruptedTurn: Equatable {
    /// The one classification of a turn's run outcome, shared by cold restore reconciliation, live
    /// state and the recovery catalog. It reads recorded run evidence only; a turn's `completedAt`
    /// (set by sanitizing) never implies completion. Every status other than `interrupted` and
    /// `unknown` comes from terminal evidence of a turn saved open, so its transcript tail may be
    /// missing.
    package enum Status: Equatable {
        case interrupted
        /// The run completed: "completed; transcript tail may be missing".
        case completedTailMayBeMissing
        /// The provider run failed on its own (not an interruption).
        case failed
        /// Stopped by the app for an ordinary reason (workspace switch, reset, delete).
        case stopped
        /// The user explicitly cancelled the run; not an interruption.
        case cancelledByUser
        /// The evidence does not say how the run ended.
        case unknown

        /// Whether the run's end is an interruption the user may want to resume.
        package var isInterruption: Bool {
            self == .interrupted
        }

        /// Classifies a run attempt from its recorded evidence. No terminal evidence is an
        /// interruption (the run never committed). A completed terminal is completion only with an
        /// ordinary (or legacy unspecified) cause; a failed or cancelled terminal is never
        /// completion. A legacy cancelled terminal without a cause is an interruption only when
        /// shutdown evidence was recorded, otherwise unknown.
        package static func classify(
            terminal: AgentRecoveryRunTerminalEvidence?,
            shutdown: AgentRecoveryRunShutdownEvidence?
        ) -> Status {
            guard let terminal else { return .interrupted }
            let cause = terminal.cause
            switch terminal.terminalState {
            case .completed:
                return cause == nil || cause == .ordinary ? .completedTailMayBeMissing : .unknown
            case .failed:
                if cause?.interruptionReason != nil { return .interrupted }
                return cause == .userCancel ? .cancelledByUser : .failed
            case .cancelled:
                switch cause {
                case .userCancel?: return .cancelledByUser
                case .ordinary?: return .stopped
                case .appQuit?, .windowClose?, .providerProcessLost?: return .interrupted
                case nil: return shutdown == nil ? .unknown : .interrupted
                }
            default:
                return .unknown
            }
        }

        /// Classification of a stamped turn: by its joined run attempt when there is one;
        /// otherwise (a legacy turn with no attempt) the stamp is the only evidence.
        package static func classify(attempt: AgentRecoveryRunAttempt?) -> Status {
            guard let attempt else { return .interrupted }
            return classify(terminal: attempt.terminal, shutdown: attempt.shutdown)
        }
    }

    package let turnID: UUID
    package let interruption: AgentTranscriptTurnInterruption
    package let status: Status
    /// Whether this is the session's last transcript turn.
    package let isLastTurn: Bool

    package init(turnID: UUID, interruption: AgentTranscriptTurnInterruption, status: Status, isLastTurn: Bool) {
        self.turnID = turnID
        self.interruption = interruption
        self.status = status
        self.isLastTurn = isLastTurn
    }
}

/// A turn saved open that cold restoration closed with its run attempt's authoritative ordinary
/// outcome (completed, an ordinary failure or cancel, or a user cancel) instead of an interruption
/// (review A F03). Listed by the launch that closed it: its transcript tail may be missing. Carries
/// no interruption stamp and never contributes to a crash hold.
package struct AgentRecoveryOutcomeTurn: Equatable {
    package let turnID: UUID
    package let runAttempt: AgentRecoveryRunAttempt

    package init(turnID: UUID, runAttempt: AgentRecoveryRunAttempt) {
        self.turnID = turnID
        self.runAttempt = runAttempt
    }

    /// The shared classifier over the attempt's recorded evidence (never `interrupted`).
    package var status: AgentRecoveryInterruptedTurn.Status {
        .classify(attempt: runAttempt)
    }
}

/// R9 schedule-transfer outcome of a gate-held repair.
package enum AgentRecoveryScheduleTransferOutcome: Equatable {
    case notApplicable
    case completed(AgentScheduledSendProvenance)
    /// No linked intent: the delivery-unknown confirmation was committed.
    case normalized
    /// Unknown or conflicting evidence: held with the pending schedule and payload unchanged.
    case held(String)
    /// R10: the user's matching cancellation decision was honoured; the exact pending schedule was
    /// cleared without a receipt. The linked input's delivery evidence is unchanged.
    case cancelled
}

package enum AgentSessionRecoveryClassification: Equatable {
    /// Current lifecycle authority was validated; recovered content and evidence are actionable.
    case actionable
    /// Nothing pending (a legacy idle session needs no recovery record).
    case idle
    /// Retired by a committed or unreadable tombstone: never restorable.
    case tombstoned
    /// Preserved data whose recovery status is unknown; view only, blocks the session.
    case nonactionable(AgentSessionRecoveryNonactionableReason)
    /// Several destinations hold the same globally unique session UUID; none is chosen.
    case duplicateDestination(workspaceIDs: [UUID])
    /// A recovery record whose session has no established destination (not an empty session).
    case noDestination
}

/// Immutable result of reconciling one session at startup (or for a hydrated owner).
package struct AgentSessionRecoveryResolution: Equatable {
    package let sessionID: UUID
    package let workspaceID: UUID?
    package let sessionName: String?
    /// The session's compose tab, used only to open it from the recovery list.
    package let composeTabID: UUID?
    package let classification: AgentSessionRecoveryClassification
    /// Validated current lifecycle binding (actionable sessions only).
    package let binding: AgentRecoveryLifecycleBinding?
    /// The recovery record with holds against the authoritative generation (actionable only).
    package let record: AgentRecoveryDiscoveredRecord?
    package let interruptedTurns: [AgentRecoveryInterruptedTurn]
    /// Turns saved open that this launch's cold restoration closed with an ordinary outcome.
    package let outcomeTurns: [AgentRecoveryOutcomeTurn]
    /// Run attempts with no saved transcript turn (`AgentRecoveryRunTurnJoin.unrepresentedAttempts`):
    /// open ones (the run started but the transcript never saved it) and terminal ones of the
    /// current generation (the run finished but its turn is missing, R09). Listed as their own rows
    /// (R1a); only open ones contribute to a crash hold (`deriveCrashHolds`).
    package let recoveryOnlyRunAttempts: [AgentRecoveryRunAttempt]
    package let scheduleTransfer: AgentRecoveryScheduleTransferOutcome
    /// The persisted session execution binding's remote host (`AgentSession.remoteHost`), when the
    /// session executes on an authoritative remote host (F-3). Such a session's uncertainty is the
    /// host's, not a local process's: it is excluded from local crash holds and local-owner
    /// confirmation, and its uncertain input stays visible as remote uncertainty.
    package let remoteHostID: String?
    /// The validated session storage destination (actionable sessions only): the closed-session
    /// gate a recovery-card acknowledgement uses when no live lane exists.
    package let workspace: AgentRecoveryWorkspaceDestination?

    package init(
        sessionID: UUID,
        workspaceID: UUID?,
        sessionName: String? = nil,
        composeTabID: UUID? = nil,
        classification: AgentSessionRecoveryClassification,
        binding: AgentRecoveryLifecycleBinding? = nil,
        record: AgentRecoveryDiscoveredRecord? = nil,
        interruptedTurns: [AgentRecoveryInterruptedTurn] = [],
        outcomeTurns: [AgentRecoveryOutcomeTurn] = [],
        recoveryOnlyRunAttempts: [AgentRecoveryRunAttempt] = [],
        scheduleTransfer: AgentRecoveryScheduleTransferOutcome = .notApplicable,
        remoteHostID: String? = nil,
        workspace: AgentRecoveryWorkspaceDestination? = nil
    ) {
        self.outcomeTurns = outcomeTurns
        self.remoteHostID = remoteHostID
        self.workspace = workspace
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.sessionName = sessionName
        self.composeTabID = composeTabID
        self.classification = classification
        self.binding = binding
        self.record = record
        self.interruptedTurns = interruptedTurns
        self.recoveryOnlyRunAttempts = recoveryOnlyRunAttempts
        self.scheduleTransfer = scheduleTransfer
    }

    /// Why this session's scheduling and admission stay blocked, if they do.
    package var restrictionReason: String? {
        switch classification {
        case .actionable, .idle, .tombstoned:
            break
        case .noDestination:
            return "Its recovery record has no readable session destination."
        case let .nonactionable(reason):
            return "Recovery status unknown (\(reason))."
        case .duplicateDestination:
            return "Several workspaces hold this session; recovery cannot choose one."
        }
        if case let .held(message) = scheduleTransfer {
            return message
        }
        return nil
    }

    /// Unresolved interrupted last turn without a run attempt (legacy): contributes to the crash hold.
    package var unresolvedLegacyInterruptedTurnIDs: Set<UUID> {
        Set(interruptedTurns.filter {
            $0.isLastTurn && $0.status == .interrupted && $0.interruption.runAttemptID == nil
                && $0.interruption.resolution == nil
        }.map(\.turnID))
    }

    /// Whether the resolution has anything to show in the recovery list.
    package var hasRecoveryItems: Bool {
        switch classification {
        case .idle, .tombstoned:
            return false
        case .nonactionable, .duplicateDestination, .noDestination:
            return true
        case .actionable:
            break
        }
        if case .held = scheduleTransfer { return true }
        if interruptedTurns.contains(where: { $0.interruption.resolution == nil }) { return true }
        if !outcomeTurns.isEmpty { return true }
        if !recoveryOnlyRunAttempts.isEmpty { return true }
        guard let record = record?.record else { return false }
        // Unresolved run evidence counts even without a transcript turn.
        return record.runAttempts.contains { $0.terminal == nil }
            || record.intents.contains { !$0.deliveryState.requiresNoFurtherDelivery || $0.deliveryState == .deliveryUnknown }
            || record.composer.map { $0.transcriptResetGeneration != record.transcriptResetGeneration } == true
    }
}

/// Every startup result: per-session resolutions, scoped workspace failures, and preserved record
/// files without a session UUID.
package struct AgentRecoveryStartupReconciliation: Equatable {
    package var sessions: [AgentSessionRecoveryResolution]
    package var workspaceFailures: [AgentRecoveryWorkspaceInventory.Failure]
    package var unattributedPreserved: [AgentRecoveryPreservedEntry]

    package init(
        sessions: [AgentSessionRecoveryResolution] = [],
        workspaceFailures: [AgentRecoveryWorkspaceInventory.Failure] = [],
        unattributedPreserved: [AgentRecoveryPreservedEntry] = []
    ) {
        self.sessions = sessions
        self.workspaceFailures = workspaceFailures
        self.unattributedPreserved = unattributedPreserved
    }

    package static let empty = AgentRecoveryStartupReconciliation()

    package func resolution(for sessionID: UUID) -> AgentSessionRecoveryResolution? {
        sessions.first { $0.sessionID == sessionID }
    }
}

// MARK: - Restrictions

/// The app-scoped restriction map used by both recovery admission and scheduling. Built from
/// authoritative startup results; a scoped failure blocks its session or workspace only.
package struct AgentRecoveryRestrictions: Equatable {
    package struct SessionRestriction: Equatable {
        package let workspaceID: UUID?
        package let reason: String
    }

    package private(set) var sessions: [UUID: SessionRestriction]
    package private(set) var workspaces: [UUID: String]

    package init(sessions: [UUID: SessionRestriction] = [:], workspaces: [UUID: String] = [:]) {
        self.sessions = sessions
        self.workspaces = workspaces
    }

    package static let none = AgentRecoveryRestrictions()

    package func sessionRestriction(_ sessionID: UUID) -> String? {
        sessions[sessionID]?.reason
    }

    package func workspaceRestriction(_ workspaceID: UUID) -> String? {
        workspaces[workspaceID]
    }

    /// Whether the session itself, or its workspace, is restricted.
    package func blocks(sessionID: UUID, workspaceID: UUID?) -> Bool {
        if sessions[sessionID] != nil { return true }
        guard let workspaceID else { return false }
        return workspaces[workspaceID] != nil
    }

    /// Whether any restricted session other than `sessionID` (open or closed) or the workspace
    /// itself is unresolved: the workspace-busy extension for closed sessions.
    package func hasUnresolvedSession(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> Bool {
        if workspaces[workspaceID] != nil { return true }
        return !restrictedSessionIDs(inWorkspace: workspaceID, excluding: sessionID).isEmpty
    }

    /// The restricted sessions other than `sessionID` (open or closed) in `workspaceID`.
    package func restrictedSessionIDs(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> Set<UUID> {
        Set(sessions.compactMap { entry in
            entry.key != sessionID && entry.value.workspaceID == workspaceID ? entry.key : nil
        })
    }

    package mutating func restrict(sessionID: UUID, workspaceID: UUID?, reason: String) {
        sessions[sessionID] = SessionRestriction(workspaceID: workspaceID, reason: reason)
    }

    package mutating func lift(sessionID: UUID) {
        sessions[sessionID] = nil
    }

    /// Scoped restrictions from startup results. Crash holds are separate: they are lifted only by
    /// explicit confirmation of the exact hold, not by these restrictions.
    package static func from(_ reconciliation: AgentRecoveryStartupReconciliation) -> AgentRecoveryRestrictions {
        var restrictions = AgentRecoveryRestrictions()
        for failure in reconciliation.workspaceFailures {
            restrictions.workspaces[failure.workspaceID] = "The workspace could not be read for recovery: \(failure.reason)"
        }
        for resolution in reconciliation.sessions {
            if let reason = resolution.restrictionReason {
                restrictions.restrict(sessionID: resolution.sessionID, workspaceID: resolution.workspaceID, reason: reason)
            }
        }
        return restrictions
    }
}

/// The unresolved sessions of one workspace that keep new-session starts paused
/// (`AgentRecoveryCoordinator.hasUnresolvedSession`), itemized for presentation.
package struct AgentRecoveryWorkspaceUnresolvedSummary: Equatable {
    /// Sessions with an unconfirmed crash hold.
    package var crashHeldSessionIDs: Set<UUID> = []
    /// Sessions restricted by startup results.
    package var restrictedSessionIDs: Set<UUID> = []
    /// The workspace's own restriction (it could not be read for recovery).
    package var workspaceRestriction: String?

    package init(
        crashHeldSessionIDs: Set<UUID> = [],
        restrictedSessionIDs: Set<UUID> = [],
        workspaceRestriction: String? = nil
    ) {
        self.crashHeldSessionIDs = crashHeldSessionIDs
        self.restrictedSessionIDs = restrictedSessionIDs
        self.workspaceRestriction = workspaceRestriction
    }

    package var isEmpty: Bool {
        crashHeldSessionIDs.isEmpty && restrictedSessionIDs.isEmpty && workspaceRestriction == nil
    }
}

// MARK: - Startup sweep

/// Enumerates every readable workspace's session files (including durable stubs), unions them with
/// recovery-record IDs, resolves each session once against its known destinations, and reconciles
/// it through the DataService session gate. Never constructs providers, controllers, or view
/// models, never awaits a startup barrier, and never replays or resumes anything.
package enum AgentRecoveryStartupSweep {
    package static func run(
        inventory: AgentRecoveryWorkspaceInventory,
        entries: [AgentRecoveryDiscoveryEntry],
        dataService: AgentSessionDataService
    ) async -> AgentRecoveryStartupReconciliation {
        var failures = inventory.failures
        var destinations: [UUID: [(workspace: AgentRecoveryWorkspaceDestination, hint: AgentRecoverySessionFileHint?)]] = [:]
        for workspace in inventory.workspaces {
            do {
                for file in try await dataService.recoverySessionFiles(for: workspace) {
                    destinations[file.sessionID, default: []].append((workspace, file.hint))
                }
            } catch {
                failures.append(AgentRecoveryWorkspaceInventory.Failure(
                    workspaceID: workspace.id,
                    location: workspace.customStoragePath?.path ?? workspace.name,
                    reason: String(describing: error)
                ))
            }
        }
        var recordSessionIDs: Set<UUID> = []
        var unattributed: [AgentRecoveryPreservedEntry] = []
        for entry in entries {
            switch entry {
            case let .supported(discovered):
                recordSessionIDs.insert(discovered.record.sessionID)
            case let .preserved(preserved):
                if let sessionID = preserved.sessionID {
                    recordSessionIDs.insert(sessionID)
                } else {
                    unattributed.append(preserved)
                }
            }
        }
        var results: [AgentSessionRecoveryResolution] = []
        let sessionIDs = Set(destinations.keys).union(recordSessionIDs).sorted { $0.uuidString < $1.uuidString }
        for sessionID in sessionIDs {
            let known = destinations[sessionID] ?? []
            let hasRecord = recordSessionIDs.contains(sessionID)
            guard known.count == 1, let destination = known.first else {
                // Several files, or only a record (its destination may also live in an unreadable
                // workspace): nonactionable, never an empty session. Deletion residue behind a
                // tombstone is retired instead.
                let unplaced: AgentSessionRecoveryClassification = known.isEmpty
                    ? .noDestination
                    : .duplicateDestination(workspaceIDs: known.map(\.workspace.id))
                let classification = await dataService.classifyUnplacedRecoverySession(sessionID: sessionID, unplaced: unplaced)
                results.append(AgentSessionRecoveryResolution(
                    sessionID: sessionID,
                    workspaceID: nil,
                    classification: classification
                ))
                continue
            }
            let needsInspection = hasRecord || (destination.hint?.needsInspection ?? true)
            guard needsInspection else { continue }
            let resolution = await dataService.reconcileRecoverySession(
                sessionID: sessionID,
                workspace: destination.workspace
            )
            if resolution.classification != .idle {
                results.append(resolution)
            }
        }
        return AgentRecoveryStartupReconciliation(
            sessions: results,
            workspaceFailures: failures,
            unattributedPreserved: unattributed
        )
    }
}
