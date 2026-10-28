import Foundation

// Lossless-restart Phase 1b production composition (spec R1, R2, R8). Constructed once by the App's
// `AgentRecoveryAppComposition` (mandatory admission, startup before scheduler admission opens);
// XCTest processes compose it explicitly with temporary stores.
//
// Ownership: one app-scoped coordinator owns one store, the DataService that gates it, the launch
// mark and startup barrier, crash holds, and exactly one live `AgentRecoverySessionLane` (one
// composer controller) per durable session. Lock order stays DataService gate -> recovery store.

package extension Notification.Name {
    /// A tracked delivery-evidence write of a session lane finished. `object`: the
    /// `AgentRecoverySessionLane`; `userInfo`: `sessionID`. A wake-up only: observers re-read the
    /// durable record, which stays the authority.
    static let agentRecoveryDeliveryEvidenceDidSettle = Notification.Name("AgentRecoverySessionLane.deliveryEvidenceDidSettle")
}

// MARK: - Composition errors

package enum AgentRecoveryCompositionError: Error, Equatable {
    /// The DataService validates gates and discovery against a different recovery store.
    case dataServiceStoreMismatch
}

// MARK: - Admission carrier

/// Immutable runtime admission carrier (not persisted). Identities are allocated once at input
/// admission and carried unchanged through preparation, queues, runners, and callbacks. `original`
/// is the user's input before optimistic clearing or provider-text augmentation.
package struct AgentRecoveryAdmission: Equatable {
    package let binding: AgentRecoveryLifecycleBinding
    package let intentID: UUID
    package let userItemID: UUID
    package let origin: AgentRecoveryIntentOrigin
    package let target: AgentRecoveryIntentTarget
    package let original: AgentRecoveryInputContent
    package let scheduleReference: AgentRecoveryScheduleReference?
    /// The pending handoff this input's send prepends, captured (with its fenced payload ID) before
    /// admission and committed with the intent, so the exact prefix is durable before any handoff.
    package let pendingHandoff: AgentRecoveryPendingHandoffSnapshot?
    /// The explicit recovery action whose own payload this is (coordinator-issued, never persisted).
    /// It exempts only this input from that action's hold; every other admission check applies.
    package let actionAuthorization: AgentRecoveryActionAuthorization?

    package init(
        binding: AgentRecoveryLifecycleBinding,
        intentID: UUID = UUID(),
        userItemID: UUID,
        origin: AgentRecoveryIntentOrigin,
        target: AgentRecoveryIntentTarget,
        original: AgentRecoveryInputContent,
        scheduleReference: AgentRecoveryScheduleReference? = nil,
        pendingHandoff: AgentRecoveryPendingHandoffSnapshot? = nil,
        actionAuthorization: AgentRecoveryActionAuthorization? = nil
    ) {
        self.binding = binding
        self.intentID = intentID
        self.userItemID = userItemID
        self.origin = origin
        self.target = target
        self.original = original
        self.scheduleReference = scheduleReference
        self.pendingHandoff = pendingHandoff
        self.actionAuthorization = actionAuthorization
    }

    package var submission: AgentRecoveryIntentSubmission {
        AgentRecoveryIntentSubmission(
            intentID: intentID,
            userItemID: userItemID,
            origin: origin,
            target: target,
            payload: original,
            scheduleReference: scheduleReference,
            pendingHandoff: pendingHandoff
        )
    }
}

// MARK: - Recovery action authorization (review A P1-01)

/// Coordinator-issued authority for one explicit recovery action's own payload. Only
/// `AgentRecoveryCoordinator.beginRecoveryAction` constructs it; it is never persisted or decoded,
/// so it is no authority after a relaunch (the durable action/intent association is the evidence).
/// It names exactly one input: a continuation's planned user item (and the intent its admission
/// issues) or Send saved's single claimed intent, dispatched once. It exempts that input from its
/// own action's hold only; startup, crash holds, R6, shutdown, reset, and attachment checks apply.
package struct AgentRecoveryActionAuthorization: Hashable {
    package let token: UUID
    package let actionID: UUID
    package let sessionID: UUID
    /// A continuation's planned transcript user item.
    package let plannedUserItemID: UUID?
    /// Send saved's claimed saved intent.
    package let sourceIntentID: UUID?

    fileprivate init(token: UUID, actionID: UUID, sessionID: UUID, plannedUserItemID: UUID?, sourceIntentID: UUID?) {
        self.token = token
        self.actionID = actionID
        self.sessionID = sessionID
        self.plannedUserItemID = plannedUserItemID
        self.sourceIntentID = sourceIntentID
    }
}

/// How a recovery action's submission settled: the only evidence that releases its hold.
package enum AgentRecoveryActionSettlement: Equatable {
    /// The provider boundary was entered (acceptance is not awaited) or delivery was recorded.
    case handedOff
    /// Nothing was handed off and nothing can be any more (the authorization is revoked).
    case notHandedOff(String?)
    /// A handoff may have happened but its evidence could not be recorded.
    case uncertain(String)
}

/// Result of acquiring the shared hold for one explicit recovery action.
package enum AgentRecoveryActionHoldAcquisition {
    case acquired(AgentRecoveryActionAuthorization)
    /// An exact repeat of the running action: its performance.
    case joined(Task<AgentRecoveryActionResult, Never>)
    /// Another action holds the session or workspace, or the lane/workspace is not current.
    case refused
}

/// A committed admission: the carrier, its store-issued receipt (never provider acceptance), and
/// the composer revision it consumed, if it came from the composer.
package struct AgentRecoveryAdmitted<Receipt: Equatable & Sendable>: Equatable {
    package let admission: AgentRecoveryAdmission
    package let receipt: Receipt
    package let submittedComposerRevision: AgentRecoveryComposerRevision?
}

/// Why admission was refused before any durable write. Every refusal is fail-closed.
package enum AgentRecoveryAdmissionRefusal: Error, Equatable {
    /// Startup has not completed (or was never started): admission stays closed.
    case startupNotReady
    case startupFailed(String)
    /// The session or its workspace is restricted by startup results (unknown recovery status,
    /// duplicate destinations, an unreadable workspace, or a held schedule transfer).
    case restricted(String)
    /// An uncertain previous-launch attempt for this session awaits explicit confirmation.
    case crashHeld(AgentRecoveryCrashHold)
    case laneRetired
    case bindingMismatch
    /// The composer could not be restored, so its submission has no safe revision.
    case composerUnavailable(AgentRecoveryControllerFailure)
    /// Input without durable admission reached a dispatch while admission is mandatory (or mixed
    /// with durable constituents). Never dispatched as legacy input.
    case untrackedInput
    /// A retired predecessor lane left composer input it could not persist; new admissions wait
    /// for its explicit resolution (`resolveUnsavedPredecessorInput`).
    case unsavedPredecessorInput
    /// A transcript reset is preparing this lane (preserving its composer before the generation
    /// advances); admission reopens if the reset is vetoed, or under the successor lane.
    case resetPreparationInProgress
    /// App quit or this window's close is preserving state (two-stage shutdown). Reopens if the
    /// user cancels Stage A; never reopens once teardown began.
    case shutdownInProgress
    /// An explicit recovery action holds this session or its workspace (review A P1-01), or the
    /// input carries an action authorization that is no longer current. Only the holding action's
    /// own exact payload passes.
    case recoveryActionInProgress
}

/// Owners frozen by one shutdown request: every lane (app quit) or the lanes of specific owners
/// (window close). See `AgentRecoveryCoordinator.beginShutdownFreeze`.
package enum AgentRecoveryShutdownScope: Equatable {
    case application
    case owners(Set<ObjectIdentifier>)

    package func contains(_ ownerID: ObjectIdentifier) -> Bool {
        switch self {
        case .application: true
        case let .owners(owners): owners.contains(ownerID)
        }
    }
}

/// Why a lane's shutdown preparation (Stage A) could not prove its state durable. The lane, its
/// live input, and admission are left untouched apart from the caller-owned freeze.
package enum AgentRecoveryShutdownPreparationFailure: Error, Equatable {
    /// Composer preservation failed (same cases as reset preparation).
    case composer(AgentRecoveryResetPreparationFailure)
    /// Pending-question snapshots or run shutdown evidence could not be written.
    case evidenceNotPersisted(AgentRecoveryControllerFailure)
}

/// Why a transcript reset was vetoed before the generation advanced. The old lane and its live
/// input are left untouched; nothing was carried into, or written under, a new generation.
package enum AgentRecoveryResetPreparationFailure: Error, Equatable {
    case laneRetired
    case alreadyPreparing
    /// The latest composer could not be written under the current generation (or its baseline
    /// could not be learned); the controller's failure when known.
    case composerNotPersisted(AgentRecoveryControllerFailure?)
    /// The live composer holds content not yet representable durably (for example an image
    /// awaiting promotion into managed storage).
    case unrepresentableComposerInput
    /// A retired predecessor's input is retained only in memory and awaits explicit resolution.
    case unsavedPredecessorInput
    /// The composer kept changing while it was being preserved; retry the reset.
    case composerChangedDuringPreparation
}

/// Why composer input that had no lane yet (first draft of a new tab, or content awaiting image
/// promotion) could not be handed to a lane. The obligation and its payload stay visible.
package enum AgentRecoveryComposerPreparationFailure: Error, Equatable {
    /// Durable session authority could not be established (creation refused, conflict, no context).
    case authorityUnavailable(String)
    /// The owner was replaced or rebound while preparing; nothing is written into the replacement.
    case ownerReplaced
    /// An attached image could not be imported into managed recovery storage. The live attachment
    /// is kept.
    case imagePromotionFailed(String)
}

/// Composer input owed to disk that cannot be forwarded to a lane yet. Holds the earliest first
/// unsaved instant on the coordinator's absolute clock; forwarding passes it on so preparation
/// (authority creation, image promotion, restore) never restarts the 2-second bound. One
/// preparation task per owner; later mutations coalesce into the same obligation.
@MainActor
package final class AgentRecoveryComposerPreparation {
    package let firstUnsavedAt: ContinuousClock.Instant
    /// Latest representable content (`nil` while it still references unpromoted images).
    package fileprivate(set) var latestContent: AgentRecoveryInputContent?
    package fileprivate(set) var failure: AgentRecoveryComposerPreparationFailure?
    fileprivate var task: Task<Void, Never>?
    fileprivate weak var owner: AnyObject?

    fileprivate init(owner: AnyObject, firstUnsavedAt: ContinuousClock.Instant) {
        self.owner = owner
        self.firstUnsavedAt = firstUnsavedAt
    }

    package var isPreparing: Bool {
        task != nil
    }

    /// The task running the single preparation (test observability and joins).
    package var preparationTask: Task<Void, Never>? {
        task
    }
}

/// Unsaved composer input of a released lane whose owner went away (see
/// `AgentRecoveryCoordinator.ownerlessUnsavedInputs`), oldest first.
package struct AgentRecoveryOwnerlessUnsavedInput: Equatable {
    package let workspaceID: UUID
    package fileprivate(set) var inputs: [AgentRecoveryUnsavedComposerInput]
}

/// Live composer input a retired lane genuinely could not persist under its own authority: its
/// final preservation write failed or was rejected (storage, held composer, lifecycle), its
/// durable baseline could not be learned, or it was still pending when its lifecycle binding
/// changed without reset preparation. A healthy same-binding hand-over writes the input and yields
/// none. Never written with the retired authority afterward, never carried into a new generation
/// implicitly, and never silently dropped: the successor lane keeps it visible until the user
/// resolves it.
package struct AgentRecoveryUnsavedComposerInput: Equatable {
    /// Binding the input was typed under (the retired lane's).
    package let binding: AgentRecoveryLifecycleBinding
    package let content: AgentRecoveryInputContent
    /// The retired controller's final write failure, if its flush failed.
    package let failure: AgentRecoveryControllerFailure?
    /// R02: this is the visible copy of a restored draft whose rollback is still owed. The durable
    /// copy stays protected by every owner (a same-binding successor adopts the obligation) until the
    /// rollback or an explicit, durably written resolution commits.
    package var restoreRollback: AgentRecoveryRestoreRollbackObligation?
}

package enum AgentRecoveryAdmissionFailure: Error, Equatable {
    case refused(AgentRecoveryAdmissionRefusal)
    /// The durable commit failed; nothing was admitted and no handoff may happen.
    case commitFailed(AgentRecoveryControllerFailure)
    /// Committed durably, but the lane was retired during the await. The intent is preserved as
    /// held input (stale target) and must not be projected or dispatched by this caller.
    case staleAfterCommit(intentID: UUID, staleMarkPersisted: Bool)
    /// A delivery attempt committed, but the lane was retired or frozen by reset preparation during
    /// the await: nothing may be handed off. `settledToQueue` says whether the attempts were settled
    /// back to `queued` as pre-handoff (otherwise they stay `dispatching`, never retried silently).
    case dispatchStaleAfterCommit(settledToQueue: Bool)

    /// User-facing text for a dispatch that could not be committed (or went stale) before handoff.
    package var dispatchFailureText: String {
        switch self {
        case .refused(.untrackedInput):
            "This message was not sent because it was not saved for recovery first."
        case .refused(.recoveryActionInProgress):
            "This message was not sent because a recovery choice in this workspace is in progress. It stays saved."
        case .refused:
            "This message was not sent because its recovery state is not ready. It stays saved."
        case .commitFailed:
            // Same user text as the runners' run-attempt failures; `diagnosticReason` tells them apart.
            Self.deliveryNotRecordedText()
        case .staleAfterCommit, .dispatchStaleAfterCommit:
            "This message was not sent because the session changed. It stays saved."
        }
    }

    /// Fixed, content-free reason for logs and diagnostics (several cases share user text).
    package var diagnosticReason: String {
        switch self {
        case .refused:
            "dispatch_refused"
        case .commitFailed:
            "dispatch_commit_failed"
        case .staleAfterCommit:
            "admission_stale_after_commit"
        case .dispatchStaleAfterCommit:
            "dispatch_stale_after_commit"
        }
    }
}

/// A deferred run-start handoff's state for one durable intent (`AgentRecoverySessionLane`).
package enum AgentDeferredRunStartHandoffState: Equatable {
    /// Prepared: its runner owes the dispatch commit or a no-handoff settlement.
    case pending
    /// Settled before any dispatch commit; the handoff's own message, when it gave one.
    case notHandedOff(message: String?)
}

/// Submission captured synchronously at the moment the user sends from the composer. Its revision
/// is issued immediately when the composer is restored, or right after restore completes (before
/// any typing that followed), so later typing never becomes consumable by this submission.
@MainActor
package final class AgentRecoveryComposerSubmissionToken {
    package let content: AgentRecoveryInputContent
    package fileprivate(set) var revision: AgentRecoveryComposerRevision?

    fileprivate init(content: AgentRecoveryInputContent) {
        self.content = content
    }
}

// MARK: - Startup

/// Per-session crash hold: previous-launch run attempts or deliveries left open, bound to the
/// validated lifecycle (incarnation and reset generation) and those exact identities. A shutdown
/// reason does not close an open run. Legacy open turns without a run attempt contribute their own
/// transcript turn identity (no run identity is invented). Confirmation is a durable, exact
/// acknowledgement (`AgentRecoveryCrashHoldAcknowledgement`, F-2): it lifts only this hold, a later
/// launch with the identical uncertainty does not ask again, and it is never a retry of
/// `deliveryUnknown` input or a run outcome.
package struct AgentRecoveryCrashHold: Equatable {
    package let sessionID: UUID
    package let incarnationID: UUID
    package let transcriptResetGeneration: UInt64
    package let uncertainRunAttemptIDs: Set<UUID>
    package let uncertainIntentIDs: Set<UUID>
    package let uncertainTranscriptTurnIDs: Set<UUID>
    /// Whether the previous launch wrote a clean-exit mark. Per-attempt open evidence still holds.
    package let previousExitProvenClean: Bool

    package init(
        sessionID: UUID,
        incarnationID: UUID,
        transcriptResetGeneration: UInt64,
        uncertainRunAttemptIDs: Set<UUID>,
        uncertainIntentIDs: Set<UUID>,
        uncertainTranscriptTurnIDs: Set<UUID> = [],
        previousExitProvenClean: Bool
    ) {
        self.sessionID = sessionID
        self.incarnationID = incarnationID
        self.transcriptResetGeneration = transcriptResetGeneration
        self.uncertainRunAttemptIDs = uncertainRunAttemptIDs
        self.uncertainIntentIDs = uncertainIntentIDs
        self.uncertainTranscriptTurnIDs = uncertainTranscriptTurnIDs
        self.previousExitProvenClean = previousExitProvenClean
    }

    /// Whether `acknowledgement` acknowledged exactly this hold.
    package func isCovered(by acknowledgement: AgentRecoveryCrashHoldAcknowledgement?) -> Bool {
        acknowledgement?.covers(
            incarnationID: incarnationID,
            transcriptResetGeneration: transcriptResetGeneration,
            runAttemptIDs: uncertainRunAttemptIDs,
            intentIDs: uncertainIntentIDs,
            transcriptTurnIDs: uncertainTranscriptTurnIDs
        ) == true
    }
}

package struct AgentRecoveryStartupReport: Equatable {
    package let previousLaunch: AgentRecoveryPreviousLaunch
    package let currentLaunch: AgentRecoveryLaunchMark
    /// Raw inventory. Not lifecycle authorization: lanes validate through the DataService gate, and
    /// a tombstoned session never acquires a lane, so its record never restores.
    package let discovered: [AgentRecoveryDiscoveryEntry]
    /// Authoritative reconciliation results (empty in the report handed to `Reconcile`).
    package let reconciliation: AgentRecoveryStartupReconciliation
    /// Derived from `reconciliation`, never from raw discovery (empty in the report handed to
    /// `Reconcile`).
    package let crashHolds: [UUID: AgentRecoveryCrashHold]

    package init(
        previousLaunch: AgentRecoveryPreviousLaunch,
        currentLaunch: AgentRecoveryLaunchMark,
        discovered: [AgentRecoveryDiscoveryEntry],
        reconciliation: AgentRecoveryStartupReconciliation = .empty,
        crashHolds: [UUID: AgentRecoveryCrashHold] = [:]
    ) {
        self.previousLaunch = previousLaunch
        self.currentLaunch = currentLaunch
        self.discovered = discovered
        self.reconciliation = reconciliation
        self.crashHolds = crashHolds
    }
}

package extension Notification.Name {
    /// The recovery coordinator's startup state, results, restrictions, or crash holds changed.
    /// `object`: the `AgentRecoveryCoordinator`. A wake-up only; observers re-read the coordinator.
    static let agentRecoveryCoordinatorDidChange = Notification.Name("AgentRecoveryCoordinator.didChange")
    /// Records were committed (written or removed) after composition. `object`: the coordinator;
    /// `userInfo["sessionIDs"]`: `Set<UUID>`. Coalesced; observers re-read `liveRecordState(for:)`.
    /// Distinct from `agentRecoveryCoordinatorDidChange`: startup results, holds, and restrictions
    /// are unchanged by an ordinary write.
    static let agentRecoveryRecordsDidChange = Notification.Name("AgentRecoveryCoordinator.recordsDidChange")
    /// The recovery catalog may have changed (any recovery, lane, composer, question, or schedule
    /// confirmation state, or a catalog action state). `object`: the coordinator. Coalesced; a
    /// wake-up only: observers re-read `catalog` and `catalogActionStates`.
    static let agentRecoveryCatalogDidChange = Notification.Name("AgentRecoveryCoordinator.catalogDidChange")
    /// Composer recovery state that needs a visible user decision or error changed (held composer,
    /// unsaved predecessor input, held intents, composer write or preparation failure). `object`: the
    /// coordinator; `userInfo["sessionID"]` when a lane is known. A wake-up only.
    static let agentRecoveryComposerStateDidChange = Notification.Name("AgentRecoveryCoordinator.composerStateDidChange")
}

package enum AgentRecoveryStartupState: Equatable {
    case notStarted
    case loading
    case ready
    case failed(String)
}

// MARK: - Coordinator

@MainActor
package final class AgentRecoveryCoordinator {
    /// Startup reconciliation (inventory, intent/transcript joins, schedule receipt transfer) run
    /// after discovery and before admission opens; returns the authoritative per-session results
    /// that holds and restrictions are built from. Throws when the global scope cannot be
    /// established (startup stays closed). Must never await this coordinator's startup or a
    /// scheduler barrier. Required: there is no permissive default.
    package typealias Reconcile = @MainActor (AgentRecoveryStartupReport) async throws -> AgentRecoveryStartupReconciliation
    package typealias ComposerControllerFactory = @MainActor (
        AgentRecoveryStore,
        any AgentRecoveryLifecycleGate
    ) -> AgentRecoveryComposerPersistenceController

    package let store: AgentRecoveryStore
    package let dataService: AgentSessionDataService
    private let reconcile: Reconcile
    private let makeComposerController: ComposerControllerFactory
    /// Absolute monotonic clock seam shared with composer controllers (first-unsaved instants).
    private let clockNow: () -> ContinuousClock.Instant
    /// Owner-scoped composer obligations awaiting a lane (see `AgentRecoveryComposerPreparation`).
    private var composerPreparations: [ObjectIdentifier: AgentRecoveryComposerPreparation] = [:]

    package private(set) var startupState: AgentRecoveryStartupState = .notStarted
    package private(set) var startupReport: AgentRecoveryStartupReport?
    /// Read once, before this launch's mark replaces it; retained across startup retries.
    private var capturedPreviousLaunch: AgentRecoveryPreviousLaunch?
    private var startupTask: Task<Void, Never>?
    private var crashHolds: [UUID: AgentRecoveryCrashHold] = [:]
    private var confirmedCrashHolds: [UUID: AgentRecoveryCrashHold] = [:]
    /// Authoritative startup results (closed sessions included); `.empty` until ready.
    package private(set) var reconciliation: AgentRecoveryStartupReconciliation = .empty
    /// App-scoped restrictions shared by recovery admission and scheduling.
    package private(set) var restrictions: AgentRecoveryRestrictions = .none
    private var lanes: [UUID: AgentRecoverySessionLane] = [:]
    /// Workspace of each session's latest lane claim this launch (kept after release, so items of a
    /// closed session can still be opened in their workspace).
    private var laneWorkspaceIDs: [UUID: UUID] = [:]
    /// Compose tab of each session's latest lane claim this launch, kept alongside its workspace so
    /// Open on a closed session's item targets its tab identity (review R1, A P2).
    private var laneComposeTabIDs: [UUID: UUID] = [:]
    /// Retirements of released lanes not yet inherited by a new lane for the same session.
    private var releasedRetirements: [UUID: AgentRecoverySessionLane.Retirement] = [:]
    /// Latest committed record state per session published by the store since composition (live
    /// overlay of the startup snapshot; `reconciliation` itself is never re-run per write).
    private var liveRecordCommits: [UUID: AgentRecoveryRecordCommit] = [:]
    /// Sessions whose deletion committed (tombstone) since composition. A tombstone retires its
    /// session for good, so nothing of it is listed or held again; the next launch's reconciliation
    /// classifies it `.tombstoned` (F8).
    package private(set) var deletedSessionIDs: Set<UUID> = []
    private var deletionObserver: (any NSObjectProtocol)?
    private var pendingRecordChangeSessionIDs: Set<UUID> = []
    private var recordChangePostScheduled = false
    private struct HeldIntentNotes {
        let incarnationID: UUID
        let workspaceID: UUID
        var reasons: [UUID: String]
    }

    /// App-scoped held-intent presentation (this launch), per session and incarnation.
    private var heldIntentNotes: [UUID: HeldIntentNotes] = [:]
    /// See `ownerlessUnsavedInputs`.
    private var releasedUnsavedInputs: [UUID: AgentRecoveryOwnerlessUnsavedInput] = [:]
    /// Active shutdown freezes by token (see `beginShutdownFreeze`).
    private var shutdownFreezes: [UUID: AgentRecoveryShutdownScope] = [:]
    /// Explicit recovery actions in flight, by hold token (review A P1-01). App-scoped, so every
    /// window's dispatch seams and scheduler projections see the same holds.
    private var recoveryActionHolds: [UUID: RecoveryActionHold] = [:]
    /// Cached catalog snapshot; `nil` once anything it projects changed.
    private var cachedCatalog: AgentRecoveryCatalog?
    private var catalogGeneration: UInt64 = 0
    private var catalogChangePostScheduled = false
    /// The shared scheduler: its summaries cover schedules of sessions some window hosts.
    private weak var attachedScheduler: AgentScheduledSendCoordinator?
    private var scheduleConfirmationObserver: (any NSObjectProtocol)?
    /// Sessions a window hydrated: their owner (through the scheduler), never the index, is
    /// authoritative for their schedule.
    private var hydratedScheduleSessionIDs: @MainActor () -> Set<UUID> = { [] }
    /// Every workspace whose metadata index the catalog reads for schedules no window hosts (`nil`
    /// result: the inventory could not be read; the last read is kept).
    private var scheduleIndexWorkspaces: (@MainActor () async -> [AgentRecoveryWorkspaceDestination]?)?
    /// The latest index read (see `requestIndexedScheduleRefresh`).
    private var indexedSchedules = AgentRecoveryIndexedSchedules.empty
    private var indexedScheduleRefreshTask: Task<Void, Never>?
    private var indexedScheduleRefreshPending = false
    /// Shared, app-wide action state per catalog item (every surface shows the same progress or
    /// error). An item disappears only when its backing state changes, never by a local mark.
    package private(set) var catalogActionStates: [String: AgentRecoveryCatalogActionState] = [:]
    /// 9-live R4b/R5 (review B L2): the Continue editor's text per catalog row ID, written on every
    /// edit so it survives the editor, its row view, or its window closing. App-wide like
    /// `catalogActionStates` (any window's banner or sheet reopens with it), in memory only, and
    /// not observed: the editor reads it when it opens. The window removes an entry once the
    /// record holds the text (or the text moved to the message box), never on a refusal.
    package var continuationDraftsByRowID: [String: String] = [:]
    /// Step 8-attention-2: the app-wide bulk Dismiss (one at a time; transient, never persisted).
    /// The running one, or the last finished one's summary until the next starts
    /// (`AgentRecoveryCoordinator+BulkDismiss.swift`).
    package internal(set) var bulkDismiss: AgentRecoveryBulkDismissStatus?
    /// Step 9-check: the app-wide Check and resolve (one at a time; transient, never persisted).
    /// The running one, or the last finished one's report (`AgentRecoveryCoordinator+Check.swift`).
    package internal(set) var recoveryCheck: AgentRecoveryCheckStatus?
    /// The running check's wait on its current item, which Stop ends early (Step 9-activation).
    var recoveryCheckItemWait: AgentRecoveryCheckItemWait?
    #if DEBUG
        /// Runs after an item's wait is installed and its work queued, before Check waits on it
        /// (lets a test press Stop before the item's work has started).
        package var test_recoveryCheckItemQueued: (@MainActor () -> Void)?
        /// Runs before each commit attempt of a registry-proven crash-hold confirmation, before its
        /// last re-check (lets a test press Stop or change the card at that point).
        package var test_crashHoldProofBeforeCommit: (@MainActor () async -> Void)?
        /// Runs after the last re-check, immediately before the acknowledgement write (lets a test
        /// commit a Dismiss or press Stop once nothing re-checks any more).
        package var test_crashHoldProofAtCommit: (@MainActor () async -> Void)?
    #endif
    /// Serial tail of launch-mark writes (`shutdownInProgress`, `cleanExit`, corrections).
    private var launchMarkTail: Task<Void, Never>?
    /// Spec R6 runtime ownership (see `AgentRecoveryCoordinator+RuntimeOwnership.swift`). `nil`
    /// leaves runtime restrictions empty (XCTest compositions without a registry).
    var processRegistry: AgentProcessRegistry?
    /// The registry's latest restriction snapshot, published before readiness and on every change.
    package internal(set) var runtimeRestrictions: AgentRuntimeRestrictionSnapshot = .empty
    /// What a durable session would touch (its native conversations and worktree), from the windows
    /// hosting it; empty for a session no window hosts.
    var runtimeOwnershipKeys: @MainActor (UUID) -> [AgentRuntimeOwnershipKeys] = { _ in [] }
    /// Latest issued snapshot pull; an older pull's result is never adopted over a newer one.
    var runtimeSnapshotRequest: UInt64 = 0
    /// The request whose snapshot `runtimeRestrictions` was last adopted from (never decreases).
    var runtimeSnapshotAdopted: UInt64 = 0

    package init(
        store: AgentRecoveryStore,
        dataService: AgentSessionDataService,
        reconcile: @escaping Reconcile,
        makeComposerController: @escaping ComposerControllerFactory = { store, gate in
            AgentRecoveryComposerPersistenceController(store: store, gate: gate)
        },
        clockNow: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) throws {
        guard dataService.usesRecoveryStore(store) else {
            throw AgentRecoveryCompositionError.dataServiceStoreMismatch
        }
        self.store = store
        self.dataService = dataService
        self.reconcile = reconcile
        self.makeComposerController = makeComposerController
        self.clockNow = clockNow
        store.commitPublisher.setHandler { [weak self] commit in
            Task { @MainActor [weak self] in
                self?.adoptRecordCommit(commit)
            }
        }
        // Posted by `AgentSessionDataService` once per tombstone commit, before the session file and
        // record are removed. A record that was absent or unreadable publishes no record commit, so
        // the tombstone is the deletion signal.
        deletionObserver = NotificationCenter.default.addObserver(
            forName: .agentSessionDeletionDidCommit,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let sessionID = notification.userInfo?["sessionID"] as? UUID else { return }
            MainActor.assumeIsolated {
                self?.noteSessionDeleted(sessionID)
            }
        }
    }

    deinit {
        if let deletionObserver {
            NotificationCenter.default.removeObserver(deletionObserver)
        }
    }

    // MARK: Live records

    /// The latest record state committed for `sessionID` since composition, or `nil` when the store
    /// has not written or removed it since (the startup snapshot is then current).
    package func liveRecordState(for sessionID: UUID) -> AgentRecoveryRecordCommit.State? {
        liveRecordCommits[sessionID]?.state
    }

    /// Sessions with a record committed since composition.
    package var liveRecordSessionIDs: Set<UUID> {
        Set(liveRecordCommits.keys)
    }

    /// Every live (unretired) lane.
    package var liveLanes: [AgentRecoverySessionLane] {
        lanes.values.filter { !$0.isRetired }
    }

    /// F8: a committed deletion takes the session's items out of the catalog (every window and the
    /// badge) and drops its startup crash hold and session restriction, which would otherwise keep
    /// pausing its workspace's other sessions until the next launch. Its held-intent notes, ownerless
    /// unsaved input and released lane retirement go too: that input can never be saved or restored
    /// again, and quit (`settleReleasedRetirements`) must not refuse over a row the catalog no longer
    /// shows. A retirement still running then finds itself untracked and publishes nothing.
    /// Idempotent.
    package func noteSessionDeleted(_ sessionID: UUID) {
        guard deletedSessionIDs.insert(sessionID).inserted else { return }
        retireStartupState(ofDeletedSessions: [sessionID])
        releasedRetirements[sessionID] = nil
        let hadNotes = heldIntentNotes.removeValue(forKey: sessionID) != nil
        let hadUnsaved = releasedUnsavedInputs.removeValue(forKey: sessionID) != nil
        if hadNotes || hadUnsaved { composerStateDidChange(sessionID: sessionID) }
        postCoordinatorDidChange()
    }

    private func retireStartupState(ofDeletedSessions sessionIDs: Set<UUID>) {
        for sessionID in sessionIDs {
            crashHolds[sessionID] = nil
            confirmedCrashHolds[sessionID] = nil
            restrictions.lift(sessionID: sessionID)
        }
    }

    private func adoptRecordCommit(_ commit: AgentRecoveryRecordCommit) {
        if let existing = liveRecordCommits[commit.sessionID], existing.sequence >= commit.sequence {
            return
        }
        liveRecordCommits[commit.sessionID] = commit
        invalidateCatalog()
        // Schema-8 index hint: recomposed from the committed record facts (rewritten only on change).
        let facts: AgentSessionRecoveryHint.RecordFacts = switch commit.state {
        case let .supported(record): .make(from: record)
        case .absent: .absent
        }
        let dataService = dataService
        Task {
            await dataService.noteRecoveryRecordCommitted(sessionID: commit.sessionID, sequence: commit.sequence, facts: facts)
        }
        pruneHeldPresentation(for: commit)
        if case let .supported(record) = commit.state {
            presentUncertainInputOfEndedRuns(in: record)
        }
        pendingRecordChangeSessionIDs.insert(commit.sessionID)
        guard !recordChangePostScheduled else { return }
        recordChangePostScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            recordChangePostScheduled = false
            let sessionIDs = pendingRecordChangeSessionIDs
            pendingRecordChangeSessionIDs = []
            NotificationCenter.default.post(
                name: .agentRecoveryRecordsDidChange,
                object: self,
                userInfo: ["sessionIDs": sessionIDs]
            )
        }
    }

    // MARK: Catalog

    /// The current app-wide recovery catalog (cached until anything it projects changes).
    package var catalog: AgentRecoveryCatalog {
        if let cachedCatalog { return cachedCatalog }
        catalogGeneration &+= 1
        let built = AgentRecoveryCatalogProjection.build(
            coordinator: self,
            schedules: mergedScheduleConfirmations(),
            unavailableScheduleIndexes: indexedSchedules.unavailableWorkspaces,
            generation: catalogGeneration
        )
        cachedCatalog = built
        return built
    }

    /// Feeds the catalog schedules awaiting explicit confirmation from two read-only sources and
    /// re-projects it whenever the scheduler's dashboard changes (replacing an earlier source):
    /// - the shared scheduler's summaries, for sessions a window hosts (hydrated or open tab);
    /// - every workspace's metadata index (`indexWorkspaces`), for sessions no window hosts, closed
    ///   workspaces included. A hosted or hydrated session's index entry never adds a second item.
    /// Neither source confirms, sends, or changes scheduler policy.
    package func attachScheduler(
        _ scheduler: AgentScheduledSendCoordinator,
        hydratedSessionIDs: @escaping @MainActor () -> Set<UUID> = { [] },
        indexWorkspaces: (@MainActor () async -> [AgentRecoveryWorkspaceDestination]?)? = nil
    ) {
        if let scheduleConfirmationObserver {
            NotificationCenter.default.removeObserver(scheduleConfirmationObserver)
        }
        attachedScheduler = scheduler
        hydratedScheduleSessionIDs = hydratedSessionIDs
        scheduleIndexWorkspaces = indexWorkspaces
        scheduleConfirmationObserver = NotificationCenter.default.addObserver(
            forName: .agentScheduledSendDashboardDidChange,
            object: scheduler,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateCatalog()
                self?.requestIndexedScheduleRefresh()
            }
        }
        invalidateCatalog()
        requestIndexedScheduleRefresh()
    }

    /// One item per schedule identity: the scheduler's summaries first, then index summaries of
    /// sessions neither the scheduler nor a hydrated window covers. A schedule whose exact attempt is
    /// held for transfer is presented by the transfer item instead.
    private func mergedScheduleConfirmations() -> [AgentScheduledSendConfirmationSummary] {
        let live = attachedScheduler?.confirmationSummaries() ?? []
        let liveScheduleIDs = Set(live.map(\.scheduleID))
        let liveSessionIDs = Set(live.map(\.sessionID))
        let hydrated = hydratedScheduleSessionIDs()
        let indexed = indexedSchedules.summaries.filter { summary in
            !liveScheduleIDs.contains(summary.scheduleID)
                && !liveSessionIDs.contains(summary.sessionID)
                && !hydrated.contains(summary.sessionID)
        }
        return (live + indexed)
            .filter { attachedScheduler?.transferHold(scheduleID: $0.scheduleID) == nil }
            .sorted { ($0.notBefore, $0.scheduleID.uuidString) < ($1.notBefore, $1.scheduleID.uuidString) }
    }

    /// Re-reads every workspace's index for schedules awaiting confirmation (coalesced: at most one
    /// read runs, and a request during it runs one more). Never hydrates, rebuilds, or writes.
    package func requestIndexedScheduleRefresh() {
        guard scheduleIndexWorkspaces != nil else { return }
        guard indexedScheduleRefreshTask == nil else {
            indexedScheduleRefreshPending = true
            return
        }
        indexedScheduleRefreshTask = Task { @MainActor [weak self] in
            await self?.runIndexedScheduleRefresh()
        }
    }

    /// Test observability: the running index read, if any.
    package var indexedScheduleRefresh: Task<Void, Never>? {
        indexedScheduleRefreshTask
    }

    private func runIndexedScheduleRefresh() async {
        defer { indexedScheduleRefreshTask = nil }
        repeat {
            indexedScheduleRefreshPending = false
            guard startupState == .ready, let source = scheduleIndexWorkspaces else { return }
            guard let workspaces = await source() else { continue }
            let read = await Self.readIndexedSchedules(workspaces: workspaces, dataService: dataService)
            if read != indexedSchedules {
                indexedSchedules = read
                invalidateCatalog()
            }
        } while indexedScheduleRefreshPending
    }

    private static func readIndexedSchedules(
        workspaces: [AgentRecoveryWorkspaceDestination],
        dataService: AgentSessionDataService
    ) async -> AgentRecoveryIndexedSchedules {
        var summaries: [AgentScheduledSendConfirmationSummary] = []
        var unavailable: [AgentRecoveryWorkspaceDestination] = []
        for workspace in workspaces {
            guard let records = await dataService.recoveryIndexedSessionRecords(for: workspace) else {
                unavailable.append(workspace)
                continue
            }
            for record in records {
                guard let summary = record.scheduledSendSummary, !summary.isUnreadable,
                      summary.stateRaw == AgentScheduledSendPersist.State.needsConfirmation.rawValue,
                      let scheduleID = summary.id, let notBefore = summary.notBefore
                else { continue }
                summaries.append(AgentScheduledSendConfirmationSummary(
                    sessionID: record.id,
                    tabID: record.composeTabID,
                    workspaceID: workspace.id,
                    scheduleID: scheduleID,
                    attemptID: summary.attemptID,
                    reason: summary.confirmationReasonRaw.flatMap(AgentScheduledSendPersist.ConfirmationReason.init(rawValue:)),
                    notBefore: notBefore,
                    previewText: summary.previewText,
                    sessionName: record.name,
                    requiresOpenBeforeDismiss: summary.attemptID == nil
                ))
            }
        }
        return AgentRecoveryIndexedSchedules(summaries: summaries, unavailableWorkspaces: unavailable)
    }

    /// Marks the catalog stale and posts one coalesced `agentRecoveryCatalogDidChange`.
    package func invalidateCatalog() {
        cachedCatalog = nil
        postCatalogChange()
    }

    /// Startup results, holds, restrictions (runtime ownership included), or freezes changed.
    func postCoordinatorDidChange() {
        invalidateCatalog()
        NotificationCenter.default.post(name: .agentRecoveryCoordinatorDidChange, object: self)
    }

    /// Sets (or clears, with `nil`) the shared action state of one catalog item.
    package func setCatalogActionState(_ state: AgentRecoveryCatalogActionState?, for itemID: String) {
        guard catalogActionStates[itemID] != state else { return }
        catalogActionStates[itemID] = state
        // Action states are not projected into the catalog; only observers are woken.
        postCatalogChange()
    }

    func postCatalogChange() {
        guard !catalogChangePostScheduled else { return }
        catalogChangePostScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            catalogChangePostScheduled = false
            NotificationCenter.default.post(name: .agentRecoveryCatalogDidChange, object: self)
        }
    }

    /// Durable Dismiss of exactly the displayed item in its displayed state (Phase 2 §D). Written
    /// through the session's live lane when its incarnation is live, otherwise under the closed
    /// session's persistence gate after revalidating its durable lifecycle. It changes nothing but
    /// the card acknowledgement: the turn, input, question, draft, schedule, crash hold, and any
    /// restriction stay as they are. A repeated Dismiss of an already-dismissed state succeeds.
    /// Returns a user-facing failure, or `nil` once committed.
    package func dismissCatalogItem(_ item: AgentRecoveryCatalogItem) async -> String? {
        guard let acknowledgement = item.acknowledgement, let sessionID = item.sessionID else {
            return "This item can't be dismissed."
        }
        let changed = "This item changed. Review it again."
        // Revalidated against the current projection: a changed item is never dismissed in its place.
        guard let current = catalog.item(id: item.id), current.acknowledgement?.key == acknowledgement.key,
              current.acknowledgement?.freshness == acknowledgement.freshness
        else { return changed }
        if current.isDismissed { return nil }
        let key = acknowledgement.key
        let freshness = acknowledgement.freshness
        let result: Result<AgentRecoveryLocalReceipt, AgentRecoveryControllerFailure>
        if let lane = lane(for: sessionID), lane.binding.incarnationID == key.incarnationID {
            result = await lane.acknowledgeCard(key: key, freshness: freshness)
        } else if let resolution = reconciliation.resolution(for: sessionID),
                  let binding = resolution.binding, binding.incarnationID == key.incarnationID,
                  let workspace = resolution.workspace
        {
            result = await acknowledgeClosedCard(binding: binding, workspace: workspace, key: key, freshness: freshness)
        } else {
            return "Open this session to dismiss this item."
        }
        switch result {
        case .success:
            return nil
        case .failure(.store(.cardChanged)):
            return changed
        case .failure:
            // Generic wording: store failures can describe local paths.
            return "This item couldn't be dismissed. It is still listed; try again."
        }
    }

    private func acknowledgeClosedCard(
        binding: AgentRecoveryLifecycleBinding,
        workspace: AgentRecoveryWorkspaceDestination,
        key: AgentRecoveryCardKey,
        freshness: AgentRecoveryCardFreshness
    ) async -> Result<AgentRecoveryLocalReceipt, AgentRecoveryControllerFailure> {
        let store = store
        var lastFailure: AgentRecoveryControllerFailure = .store(.storageFailure("no attempt", cause: .other))
        for _ in 0 ..< 3 {
            do {
                return try await .success(dataService.performClosedRecoveryTransaction(binding: binding, workspace: workspace) {
                    try await store.acknowledgeCard(
                        binding: binding,
                        expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                        key: key,
                        freshness: freshness,
                        isCurrent: { AgentRecoveryCatalogProjection.recordStillMatches(key: key, freshness: freshness, record: $0) }
                    )
                })
            } catch let error as AgentRecoveryStoreError {
                lastFailure = .store(error)
                if case .revisionConflict = error { continue }
                return .failure(lastFailure)
            } catch {
                return .failure(.lifecycleRejected(String(describing: error)))
            }
        }
        return .failure(lastFailure)
    }

    /// Posts `agentRecoveryComposerStateDidChange` (lanes and composer preparations).
    fileprivate func composerStateDidChange(sessionID: UUID?) {
        invalidateCatalog()
        NotificationCenter.default.post(
            name: .agentRecoveryComposerStateDidChange,
            object: self,
            userInfo: sessionID.map { ["sessionID": $0] }
        )
    }

    // MARK: Startup barrier

    /// Starts the startup sequence once: previous mark -> current unclean mark -> discovery ->
    /// reconciliation -> crash holds -> ready. Admission is closed until it reports `ready`.
    package func startIfNeeded() {
        guard startupState == .notStarted else { return }
        runStartup()
    }

    /// Re-runs startup after a failure. Files are never modified by a failed startup.
    package func retryStartup() {
        guard case .failed = startupState else { return }
        runStartup()
    }

    /// Waits for an in-flight startup and returns the settled state (`notStarted` stays closed).
    package func awaitStartup() async -> AgentRecoveryStartupState {
        while startupState == .loading, let task = startupTask {
            await task.value
        }
        return startupState
    }

    private func runStartup() {
        startupState = .loading
        startupTask = Task { [weak self] in
            await self?.performStartup()
        }
    }

    private func performStartup() async {
        do {
            let previous: AgentRecoveryPreviousLaunch
            if let capturedPreviousLaunch {
                previous = capturedPreviousLaunch
            } else {
                previous = await store.readLaunchMark()
                capturedPreviousLaunch = previous
            }
            // R6: existing runtime records are enforced before admission opens (never skipped when
            // new registration is inactive); ownership failures become scoped or global restrictions.
            await startRuntimeOwnership()
            // R5: cold loads stamp from the captured previous launch, not this launch's mark.
            await dataService.adoptColdRestoreLaunchEvidence(previous)
            let current = try await store.recordCurrentLaunchRunning()
            let entries = try await store.discoverRecords()
            // Schema-8 hints: from now on a session without a discovered record is known clear.
            await dataService.adoptRecoveryHintInventory(entries)
            let results = try await reconcile(AgentRecoveryStartupReport(
                previousLaunch: previous,
                currentLaunch: current,
                discovered: entries
            ))
            let holds = Self.deriveCrashHolds(
                from: results,
                currentInstanceID: store.appInstanceID,
                previousExitProvenClean: previous.provesCleanExit(currentInstanceID: store.appInstanceID)
            )
            // Results, holds, and restrictions are published before readiness. A hold the user
            // already acknowledged exactly (durably, F-2) does not ask again.
            reconciliation = results
            crashHolds = holds
            confirmedCrashHolds = holds.filter { sessionID, hold in
                confirmedCrashHolds[sessionID] == hold
                    || hold.isCovered(by: results.resolution(for: sessionID)?.record?.record.crashHoldAcknowledgement)
            }
            restrictions = AgentRecoveryRestrictions.from(results)
            // A deletion that committed while this startup was reading stays retired.
            retireStartupState(ofDeletedSessions: deletedSessionIDs)
            startupReport = AgentRecoveryStartupReport(
                previousLaunch: previous,
                currentLaunch: current,
                discovered: entries,
                reconciliation: results,
                crashHolds: holds
            )
            startupState = .ready
        } catch {
            // F6: plain wording reaches the banner, scheduler, and refusals; the raw error is logged.
            AgentRecoveryFailureDiagnostics.startupFailed(error)
            startupState = .failed(AgentRecoveryStorageFailureCause.startupFailureDescription(error))
        }
        postCoordinatorDidChange()
        requestIndexedScheduleRefresh()
    }

    /// Crash holds from authoritative results only (actionable sessions whose record matched the
    /// validated lifecycle; tombstoned or mismatched records hold nothing for another incarnation).
    /// Open evidence at startup belongs to an earlier launch (no admission has opened yet):
    /// - run attempts without terminal evidence (a shutdown reason does not close a run);
    /// - earlier-instance `dispatching` or `deliveryUnknown` intents, with or without a run attempt
    ///   (terminal run evidence settles completion, not independently unknown delivery);
    /// - interrupted last turns without a run attempt (legacy), by their own turn identity.
    /// A session executing on an authoritative remote host (persisted execution binding, F-3) holds
    /// nothing locally: no local process ran it. Its uncertain input stays visible as remote
    /// uncertainty and is never auto-retried.
    package static func deriveCrashHolds(
        from reconciliation: AgentRecoveryStartupReconciliation,
        currentInstanceID: UUID,
        previousExitProvenClean: Bool
    ) -> [UUID: AgentRecoveryCrashHold] {
        var holds: [UUID: AgentRecoveryCrashHold] = [:]
        for resolution in reconciliation.sessions {
            guard resolution.classification == .actionable, let binding = resolution.binding,
                  resolution.remoteHostID == nil
            else { continue }
            let record = resolution.record?.record
            let openRuns = Set((record?.runAttempts ?? []).filter { $0.terminal == nil }.map(\.runAttemptID))
            let uncertainIntents = Set((record?.intents ?? []).filter {
                ($0.deliveryState == .dispatching || $0.deliveryState == .deliveryUnknown)
                    && $0.appInstanceID != currentInstanceID
            }.map(\.intentID))
            let legacyTurns = resolution.unresolvedLegacyInterruptedTurnIDs
            guard !openRuns.isEmpty || !uncertainIntents.isEmpty || !legacyTurns.isEmpty else { continue }
            holds[resolution.sessionID] = AgentRecoveryCrashHold(
                sessionID: resolution.sessionID,
                incarnationID: binding.incarnationID,
                transcriptResetGeneration: binding.transcriptResetGeneration,
                uncertainRunAttemptIDs: openRuns,
                uncertainIntentIDs: uncertainIntents,
                uncertainTranscriptTurnIDs: legacyTurns,
                previousExitProvenClean: previousExitProvenClean
            )
        }
        return holds
    }

    // MARK: Shutdown freeze (two-stage quit / window close)

    /// Synchronously closes admission, dispatch commits, handoff, and composer submission for
    /// `scope` (call before the first await of a shutdown request). Returns the token that ends it.
    /// Freezes are independent: an owner stays frozen while any covering token is active.
    @discardableResult
    package func beginShutdownFreeze(scope: AgentRecoveryShutdownScope) -> UUID {
        let token = UUID()
        shutdownFreezes[token] = scope
        postCoordinatorDidChange()
        return token
    }

    /// Adds an owner to a window-scoped freeze (a lane claimed by a frozen window's new session).
    package func extendShutdownFreeze(_ token: UUID, owner: AnyObject) {
        guard case var .owners(owners) = shutdownFreezes[token] else { return }
        owners.insert(ObjectIdentifier(owner))
        shutdownFreezes[token] = .owners(owners)
    }

    /// Ends one freeze (Stage A cancelled or failed). Idempotent.
    package func endShutdownFreeze(_ token: UUID) {
        guard shutdownFreezes.removeValue(forKey: token) != nil else { return }
        postCoordinatorDidChange()
    }

    /// Whether a shutdown freeze covers `owner`'s lanes and producers.
    package func isShutdownFrozen(owner: AnyObject) -> Bool {
        isShutdownFrozen(ownerID: ObjectIdentifier(owner))
    }

    package func isShutdownFrozen(ownerID: ObjectIdentifier) -> Bool {
        shutdownFreezes.values.contains { $0.contains(ownerID) }
    }

    package var hasShutdownFreeze: Bool {
        !shutdownFreezes.isEmpty
    }

    // MARK: Recovery action holds (review A P1-01)

    /// One explicit recovery action between its acquisition and its recorded outcome. An exclusion
    /// and authorization record, never a lock held across persistence.
    fileprivate struct RecoveryActionHold {
        let authorization: AgentRecoveryActionAuthorization
        let request: AgentRecoveryActionRequest
        let laneID: ObjectIdentifier
        let workspaceID: UUID
        var operation: Task<AgentRecoveryActionResult, Never>?
        /// The intent normal admission issued for a continuation's planned user item.
        var admittedIntentID: UUID?
        /// The one delivery attempt committed for the authorized payload.
        var dispatchAttemptID: UUID?
        var commitsInFlight = 0
        var isRevoked = false
        var settlement: AgentRecoveryActionSettlement?
        var waiters: [CheckedContinuation<AgentRecoveryActionSettlement, Never>] = []

        /// The single intent this authorization may dispatch (`nil`: none yet, or none at all).
        var authorizedIntentID: UUID? {
            authorization.sourceIntentID ?? admittedIntentID
        }
    }

    /// Acquires the shared hold for one explicit recovery action. Call synchronously before the
    /// action's first await. An exact repeat (same request, same lane) joins the running
    /// performance; any other action in the same session or workspace, and every ordinary
    /// admission, dispatch, and handoff of the same durable session (any window), is refused while
    /// the hold lasts; workspace siblings see only the automatic busy projection. Refused when `lane` is not the
    /// session's live lane or the session's workspace mapping is unknown.
    package func beginRecoveryAction(
        _ request: AgentRecoveryActionRequest,
        lane: AgentRecoverySessionLane
    ) -> AgentRecoveryActionHoldAcquisition {
        if let existing = recoveryActionHolds.values.first(where: { $0.authorization.actionID == request.actionID }) {
            guard existing.request == request, existing.laneID == ObjectIdentifier(lane),
                  let operation = existing.operation
            else {
                return .refused
            }
            return .joined(operation)
        }
        let sessionID = lane.sessionID
        guard lanes[sessionID] === lane, !lane.isRetired, let workspaceID = laneWorkspaceIDs[sessionID] else {
            return .refused
        }
        guard !recoveryActionHolds.values.contains(where: {
            $0.authorization.sessionID == sessionID || $0.workspaceID == workspaceID
        }) else {
            return .refused
        }
        let authorization = AgentRecoveryActionAuthorization(
            token: UUID(),
            actionID: request.actionID,
            sessionID: sessionID,
            plannedUserItemID: request.kind == .sendSaved ? nil : request.plannedUserItemID,
            sourceIntentID: request.kind == .sendSaved && request.sourceIntentIDs.count == 1
                ? request.sourceIntentIDs[0]
                : nil
        )
        recoveryActionHolds[authorization.token] = RecoveryActionHold(
            authorization: authorization,
            request: request,
            laneID: ObjectIdentifier(lane),
            workspaceID: workspaceID
        )
        postCoordinatorDidChange()
        return .acquired(authorization)
    }

    /// Records the performance an exact repeat joins (installed synchronously after acquisition).
    package func attachRecoveryActionOperation(
        _ authorization: AgentRecoveryActionAuthorization,
        _ operation: Task<AgentRecoveryActionResult, Never>
    ) {
        recoveryActionHolds[authorization.token]?.operation = operation
    }

    /// Revokes the authorization: no later admission, dispatch commit, or handoff may use it. When
    /// nothing was committed (or is committing) for it, nothing can be handed off any more, so the
    /// submission settles as not handed off.
    package func revokeRecoveryAction(_ authorization: AgentRecoveryActionAuthorization, reason: String? = nil) {
        guard var hold = recoveryActionHolds[authorization.token] else { return }
        hold.isRevoked = true
        recoveryActionHolds[authorization.token] = hold
        settleRecoveryActionIfFenced(authorization.token, reason: reason)
    }

    /// The action's submission ended without handing off its payload through any later task (a
    /// refusal after hydration, a start that provably handed nothing off, a deferred handoff that
    /// settled without a commit). Revokes, then settles unless a committed dispatch still owes its
    /// evidence (which then settles it).
    package func noteRecoveryActionSubmissionEnded(_ authorization: AgentRecoveryActionAuthorization?, reason: String? = nil) {
        guard let authorization else { return }
        revokeRecoveryAction(authorization, reason: reason)
    }

    /// The action's committed delivery attempt entered the provider boundary: it is handed off.
    /// Acceptance is not awaited; ordinary run restrictions take over from here.
    package func noteRecoveryActionHandoffBegan(_ authorization: AgentRecoveryActionAuthorization?, attemptIDs: [UUID]) {
        guard let authorization, let hold = recoveryActionHolds[authorization.token],
              let attemptID = hold.dispatchAttemptID, attemptIDs.contains(attemptID)
        else { return }
        settleRecoveryAction(authorization.token, .handedOff)
    }

    /// Ordered evidence writes for the action's committed delivery attempt landed (or failed).
    package func noteRecoveryActionEvidence(
        _ authorization: AgentRecoveryActionAuthorization?,
        attemptIDs: [UUID],
        observation: AgentRecoveryDispatchEvidence.Observation,
        writeFailed: Bool
    ) {
        guard let authorization, let hold = recoveryActionHolds[authorization.token],
              let attemptID = hold.dispatchAttemptID, attemptIDs.contains(attemptID)
        else { return }
        let settlement: AgentRecoveryActionSettlement? = switch observation {
        case .open:
            nil
        case .accepted, .deliveryUnknown:
            writeFailed ? .uncertain(Self.recoveryActionEvidenceUnrecordedText) : .handedOff
        case .notHandedOff, .rejected:
            // A failed settle leaves the attempt `dispatching`: never claimed as not sent.
            writeFailed ? .uncertain(Self.recoveryActionEvidenceUnrecordedText) : .notHandedOff(nil)
        }
        if let settlement {
            settleRecoveryAction(authorization.token, settlement)
        }
    }

    package static let recoveryActionEvidenceUnrecordedText =
        "The message's delivery couldn't be recorded. Check the conversation before choosing again."

    /// How the action's submission settled; waits until it has (no timeout: a cancelled UI task or
    /// elapsed time is never release evidence).
    package func awaitRecoveryActionSettlement(_ authorization: AgentRecoveryActionAuthorization) async -> AgentRecoveryActionSettlement {
        guard let hold = recoveryActionHolds[authorization.token] else {
            return .uncertain(Self.recoveryActionEvidenceUnrecordedText)
        }
        if let settlement = hold.settlement { return settlement }
        return await withCheckedContinuation { continuation in
            recoveryActionHolds[authorization.token]?.waiters.append(continuation)
        }
    }

    /// Ends the hold after the action's outcome write (revoked first: its token never revives).
    package func endRecoveryAction(_ authorization: AgentRecoveryActionAuthorization) {
        guard let hold = recoveryActionHolds.removeValue(forKey: authorization.token) else { return }
        for waiter in hold.waiters {
            waiter.resume(returning: hold.settlement ?? .uncertain(Self.recoveryActionEvidenceUnrecordedText))
        }
        postCoordinatorDidChange()
    }

    /// Whether an explicit recovery action holds `sessionID` itself or its workspace: the R9
    /// AUTOMATIC busy projection only (scheduler, automatic new session; `runAlongsideOtherSessions`
    /// never bypasses it). Hard refusals of manual, MCP, queued-drain, and handoff work are scoped to
    /// the action's own durable session (`ownRecoveryActionHold`), never its workspace siblings.
    package func isCoveredByRecoveryAction(sessionID: UUID) -> Bool {
        coveringRecoveryActionHold(sessionID: sessionID) != nil
    }

    /// Whether an explicit recovery action on the card `itemKey` of `sessionID` holds the session
    /// right now (acquired before its reservation is written, released after its outcome write).
    package func hasRecoveryActionHold(sessionID: UUID, itemKey: AgentRecoveryCardKey) -> Bool {
        recoveryActionHolds.values.contains { $0.authorization.sessionID == sessionID && $0.request.itemKey == itemKey }
    }

    /// Whether any explicit recovery action holds `sessionID` right now (whichever card it is on).
    func hasRecoveryActionHold(sessionID: UUID) -> Bool {
        ownRecoveryActionHold(sessionID: sessionID) != nil
    }

    /// Whether an action of a session other than `sessionID` holds `workspaceID`.
    package func hasRecoveryAction(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> Bool {
        recoveryActionHolds.values.contains { $0.workspaceID == workspaceID && $0.authorization.sessionID != sessionID }
    }

    /// Test and diagnostics observability.
    package var recoveryActionHoldCount: Int {
        recoveryActionHolds.count
    }

    /// Test and diagnostics observability: the action's dispatch commit is in flight.
    package func recoveryActionCommitIsInFlight(_ authorization: AgentRecoveryActionAuthorization) -> Bool {
        (recoveryActionHolds[authorization.token]?.commitsInFlight ?? 0) > 0
    }

    /// The hold covering `sessionID` (its own, or one in its workspace per the coordinator's
    /// mapping). With no session identity or no known workspace, any hold covers it (fail closed).
    private func coveringRecoveryActionHold(sessionID: UUID?) -> RecoveryActionHold? {
        guard !recoveryActionHolds.isEmpty else { return nil }
        guard let sessionID else { return recoveryActionHolds.values.first }
        if let own = recoveryActionHolds.values.first(where: { $0.authorization.sessionID == sessionID }) {
            return own
        }
        guard let workspaceID = knownWorkspaceID(for: sessionID) else { return recoveryActionHolds.values.first }
        return recoveryActionHolds.values.first { $0.workspaceID == workspaceID }
    }

    /// The hold of the action whose durable session is `sessionID` (whichever window or lane now
    /// owns it). The shared HARD exclusion (admission, dispatch commit, handoff, untracked input)
    /// applies only here (review R1 B N1): sibling sessions of the workspace keep their manual, MCP,
    /// queued-drain, and steering work, while automatic work stays gated by the workspace projection.
    private func ownRecoveryActionHold(sessionID: UUID?) -> RecoveryActionHold? {
        guard let sessionID else { return nil }
        return recoveryActionHolds.values.first { $0.authorization.sessionID == sessionID }
    }

    /// The carried authorization's live hold, when it is current for `sessionID` and is the hold
    /// covering it.
    private func currentRecoveryActionHold(
        _ authorization: AgentRecoveryActionAuthorization,
        sessionID: UUID
    ) -> RecoveryActionHold? {
        guard let hold = recoveryActionHolds[authorization.token], !hold.isRevoked,
              hold.authorization == authorization, authorization.sessionID == sessionID,
              coveringRecoveryActionHold(sessionID: sessionID)?.authorization.token == authorization.token
        else { return nil }
        return hold
    }

    /// Input admission: refused while an action holds this durable session, unless the input is the
    /// holding action's own planned item (admitted once).
    fileprivate func recoveryActionAdmissionRefusal(
        sessionID: UUID,
        userItemID: UUID,
        authorization: AgentRecoveryActionAuthorization?
    ) -> AgentRecoveryAdmissionRefusal? {
        guard let authorization else {
            return ownRecoveryActionHold(sessionID: sessionID) == nil ? nil : .recoveryActionInProgress
        }
        guard let hold = currentRecoveryActionHold(authorization, sessionID: sessionID),
              let planned = authorization.plannedUserItemID, planned == userItemID,
              hold.admittedIntentID == nil
        else {
            return .recoveryActionInProgress
        }
        return nil
    }

    /// Binds the intent admission issued for the action's planned item (once).
    fileprivate func noteRecoveryActionAdmitted(_ authorization: AgentRecoveryActionAuthorization?, intentID: UUID) {
        guard let authorization, recoveryActionHolds[authorization.token]?.admittedIntentID == nil else { return }
        recoveryActionHolds[authorization.token]?.admittedIntentID = intentID
    }

    /// Dispatch commit: refused while an action holds this durable session, unless it is exactly
    /// the holding action's one authorized intent, dispatched once. Mixed or coalesced constituents
    /// never pass.
    fileprivate func recoveryActionDispatchRefusal(
        sessionID: UUID,
        intentIDs: [UUID],
        authorization: AgentRecoveryActionAuthorization?
    ) -> AgentRecoveryAdmissionRefusal? {
        guard let authorization else {
            return ownRecoveryActionHold(sessionID: sessionID) == nil ? nil : .recoveryActionInProgress
        }
        guard let hold = currentRecoveryActionHold(authorization, sessionID: sessionID),
              intentIDs.count == 1, let authorized = hold.authorizedIntentID, authorized == intentIDs[0],
              hold.dispatchAttemptID == nil, hold.commitsInFlight == 0
        else {
            return .recoveryActionInProgress
        }
        return nil
    }

    fileprivate func beginRecoveryActionDispatchCommit(_ authorization: AgentRecoveryActionAuthorization?) {
        guard let authorization else { return }
        recoveryActionHolds[authorization.token]?.commitsInFlight += 1
    }

    /// After the dispatch commit landed (`attemptID`, or `nil` when it failed): whether the
    /// committed attempt may still be handed off. A refused one is settled stale by the lane.
    fileprivate func finishRecoveryActionDispatchCommit(
        _ authorization: AgentRecoveryActionAuthorization?,
        sessionID: UUID,
        attemptID: UUID?
    ) -> Bool {
        guard let authorization else {
            return ownRecoveryActionHold(sessionID: sessionID) == nil
        }
        guard var hold = recoveryActionHolds[authorization.token] else { return false }
        hold.commitsInFlight -= 1
        let permitted = attemptID != nil && hold.dispatchAttemptID == nil
            && currentRecoveryActionHold(authorization, sessionID: sessionID) != nil
        if permitted {
            hold.dispatchAttemptID = attemptID
        }
        recoveryActionHolds[authorization.token] = hold
        if !permitted {
            settleRecoveryActionIfFenced(authorization.token, reason: nil)
        }
        return permitted
    }

    /// A refused post-commit dispatch (`attemptIDs`) was settled back to `queued` (or could not be).
    /// Bound to the exact attempt: when the commit already attached it to the hold (a shutdown or
    /// reset freeze landed during the write, after the action check passed), the action's one
    /// delivery attempt is spent and provably not handed off, so the submission settles
    /// `notHandedOff` (revoked: nothing can use the token any more); a failed settle write is
    /// `uncertain`, never claimed as not sent.
    fileprivate func noteRecoveryActionStaleCommitSettled(
        _ authorization: AgentRecoveryActionAuthorization?,
        attemptIDs: [UUID],
        settled: Bool
    ) {
        guard let authorization, var hold = recoveryActionHolds[authorization.token] else { return }
        if let attached = hold.dispatchAttemptID {
            guard attemptIDs.contains(attached) else { return }
            hold.isRevoked = true
            recoveryActionHolds[authorization.token] = hold
            settleRecoveryAction(
                authorization.token,
                settled ? .notHandedOff(nil) : .uncertain(Self.recoveryActionEvidenceUnrecordedText)
            )
            return
        }
        if !settled {
            settleRecoveryAction(authorization.token, .uncertain(Self.recoveryActionEvidenceUnrecordedText))
        } else {
            settleRecoveryActionIfFenced(authorization.token, reason: nil)
        }
    }

    /// Final handoff check: no action holds this durable session, or the carried authorization is
    /// current and the delivery attempts are exactly its one committed attempt.
    fileprivate func recoveryActionPermitsHandoff(
        sessionID: UUID?,
        attemptIDs: [UUID],
        authorization: AgentRecoveryActionAuthorization?
    ) -> Bool {
        guard let authorization else {
            return ownRecoveryActionHold(sessionID: sessionID) == nil
        }
        guard let sessionID, let hold = currentRecoveryActionHold(authorization, sessionID: sessionID),
              let attemptID = hold.dispatchAttemptID
        else { return false }
        return attemptIDs == [attemptID]
    }

    /// Untracked input (inactive admission) carries no authorization: it is refused while an action
    /// holds its own durable session. Input without a durable session identity is a new session,
    /// never the action's (whose tab is bound to it), so only the automatic projection applies there.
    package func recoveryActionBlocksUntrackedInput(sessionID: UUID?) -> Bool {
        ownRecoveryActionHold(sessionID: sessionID) != nil
    }

    /// Revokes every hold acquired through `lane` (its owner replaced or released it). Ownership is
    /// kept until the delayed work is fenced or its committed dispatch settles.
    private func revokeRecoveryActions(of lane: AgentRecoverySessionLane) {
        let laneID = ObjectIdentifier(lane)
        for hold in recoveryActionHolds.values where hold.laneID == laneID {
            revokeRecoveryAction(hold.authorization, reason: AgentRecoverySessionLane.sessionChangedHoldReason)
        }
    }

    private func settleRecoveryActionIfFenced(_ token: UUID, reason: String?) {
        guard let hold = recoveryActionHolds[token], hold.isRevoked, hold.settlement == nil,
              hold.dispatchAttemptID == nil, hold.commitsInFlight == 0
        else { return }
        settleRecoveryAction(token, .notHandedOff(reason))
    }

    private func settleRecoveryAction(_ token: UUID, _ settlement: AgentRecoveryActionSettlement) {
        guard var hold = recoveryActionHolds[token], hold.settlement == nil else { return }
        hold.settlement = settlement
        if case .notHandedOff = settlement {
            hold.isRevoked = true
        }
        let waiters = hold.waiters
        hold.waiters = []
        recoveryActionHolds[token] = hold
        for waiter in waiters {
            waiter.resume(returning: settlement)
        }
    }

    /// Joins released lanes' retirements and returns the sessions whose ownerless input is still
    /// unsaved afterwards. Released lanes are app-owned (their window may already be gone), so only
    /// app quit loses that memory and vetoes on it; a window close never attributes them to itself.
    package func settleReleasedRetirements() async -> Set<UUID> {
        var unsaved: Set<UUID> = []
        for (sessionID, retirement) in releasedRetirements {
            let remaining = await retirement.value
            if !remaining.isEmpty, releasedRetirements[sessionID] == retirement {
                unsaved.insert(sessionID)
            }
        }
        unsaved.formUnion(releasedUnsavedInputs.keys)
        return unsaved
    }

    /// Enqueues an ordered unclean launch-mark write for this instance and returns its outcome.
    /// Writes (clean ones included) run strictly in call order.
    package func recordLaunchState(_ state: AgentRecoveryLaunchMark.State) -> Task<Bool, Never> {
        enqueueLaunchMarkWrite { store in
            _ = try await store.recordCurrentLaunch(state)
            return true
        }
    }

    /// A fresh clean-exit authorization (see `AgentRecoveryCleanExitGate`).
    package func authorizeCleanExit() -> UUID {
        store.cleanExitGate.authorize()
    }

    /// Revokes any unstarted clean write and reports whether a clean mark can still land (a write
    /// that already began cannot be revoked).
    package func revokeCleanExit() -> AgentRecoveryCleanExitGate.Revocation {
        store.cleanExitGate.revoke()
    }

    /// Enqueues the ordered clean write under `authorization`; `false` when it failed or its
    /// authorization was no longer current when it began (nothing written).
    package func recordCleanExit(authorization: UUID) -> Task<Bool, Never> {
        enqueueLaunchMarkWrite { store in
            try await store.recordCleanExit(authorization: authorization)
        }
    }

    private func enqueueLaunchMarkWrite(
        _ write: @escaping @Sendable (AgentRecoveryStore) async throws -> Bool
    ) -> Task<Bool, Never> {
        let previous = launchMarkTail
        let store = store
        let task = Task { @MainActor () -> Bool in
            await previous?.value
            do {
                return try await write(store)
            } catch {
                return false
            }
        }
        launchMarkTail = Task { _ = await task.value }
        return task
    }

    // MARK: Admission and crash holds

    /// `nil` when admission is open for `binding`; otherwise the fail-closed refusal.
    package func admissionRefusal(
        for binding: AgentRecoveryLifecycleBinding,
        workspaceID: UUID? = nil
    ) async -> AgentRecoveryAdmissionRefusal? {
        switch await awaitStartup() {
        case .notStarted, .loading:
            return .startupNotReady
        case let .failed(message):
            return .startupFailed(message)
        case .ready:
            break
        }
        if let hold = blockingCrashHold(for: binding) {
            return .crashHeld(hold)
        }
        if let reason = runtimeSendRefusalReason(sessionID: binding.sessionID) {
            return .restricted(reason)
        }
        if let reason = restrictions.sessionRestriction(binding.sessionID)
            ?? workspaceID.flatMap({ restrictions.workspaceRestriction($0) })
        {
            return .restricted(reason)
        }
        return nil
    }

    /// Whether a restricted or crash-held session other than `sessionID` (open or closed), or the
    /// workspace itself, is unresolved in `workspaceID`: the scheduler's workspace-busy extension.
    package func hasUnresolvedSession(inWorkspace workspaceID: UUID, excluding sessionID: UUID) -> Bool {
        !unresolvedSessionSummary(inWorkspace: workspaceID, excluding: sessionID).isEmpty
    }

    /// What `hasUnresolvedSession` found, for presentation (lossless restart F2): the sessions with
    /// an unconfirmed crash hold (lifted only by It stopped for that exact hold; Dismiss lifts
    /// nothing), the restricted sessions, and the workspace's own restriction.
    package func unresolvedSessionSummary(
        inWorkspace workspaceID: UUID,
        excluding sessionID: UUID
    ) -> AgentRecoveryWorkspaceUnresolvedSummary {
        AgentRecoveryWorkspaceUnresolvedSummary(
            crashHeldSessionIDs: Set(crashHolds.values.compactMap { hold in
                hold.sessionID != sessionID
                    && confirmedCrashHolds[hold.sessionID] != hold
                    && reconciliation.resolution(for: hold.sessionID)?.workspaceID == workspaceID
                    ? hold.sessionID : nil
            }),
            restrictedSessionIDs: restrictions.restrictedSessionIDs(inWorkspace: workspaceID, excluding: sessionID),
            workspaceRestriction: restrictions.workspaceRestriction(workspaceID)
        )
    }

    /// Lifts a session's held-transfer restriction after its owner resolved the schedule transfer.
    /// Nonactionable, duplicate, and workspace restrictions stay until a fresh startup inspection.
    package func noteScheduleTransferResolved(sessionID: UUID) {
        guard let resolution = reconciliation.resolution(for: sessionID),
              resolution.classification == .actionable,
              case .held = resolution.scheduleTransfer,
              restrictions.sessionRestriction(sessionID) != nil
        else { return }
        restrictions.lift(sessionID: sessionID)
        postCoordinatorDidChange()
    }

    /// The published crash hold for the session (confirmed or not).
    package func crashHold(for sessionID: UUID) -> AgentRecoveryCrashHold? {
        crashHolds[sessionID]
    }

    /// An unconfirmed crash hold bound to this incarnation and reset generation.
    package func blockingCrashHold(for binding: AgentRecoveryLifecycleBinding) -> AgentRecoveryCrashHold? {
        guard let hold = crashHolds[binding.sessionID],
              hold.incarnationID == binding.incarnationID,
              hold.transcriptResetGeneration == binding.transcriptResetGeneration
        else {
            return nil
        }
        return confirmedCrashHolds[binding.sessionID] == hold ? nil : hold
    }

    /// Explicit user confirmation of exactly the published hold (F-2), through `lane` (the session's
    /// live lane, same lifecycle as the hold): the displayed hold is revalidated, the exact
    /// acknowledgement is committed under the lifecycle gate, and only after that commit succeeds
    /// is the hold published as confirmed. `false` for a stale hold or a failed commit (nothing is
    /// lifted). The acknowledgement closes no run; in the same write it settles the hold's qualifying
    /// `dispatching` messages to `deliveryUnknown` (O46), never resending them.
    package func confirmCrashHold(_ hold: AgentRecoveryCrashHold, lane: AgentRecoverySessionLane) async -> Bool {
        func isCurrent() -> Bool {
            crashHolds[hold.sessionID] == hold
                && !lane.isRetired
                && lane.sessionID == hold.sessionID
                && lane.binding.incarnationID == hold.incarnationID
                && lane.binding.transcriptResetGeneration == hold.transcriptResetGeneration
        }
        guard isCurrent() else { return false }
        if confirmedCrashHolds[hold.sessionID] == hold { return true }
        guard case .success = await lane.recordCrashHoldAcknowledgement(hold), isCurrent() else { return false }
        return publishCrashHoldConfirmation(hold)
    }

    /// Whether exactly `hold` is published as confirmed.
    func isCrashHoldConfirmed(_ hold: AgentRecoveryCrashHold) -> Bool {
        confirmedCrashHolds[hold.sessionID] == hold
    }

    /// The one post-commit publication of a crash-hold confirmation, shared by "It stopped"
    /// (`confirmCrashHold(_:lane:)`) and Check and resolve's registry-proven confirmation: called
    /// only after the exact acknowledgement of `hold` committed. Publishes it as confirmed (lifting
    /// admission and the workspace-busy extension, so already-authorized scheduled sends may run)
    /// when it is still the published hold; `false` (nothing lifted) when the hold changed.
    func publishCrashHoldConfirmation(_ hold: AgentRecoveryCrashHold) -> Bool {
        guard crashHolds[hold.sessionID] == hold else { return false }
        if confirmedCrashHolds[hold.sessionID] != hold {
            confirmedCrashHolds[hold.sessionID] = hold
            postCoordinatorDidChange()
        }
        return true
    }

    // MARK: Lanes

    /// Installs the single live lane for `persistenceState`'s durable session. An existing lane for
    /// the same owner and persistence state is returned unchanged. Any other existing lane is
    /// retired first (synchronously closed to new admissions and edits; when the lifecycle binding
    /// is unchanged its latest input, including typing buffered before its restore, is written
    /// before its controller retires), and the new lane's restore waits for that retirement. Only
    /// input that genuinely failed to persist is inherited as `unsavedPredecessorInputs`.
    package func claimLane(
        owner: AnyObject,
        persistenceState: AgentSessionPersistenceState
    ) throws -> AgentRecoverySessionLane {
        let gate = try dataService.recoveryLifecycleGate(for: persistenceState)
        let sessionID = gate.binding.sessionID
        let predecessor = lanes[sessionID]
        if let predecessor, !predecessor.isRetired, predecessor.isOwned(by: owner),
           predecessor.persistenceState == persistenceState
        {
            return predecessor
        }
        // A released lane's retirement is inherited too, so its unsaved input reaches the next owner
        // (which then presents it; the ownerless publication below is withdrawn).
        let released = releasedRetirements.removeValue(forKey: sessionID)
        if released != nil, releasedUnsavedInputs.removeValue(forKey: sessionID) != nil {
            composerStateDidChange(sessionID: sessionID)
        }
        // Review B F9: a hand-over that preserves ownership (same owner, same lifecycle binding) keeps
        // the predecessor's still-live questions live in the successor, captured before retirement.
        // Any other claim inherits none: historical or expired requests never become live.
        let preservesOwnership = predecessor.map {
            !$0.isRetired && $0.isOwned(by: owner) && $0.binding == gate.binding
        } ?? false
        let inheritedLiveQuestions: [AgentRecoveryQuestionSnapshot] = if preservesOwnership, let predecessor {
            predecessor.questionPersistence.liveSnapshots
        } else {
            []
        }
        if let predecessor {
            // A successor never inherits the predecessor's action authority.
            revokeRecoveryActions(of: predecessor)
        }
        let retirement = predecessor?.beginRetirement(preserving: predecessor?.binding == gate.binding) ?? released
        let lane = AgentRecoverySessionLane(
            coordinator: self,
            store: store,
            owner: owner,
            persistenceState: persistenceState,
            gate: gate,
            composer: makeComposerController(store, gate),
            predecessorRetirement: retirement
        )
        lanes[sessionID] = lane
        laneWorkspaceIDs[sessionID] = persistenceState.stamp.workspaceID
        if let tabID = (owner as? AgentTabSession)?.tabID {
            laneComposeTabIDs[sessionID] = tabID
        }
        if !inheritedLiveQuestions.isEmpty {
            // Pending until this lane writes them, after the predecessor's retirement (review R1).
            var afterRetirement: (@MainActor () async -> Void)?
            if let retirement {
                afterRetirement = { _ = await retirement.value }
            }
            lane.questionPersistence.adoptLiveInteractions(inheritedLiveQuestions, after: afterRetirement)
        }
        invalidateCatalog()
        return lane
    }

    /// The workspace a session was last owned in this launch (a lane claim), else its startup
    /// destination; `nil` when neither is known.
    package func knownWorkspaceID(for sessionID: UUID) -> UUID? {
        laneWorkspaceIDs[sessionID] ?? reconciliation.resolution(for: sessionID)?.workspaceID
    }

    /// The compose tab a session was last owned in this launch (a lane claim), else its startup
    /// compose tab; `nil` when neither is known.
    package func knownComposeTabID(for sessionID: UUID) -> UUID? {
        laneComposeTabIDs[sessionID] ?? reconciliation.resolution(for: sessionID)?.composeTabID
    }

    /// Deferred run-start handoffs (F1) by durable intent, kept here rather than on the issuing lane so
    /// a successor owner (tab replaced or reopened while the runner still prepares) sees the
    /// predecessor's `pending` entry and its later no-handoff settlement. The retired issuing lane
    /// refuses the late commit itself (`beginDispatches`). Process memory only.
    fileprivate var deferredRunStartHandoffs: [UUID: AgentDeferredRunStartHandoffState] = [:]
    /// Intents whose owner consumes a no-handoff settlement later (a scheduled send's hold), marked
    /// before its run starts. Only these keep a `notHandedOff` entry; others are cleared when settled.
    fileprivate var ownerAwaitedDeferredRunStartIntentIDs: Set<UUID> = []
    /// The durable session of each `deferredRunStartHandoffs` entry (kept and removed with it).
    fileprivate var deferredRunStartHandoffSessionIDs: [UUID: UUID] = [:]

    /// Whether any deferred run-start handoff entry (pending or an unconsumed no-handoff settlement)
    /// exists for `sessionID` in this launch. When none does, no runner in this process can owe
    /// the session's input a settlement, so the R9 repair decides exactly as before F1.
    package func hasDeferredRunStartHandoff(sessionID: UUID) -> Bool {
        deferredRunStartHandoffSessionIDs.values.contains(sessionID)
    }

    /// The live (unretired) lane for a durable session.
    package func lane(for sessionID: UUID) -> AgentRecoverySessionLane? {
        guard let lane = lanes[sessionID], !lane.isRetired else { return nil }
        return lane
    }

    /// Retires `lane` (preserving its latest composer input first) and unregisters it if still
    /// current. The release task stays owned by the coordinator until a later lane inherits it.
    @discardableResult
    package func releaseLane(_ lane: AgentRecoverySessionLane) -> Task<Void, Never> {
        revokeRecoveryActions(of: lane)
        let retirement = lane.beginRetirement(preserving: true)
        let sessionID = lane.sessionID
        if lanes[sessionID] === lane {
            lanes[sessionID] = nil
            releasedRetirements[sessionID] = retirement
        }
        invalidateCatalog()
        return Task { @MainActor [weak self] in
            let unsaved = await retirement.value
            // The owner went away: input its lane could not persist is published here until a
            // later lane for the session inherits it, never kept only inside a parked task.
            guard let self, !unsaved.isEmpty, releasedRetirements[sessionID] == retirement else { return }
            releasedUnsavedInputs[sessionID] = AgentRecoveryOwnerlessUnsavedInput(
                workspaceID: lane.persistenceState.stamp.workspaceID,
                inputs: unsaved
            )
            composerStateDidChange(sessionID: sessionID)
        }
    }

    /// Composer input a released lane could not persist while no later lane has inherited it (its
    /// owner tab or window went away), by session. Shown by the recovery list of its workspace.
    package var ownerlessUnsavedInputs: [UUID: AgentRecoveryOwnerlessUnsavedInput] {
        releasedUnsavedInputs
    }

    /// Explicit user discard of exactly the displayed ownerless input (oldest first). The parked
    /// retirement is replaced by one carrying only the remaining inputs, so a later lane never
    /// inherits the discarded payload. Returns `false` when it is no longer the oldest entry.
    @discardableResult
    package func discardOwnerlessUnsavedInput(sessionID: UUID, expected: AgentRecoveryUnsavedComposerInput) -> Bool {
        // R02: a restored copy whose rollback is still owed is resolved only through a lane (a
        // durable write); dropping it here would leave its stored copy unprotected for the next owner.
        guard expected.restoreRollback == nil,
              var ownerless = releasedUnsavedInputs[sessionID], ownerless.inputs.first == expected,
              releasedRetirements[sessionID] != nil
        else { return false }
        ownerless.inputs.removeFirst()
        let remaining = ownerless.inputs
        releasedUnsavedInputs[sessionID] = remaining.isEmpty ? nil : ownerless
        releasedRetirements[sessionID] = remaining.isEmpty ? nil : Task { remaining }
        composerStateDidChange(sessionID: sessionID)
        return true
    }

    // MARK: Held intents (this launch)

    /// Held intents recorded for this incarnation of the session (see
    /// `AgentRecoverySessionLane.noteProjectionRemoved`).
    package func heldIntents(for binding: AgentRecoveryLifecycleBinding) -> [UUID: String] {
        heldIntents(sessionID: binding.sessionID, incarnationID: binding.incarnationID)
    }

    package func heldIntents(sessionID: UUID, incarnationID: UUID) -> [UUID: String] {
        guard let notes = heldIntentNotes[sessionID], notes.incarnationID == incarnationID else { return [:] }
        return notes.reasons
    }

    /// Sessions with held intents recorded this launch (any owner, any window).
    package var heldIntentSessions: [UUID: (incarnationID: UUID, workspaceID: UUID, reasons: [UUID: String])] {
        heldIntentNotes.mapValues { ($0.incarnationID, $0.workspaceID, $0.reasons) }
    }

    fileprivate func noteHeldIntents(
        _ intentIDs: [UUID],
        reason: String,
        binding: AgentRecoveryLifecycleBinding,
        workspaceID: UUID
    ) {
        var notes = heldIntentNotes[binding.sessionID].flatMap { $0.incarnationID == binding.incarnationID ? $0 : nil }
            ?? HeldIntentNotes(incarnationID: binding.incarnationID, workspaceID: workspaceID, reasons: [:])
        var changed = false
        for intentID in intentIDs where notes.reasons[intentID] == nil {
            notes.reasons[intentID] = reason
            changed = true
        }
        guard changed else { return }
        heldIntentNotes[binding.sessionID] = notes
        composerStateDidChange(sessionID: binding.sessionID)
    }

    fileprivate func clearHeldIntent(_ intentID: UUID, binding: AgentRecoveryLifecycleBinding) {
        guard var notes = heldIntentNotes[binding.sessionID], notes.incarnationID == binding.incarnationID,
              notes.reasons.removeValue(forKey: intentID) != nil
        else { return }
        heldIntentNotes[binding.sessionID] = notes.reasons.isEmpty ? nil : notes
        composerStateDidChange(sessionID: binding.sessionID)
    }

    /// Keeps held-intent and ownerless presentation consistent with a committed record: a deleted
    /// session or another incarnation drops it; accepted or withdrawn intents need no decision.
    private func pruneHeldPresentation(for commit: AgentRecoveryRecordCommit) {
        let sessionID = commit.sessionID
        switch commit.state {
        case .absent:
            let hadNotes = heldIntentNotes.removeValue(forKey: sessionID) != nil
            let hadUnsaved = releasedUnsavedInputs.removeValue(forKey: sessionID) != nil
            if hadNotes || hadUnsaved { composerStateDidChange(sessionID: sessionID) }
        case let .supported(record):
            guard var notes = heldIntentNotes[sessionID] else { return }
            guard notes.incarnationID == record.incarnationID else {
                heldIntentNotes[sessionID] = nil
                composerStateDidChange(sessionID: sessionID)
                return
            }
            let before = notes.reasons.count
            notes.reasons = notes.reasons.filter { intentID, reason in
                guard let intent = record.intent(id: intentID) else { return true }
                switch intent.deliveryState {
                case .providerAccepted, .withdrawn:
                    return false
                default:
                    // A derived ended-run note lasts only while its condition holds (input settled
                    // back to the live queue is owned by it again).
                    guard Self.derivedHoldReasons.contains(reason) else { return true }
                    return Self.uncertainInputHoldReason(intent, in: record) != nil
                }
            }
            guard notes.reasons.count != before else { return }
            heldIntentNotes[sessionID] = notes.reasons.isEmpty ? nil : notes
            composerStateDidChange(sessionID: sessionID)
        }
    }

    // MARK: Uncertain input after its run ended (this launch)

    package static let runEndedUnconfirmedHoldReason = "Its run ended before delivery was confirmed."
    package static let unlinkedUnconfirmedHoldReason = "Its handoff ended before delivery was confirmed."
    private static let derivedHoldReasons: Set<String> = [runEndedUnconfirmedHoldReason, unlinkedUnconfirmedHoldReason]

    /// The hold reason for uncertain input whose live projection is over, or `nil` while one still
    /// owns it:
    /// - `dispatching`/`deliveryUnknown` whose latest attempt belongs to a run with terminal
    ///   evidence (the run ended; a recorded shutdown reason is intent, not a stop);
    /// - `deliveryUnknown` whose latest attempt has no run attempt: its handoff already settled as
    ///   unknown and no run will end for it.
    /// A `dispatching` attempt without a run attempt is still owned by its in-flight handoff.
    package static func uncertainInputHoldReason(_ intent: AgentRecoveryIntent, in record: AgentRecoveryRecord) -> String? {
        guard intent.deliveryState == .dispatching || intent.deliveryState == .deliveryUnknown,
              let attempt = record.attempts(forIntent: intent.intentID).last
        else { return nil }
        guard let runAttemptID = attempt.runAttemptID else {
            return intent.deliveryState == .deliveryUnknown ? unlinkedUnconfirmedHoldReason : nil
        }
        guard let run = record.runAttempt(id: runAttemptID), run.terminal != nil else {
            return nil
        }
        return runEndedUnconfirmedHoldReason
    }

    /// Registers this launch's uncertain input of ended runs as held presentation, derived from the
    /// committed record (order-independent: whichever of the outcome or the terminal evidence lands
    /// last). The workspace comes from the session's current lane or its existing notes; a session
    /// with neither is listed from the record by the startup overlay instead.
    private func presentUncertainInputOfEndedRuns(in record: AgentRecoveryRecord) {
        let currentInstanceID = store.appInstanceID
        var byReason: [String: [UUID]] = [:]
        for intent in record.intents where intent.appInstanceID == currentInstanceID {
            if let reason = Self.uncertainInputHoldReason(intent, in: record) {
                byReason[reason, default: []].append(intent.intentID)
            }
        }
        guard !byReason.isEmpty else { return }
        let existing = heldIntentNotes[record.sessionID].flatMap { $0.incarnationID == record.incarnationID ? $0 : nil }
        guard let workspaceID = lanes[record.sessionID]?.persistenceState.stamp.workspaceID ?? existing?.workspaceID else {
            return
        }
        let binding = AgentRecoveryLifecycleBinding(
            sessionID: record.sessionID,
            incarnationID: record.incarnationID,
            transcriptResetGeneration: record.transcriptResetGeneration
        )
        for (reason, intentIDs) in byReason.sorted(by: { $0.key < $1.key }) {
            noteHeldIntents(intentIDs, reason: reason, binding: binding, workspaceID: workspaceID)
        }
    }

    // MARK: Composer preparation (no lane yet)

    /// Live owners' failed preparations, for the catalog's runtime projection (never persisted and
    /// never dismissible: the obligation clears only by a successful retry, hand-off, or discard).
    package var failedComposerPreparations: [(owner: AnyObject, failure: AgentRecoveryComposerPreparationFailure)] {
        composerPreparations.values.compactMap { preparation in
            guard let failure = preparation.failure, let owner = preparation.owner else { return nil }
            return (owner, failure)
        }
    }

    /// The owner's outstanding obligation, if any.
    package func composerPreparation(for owner: AnyObject) -> AgentRecoveryComposerPreparation? {
        guard let preparation = composerPreparations[ObjectIdentifier(owner)] else { return nil }
        guard preparation.owner === owner else {
            // A deallocated owner's identifier was reused; its obligation died with it.
            composerPreparations[ObjectIdentifier(owner)] = nil
            return nil
        }
        return preparation
    }

    /// Records a composer mutation of `owner` that cannot reach a lane yet. The first such mutation
    /// fixes the obligation's first-unsaved instant (now, on the shared clock); later ones only
    /// replace the latest content (`nil` = not yet representable).
    @discardableResult
    package func recordComposerMutationAwaitingPreparation(
        owner: AnyObject,
        content: AgentRecoveryInputContent?
    ) -> AgentRecoveryComposerPreparation {
        let preparation = composerPreparation(for: owner) ?? {
            let created = AgentRecoveryComposerPreparation(owner: owner, firstUnsavedAt: clockNow())
            composerPreparations[ObjectIdentifier(owner)] = created
            return created
        }()
        preparation.latestContent = content
        return preparation
    }

    /// Starts the owner's single preparation task unless one is running. `body` establishes
    /// authority, promotes images, and hands the latest content over with
    /// `completeComposerPreparation`; a returned failure keeps the obligation and its payload
    /// visible. Returns `false` when a preparation was already running (the mutation coalesced).
    @discardableResult
    package func startComposerPreparation(
        owner: AnyObject,
        _ body: @escaping @MainActor (AgentRecoveryComposerPreparation) async -> AgentRecoveryComposerPreparationFailure?
    ) -> Bool {
        guard let preparation = composerPreparation(for: owner), preparation.task == nil else { return false }
        if preparation.failure != nil {
            preparation.failure = nil
            composerStateDidChange(sessionID: nil)
        }
        preparation.task = Task { @MainActor [weak self, preparation] in
            let failure = await body(preparation)
            preparation.task = nil
            if let failure {
                preparation.failure = failure
                self?.composerStateDidChange(sessionID: nil)
            }
        }
        return true
    }

    /// Hands the owner's obligation to `lane` with its original first-unsaved instant, so the write
    /// is due at that instant plus 2 seconds (immediately when overdue). Refused when `lane` is not
    /// owned by `owner` (a replacement or late completion never adopts the obligation); the
    /// obligation is then kept with `ownerReplaced`.
    @discardableResult
    package func completeComposerPreparation(
        owner: AnyObject,
        forwardingTo lane: AgentRecoverySessionLane,
        content: AgentRecoveryInputContent
    ) -> Result<AgentRecoveryComposerRevision?, AgentRecoveryComposerPreparationFailure> {
        guard let preparation = composerPreparation(for: owner) else {
            return .success(lane.composerDidChange(content))
        }
        guard lane.isOwned(by: owner), !lane.isRetired, lanes[lane.sessionID] === lane else {
            preparation.failure = .ownerReplaced
            composerStateDidChange(sessionID: nil)
            return .failure(.ownerReplaced)
        }
        composerPreparations[ObjectIdentifier(owner)] = nil
        if preparation.failure != nil {
            composerStateDidChange(sessionID: lane.sessionID)
        }
        return .success(lane.composerDidChange(content, firstUnsavedAt: preparation.firstUnsavedAt))
    }

    /// Drops the owner's obligation after an explicit user discard (or once its content is empty).
    package func discardComposerPreparation(owner: AnyObject) {
        guard composerPreparations.removeValue(forKey: ObjectIdentifier(owner)) != nil else { return }
        composerStateDidChange(sessionID: nil)
    }
}

// MARK: - Session lane

/// One durable session's recovery ownership: its lifecycle gate, its single composer controller,
/// restore-before-edits sequencing, explicit held-composer resolution, and gated admission and
/// evidence transactions used by every producer.
@MainActor
package final class AgentRecoverySessionLane {
    package enum ComposerState: Equatable {
        case unrestored
        case restoring
        /// Restored (or superseded by newer live typing); edits write through.
        case ready
        /// A composer from another reset generation is stored; it awaits explicit resolution.
        /// Live edits are kept pending (writes refuse with `heldComposerUnresolved`).
        case held(AgentRecoveryComposerSnapshot)
        case restoreFailed(AgentRecoveryControllerFailure)
    }

    private static let maximumConflictRetries = 3
    /// Held-input reason for input committed while its session changed (lane retired meanwhile).
    package static let sessionChangedHoldReason = "The session changed before it was sent, so it was never queued."

    package let persistenceState: AgentSessionPersistenceState
    package let binding: AgentRecoveryLifecycleBinding
    package let composer: AgentRecoveryComposerPersistenceController
    /// Live pending-question persistence (plan §E): creation, drafts, and resolution of this
    /// session's questions, written through this lane's gated question update.
    package private(set) lazy var questionPersistence: AgentRecoveryQuestionPersistenceController = {
        let controller = AgentRecoveryQuestionPersistenceController { [weak self] update in
            guard let self else { return .failure(.retired) }
            return await updateQuestionSnapshots(update)
        }
        controller.stateDidChange = { [weak self] in
            self?.notifyStateChange()
        }
        return controller
    }()

    private let gate: any AgentRecoveryLifecycleGate
    package let store: AgentRecoveryStore
    private weak var coordinator: AgentRecoveryCoordinator?
    private weak var owner: AnyObject?
    private let ownerID: ObjectIdentifier
    /// A retired lane's handoff: the composer input it could not persist, oldest first.
    package typealias Retirement = Task<[AgentRecoveryUnsavedComposerInput], Never>

    private let predecessorRetirement: Retirement?
    /// Adopts the predecessor's unsaved input once its retirement finishes.
    private var predecessorSettlement: Task<Void, Never>?

    package private(set) var composerState: ComposerState = .unrestored {
        didSet {
            if oldValue != composerState { notifyStateChange() }
        }
    }

    package private(set) var isRetired = false
    /// The latest live composer could not be represented durably (for example an image not yet in
    /// managed storage), so it was not persisted. Cleared by the next representable edit.
    package private(set) var hasUnrepresentableComposerEdit = false
    /// Terminal-evidence write failures by run attempt (see `recordTerminalEvidence`).
    package private(set) var terminalEvidenceFailures: [UUID: AgentRecoveryControllerFailure] = [:]
    /// The failed terminal-evidence operation of each attempt in `terminalEvidenceFailures`, kept so
    /// shutdown finalization can retry the storage write after the provider already stopped (no new
    /// terminal event will arrive to repair it).
    private var failedTerminalEvidence: [UUID: (commit: AgentRunTerminalCommitRevision, transcriptTurnID: UUID?)] = [:]
    private var terminalEvidenceTail: Task<Void, Never>?
    /// Composer input inherited from retired predecessors, oldest first (plus restored held content
    /// that newer typing kept out of the composer, see `resolveHeldComposer`). While non-empty, new
    /// admissions are refused (`unsavedPredecessorInput`) and a restore never replaces live UI.
    package private(set) var unsavedPredecessorInputs: [AgentRecoveryUnsavedComposerInput] = [] {
        didSet {
            if oldValue != unsavedPredecessorInputs { notifyStateChange() }
        }
    }

    /// Durable intents of this session (this incarnation) whose live projection was removed without
    /// a replacement, with the reason shown to the user. Owned by the app-scoped coordinator, so a
    /// lane retirement, reclaim, or another window's ownership never hides them.
    package var heldIntents: [UUID: String] {
        coordinator?.heldIntents(for: binding) ?? [:]
    }

    private var retirementTask: Retirement?
    private var restoreTask: Task<AgentRecoveryComposerRestoreOutcome, Never>?
    /// Latest live content typed before restore completed (forwarded after the restore).
    private var bufferedEdit: AgentRecoveryInputContent?
    /// Earliest first-unsaved instant of the buffered (or unrepresentable) input. Forwarded with it
    /// so the controller's 2-second bound is never restarted by waiting for restore or promotion.
    package private(set) var bufferedFirstUnsavedAt: ContinuousClock.Instant?
    private var awaitingRevision: [AgentRecoveryComposerSubmissionToken] = []
    /// Set while a transcript reset preserves this lane's composer; new admissions and dispatch
    /// commits are refused.
    package private(set) var isResetPreparationActive = false
    /// In-flight admission and dispatch commits, joined by reset preparation before it flushes.
    private var activeAdmissionCount = 0
    /// An admission or dispatch commit is in flight (test observability of the reset drain).
    package var hasInFlightAdmissions: Bool {
        activeAdmissionCount > 0
    }

    private var admissionDrainWaiters: [CheckedContinuation<Void, Never>] = []

    fileprivate init(
        coordinator: AgentRecoveryCoordinator,
        store: AgentRecoveryStore,
        owner: AnyObject,
        persistenceState: AgentSessionPersistenceState,
        gate: any AgentRecoveryLifecycleGate,
        composer: AgentRecoveryComposerPersistenceController,
        predecessorRetirement: Retirement?
    ) {
        self.coordinator = coordinator
        self.store = store
        self.owner = owner
        ownerID = ObjectIdentifier(owner)
        self.persistenceState = persistenceState
        binding = gate.binding
        self.gate = gate
        self.composer = composer
        self.predecessorRetirement = predecessorRetirement
        if let predecessorRetirement {
            // Strong capture: inherited input must not be lost with a short-lived lane.
            predecessorSettlement = Task { @MainActor in
                let inherited = await predecessorRetirement.value
                unsavedPredecessorInputs.append(contentsOf: inherited.map(adoptingRestoreRollback))
            }
        }
        composer.stateDidChange = { [weak self] in
            self?.notifyStateChange()
        }
        composer.restoreRollbackDidSucceed = { [weak self] held in
            self?.restoreRollbackDidSucceed(held)
        }
    }

    /// R02 hand-over: runs in the predecessor settlement, before this lane's first restore, write,
    /// or admission (each waits for it). A same-binding predecessor's outstanding rollback becomes
    /// this controller's, so the stored restored draft stays protected under the new owner. A lane
    /// already retired before its settlement (a transit-only owner in a rapid chain) still adopts:
    /// its controller retires only after this settlement, and its own retirement then forwards the
    /// still-owed obligation to the next owner. Under another binding the obligation does not apply
    /// (the store refuses ordinary composer writes over another reset generation's composer and any
    /// write under another incarnation), so the entry is kept as ordinary unsaved input.
    private func adoptingRestoreRollback(_ input: AgentRecoveryUnsavedComposerInput) -> AgentRecoveryUnsavedComposerInput {
        guard let obligation = input.restoreRollback else { return input }
        guard input.binding == binding else {
            var ordinary = input
            ordinary.restoreRollback = nil
            return ordinary
        }
        composer.adoptRestoreRollback(obligation)
        return input
    }

    /// A retried rollback put the held draft back: it is presented as held again, replacing the
    /// visible restored copy.
    private func restoreRollbackDidSucceed(_ held: AgentRecoveryComposerSnapshot) {
        guard !isRetired else { return }
        unsavedPredecessorInputs.removeAll { $0.restoreRollback?.held == held }
        composerState = .held(held)
    }

    private func notifyStateChange() {
        coordinator?.composerStateDidChange(sessionID: binding.sessionID)
    }

    // MARK: Live edit reviews (Step 5a)

    private var liveEditProposalIDStorage: Set<UUID> = []

    /// Review IDs of this session's `apply_edits` proposals whose live review (or accepted write)
    /// is in progress in this launch; the recovery catalog does not list them. Empty once retired,
    /// so a retired owner's proposals become historical.
    package var liveEditProposalIDs: Set<UUID> {
        isRetired ? [] : liveEditProposalIDStorage
    }

    /// Marks a proposal live, before its pending commit (so it never flashes as historical).
    package func noteEditProposalLive(_ reviewID: UUID) {
        guard liveEditProposalIDStorage.insert(reviewID).inserted else { return }
        notifyStateChange()
    }

    /// Ends a proposal's live phase: whatever is still stored for it becomes historical.
    package func endEditProposalLive(_ reviewID: UUID) {
        guard liveEditProposalIDStorage.remove(reviewID) != nil else { return }
        notifyStateChange()
    }

    // MARK: Held intents (this launch)

    /// Records that the live projections of these durable intents were removed without a
    /// replacement, so they are presented as held input (`reason` is shown with them). Recorded on
    /// the coordinator even after this lane retired (a late runner path), so the next owner, in any
    /// window, still presents them. Untracked input has no intent and is never recorded.
    package func noteProjectionRemoved(intentIDs: some Sequence<UUID>, reason: String) {
        coordinator?.noteHeldIntents(
            Array(intentIDs),
            reason: reason,
            binding: binding,
            workspaceID: persistenceState.stamp.workspaceID
        )
    }

    /// Drops held-intent presentation once the intent no longer needs a decision (withdrawn,
    /// accepted, or moved back into the composer).
    package func clearHeldIntent(_ intentID: UUID) {
        coordinator?.clearHeldIntent(intentID, binding: binding)
    }

    package var sessionID: UUID {
        binding.sessionID
    }

    package func isOwned(by candidate: AnyObject) -> Bool {
        owner != nil && ObjectIdentifier(candidate) == ownerID
    }

    // MARK: Composer

    /// Forwards a full live composer snapshot. Before restore completes the latest content is
    /// buffered (restore before edits) and `nil` is returned. `firstUnsavedAt` is the instant of the
    /// earliest mutation this content represents when it was held elsewhere first (no lane yet);
    /// the earliest outstanding instant always wins.
    @discardableResult
    package func composerDidChange(
        _ content: AgentRecoveryInputContent,
        firstUnsavedAt: ContinuousClock.Instant? = nil
    ) -> AgentRecoveryComposerRevision? {
        guard !isRetired else { return nil }
        hasUnrepresentableComposerEdit = false
        let instant = earliest(firstUnsavedAt ?? composer.currentInstant, bufferedFirstUnsavedAt)
        switch composerState {
        case .ready, .held:
            bufferedFirstUnsavedAt = nil
            return composer.composerDidChange(content, firstUnsavedAt: instant)
        case .unrestored, .restoring, .restoreFailed:
            bufferedEdit = content
            bufferedFirstUnsavedAt = instant
            return nil
        }
    }

    /// Records that the live composer changed to content that cannot be persisted yet. The
    /// obligation's first-unsaved instant is kept for the content that later represents it.
    package func composerContentUnrepresentable(firstUnsavedAt: ContinuousClock.Instant? = nil) {
        guard !isRetired else { return }
        composer.noteUnrepresentableComposerChange()
        hasUnrepresentableComposerEdit = true
        bufferedFirstUnsavedAt = earliest(firstUnsavedAt ?? composer.currentInstant, bufferedFirstUnsavedAt)
    }

    private func earliest(
        _ instant: ContinuousClock.Instant,
        _ other: ContinuousClock.Instant?
    ) -> ContinuousClock.Instant {
        other.map { min($0, instant) } ?? instant
    }

    /// Captures a composer submission synchronously (before optimistic clearing).
    package func beginComposerSubmission(_ content: AgentRecoveryInputContent) -> AgentRecoveryComposerSubmissionToken {
        let token = AgentRecoveryComposerSubmissionToken(content: content)
        guard !isRetired else { return token }
        switch composerState {
        case .ready, .held:
            token.revision = composer.composerDidChange(content)
        case .unrestored, .restoring, .restoreFailed:
            // The submitted content supersedes earlier buffered typing.
            bufferedEdit = nil
            bufferedFirstUnsavedAt = nil
            awaitingRevision.append(token)
        }
        return token
    }

    /// Restores the durable composer once (after any predecessor's retirement). The returned
    /// outcome is what the live UI may adopt: `.restored(snapshot)` only when nothing was typed or
    /// submitted meanwhile, otherwise `.superseded`. A failed restore may be retried.
    package func restoreComposer() async -> AgentRecoveryComposerRestoreOutcome {
        if let restoreTask {
            return await restoreTask.value
        }
        guard !isRetired else { return .failed(.retired) }
        composerState = .restoring
        let settlement = predecessorSettlement
        let task = Task { [weak self] () -> AgentRecoveryComposerRestoreOutcome in
            await settlement?.value
            guard let self else { return .failed(.retired) }
            return await performRestore()
        }
        restoreTask = task
        return await task.value
    }

    private func performRestore() async -> AgentRecoveryComposerRestoreOutcome {
        let outcome = await composer.loadRestorableComposer()
        // The learned state is recorded even when retirement began meanwhile: a same-binding
        // retirement preserves its captured input against exactly this baseline.
        switch outcome {
        case .restored, .superseded:
            composerState = .ready
        case let .heldForOtherGeneration(snapshot):
            composerState = .held(snapshot)
        case let .failed(failure):
            composerState = .restoreFailed(failure)
            restoreTask = nil
            return outcome
        }
        // Retirement captured the buffered input and forwards it itself before retiring.
        guard !isRetired else { return .failed(.retired) }
        // Submissions captured during the restore issue revisions first, then later typing.
        let hadLiveInput = !awaitingRevision.isEmpty || bufferedEdit != nil
        for token in awaitingRevision {
            token.revision = composer.composerDidChange(token.content)
        }
        awaitingRevision = []
        if let edit = bufferedEdit {
            bufferedEdit = nil
            // The original first-unsaved instant: waiting for restore never restarts the bound.
            composer.composerDidChange(edit, firstUnsavedAt: bufferedFirstUnsavedAt)
            bufferedFirstUnsavedAt = nil
        }
        // Unresolved predecessor input is live input too: a restore never replaces it in the UI.
        if hadLiveInput || !unsavedPredecessorInputs.isEmpty, case .restored = outcome {
            return .superseded
        }
        return outcome
    }

    /// Explicit user resolution of exactly the displayed (oldest) unsaved predecessor input
    /// (`expected`; otherwise `heldInputChanged`). `discard` drops that payload;
    /// `restoreToComposer` requires an empty live composer, forwards the content as this lane's
    /// live composer (written under this lane's authority, by explicit choice), and returns it for
    /// the UI to show. Admission reopens once none remain.
    package func resolveUnsavedPredecessorInput(
        _ choice: AgentRecoveryHeldComposerChoice,
        expected: AgentRecoveryUnsavedComposerInput,
        liveComposerIsEmpty: Bool
    ) async -> Result<AgentRecoveryInputContent?, AgentRecoveryControllerFailure> {
        // `liveComposerIsEmpty` describes the composer at this instant; a change while waiting for
        // the predecessor settlement must not be replaced by the restored content.
        let liveRevisionAtRequest = composer.liveRevision
        await predecessorSettlement?.value
        guard !isRetired else { return .failure(.retired) }
        guard let oldest = unsavedPredecessorInputs.first else { return .failure(.noHeldComposer) }
        guard oldest == expected else { return .failure(.heldInputChanged) }
        if let obligation = oldest.restoreRollback, composer.outstandingRestoreRollback == obligation {
            return await resolveProtectedRestore(
                choice,
                entry: oldest,
                obligation: obligation,
                liveComposerIsEmpty: liveComposerIsEmpty,
                liveRevisionAtRequest: liveRevisionAtRequest
            )
        }
        switch choice {
        case .discard:
            unsavedPredecessorInputs.removeFirst()
            return .success(nil)
        case .restoreToComposer:
            guard liveComposerIsEmpty else { return .failure(.liveComposerHasUnsavedContent) }
            guard composer.liveRevision == liveRevisionAtRequest else { return .failure(.composerChangedDuringRestore) }
            unsavedPredecessorInputs.removeFirst()
            composerDidChange(oldest.content)
            return .success(oldest.content)
        }
    }

    /// R02: the protected restored copy is resolved only by a durable write (the controller stores
    /// the live typing or removes the copy for discard, or stores the placed content for restore);
    /// the entry is removed, and admission reopens, only after that write commits. A failure keeps
    /// the entry, the protection, and the stored copy, and is returned for a Retry.
    private func resolveProtectedRestore(
        _ choice: AgentRecoveryHeldComposerChoice,
        entry: AgentRecoveryUnsavedComposerInput,
        obligation: AgentRecoveryRestoreRollbackObligation,
        liveComposerIsEmpty: Bool,
        liveRevisionAtRequest: AgentRecoveryComposerRevision?
    ) async -> Result<AgentRecoveryInputContent?, AgentRecoveryControllerFailure> {
        // The write needs this lane's learned baseline (the stored restored revision).
        if let restoreTask {
            _ = await restoreTask.value
        }
        guard !isRetired else { return .failure(.retired) }
        guard case .ready = composerState else {
            if case let .restoreFailed(failure) = composerState { return .failure(failure) }
            return .failure(.heldInputChanged)
        }
        let placing: AgentRecoveryInputContent?
        switch choice {
        case .discard:
            placing = nil
        case .restoreToComposer:
            guard liveComposerIsEmpty else { return .failure(.liveComposerHasUnsavedContent) }
            guard composer.liveRevision == liveRevisionAtRequest else { return .failure(.composerChangedDuringRestore) }
            placing = entry.content
        }
        if case let .failure(failure) = await composer.resolveProtectedRestore(obligation, placing: placing) {
            // R02-R2: typing raced the placement write and its put-back failed, so the committed
            // placement is now the protected revision; the visible copy carries that obligation.
            if !isRetired, let current = composer.outstandingRestoreRollback, current != obligation,
               let index = unsavedPredecessorInputs.firstIndex(of: entry)
            {
                unsavedPredecessorInputs[index].restoreRollback = current
            }
            return .failure(failure)
        }
        if let index = unsavedPredecessorInputs.firstIndex(of: entry) {
            unsavedPredecessorInputs.remove(at: index)
        }
        return .success(placing)
    }

    package func flushComposer() async -> AgentRecoveryComposerFlushOutcome {
        await composer.flush()
    }

    /// Explicit user resolution of exactly the displayed held composer (`expectedHeldRevision`;
    /// otherwise `heldInputChanged`). `restoreToComposer` requires an empty live composer and
    /// returns the content to place into it; `discard` stores current live typing in the same
    /// replacement. A composer change during a restore yields `composerChangedDuringRestore`
    /// with the held draft still stored and still presented (see the controller's restore
    /// freeze). Only when the controller could not revert a raced restore is the restored content
    /// kept visible as unsaved predecessor-style input with that failure (never dropped, never
    /// merged); `.success(nil)` is then returned.
    package func resolveHeldComposer(
        _ choice: AgentRecoveryHeldComposerChoice,
        expectedHeldRevision: AgentRecoveryComposerRevision,
        liveComposerIsEmpty: Bool
    ) async -> Result<AgentRecoveryComposerSnapshot?, AgentRecoveryControllerFailure> {
        guard !isRetired else { return .failure(.retired) }
        guard case let .held(displayed) = composerState else { return .failure(.noHeldComposer) }
        guard displayed.revision == expectedHeldRevision else { return .failure(.heldInputChanged) }
        if choice == .restoreToComposer, !liveComposerIsEmpty {
            return .failure(.liveComposerHasUnsavedContent)
        }
        let result = await composer.resolveHeldComposer(choice, expectedHeldRevision: expectedHeldRevision)
        guard case let .success(restored) = result else { return result }
        if !isRetired {
            composerState = .ready
        }
        if let restored, composer.liveRevision != restored.revision {
            if !isRetired {
                unsavedPredecessorInputs.append(AgentRecoveryUnsavedComposerInput(
                    binding: binding,
                    content: restored.content,
                    failure: composer.restoreRevertFailure,
                    restoreRollback: composer.outstandingRestoreRollback
                ))
            }
            return .success(nil)
        }
        return result
    }

    // MARK: Admission

    /// Commits a `queued` intent (no handoff begun) after the startup barrier and crash-hold check.
    /// Composer submissions consume only the submitted (or earlier) composer revision.
    package func admitQueued(
        _ admission: AgentRecoveryAdmission,
        composerToken: AgentRecoveryComposerSubmissionToken? = nil
    ) async -> Result<AgentRecoveryAdmitted<AgentRecoveryQueueReceipt>, AgentRecoveryAdmissionFailure> {
        await admit(admission, composerToken: composerToken, intentReceipt: \.intent) { lane, submission, revision in
            if let revision {
                return await lane.composer.submitQueued(submission, submittedRevision: revision).map(\.receipt)
            }
            return await lane.transaction { store, binding in
                try await store.commitQueuedIntent(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    submission: submission,
                    consumption: nil
                )
            }
        }
    }

    /// Commits a `dispatching` intent and its delivery attempt before any provider handoff.
    package func admitDirect(
        _ admission: AgentRecoveryAdmission,
        attempt: AgentRecoveryAttemptStart,
        composerToken: AgentRecoveryComposerSubmissionToken? = nil
    ) async -> Result<AgentRecoveryAdmitted<AgentRecoveryDispatchReceipt>, AgentRecoveryAdmissionFailure> {
        await admit(admission, composerToken: composerToken, intentReceipt: \.intent) { lane, submission, revision in
            if let revision {
                return await lane.composer.submitDirect(submission, attempt: attempt, submittedRevision: revision)
                    .map(\.receipt)
            }
            return await lane.transaction { store, binding in
                try await store.commitDispatchingIntent(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    submission: submission,
                    attempt: attempt,
                    consumption: nil
                )
            }
        }
    }

    private func admit<Receipt: Equatable & Sendable>(
        _ admission: AgentRecoveryAdmission,
        composerToken: AgentRecoveryComposerSubmissionToken?,
        intentReceipt: (Receipt) -> AgentRecoveryIntentReceipt,
        commit: (AgentRecoverySessionLane, AgentRecoveryIntentSubmission, AgentRecoveryComposerRevision?) async
            -> Result<Receipt, AgentRecoveryControllerFailure>
    ) async -> Result<AgentRecoveryAdmitted<Receipt>, AgentRecoveryAdmissionFailure> {
        guard !isRetired else { return .failure(.refused(.laneRetired)) }
        guard !isResetPreparationActive else { return .failure(.refused(.resetPreparationInProgress)) }
        guard !isShutdownFrozen else { return .failure(.refused(.shutdownInProgress)) }
        guard admission.binding == binding else { return .failure(.refused(.bindingMismatch)) }
        // Joined by reset preparation before it flushes the old generation's composer.
        activeAdmissionCount += 1
        defer { admissionDidFinish() }
        if let refusal = await admissionRefusal() {
            return .failure(.refused(refusal))
        }
        if let refusal = actionAdmissionRefusal(admission) {
            return .failure(.refused(refusal))
        }
        await predecessorSettlement?.value
        guard unsavedPredecessorInputs.isEmpty else { return .failure(.refused(.unsavedPredecessorInput)) }
        var revision: AgentRecoveryComposerRevision?
        if let composerToken {
            let outcome = await restoreComposer()
            guard let tokenRevision = composerToken.revision else {
                if case let .failed(failure) = outcome {
                    return .failure(.refused(.composerUnavailable(failure)))
                }
                return .failure(.refused(.composerUnavailable(.retired)))
            }
            revision = tokenRevision
        }
        // Revalidate after every await before the durable write.
        guard !isRetired else { return .failure(.refused(.laneRetired)) }
        if let refusal = await admissionRefusal() {
            return .failure(.refused(refusal))
        }
        guard !isRetired else { return .failure(.refused(.laneRetired)) }
        guard unsavedPredecessorInputs.isEmpty else { return .failure(.refused(.unsavedPredecessorInput)) }
        guard !isResetPreparationActive else { return .failure(.refused(.resetPreparationInProgress)) }
        guard !isShutdownFrozen else { return .failure(.refused(.shutdownInProgress)) }
        if let refusal = actionAdmissionRefusal(admission) {
            return .failure(.refused(refusal))
        }
        let receipt: Receipt
        switch await commit(self, admission.submission, revision) {
        case let .failure(failure):
            return .failure(.commitFailed(failure))
        case let .success(value):
            receipt = value
        }
        if isRetired {
            let marked = await markTargetStale(intentID: intentReceipt(receipt).intentID)
            let persisted = if case .success = marked { true } else { false }
            // Presented now by the session's next owner (any window), marked or not.
            noteProjectionRemoved(intentIDs: [intentReceipt(receipt).intentID], reason: Self.sessionChangedHoldReason)
            return .failure(.staleAfterCommit(intentID: admission.intentID, staleMarkPersisted: persisted))
        }
        coordinator?.noteRecoveryActionAdmitted(admission.actionAuthorization, intentID: intentReceipt(receipt).intentID)
        return .success(AgentRecoveryAdmitted(admission: admission, receipt: receipt, submittedComposerRevision: revision))
    }

    /// The shared action hold (review A P1-01): refused while an explicit recovery action holds this
    /// session or its workspace, unless this is that action's own planned item.
    private func actionAdmissionRefusal(_ admission: AgentRecoveryAdmission) -> AgentRecoveryAdmissionRefusal? {
        guard let coordinator else {
            return admission.actionAuthorization == nil ? nil : .recoveryActionInProgress
        }
        return coordinator.recoveryActionAdmissionRefusal(
            sessionID: binding.sessionID,
            userItemID: admission.userItemID,
            authorization: admission.actionAuthorization
        )
    }

    /// The app-scoped coordinator owning this lane (`nil` once it is gone).
    package var recoveryCoordinator: AgentRecoveryCoordinator? {
        coordinator
    }

    /// A shutdown request (app quit or this owner's window close) froze this lane's owner.
    package var isShutdownFrozen: Bool {
        coordinator?.isShutdownFrozen(ownerID: ownerID) ?? false
    }

    private func admissionRefusal() async -> AgentRecoveryAdmissionRefusal? {
        guard let coordinator else { return .startupNotReady }
        return await coordinator.admissionRefusal(for: binding, workspaceID: persistenceState.stamp.workspaceID)
    }

    private func admissionDidFinish() {
        activeAdmissionCount -= 1
        guard activeAdmissionCount == 0 else { return }
        let waiters = admissionDrainWaiters
        admissionDrainWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForAdmissionsToDrain() async {
        guard activeAdmissionCount > 0 else { return }
        await withCheckedContinuation { admissionDrainWaiters.append($0) }
    }

    // MARK: Transcript reset preparation

    /// Preserves this lane's composer before a transcript reset advances the generation (spec R2
    /// reset ordering). Synchronously closes admission, then joins predecessor settlement, admitted
    /// submissions, and restore, and writes the latest composer under the current generation.
    /// Fails (vetoing the reset, admission reopened, nothing cleared) when input remains
    /// unrepresentable, unwritten, or retained only in memory. On success admission stays closed
    /// until the caller commits the reset (the lane is then retired by the successor claim) or calls
    /// `endTranscriptResetPreparation()`. The written composer is left held by the new generation;
    /// it is never adopted there implicitly.
    package func prepareForTranscriptReset() async -> Result<Void, AgentRecoveryResetPreparationFailure> {
        guard !isRetired else { return .failure(.laneRetired) }
        guard !isResetPreparationActive else { return .failure(.alreadyPreparing) }
        isResetPreparationActive = true
        let result = await performResetPreparation()
        if case .failure = result {
            isResetPreparationActive = false
        }
        return result
    }

    /// Releases a successful preparation whose reset was not committed (reopens admission).
    package func endTranscriptResetPreparation() {
        isResetPreparationActive = false
    }

    // MARK: Shutdown preparation (Stage A)

    /// Run evidence written by shutdown preparation for the owner's active run.
    package struct ShutdownRunEvidence {
        package let ownership: AgentRunOwnership
        package let processRunID: UUID?
        package let reason: AgentRecoveryShutdownReason
        package let lastConfirmedActivityAt: Date?

        package init(
            ownership: AgentRunOwnership,
            processRunID: UUID?,
            reason: AgentRecoveryShutdownReason,
            lastConfirmedActivityAt: Date?
        ) {
            self.ownership = ownership
            self.processRunID = processRunID
            self.reason = reason
            self.lastConfirmedActivityAt = lastConfirmedActivityAt
        }
    }

    /// Stage A for one lane while the caller holds a shutdown freeze covering its owner: joins
    /// predecessor settlement, in-flight admissions and dispatch commits, restore, and tracked
    /// evidence writes; writes the latest composer under the current generation (failing on
    /// unrepresentable, unsaved-predecessor, or unwritten input exactly like reset preparation);
    /// then applies the exact pending-question update (`nil` leaves them unchanged) and records the
    /// active run's shutdown reason. Never retires the lane or changes reset state, so a cancelled
    /// shutdown leaves it fully usable. A reason already recorded by an earlier, cancelled attempt
    /// is kept (the store keeps the first reason; it is intent, never proof of a stop). Succeeds
    /// with the upserted interaction IDs that were already stored (another owner's, or an earlier
    /// attempt's, preserved questions).
    package func prepareForShutdown(
        questions: AgentRecoveryStore.QuestionSnapshotUpdate?,
        run: ShutdownRunEvidence?
    ) async -> Result<Set<UUID>, AgentRecoveryShutdownPreparationFailure> {
        guard !isRetired else { return .failure(.composer(.laneRetired)) }
        if case let .failure(failure) = await performComposerPreservation() {
            return .failure(.composer(failure))
        }
        await settleEvidenceWrites()
        guard !isRetired else { return .failure(.composer(.laneRetired)) }
        // The live question lane drains first (answers are frozen): unsaved drafts and owed
        // removals land before the aggregate capture closes any remaining gap.
        if case let .failed(failure) = await questionPersistence.drain() {
            return .failure(.evidenceNotPersisted(failure))
        }
        guard !isRetired else { return .failure(.composer(.laneRetired)) }
        var alreadyStored = Set<UUID>()
        if let questions {
            // Exact IDs only: a question another owner preserved (a closed window of this or an
            // earlier launch) is kept until it is resolved by its own ID.
            switch await updateQuestionSnapshots(questions) {
            case let .success(written):
                alreadyStored = written.alreadyStored
            case let .failure(failure):
                return .failure(.evidenceNotPersisted(failure))
            }
        }
        if let run {
            if case let .failure(failure) = await ensureRunAttempt(
                ownership: run.ownership,
                processRunID: run.processRunID,
                transcriptTurnID: nil,
                processRunAssociation: .keepExisting,
                // The run-start provider, if this write creates the attempt.
                providerKindRaw: run.ownership.providerKindRaw,
                // Shutdown evidence never precedes the run's first provider write: no mark.
                runtimeRegistrationRaw: nil
            ) {
                return .failure(.evidenceNotPersisted(failure))
            }
            let recorded = await transaction { store, binding in
                try await store.recordRunShutdown(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    runAttemptID: run.ownership.attemptID,
                    reason: run.reason,
                    lastConfirmedActivityAt: run.lastConfirmedActivityAt
                )
            }
            switch recorded {
            case .success, .failure(.store(.runAttemptConflict)):
                break
            case let .failure(failure):
                return .failure(.evidenceNotPersisted(failure))
            }
        }
        return .success(alreadyStored)
    }

    /// Applies an exact, interaction-keyed change to the durable pending-question snapshots (see
    /// `AgentRecoveryStore.QuestionSnapshotUpdate`), atomically with whatever else is stored.
    package func updateQuestionSnapshots(
        _ update: AgentRecoveryStore.QuestionSnapshotUpdate
    ) async -> Result<AgentRecoveryStore.QuestionSnapshotUpdateReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.updateQuestionSnapshots(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                update: update
            )
        }
    }

    private func performResetPreparation() async -> Result<Void, AgentRecoveryResetPreparationFailure> {
        await performComposerPreservation()
    }

    /// Shared by reset and shutdown preparation: proves the latest composer durable under the
    /// current generation without retiring the lane.
    private func performComposerPreservation() async -> Result<Void, AgentRecoveryResetPreparationFailure> {
        await predecessorSettlement?.value
        await waitForAdmissionsToDrain()
        guard !isRetired else { return .failure(.laneRetired) }
        // Learns the baseline and forwards buffered typing with its original instant.
        let restore = await restoreComposer()
        guard !isRetired else { return .failure(.laneRetired) }
        switch composerState {
        case .ready, .held:
            break
        case let .restoreFailed(failure):
            return .failure(.composerNotPersisted(failure))
        case .unrestored, .restoring:
            if case let .failed(failure) = restore {
                return .failure(.composerNotPersisted(failure))
            }
            return .failure(.composerNotPersisted(nil))
        }
        guard unsavedPredecessorInputs.isEmpty else { return .failure(.unsavedPredecessorInput) }
        for _ in 0 ..< Self.maximumConflictRetries {
            guard !isRetired else { return .failure(.laneRetired) }
            guard !hasUnrepresentableComposerEdit else { return .failure(.unrepresentableComposerInput) }
            guard composer.hasPendingChanges else { return .success(()) }
            if case let .failed(failure) = await composer.flush() {
                return .failure(.composerNotPersisted(failure))
            }
        }
        guard !isRetired else { return .failure(.laneRetired) }
        return composer.hasPendingChanges ? .failure(.composerChangedDuringPreparation) : .success(())
    }

    // MARK: Dispatch and evidence

    /// Starts a delivery attempt for an existing intent. Closed by retirement, reset preparation,
    /// the startup barrier, and an unconfirmed crash hold.
    package func beginDispatch(
        intentID: UUID,
        attempt: AgentRecoveryAttemptStart,
        authorization: AgentRecoveryDispatchAuthorization,
        action: AgentRecoveryActionAuthorization? = nil
    ) async -> Result<AgentRecoveryDispatchReceipt, AgentRecoveryAdmissionFailure> {
        await beginDispatches(
            [AgentRecoveryDispatchRequest(intentID: intentID, attempt: attempt)],
            authorization: authorization,
            action: action,
            single: true
        ).map { $0[0] }
    }

    /// Starts one delivery attempt per constituent of a single combined handoff, atomically and in
    /// order (`AgentRecoveryStore.beginDispatches`). Same closures as `beginDispatch`.
    package func beginDispatches(
        _ dispatches: [AgentRecoveryDispatchRequest],
        authorization: AgentRecoveryDispatchAuthorization,
        action: AgentRecoveryActionAuthorization? = nil
    ) async -> Result<[AgentRecoveryDispatchReceipt], AgentRecoveryAdmissionFailure> {
        await beginDispatches(dispatches, authorization: authorization, action: action, single: false)
    }

    /// The commit participates in the reset drain. A commit that lands after this lane retired (a
    /// new owner claimed the session) or after reset preparation froze it is settled back to
    /// `queued` as pre-handoff and refused, so its stale owner never hands it off.
    private func beginDispatches(
        _ dispatches: [AgentRecoveryDispatchRequest],
        authorization: AgentRecoveryDispatchAuthorization,
        action: AgentRecoveryActionAuthorization?,
        single: Bool
    ) async -> Result<[AgentRecoveryDispatchReceipt], AgentRecoveryAdmissionFailure> {
        guard !dispatches.isEmpty else { return .failure(.refused(.untrackedInput)) }
        guard !isRetired else { return .failure(.refused(.laneRetired)) }
        guard !isResetPreparationActive else { return .failure(.refused(.resetPreparationInProgress)) }
        guard !isShutdownFrozen else { return .failure(.refused(.shutdownInProgress)) }
        if let refusal = actionDispatchRefusal(dispatches, action: action) {
            return .failure(.refused(refusal))
        }
        activeAdmissionCount += 1
        defer { admissionDidFinish() }
        if let refusal = await admissionRefusal() {
            return .failure(.refused(refusal))
        }
        guard !isRetired else { return .failure(.refused(.laneRetired)) }
        guard !isResetPreparationActive else { return .failure(.refused(.resetPreparationInProgress)) }
        guard !isShutdownFrozen else { return .failure(.refused(.shutdownInProgress)) }
        // Revalidated after the await, with no suspension before the commit begins.
        if let refusal = actionDispatchRefusal(dispatches, action: action) {
            return .failure(.refused(refusal))
        }
        coordinator?.beginRecoveryActionDispatchCommit(action)
        let committed: Result<[AgentRecoveryDispatchReceipt], AgentRecoveryControllerFailure> = await transaction { store, binding in
            if single {
                let receipt = try await store.beginDispatch(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    intentID: dispatches[0].intentID,
                    attempt: dispatches[0].attempt,
                    authorization: authorization
                )
                return [receipt]
            }
            return try await store.beginDispatches(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                dispatches: dispatches,
                authorization: authorization
            )
        }
        let receipts: [AgentRecoveryDispatchReceipt]
        switch committed {
        case let .failure(failure):
            _ = coordinator?.finishRecoveryActionDispatchCommit(action, sessionID: sessionID, attemptID: nil)
            return .failure(.commitFailed(failure))
        case let .success(value):
            receipts = value
        }
        let actionPermits = coordinator?.finishRecoveryActionDispatchCommit(
            action,
            sessionID: sessionID,
            attemptID: receipts.count == 1 ? receipts[0].attemptID : nil
        ) ?? (action == nil)
        guard isValidForHandoff, actionPermits else {
            let settled = await settleStaleDispatch(receipts)
            coordinator?.noteRecoveryActionStaleCommitSettled(action, attemptIDs: receipts.map(\.attemptID), settled: settled)
            return .failure(.dispatchStaleAfterCommit(settledToQueue: settled))
        }
        return .success(receipts)
    }

    /// The shared action hold at the dispatch commit: exactly the holding action's one authorized
    /// intent passes; any other dispatch of its durable session is refused.
    private func actionDispatchRefusal(
        _ dispatches: [AgentRecoveryDispatchRequest],
        action: AgentRecoveryActionAuthorization?
    ) -> AgentRecoveryAdmissionRefusal? {
        guard let coordinator else { return action == nil ? nil : .recoveryActionInProgress }
        return coordinator.recoveryActionDispatchRefusal(
            sessionID: sessionID,
            intentIDs: dispatches.map(\.intentID),
            authorization: action
        )
    }

    /// Synchronous pre-check of the shared action hold for a dispatch of `intentIDs` (no write).
    package func recoveryActionDispatchRefusal(
        intentIDs: [UUID],
        action: AgentRecoveryActionAuthorization?
    ) -> AgentRecoveryAdmissionRefusal? {
        actionDispatchRefusal(
            intentIDs.map { AgentRecoveryDispatchRequest(intentID: $0, attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: nil)) },
            action: action
        )
    }

    /// Evidence-aware final handoff check: the lane-wide closures (`isValidForHandoff`) plus the
    /// shared action hold, which only the carried authorization's exact committed attempt passes.
    package func permitsHandoff(attemptIDs: [UUID], action: AgentRecoveryActionAuthorization?) -> Bool {
        guard isValidForHandoff else { return false }
        guard let coordinator else { return action == nil }
        return coordinator.recoveryActionPermitsHandoff(sessionID: sessionID, attemptIDs: attemptIDs, authorization: action)
    }

    /// Whether input dispatched through this lane may still be handed off: not retired and not
    /// frozen by reset preparation. Re-checked by every route immediately before the provider
    /// boundary (`AgentRecoveryDispatchEvidence.isValidForHandoff(in:)`).
    package var isValidForHandoff: Bool {
        !isRetired && !isResetPreparationActive && !isShutdownFrozen
    }

    /// Settles committed attempts that will not be handed off back to `queued` (pre-handoff).
    /// Returns whether every settlement was written.
    private func settleStaleDispatch(_ receipts: [AgentRecoveryDispatchReceipt]) async -> Bool {
        var settled = true
        for receipt in receipts {
            if case .failure = await settleToQueue(
                intentID: receipt.intent.intentID,
                attemptID: receipt.attemptID,
                evidence: .preHandoff,
                message: "The session changed before this message was handed off."
            ) {
                settled = false
            }
        }
        return settled
    }

    /// Evidence writes below are not closed by retirement: evidence for work already handed off
    /// must still be recorded while the lifecycle binding is valid.
    package func recordDeliveryOutcome(
        intentID: UUID,
        attemptID: UUID,
        outcome: AgentRecoveryDeliveryOutcome
    ) async -> Result<AgentRecoveryOutcomeReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.recordDeliveryOutcome(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: intentID,
                attemptID: attemptID,
                outcome: outcome
            )
        }
    }

    package func settleToQueue(
        intentID: UUID,
        attemptID: UUID,
        evidence: AgentRecoveryFailureKind,
        message: String?
    ) async -> Result<AgentRecoveryIntentReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.settleToQueue(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: intentID,
                attemptID: attemptID,
                evidence: evidence,
                message: message
            )
        }
    }

    /// Attaches the exact pending-handoff snapshot a send is about to prepend to its carrier intent,
    /// before that intent's dispatch commit (adopted plan §5). A first attachment is refused unless
    /// the intent is `queued` and every earlier attempt is conclusively not delivered.
    package func attachPendingHandoff(
        intentID: UUID,
        snapshot: AgentRecoveryPendingHandoffSnapshot
    ) async -> Result<AgentRecoveryIntentReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.attachPendingHandoff(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: intentID,
                snapshot: snapshot
            )
        }
    }

    package func issueQueueReceipt(intentID: UUID) async -> Result<AgentRecoveryQueueReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.issueQueueReceipt(binding: binding, intentID: intentID)
        }
    }

    package func markTargetStale(intentID: UUID) async -> Result<AgentRecoveryIntentReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.markTargetStale(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: intentID
            )
        }
    }

    /// Explicit user removal only; lifecycle teardown preserves intents.
    package func withdraw(intentID: UUID) async -> Result<AgentRecoveryIntentReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.withdraw(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                intentID: intentID
            )
        }
    }

    /// `providerKindRaw`: the run's provider captured at run start (`ownership.providerKindRaw`),
    /// recorded only when this write creates the attempt. Required so every writer states it.
    /// `runtimeRegistrationRaw`: the run-start registration mark (`ownership.runtimeRegistrationRaw`),
    /// passed only by the creator that precedes the run's first provider write (the dispatch
    /// commit); every later writer passes `nil`. Recorded only when this write creates the attempt.
    package func ensureRunAttempt(
        ownership: AgentRunOwnership,
        processRunID: UUID?,
        transcriptTurnID: UUID?,
        processRunAssociation: AgentRecoveryRunAssociationPolicy = .strict,
        providerKindRaw: String?,
        runtimeRegistrationRaw: String? = nil
    ) async -> Result<AgentRecoveryRunReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.ensureRunAttempt(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                ownership: ownership,
                processRunID: processRunID,
                transcriptTurnID: transcriptTurnID,
                processRunAssociation: processRunAssociation,
                providerKindRaw: providerKindRaw,
                runtimeRegistrationRaw: runtimeRegistrationRaw
            )
        }
    }

    package func attachDeliveryAttempt(
        attemptID: UUID,
        ownership: AgentRunOwnership
    ) async -> Result<AgentRecoveryRunReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.attachDeliveryAttempt(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                attemptID: attemptID,
                ownership: ownership
            )
        }
    }

    /// Durably dismisses one recovery card in its displayed state (see
    /// `AgentRecoveryCoordinator.dismissCatalogItem`).
    package func acknowledgeCard(
        key: AgentRecoveryCardKey,
        freshness: AgentRecoveryCardFreshness
    ) async -> Result<AgentRecoveryLocalReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.acknowledgeCard(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                key: key,
                freshness: freshness,
                isCurrent: { AgentRecoveryCatalogProjection.recordStillMatches(key: key, freshness: freshness, record: $0) }
            )
        }
    }

    /// Commits the exact acknowledgement of `hold` (see `AgentRecoveryCoordinator.confirmCrashHold`).
    /// O46: "It stopped" settles the hold's qualifying delivery-uncertain messages in the same write
    /// as Check and resolve does; a message that doesn't qualify is acknowledged only.
    package func recordCrashHoldAcknowledgement(
        _ hold: AgentRecoveryCrashHold
    ) async -> Result<AgentRecoveryLocalReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.recordCrashHoldAcknowledgement(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                incarnationID: hold.incarnationID,
                transcriptResetGeneration: hold.transcriptResetGeneration,
                runAttemptIDs: hold.uncertainRunAttemptIDs,
                intentIDs: hold.uncertainIntentIDs,
                transcriptTurnIDs: hold.uncertainTranscriptTurnIDs,
                settlement: .qualifyingIntents
            )
        }
    }

    package func recordRunTerminal(
        _ commit: AgentRunTerminalCommitRevision
    ) async -> Result<AgentRecoveryRunReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.recordRunTerminal(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                commit: commit
            )
        }
    }

    /// Terminal evidence from the terminal commit barrier, independent of any MCP publication
    /// envelope: ensures the run attempt exists, completing its missing join keys (the commit's
    /// expected process run and `transcriptTurnID`, the turn the barrier retained that run in)
    /// without replacing recorded ones (R08), then records its terminal commit. Writes run in
    /// call order. A failure stays visible in `terminalEvidenceFailures` (keyed by run attempt)
    /// until a later write for that attempt succeeds. The run-start provider of the commit's
    /// ownership is recorded only if this write creates the run attempt.
    @discardableResult
    package func recordTerminalEvidence(
        _ commit: AgentRunTerminalCommitRevision,
        transcriptTurnID: UUID?
    ) -> Task<Void, Never> {
        let previous = terminalEvidenceTail
        let task = Task { @MainActor in
            await previous?.value
            let runAttemptID = commit.ownership.attemptID
            var failure: AgentRecoveryControllerFailure?
            if case let .failure(ensureFailure) = await ensureRunAttempt(
                ownership: commit.ownership,
                processRunID: commit.expectedRunID,
                transcriptTurnID: transcriptTurnID,
                processRunAssociation: .keepExisting,
                providerKindRaw: commit.ownership.providerKindRaw,
                // Terminal evidence never precedes the run's first provider write: no mark.
                runtimeRegistrationRaw: nil
            ) {
                failure = ensureFailure
            } else if case let .failure(terminalFailure) = await recordRunTerminal(commit) {
                failure = terminalFailure
            }
            terminalEvidenceFailures[runAttemptID] = failure
            failedTerminalEvidence[runAttemptID] = failure == nil ? nil : (commit, transcriptTurnID)
        }
        terminalEvidenceTail = task
        return task
    }

    /// Reissues every retained failed terminal-evidence write (storage only; nothing is torn down
    /// or re-run) after the writes enqueued so far, and waits for them. A failure stays visible.
    package func retryFailedTerminalEvidence() async {
        await terminalEvidenceTail?.value
        let failed = failedTerminalEvidence.sorted { $0.key.uuidString < $1.key.uuidString }
        for (_, operation) in failed {
            recordTerminalEvidence(operation.commit, transcriptTurnID: operation.transcriptTurnID)
        }
        await terminalEvidenceTail?.value
    }

    // MARK: Delivery evidence

    /// Delivery-evidence writes (`AgentRecoveryDispatchEvidence`) enqueued through this lane and not
    /// yet finished, by tracking token.
    private var pendingDeliveryEvidenceWrites: [UUID: Task<Void, Never>] = [:]

    /// Tracks one enqueued delivery-evidence write. Once it finished (written or failed) the lane
    /// posts `agentRecoveryDeliveryEvidenceDidSettle` (object: this lane) so a waiter on a still-
    /// `dispatching` intent re-reads the record on that signal instead of polling. Evidence may
    /// land after the run went inactive; the signal, not run state, marks its arrival.
    package func trackDeliveryEvidenceWrite(_ write: Task<Void, Never>) {
        let token = UUID()
        pendingDeliveryEvidenceWrites[token] = write
        Task { @MainActor [weak self] in
            await write.value
            guard let self else { return }
            pendingDeliveryEvidenceWrites[token] = nil
            NotificationCenter.default.post(
                name: .agentRecoveryDeliveryEvidenceDidSettle,
                object: self,
                userInfo: ["sessionID": sessionID]
            )
        }
    }

    package var hasPendingDeliveryEvidenceWrites: Bool {
        !pendingDeliveryEvidenceWrites.isEmpty
    }

    // MARK: Deferred run-start handoffs (F1)

    /// Durable intents carried by a deferred run-start handoff (adopted plan §5), in this launch:
    /// `pending` while its runner still owes the dispatch commit or a no-handoff settlement;
    /// `notHandedOff` once it settled without a commit (nothing was written, so the intent is still
    /// `queued` with no attempt). A committed handoff is removed: its durable evidence speaks from
    /// then on. Stored by the coordinator (shared by every lane of the session, so a successor owner
    /// reads its predecessor's entry). Process memory only; never read as delivery evidence after a
    /// relaunch. Without a coordinator nothing can be ruled out, so the answer is `pending` (decide
    /// nothing), never "no entry".
    package func deferredRunStartHandoffState(intentID: UUID) -> AgentDeferredRunStartHandoffState? {
        guard let coordinator else { return .pending }
        return coordinator.deferredRunStartHandoffs[intentID]
    }

    /// Drops the entry (and its owner's mark) once its owner consumed the settlement (or no longer
    /// needs it).
    package func clearDeferredRunStartHandoff(intentID: UUID) {
        coordinator?.deferredRunStartHandoffs[intentID] = nil
        coordinator?.deferredRunStartHandoffSessionIDs[intentID] = nil
        coordinator?.ownerAwaitedDeferredRunStartIntentIDs.remove(intentID)
    }

    /// Marks `intentID` as awaited by an owner that consumes its no-handoff settlement later (a
    /// scheduled send). Call before the run starts; the owner clears it on every other exit.
    package func noteDeferredRunStartHandoffAwaitedByOwner(intentID: UUID) {
        coordinator?.ownerAwaitedDeferredRunStartIntentIDs.insert(intentID)
    }

    func noteDeferredRunStartHandoffPrepared(intentIDs: [UUID]) {
        for intentID in intentIDs {
            coordinator?.deferredRunStartHandoffs[intentID] = .pending
            coordinator?.deferredRunStartHandoffSessionIDs[intentID] = sessionID
        }
    }

    func noteDeferredRunStartHandoffCommitted(intentIDs: [UUID]) {
        for intentID in intentIDs {
            clearDeferredRunStartHandoff(intentID: intentID)
        }
    }

    /// The deferred handoff settled without a dispatch commit. Posts
    /// `agentRecoveryDeliveryEvidenceDidSettle` (object: this lane) so an owner waiting on the
    /// handoff's own settlement (a scheduled send's `.awaitingProviderEvidence` hold) re-checks:
    /// nothing durable was written, so no evidence write would wake it. Only owner-awaited intents
    /// (`noteDeferredRunStartHandoffAwaitedByOwner`) keep the settlement; the rest are cleared.
    func noteDeferredRunStartHandoffNotHandedOff(intentIDs: [UUID], message: String?) {
        guard !intentIDs.isEmpty else { return }
        for intentID in intentIDs {
            if coordinator?.ownerAwaitedDeferredRunStartIntentIDs.contains(intentID) == true {
                coordinator?.deferredRunStartHandoffs[intentID] = .notHandedOff(message: message)
            } else {
                clearDeferredRunStartHandoff(intentID: intentID)
            }
        }
        NotificationCenter.default.post(
            name: .agentRecoveryDeliveryEvidenceDidSettle,
            object: self,
            userInfo: ["sessionID": sessionID]
        )
    }

    /// Awaits every delivery-evidence write tracked so far. Writes enqueued afterwards post their
    /// own settle signal.
    package func deliveryEvidenceWritesSettled() async {
        for write in Array(pendingDeliveryEvidenceWrites.values) {
            await write.value
        }
    }

    /// Awaits tracked delivery-evidence writes and the terminal-evidence tail enqueued so far
    /// (Stage A before snapshots, Stage B after the actual stop and terminal commit).
    package func settleEvidenceWrites() async {
        await deliveryEvidenceWritesSettled()
        await terminalEvidenceTail?.value
    }

    /// Current durable record for this session (read inside the gate).
    package func readRecord() async -> Result<AgentRecoveryRecordState, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            await store.read(sessionID: binding.sessionID)
        }
    }

    // MARK: Retirement

    /// Closes the lane to new admissions and edits immediately, then preserves before relinquishing
    /// the single writer: with `preserving` (unchanged binding) it joins predecessor settlement and
    /// the in-flight restore, learns the durable baseline, forwards input buffered before restore
    /// with its original first-unsaved instant, flushes, and only then retires the controller.
    /// Without `preserving` (the binding changed, e.g. a committed reset) nothing is written under
    /// either authority. Idempotent. The returned task yields only input that genuinely could not be
    /// persisted, oldest first (inherited unresolved input, then this lane's latest composite input
    /// with its write/restore/authority failure); a healthy hand-over yields nothing.
    fileprivate func beginRetirement(preserving: Bool) -> Retirement {
        if let retirementTask {
            return retirementTask
        }
        isRetired = true
        let buffered = bufferedEdit
        let bufferedAt = bufferedFirstUnsavedAt
        bufferedEdit = nil
        bufferedFirstUnsavedAt = nil
        // Submissions awaiting a revision are refused (`composerUnavailable`) by their own admit;
        // their content returns to the composer through the caller's failed-submission path.
        awaitingRevision = []
        let settlement = predecessorSettlement
        let restore = restoreTask
        let task = Task { @MainActor [self] () -> [AgentRecoveryUnsavedComposerInput] in
            await settlement?.value
            var unsaved = unsavedPredecessorInputs
            let residue = await preserveForRetirement(
                buffered: buffered,
                bufferedAt: bufferedAt,
                restore: restore,
                preserving: preserving
            )
            // R02: the retiring flush retried any owed rollback. A visible restored copy whose
            // rollback succeeded is dropped (the held slot owns the draft; the successor restores
            // it as held); one still owed carries its obligation to the successor.
            let outstanding = composer.outstandingRestoreRollback
            unsaved.removeAll { $0.restoreRollback != nil && $0.restoreRollback != outstanding }
            // R02-R1: `preserveForRetirement` retired the controller after its serialized chain
            // drained, so an obligation created by a resolution still in flight when retirement
            // began (whose visible copy this retired lane never appended) is known only now. It is
            // carried exactly once, ahead of the newer typing it raced.
            if let outstanding, !unsaved.contains(where: { $0.restoreRollback == outstanding }) {
                unsaved.append(AgentRecoveryUnsavedComposerInput(
                    binding: binding,
                    content: outstanding.held.content,
                    failure: composer.restoreRevertFailure ?? .retired,
                    restoreRollback: outstanding
                ))
            }
            if let residue {
                unsaved.append(residue)
            }
            // Questions: a same-binding hand-over writes what is still owed; a changed binding
            // writes nothing under either authority.
            await questionPersistence.retire(flushingPending: preserving)
            return unsaved
        }
        retirementTask = task
        return task
    }

    /// Runs inside the retirement task (the lane is already closed). Returns the latest input left
    /// unpersisted, if any. A cancelled or failed write never counts as success.
    private func preserveForRetirement(
        buffered: AgentRecoveryInputContent?,
        bufferedAt: ContinuousClock.Instant?,
        restore: Task<AgentRecoveryComposerRestoreOutcome, Never>?,
        preserving: Bool
    ) async -> AgentRecoveryUnsavedComposerInput? {
        guard preserving else {
            // Binding changed: the old generation's input is never written under the new one.
            let content = buffered ?? composer.pendingContent
            let failure = buffered == nil ? composer.lastWriteFailure : nil
            await composer.retire(flushingPending: false)
            return content.map { AgentRecoveryUnsavedComposerInput(binding: binding, content: $0, failure: failure) }
        }
        _ = await restore?.value
        guard buffered != nil || composer.hasPendingChanges else {
            // Nothing owed: retire without learning a baseline (the serialized chain is drained).
            await composer.retire(flushingPending: false)
            return composer.pendingContent.map {
                AgentRecoveryUnsavedComposerInput(binding: binding, content: $0, failure: composer.lastWriteFailure ?? .retired)
            }
        }
        if let failure = await learnRetirementBaseline() {
            // Without a validated baseline the write could overwrite an unreadable or held composer.
            let content = buffered ?? composer.pendingContent
            await composer.retire(flushingPending: false)
            return content.map { AgentRecoveryUnsavedComposerInput(binding: binding, content: $0, failure: failure) }
        }
        if let buffered {
            composer.composerDidChange(buffered, firstUnsavedAt: bufferedAt)
        }
        let outcome = await composer.retire(flushingPending: true)
        guard let content = composer.pendingContent else { return nil }
        let failure: AgentRecoveryControllerFailure? = if case let .failed(failure) = outcome {
            failure
        } else {
            composer.lastWriteFailure ?? .retired
        }
        return AgentRecoveryUnsavedComposerInput(binding: binding, content: content, failure: failure)
    }

    /// Ensures the controller knows the durable composer before the retiring flush. `nil` when the
    /// flush may proceed (a held composer makes it fail explicitly with `heldComposerUnresolved`).
    private func learnRetirementBaseline() async -> AgentRecoveryControllerFailure? {
        switch composerState {
        case .ready, .held:
            return nil
        case .unrestored, .restoring, .restoreFailed:
            switch await composer.loadRestorableComposer() {
            case .restored, .superseded:
                composerState = .ready
                return nil
            case let .heldForOtherGeneration(snapshot):
                composerState = .held(snapshot)
                return nil
            case let .failed(failure):
                composerState = .restoreFailed(failure)
                return failure
            }
        }
    }

    // MARK: Gate

    /// Runs `body` inside the foundation lifecycle gate, retrying record-revision conflicts.
    /// Never call provider or network work from `body`.
    package func transaction<T: Sendable>(
        _ body: @escaping @Sendable (AgentRecoveryStore, AgentRecoveryLifecycleBinding) async throws -> T
    ) async -> Result<T, AgentRecoveryControllerFailure> {
        let store = store
        let binding = binding
        var lastFailure: AgentRecoveryControllerFailure = .store(.storageFailure("no attempt", cause: .other))
        for _ in 0 ..< Self.maximumConflictRetries {
            do {
                return try await .success(gate.performRecoveryTransaction { try await body(store, binding) })
            } catch let error as AgentRecoveryStoreError {
                lastFailure = .store(error)
                if case .revisionConflict = error { continue }
                return .failure(lastFailure)
            } catch {
                return .failure(.lifecycleRejected(String(describing: error)))
            }
        }
        return .failure(lastFailure)
    }
}
