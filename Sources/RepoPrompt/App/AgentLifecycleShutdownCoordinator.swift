import Foundation
import RepoPromptAgentCore
import RepoPromptPlatform

// Two-stage app quit / window close (lossless-restart spec R4). One app-scoped instance, owned by
// `WindowStatesManager`.
//
// Stage A (reversible): a synchronous scoped freeze before the first await, then layout
// preservation (quit), the `shutdownInProgress` launch mark (quit), released-lane settlement
// (quit), and each participant's preparation, under one absolute deadline per attempt. Nothing is
// torn down. A failure or timeout offers Retry / Cancel; Cancel reopens the frozen owners.
//
// Stage B (point of no return): the forwarded window delegate's veto (close), the irreversible
// flags, one owned teardown (joined, never repeated), the participants' final flush after the
// actual stop and terminal commit, and the clean launch mark LAST (quit only). A failure or
// timeout offers Retry flush / Quit (Close) anyway; never Cancel.
//
// One absolute deadline per user attempt: its monotonic expiry is captured synchronously when the
// attempt starts, spans Stage A and Stage B (Stage B receives only the remainder), and is checked at
// every success transition (point of no return, clean mark, completion); only an explicit Retry
// starts a fresh one. Work runs in owned unstructured tasks; a deadline never joins them. Every
// completion and Stage A side effect is fenced by its request and attempt identity, so late work
// cannot close, reply, write a launch mark, or mark clean.
//
// Stage A awaits and verifies its `shutdownInProgress` launch mark: Stage B is entered only once
// the launch file records this quit as unclean, so a Stage B failure never needs a correction.
//
// The clean mark is written last, once, under a single-use authorization issued only after every
// participant was prepared and finalized (`AgentRecoveryCleanExitGate` lets the write land only if
// that authorization is still current when it begins; an executing write cannot be revoked). Once
// enqueued, the clean write is owned by the request: a late acknowledgement is not uncertainty
// about saved input (everything admitted was preserved and stays frozen), so it is never corrected.
// It times out with its own message; Retry joins the pending write (never writes again); Quit
// Anyway terminates without waiting; its late completion never terminates the app by itself.
//
// Window admission (`admitApplicationWindow`, called synchronously by the only registration seam
// before the window joins the registry): during Stage A of an app quit a window is frozen, joins
// the request, and invalidates the current attempt (Retry preserves the layout again and prepares
// it; Cancel unfreezes it). At the app's point of no return admission is sealed synchronously,
// before anything irreversible, and stays sealed until the process exits: a later window is
// refused (never registered, frozen, prepared, or torn down), so it cannot invalidate the proof.
// A window close never seals. A window close that ended with Close Anyway keeps the later app quit
// from marking itself clean.
//
// Restart safely, uncertain exit (lossless restart Step 4c, owner-delegated policy): when the
// helper's stop stays unproven after an `arm` was sent, the prompt may offer one explicit
// `.exitMayReopen` ("Exit — may reopen"). Only for the app's Stage B `.safeRestart` prompt whose
// `abandon` returned `.unresolved`, and only when this request's current attempt recorded its
// pre-arm witness (final persistence and clean write acknowledged, every family and tool proven
// stopped, a ready helper, all within the attempt's work deadline) immediately before that
// attempt's `arm`. It completes the request once without claiming the helper stopped: ownership
// stays with the relaunch driver, and nothing is retried, spawned, armed, saved, or marked.
// Retry, Cancel, and the ordinary Quit Anyway (which means "no relaunch") stay refused until the
// helper's stop is proven (Step 4b then restores them).

/// A window's agent state as seen by the shutdown coordinator (`AgentModeViewModel`).
@MainActor
protocol AgentLifecycleShutdownParticipant: AnyObject {
    func beginShutdownFreeze(requestID: UUID, ownsRecoveryFreeze: Bool)
    func endShutdownFreeze(requestID: UUID)
    func shutdownPrepare(reason: AgentRecoveryShutdownReason) async -> AgentModeShutdownReport
    /// Irreversible; joinable and executed at most once per participant.
    func shutdownTearDown(reason: AgentRecoveryShutdownReason) async
    func shutdownFinalize() async -> AgentModeShutdownReport
}

extension AgentModeViewModel: AgentLifecycleShutdownParticipant {
    func shutdownPrepare(reason: AgentRecoveryShutdownReason) async -> AgentModeShutdownReport {
        await prepareSessionsForShutdown(reason: reason)
    }

    func shutdownTearDown(reason: AgentRecoveryShutdownReason) async {
        await prepareForWindowClose(reason: reason)
    }

    func shutdownFinalize() async -> AgentModeShutdownReport {
        await finalizeTranscriptsAfterShutdown()
    }
}

enum AgentLifecycleShutdownScope: Hashable {
    case application
    case window(Int)
}

enum AgentLifecycleShutdownStage: Equatable {
    /// Stage A: offers Retry / Cancel.
    case preparation
    /// Stage B: offers Retry flush / Quit (Close) anyway.
    case finalization
}

struct AgentLifecycleShutdownFailure: Equatable {
    let requestID: UUID
    let scope: AgentLifecycleShutdownScope
    let stage: AgentLifecycleShutdownStage
    let messages: [String]
    let timedOut: Bool
    /// Stage B of an app quit: every participant was prepared and finalized and the clean write was
    /// enqueued under a valid authorization; only its acknowledgement is missing.
    var awaitsCleanExitAcknowledgement = false
    /// Restart safely (review A P1-07): the relaunch helper's stop could not be proven AFTER its
    /// `arm` was sent, so it may still be alive and armed. No Retry, Cancel, or Quit Anyway is
    /// offered while ownership is retained, and any such answer is ignored. A helper never sent
    /// `arm` keeps the normal choices (review R1 B N3). Once that exact helper's stop is proven
    /// later, the prompt is replaced by the normal choices (Step 4b).
    var relaunchHelperUnresolved = false
    /// Restart safely (Step 4c): on an unresolved prompt, the app's Stage B `.safeRestart` request
    /// holds its current attempt's pre-arm witness, so the explicit `.exitMayReopen` is offered.
    /// Set only by the coordinator; meaningless (and ignored) without `relaunchHelperUnresolved`.
    var allowsUncertainRelaunchExit = false

    /// The choices this prompt may offer: while a possibly armed relaunch helper is unresolved,
    /// only the explicit uncertain exit (when admitted), otherwise none.
    var offeredChoices: [AgentLifecycleShutdownChoice] {
        guard !relaunchHelperUnresolved else {
            return offersUncertainRelaunchExit ? [.exitMayReopen] : []
        }
        return stage == .preparation ? [.retry, .cancel] : [.retry, .proceedAnyway]
    }

    /// Whether this prompt offers `.exitMayReopen` (an unresolved app Stage B prompt that was
    /// admitted by the coordinator).
    var offersUncertainRelaunchExit: Bool {
        relaunchHelperUnresolved && allowsUncertainRelaunchExit && scope == .application && stage == .finalization
    }

    /// The prompt as an admitted uncertain exit presents it: the pre-arm witness proves the clean
    /// write was acknowledged, and the restart-timeout text (no automatic restart, Try again) is
    /// replaced by the unconfirmed arm. Every other message and field is kept.
    @MainActor
    fileprivate func admittingUncertainRelaunchExit() -> AgentLifecycleShutdownFailure {
        AgentLifecycleShutdownFailure(
            requestID: requestID,
            scope: scope,
            stage: stage,
            messages: messages.map {
                $0 == AgentLifecycleShutdownCoordinator.restartTimeoutMessage
                    ? AgentLifecycleShutdownCoordinator.restartArmUnconfirmedMessage
                    : $0
            },
            timedOut: timedOut,
            awaitsCleanExitAcknowledgement: false,
            relaunchHelperUnresolved: relaunchHelperUnresolved,
            allowsUncertainRelaunchExit: allowsUncertainRelaunchExit
        )
    }

    /// The same prompt with `message` appended (and, when `unresolved`, no ordinary choices; the
    /// uncertain exit only when `allowsUncertainExit`). Every other field is carried forward.
    func appending(
        _ message: String,
        relaunchHelperUnresolved unresolved: Bool,
        allowsUncertainRelaunchExit allowsUncertainExit: Bool = false
    ) -> AgentLifecycleShutdownFailure {
        let isUnresolved = relaunchHelperUnresolved || unresolved
        return AgentLifecycleShutdownFailure(
            requestID: requestID,
            scope: scope,
            stage: stage,
            messages: messages + [message],
            timedOut: timedOut,
            awaitsCleanExitAcknowledgement: awaitsCleanExitAcknowledgement,
            relaunchHelperUnresolved: isUnresolved,
            allowsUncertainRelaunchExit: isUnresolved && (allowsUncertainRelaunchExit || allowsUncertainExit)
        )
    }
}

/// The outcome of abandoning the relaunch helper before a prompt, on Cancel, or on Quit Anyway.
enum AgentLifecycleRelaunchAbandonment: Equatable {
    /// No helper can arm or open anything: none is live, it confirmed `aborted`, or its exact exit
    /// was observed. Choices may be shown.
    case safe
    /// A helper's stop could not be proven, but the protocol proves its `arm` was never sent, so
    /// it can never open anything (review R1 B N3). The normal choices are shown; the helper stays
    /// retained and no fresh helper is spawned until its stop is proven.
    case unresolvedUnarmed(String)
    /// A helper's stop could not be proven after its `arm` was sent (it may be armed): it is
    /// retained, and no fresh helper, Retry, Cancel, or Quit Anyway may follow. Only the explicit
    /// uncertain exit may, when the request's pre-arm witness admits it (Step 4c).
    case unresolved(String)
}

/// The absolute instants of one R4 attempt's single deadline, passed to every relaunch hook
/// (review R1 A P1-07). Hooks recompute what is left after each await; nothing renews them.
struct AgentLifecycleRelaunchBudget: Equatable {
    /// Helper work (`ready`, the `armed` acknowledgement) ends here: the deadline minus the
    /// helper's cleanup reserve.
    let workExpiry: ContinuousClock.Instant
    /// Every helper stop ends here: the attempt's deadline itself.
    let cleanupExpiry: ContinuousClock.Instant
}

enum AgentLifecycleShutdownChoice: Equatable {
    case retry
    /// Stage A only.
    case cancel
    /// Stage B only.
    case proceedAnyway
    /// Restart safely, Stage B, only on an unresolved prompt admitted by the current attempt's
    /// pre-arm witness (Step 4c): completes the request without claiming the helper stopped (it may
    /// still reopen the app, or may not). Never a Cancel or an ordinary Quit Anyway; rejected on
    /// every other prompt.
    case exitMayReopen
}

enum AgentLifecycleShutdownPhase: Equatable {
    case preparing
    case preparationFailed
    case tearingDown
    case finalizationFailed
    case completed
    case cancelled
}

@MainActor
struct AgentLifecycleShutdownEnvironment {
    /// Participants a request of `scope` freezes, prepares, tears down, and finalizes.
    var participants: @MainActor (AgentLifecycleShutdownScope) -> [any AgentLifecycleShutdownParticipant]
    /// App quit: freezes every recovery lane (later lanes included); returns its release.
    var beginApplicationRecoveryFreeze: @MainActor () -> (@MainActor () -> Void)
    /// App quit: window layout preservation; `true` when written or the existing file is proven
    /// authoritative (restore gate), `false` when it could not be proven.
    var preserveLayout: @MainActor () async -> Bool
    /// App quit: joins released lanes' retirements; blockers for input left only in memory.
    var settleReleasedRecoveryInput: @MainActor () async -> [String]
    /// Enqueues an ordered unclean launch-mark write (`shutdownInProgress`, `running`) and returns
    /// its outcome task (`true` once durably written).
    var recordLaunchState: @MainActor (AgentRecoveryLaunchMark.State) -> Task<Bool, Never>
    /// App quit, after a successful final flush: a single-use clean-exit authorization.
    var authorizeCleanExit: @MainActor () -> UUID
    /// Enqueues the ordered clean write under an authorization; `false` when it failed or its
    /// authorization was no longer current when it began (nothing written).
    var recordCleanExit: @MainActor (UUID) -> Task<Bool, Never>
    /// Point of no return (app: termination flags; window: `beginClose`).
    var beginIrreversible: @MainActor (AgentLifecycleShutdownScope) -> Void
    /// Scope teardown after the participants' teardown (app: model polling, MCP servers).
    var tearDownScope: @MainActor (AgentLifecycleShutdownScope) async -> Void
    var presentFailure: @MainActor (AgentLifecycleShutdownFailure) async -> AgentLifecycleShutdownChoice
    /// Dismisses a failure prompt of a superseded request (its later choice is ignored).
    var dismissFailure: @MainActor (AgentLifecycleShutdownScope) -> Void
    /// Monotonic now; each attempt's expiry is captured from it synchronously.
    var now: @MainActor () -> ContinuousClock.Instant
    /// Sleeps until an absolute instant; cancellation throws.
    var sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void
    var deadline: Duration = .seconds(8)
    /// Restart safely (lossless restart Phase 4 §G); `nil` (production while gated) refuses it.
    var relaunch: AgentLifecycleRelaunchHooks?
}

/// The relaunch helper as seen by R4. Every hook is bounded by the helper's own v1 limits; none
/// extends the request's single deadline.
@MainActor
struct AgentLifecycleRelaunchHooks {
    /// Stage A (and a Stage B retry): abandons any earlier helper, spawns a fresh one, and waits for
    /// `ready` until the budget's work expiry (any failed helper stopped by its cleanup expiry).
    /// `nil` when ready; otherwise the blocker.
    var prepare: @MainActor (_ budget: AgentLifecycleRelaunchBudget) async -> String?
    /// Stage B, after the clean write: proof that every provider family and tool stopped. `nil`
    /// when proven; otherwise the blocker.
    var verifyAllStopped: @MainActor () async -> String?
    /// Stage B: arms the ready helper until the budget's work expiry. `nil` when armed; otherwise
    /// the blocker (the helper is stopped, by its cleanup expiry at the latest).
    var arm: @MainActor (_ budget: AgentLifecycleRelaunchBudget) async -> String?
    /// Ensures no helper is ready or armed: joins any in-flight hook (each bounded by its own
    /// budget's cleanup expiry), aborts, and waits for a correlated `aborted` or the helper's
    /// observed exit (requesting the exact child's kill) within what is left of the helper's one
    /// absolute cleanup budget. Called before every prompt, on Cancel, and on Quit Anyway.
    /// `.unresolved`/`.unresolvedUnarmed` when that proof is missing (a delivered signal is not proof).
    var abandon: @MainActor () async -> AgentLifecycleRelaunchAbandonment
    /// The helper's bounded cleanup (abort acknowledgement + exact-child kill). R4 reserves it out of
    /// its single deadline (review A P1-07): helper work ends at the budget's work expiry and every
    /// stop at its cleanup expiry, so `abandon` finishes, and the prompt appears, by the deadline.
    var cleanupReserve: Duration = ProcessRelaunchLimits.v1.cleanupReserve
    /// Lossless restart Step 4b, after an `.unresolved` `abandon`: waits for proof that the helper
    /// retained when called stopped (its exact child's observed exit, or its correlated `aborted`),
    /// then releases exactly that helper. `true` only then. Replay-safe (proof that arrived earlier
    /// counts) and cancellable (`false`); never inferred from end of input, a delivered signal, or a
    /// timeout, and never spawns, prepares, arms, retries, or renews a budget.
    var awaitRetainedHelperStop: @MainActor () async -> Bool = { false }
}

@MainActor
final class AgentLifecycleShutdownCoordinator {
    static let timeoutMessage = "Saving did not finish within 8 seconds."
    static let layoutFailureMessage = "The window layout could not be saved."
    static let cleanMarkFailureMessage = "RepoPrompt could not record that it quit cleanly."
    static let launchMarkFailureMessage = "RepoPrompt could not record that it is quitting."
    static let newWindowMessage = "A window opened while RepoPrompt was quitting. Try again to save it too."
    static let cleanExitAcknowledgementMessage = "Everything was saved and every session was stopped, but RepoPrompt could not confirm within 8 seconds that it recorded a clean exit."
    /// Defensive: a window that bypassed the admission seam was never prepared.
    static let unpreparedWindowMessage = "A window that was not prepared for quitting is open, so this quit cannot be recorded as clean."
    static let restartUnfinalizedWindowMessage = "An earlier window close did not finish saving, so RepoPrompt cannot restart safely. Quit instead."
    /// Restart safely ran out of time after the clean write was enqueued: neither that write nor
    /// the stopped-provider proof and helper arm are claimed (review B P2).
    static let restartTimeoutMessage = "RepoPrompt could not confirm within 8 seconds that it recorded a clean exit, that every agent stopped, and that it can reopen, so it won't restart automatically. Try again, or quit without restarting."
    /// Replaces `restartTimeoutMessage` on an admitted uncertain-exit prompt only (Step 4c review A
    /// F1 / B P2-1): its pre-arm witness proves the clean write and the stops, its helper may still
    /// reopen the app, and Retry / Quit Anyway are not offered, so that text would contradict it.
    static let restartArmUnconfirmedMessage = "RepoPrompt's restart helper did not confirm within 8 seconds whether it was armed."

    /// Restart safely (Step 4c): an in-memory control-flow witness, recorded synchronously
    /// immediately before an attempt invokes `relaunch.arm`, that this request's attempt had then
    /// acknowledged its final persistence and clean write, proven every family and tool stopped,
    /// and held a ready helper, while current and within its work deadline. Not persisted, not an
    /// authorization, and not a helper-stop claim. It is tied to the retained helper only through
    /// the relaunch driver's invariants (one serialized retained helper; no replacement while its
    /// stop is unresolved; every attempt clears the witness before it can arm): if the driver ever
    /// allows helper replacement, this association must be revisited.
    struct RelaunchArmSafetyProof: Equatable {
        let requestID: UUID
        let attemptID: UUID
    }

    @MainActor
    final class Request {
        let id = UUID()
        let scope: AgentLifecycleShutdownScope
        let reason: AgentRecoveryShutdownReason
        fileprivate(set) var phase: AgentLifecycleShutdownPhase = .preparing
        fileprivate(set) var attemptID = UUID()
        fileprivate(set) var participants: [any AgentLifecycleShutdownParticipant]
        /// Participants Stage A prepares (an app quit excludes windows already past their point of
        /// no return: their teardown is joined, never prepared or repeated).
        fileprivate var preparationParticipants: [any AgentLifecycleShutdownParticipant]
        fileprivate var deadlineTask: Task<Void, Never>?
        /// Identity of the current user attempt's deadline (initial request or explicit Retry).
        fileprivate var deadlineID = UUID()
        /// Monotonic expiry of the current user attempt, captured when the attempt started.
        fileprivate(set) var expiry: ContinuousClock.Instant?
        /// Restart safely: the attempt's full deadline (`expiry` plus the helper's cleanup reserve),
        /// by which every helper stop ends (review R1 A P1-07).
        fileprivate(set) var cleanupExpiry: ContinuousClock.Instant?
        /// Bumped by every participant joining in Stage A; an attempt whose participants changed
        /// never crosses the point of no return.
        fileprivate var participantRevision: UInt64 = 0
        fileprivate var attemptParticipantRevision: UInt64 = 0
        /// The single clean write once enqueued (app quit): pending, or acknowledged as written.
        /// Cleared only when it reports that nothing was written. Retry joins it; nothing else
        /// writes a clean mark while it is set.
        fileprivate(set) var cleanWrite: Task<Bool, Never>?
        /// The prompt last presented (a dismissed Stage B prompt is shown again unchanged).
        fileprivate var lastFailure: AgentLifecycleShutdownFailure?
        fileprivate var workTask: Task<Void, Never>?
        /// The single teardown, created at the point of no return.
        fileprivate(set) var teardownTask: Task<Void, Never>?
        fileprivate var endRecoveryFreeze: (@MainActor () -> Void)?
        fileprivate let forwardedVeto: (@MainActor () -> Bool)?
        fileprivate let completion: @MainActor (Bool) -> Void
        fileprivate(set) var isFinished = false
        /// Completed attempts by stage (test observability).
        fileprivate(set) var preparationAttempts = 0
        fileprivate(set) var finalizationAttempts = 0
        /// Restart safely: a helper is ready (prepared, not yet armed) for this request.
        fileprivate(set) var relaunchHelperReady = false
        /// Restart safely: the helper confirmed `armed` (the request then completes).
        fileprivate(set) var relaunchArmed = false
        /// Restart safely: prompts shown without choices because the helper's stop was unresolved
        /// (test observability; the request stays unfinished).
        fileprivate(set) var relaunchHelperUnresolvedPrompts = 0
        /// Identity of the prompt last presented: an answer to an earlier (dismissed) one is ignored.
        fileprivate var presentationID = UUID()
        /// Restart safely (Step 4b): waits for the unresolved helper's stop proof while the
        /// no-choice prompt is current. Cancelled by the next prompt and when the request ends.
        fileprivate var relaunchStopObservation: Task<Void, Never>?
        /// Restart safely: no-choice prompts replaced by the normal choices after the retained
        /// helper's stop was proven (test observability).
        fileprivate(set) var relaunchHelperStopRecoveries = 0
        /// Restart safely (Step 4c): the current attempt's pre-arm witness. Cleared when any attempt
        /// starts, after a `.safe`/`.unresolvedUnarmed` abandonment, on stop-proof recovery, and when
        /// the request ends; kept through a timeout while `arm` is in flight and an `.unresolved`
        /// abandonment.
        fileprivate(set) var relaunchArmSafetyProof: RelaunchArmSafetyProof?
        /// Restart safely (Step 4c): explicit uncertain exits taken (0 or 1; test observability).
        fileprivate(set) var relaunchUncertainExits = 0
        /// Restart safely (Step 4c): `.exitMayReopen` answers rejected outside an admitted prompt
        /// (test observability).
        fileprivate(set) var rejectedUncertainExitAnswers = 0

        fileprivate init(
            scope: AgentLifecycleShutdownScope,
            reason: AgentRecoveryShutdownReason,
            participants: [any AgentLifecycleShutdownParticipant],
            forwardedVeto: (@MainActor () -> Bool)?,
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            self.scope = scope
            self.reason = reason
            self.participants = participants
            preparationParticipants = participants
            self.forwardedVeto = forwardedVeto
            self.completion = completion
        }

        var isPastPointOfNoReturn: Bool {
            switch phase {
            case .tearingDown, .finalizationFailed, .completed: true
            case .preparing, .preparationFailed, .cancelled: false
            }
        }
    }

    private let environment: AgentLifecycleShutdownEnvironment
    private(set) var applicationRequest: Request?
    private(set) var windowRequests: [Int: Request] = [:]
    /// A window close ended with Close Anyway (its final flush did not succeed): this launch never
    /// proves a clean exit, so the next launch treats its sessions as uncertain.
    private(set) var hasUnfinalizedWindowClose = false
    /// Latched synchronously at the app quit's point of no return, before anything irreversible;
    /// never reset (the process exits). Once set, no window is admitted and no new request starts.
    private(set) var isApplicationAdmissionSealed = false

    init(environment: AgentLifecycleShutdownEnvironment) {
        self.environment = environment
    }

    // MARK: Queries

    func request(for scope: AgentLifecycleShutdownScope) -> Request? {
        switch scope {
        case .application: applicationRequest
        case let .window(windowID): windowRequests[windowID]
        }
    }

    /// An app quit owns every window until it completes or is cancelled.
    var isApplicationRequestActive: Bool {
        applicationRequest.map { !$0.isFinished } ?? false
    }

    /// The unfinished app quit's ID, for log correlation only (`nil` once it finished, so a log line
    /// never names an earlier, finished request).
    var activeApplicationRequestID: UUID? {
        applicationRequest.flatMap { $0.isFinished ? nil : $0.id }
    }

    /// Whether a window close of `windowID` is in progress (any stage, unfinished).
    func isWindowRequestActive(_ windowID: Int) -> Bool {
        windowRequests[windowID].map { !$0.isFinished } ?? false
    }

    // MARK: Requests

    /// Starts (or joins) the app quit. `reply` is called exactly once: `false` when Stage A was
    /// cancelled, `true` when the app may terminate. Returns `false` when an app quit is already
    /// in progress (its reply stays owned by the first request).
    @discardableResult
    func requestApplicationQuit(
        reason: AgentRecoveryShutdownReason = .appQuit,
        reply: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        // Only an app quit or Restart safely; Restart safely only while its hooks are composed.
        guard reason == .appQuit || (reason == .safeRestart && environment.relaunch != nil) else {
            // Refused before anything froze: the app keeps running (the reply is never lost).
            AgentLifecycleShutdownDiagnostics.requestCoalesced(
                current: activeApplicationRequestID,
                scope: .application,
                reason: reason,
                cause: "refused_reason_unavailable"
            )
            reply(false)
            return false
        }
        if isApplicationAdmissionSealed {
            // The quit that crossed the point of no return owns the (already given) reply.
            AgentLifecycleShutdownDiagnostics.requestCoalesced(
                current: activeApplicationRequestID,
                scope: .application,
                reason: reason,
                cause: "admission_sealed"
            )
            return false
        }
        if let current = applicationRequest, !current.isFinished {
            // Joins the request in progress: no new attempt, and its deadline is not extended.
            AgentLifecycleShutdownDiagnostics.requestCoalesced(
                current: current.id,
                scope: .application,
                reason: reason,
                cause: "in_progress:\(AgentLifecycleShutdownDiagnostics.phaseToken(current.phase))"
            )
            return false
        }
        let participants = environment.participants(.application)
        let request = Request(
            scope: .application,
            reason: reason,
            participants: participants,
            forwardedVeto: nil,
            completion: reply
        )
        applicationRequest = request
        AgentLifecycleShutdownDiagnostics.requested(
            request.id,
            scope: .application,
            reason: reason,
            participants: participants.count
        )
        // Synchronous freeze before any await: every lane (later ones included), every window.
        request.endRecoveryFreeze = environment.beginApplicationRecoveryFreeze()
        for participant in participants {
            participant.beginShutdownFreeze(requestID: request.id, ownsRecoveryFreeze: false)
        }
        // Absorb window closes: one still in Stage A is superseded (the app freeze above already
        // covers its owners); one past its point of no return keeps its single teardown, which
        // this quit joins instead of preparing or repeating it.
        var pastPointOfNoReturn: Set<ObjectIdentifier> = []
        for windowRequest in windowRequests.values where !windowRequest.isFinished {
            if windowRequest.isPastPointOfNoReturn {
                pastPointOfNoReturn.formUnion(windowRequest.participants.map { ObjectIdentifier($0) })
            } else {
                supersede(windowRequest)
            }
        }
        request.preparationParticipants = participants.filter { !pastPointOfNoReturn.contains(ObjectIdentifier($0)) }
        startPreparationAttempt(request)
        return true
    }

    /// Admission of a window's agent state, decided synchronously by the window registry before the
    /// window is registered or activated. `false` once the app quit crossed its point of no return:
    /// the window must stay an inert shell (never registered, restored, routed, or activated).
    /// During Stage A of an app quit it is frozen before anything else can reach it, joins the
    /// request, and invalidates the current attempt (Retry prepares it after the layout is preserved
    /// again; Cancel unfreezes it).
    func admitApplicationWindow(_ participant: any AgentLifecycleShutdownParticipant) -> Bool {
        guard !isApplicationAdmissionSealed else { return false }
        // Unsealed and unfinished means Stage A: the seal is latched before the point of no return.
        guard let request = applicationRequest, !request.isFinished else { return true }
        let identity = ObjectIdentifier(participant)
        guard !request.participants.contains(where: { ObjectIdentifier($0) == identity }) else { return true }
        participant.beginShutdownFreeze(requestID: request.id, ownsRecoveryFreeze: false)
        request.participants.append(participant)
        request.preparationParticipants.append(participant)
        request.participantRevision &+= 1
        return true
    }

    /// Starts a window close. `finish(true)` authorizes the actual close after Stage B; `finish(false)`
    /// leaves the window open (cancelled, vetoed, or superseded by an app quit). Returns `false`
    /// without side effects when an app quit or a close of this window is already in progress.
    @discardableResult
    func requestWindowClose(
        windowID: Int,
        forwardedVeto: @escaping @MainActor () -> Bool,
        finish: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard !isApplicationAdmissionSealed, !isApplicationRequestActive, !isWindowRequestActive(windowID) else {
            let cause = isApplicationAdmissionSealed
                ? "admission_sealed"
                : isApplicationRequestActive ? "application_quit_in_progress" : "close_in_progress"
            AgentLifecycleShutdownDiagnostics.requestCoalesced(
                current: isWindowRequestActive(windowID) ? windowRequests[windowID]?.id : activeApplicationRequestID,
                scope: .window(windowID),
                reason: .windowClose,
                cause: cause
            )
            return false
        }
        let request = Request(
            scope: .window(windowID),
            reason: .windowClose,
            participants: environment.participants(.window(windowID)),
            forwardedVeto: forwardedVeto,
            completion: finish
        )
        windowRequests[windowID] = request
        AgentLifecycleShutdownDiagnostics.requested(
            request.id,
            scope: request.scope,
            reason: request.reason,
            participants: request.participants.count
        )
        for participant in request.participants {
            participant.beginShutdownFreeze(requestID: request.id, ownsRecoveryFreeze: true)
        }
        startPreparationAttempt(request)
        return true
    }

    // MARK: Stage A

    private func startPreparationAttempt(_ request: Request) {
        let attempt = UUID()
        request.attemptID = attempt
        request.phase = .preparing
        request.relaunchArmSafetyProof = nil
        // Defensive: a participant that bypassed the admission seam joins like an admitted one.
        if request.scope == .application {
            for participant in unknownParticipants(request) {
                _ = admitApplicationWindow(participant)
            }
        }
        request.attemptParticipantRevision = request.participantRevision
        // A new user attempt (initial request or Retry): a fresh absolute deadline, captured now.
        let workBudget = armDeadline(request)
        AgentLifecycleShutdownDiagnostics.stageAStarted(
            request.id,
            attempt: attempt,
            attemptNumber: request.preparationAttempts + 1,
            participants: request.preparationParticipants.count,
            deadlineMilliseconds: Self.milliseconds(workBudget)
        )
        // A retried attempt runs only after the previous attempt's work settled (never twice
        // concurrently); its fresh deadline already covers that wait.
        let previous = request.workTask
        request.workTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, isCurrent(request, attempt: attempt, phase: .preparing) else { return }
            let blockers = await runPreparation(request, attempt: attempt)
            preparationFinished(request, attempt: attempt, blockers: blockers, timedOut: false)
        }
    }

    /// Stage A steps. Each side effect runs only while this attempt is still current: a cancelled,
    /// timed-out, or superseded attempt never writes a launch mark (which would land after Cancel's
    /// `running`) or prepares further participants.
    private func runPreparation(_ request: Request, attempt: UUID) async -> [String] {
        var blockers: [String] = []
        func stillCurrent() -> Bool {
            isCurrent(request, attempt: attempt, phase: .preparing)
        }
        if request.scope == .application {
            // Layout first: it is preserved before anything can be torn down.
            AgentLifecycleShutdownDiagnostics.stageAStep(request.id, attempt: attempt, step: "layout")
            if await !environment.preserveLayout() {
                blockers.append(Self.layoutFailureMessage)
            }
            guard stillCurrent() else { return blockers }
            // Verified before the point of no return: Stage B relies on this unclean mark (an
            // unconfirmed write is held by the attempt's deadline, never crossed).
            AgentLifecycleShutdownDiagnostics.stageAStep(request.id, attempt: attempt, step: "launch_mark")
            let marked = await environment.recordLaunchState(.shutdownInProgress).value
            guard stillCurrent() else { return blockers }
            if !marked {
                blockers.append(Self.launchMarkFailureMessage)
            }
            AgentLifecycleShutdownDiagnostics.stageAStep(request.id, attempt: attempt, step: "released_input")
            blockers += await environment.settleReleasedRecoveryInput()
        }
        let participants = request.preparationParticipants
        for (index, participant) in participants.enumerated() {
            guard stillCurrent() else { return blockers }
            AgentLifecycleShutdownDiagnostics.stageAStep(
                request.id,
                attempt: attempt,
                step: "participant",
                index: index,
                count: participants.count
            )
            blockers += await participant.shutdownPrepare(reason: request.reason).blockers
        }
        if blockers.isEmpty, request.reason == .safeRestart, let relaunch = environment.relaunch {
            // Stage A ends with a ready (never armed) helper, within what is left of the deadline.
            guard stillCurrent() else { return blockers }
            AgentLifecycleShutdownDiagnostics.stageAStep(request.id, attempt: attempt, step: "relaunch_prepare")
            if let blocker = await relaunch.prepare(relaunchBudget(request)) {
                blockers.append(blocker)
            } else if stillCurrent() {
                request.relaunchHelperReady = true
            }
        }
        return blockers
    }

    /// App-quit participants the request does not know. Empty whenever every window registered
    /// through the admission seam (a refused window is never registered).
    private func unknownParticipants(_ request: Request) -> [any AgentLifecycleShutdownParticipant] {
        let known = Set(request.participants.map { ObjectIdentifier($0) })
        return environment.participants(.application).filter { !known.contains(ObjectIdentifier($0)) }
    }

    /// Whether a participant joined (or bypassed the seam) since this attempt started.
    private func participantsChanged(_ request: Request) -> Bool {
        request.scope == .application
            && (request.participantRevision != request.attemptParticipantRevision || !unknownParticipants(request).isEmpty)
    }

    private func preparationFinished(_ request: Request, attempt: UUID, blockers: [String], timedOut: Bool) {
        // Late-completion fence: a timed-out, cancelled, superseded, or retried attempt is ignored.
        guard isCurrent(request, attempt: attempt, phase: .preparing) else {
            AgentLifecycleShutdownDiagnostics.staleCompletionIgnored(request.id, attempt: attempt, stage: .preparation, phase: request.phase)
            return
        }
        request.preparationAttempts += 1
        var blockers = blockers
        var timedOut = timedOut
        if blockers.isEmpty, isExpired(request) {
            // Finished after the captured expiry (the deadline task was delayed): never crosses
            // the point of no return late.
            blockers = [Self.timeoutMessage]
            timedOut = true
        }
        if participantsChanged(request) {
            // A window joined after this attempt started: it is not prepared and the layout this
            // attempt preserved does not include it. Retry covers both.
            blockers.append(Self.newWindowMessage)
        }
        AgentLifecycleShutdownDiagnostics.stageFinished(
            request.id,
            attempt: attempt,
            stage: .preparation,
            blockers: blockers.count,
            timedOut: timedOut
        )
        guard blockers.isEmpty else {
            request.deadlineTask?.cancel()
            request.deadlineTask = nil
            request.phase = .preparationFailed
            present(request, attempt: attempt, stage: .preparation, messages: blockers, timedOut: timedOut)
            return
        }
        // The same deadline keeps running: Stage B gets only what Stage A left of it.
        enterPointOfNoReturn(request)
    }

    private func cancel(_ request: Request) {
        guard !request.isFinished else { return }
        request.phase = .cancelled
        request.isFinished = true
        request.relaunchArmSafetyProof = nil
        request.deadlineTask?.cancel()
        request.deadlineTask = nil
        endRelaunchStopObservation(request)
        for participant in request.participants {
            participant.endShutdownFreeze(requestID: request.id)
        }
        request.endRecoveryFreeze?()
        request.endRecoveryFreeze = nil
        AgentLifecycleShutdownDiagnostics.ended(request.id, outcome: "cancelled", reply: false)
        if request.scope == .application {
            // Ordered after this attempt's `shutdownInProgress`: the app keeps running.
            _ = environment.recordLaunchState(.running)
        }
        if request.reason == .safeRestart, let relaunch = environment.relaunch {
            // Unfrozen now; the unarmed helper is told to stop (it never opens anything unarmed).
            request.relaunchHelperReady = false
            Task { @MainActor in _ = await relaunch.abandon() }
        }
        request.completion(false)
    }

    /// An app quit took over a window close still in Stage A: the window stays open, its prompt is
    /// dismissed, and its owners stay frozen by the app quit.
    private func supersede(_ request: Request) {
        guard !request.isFinished else { return }
        request.phase = .cancelled
        request.isFinished = true
        request.relaunchArmSafetyProof = nil
        request.deadlineTask?.cancel()
        request.deadlineTask = nil
        endRelaunchStopObservation(request)
        environment.dismissFailure(request.scope)
        for participant in request.participants {
            participant.endShutdownFreeze(requestID: request.id)
        }
        AgentLifecycleShutdownDiagnostics.ended(request.id, outcome: "superseded", reply: false)
        request.completion(false)
    }

    // MARK: Stage B

    private func enterPointOfNoReturn(_ request: Request) {
        // The forwarded delegate's veto is honored before anything irreversible happens.
        if let veto = request.forwardedVeto, !veto() {
            AgentLifecycleShutdownDiagnostics.vetoed(request.id)
            cancel(request)
            return
        }
        if request.scope == .application {
            // Synchronously, before anything irreversible: from here no window is admitted, so the
            // participants this quit prepared are the only ones it tears down and proves clean.
            isApplicationAdmissionSealed = true
        }
        request.phase = .tearingDown
        AgentLifecycleShutdownDiagnostics.stageBStarted(request.id, participants: request.participants.count)
        environment.beginIrreversible(request.scope)
        let participants = request.participants
        let reason = request.reason
        let scope = request.scope
        let environment = environment
        let requestID = request.id
        request.teardownTask = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for participant in participants {
                    group.addTask { @MainActor in
                        await participant.shutdownTearDown(reason: reason)
                    }
                }
            }
            await environment.tearDownScope(scope)
            AgentLifecycleShutdownDiagnostics.teardownFinished(requestID)
        }
        startFinalizationAttempt(request, freshDeadline: false)
    }

    /// `freshDeadline` only for an explicit Retry; the first finalization continues the deadline
    /// armed by the user attempt that passed Stage A.
    private func startFinalizationAttempt(_ request: Request, freshDeadline: Bool) {
        let attempt = UUID()
        request.attemptID = attempt
        request.phase = .tearingDown
        // A new attempt never inherits an earlier attempt's pre-arm witness (Step 4c).
        request.relaunchArmSafetyProof = nil
        let workBudget = freshDeadline || request.deadlineTask == nil ? armDeadline(request) : nil
        AgentLifecycleShutdownDiagnostics.finalizationStarted(
            request.id,
            attempt: attempt,
            attemptNumber: request.finalizationAttempts + 1,
            freshDeadlineMilliseconds: workBudget.map(Self.milliseconds)
        )
        let previous = request.workTask
        let teardown = request.teardownTask
        request.workTask = Task { @MainActor [weak self] in
            await previous?.value
            await teardown?.value
            guard let self, isCurrent(request, attempt: attempt, phase: .tearingDown) else { return }
            guard let outcome = await runFinalization(request, attempt: attempt) else {
                AgentLifecycleShutdownDiagnostics.staleCompletionIgnored(
                    request.id,
                    attempt: attempt,
                    stage: .finalization,
                    phase: request.phase
                )
                return
            }
            finalizationFinished(request, attempt: attempt, blockers: outcome.blockers, timedOut: outcome.timedOut)
        }
    }

    /// Stage B steps after the joined teardown; `nil` once the attempt is no longer current.
    private func runFinalization(
        _ request: Request,
        attempt: UUID
    ) async -> (blockers: [String], timedOut: Bool)? {
        func stillCurrent() -> Bool {
            isCurrent(request, attempt: attempt, phase: .tearingDown)
        }
        if let pending = request.cleanWrite {
            // Retry after a late acknowledgement: the proof behind the enqueued write is still
            // valid (admission is sealed; every participant stays torn down and frozen). Join it;
            // never finalize or write again while it may still land.
            let written = await awaitCleanWrite(pending, of: request)
            guard stillCurrent() else { return nil }
            if written {
                return await runRelaunchStep(request, attempt: attempt)
            }
            // Nothing was written: finalize and authorize afresh below.
        }
        var blockers: [String] = []
        for participant in request.participants {
            guard stillCurrent() else { return nil }
            blockers += await participant.shutdownFinalize().blockers
        }
        guard stillCurrent() else { return nil }
        guard blockers.isEmpty, request.scope == .application else { return (blockers, false) }
        // The clean mark is last: only before the captured expiry, with every admitted window
        // prepared and finalized, and never after a window close that ended unfinalized.
        if isExpired(request) {
            return ([Self.timeoutMessage], true)
        }
        if !unknownParticipants(request).isEmpty {
            return ([Self.unpreparedWindowMessage], false)
        }
        if hasUnfinalizedWindowClose {
            return request.reason == .safeRestart ? ([Self.restartUnfinalizedWindowMessage], false) : ([], false)
        }
        let write = environment.recordCleanExit(environment.authorizeCleanExit())
        request.cleanWrite = write
        let written = await awaitCleanWrite(write, of: request)
        // A late acknowledgement (no longer current) never completes the request by itself.
        guard stillCurrent() else { return nil }
        guard written else { return ([Self.cleanMarkFailureMessage], false) }
        return await runRelaunchStep(request, attempt: attempt)
    }

    /// Restart safely, after final persistence and the clean write: prove every family and tool
    /// stopped, then arm the helper (a fresh one when the Stage A helper was consumed or abandoned).
    /// A plain quit passes straight through.
    ///
    /// Precondition (Step 4c): called only by `runFinalization`, and only after this attempt's clean
    /// write reported `true` (a fresh write, or Retry joining the earlier acknowledged one). The
    /// pre-arm witness relies on it: `cleanWrite != nil` alone only means the write was enqueued.
    private func runRelaunchStep(_ request: Request, attempt: UUID) async -> (blockers: [String], timedOut: Bool)? {
        guard request.reason == .safeRestart, let relaunch = environment.relaunch else { return ([], false) }
        func stillCurrent() -> Bool {
            isCurrent(request, attempt: attempt, phase: .tearingDown)
        }
        if isExpired(request) { return ([Self.timeoutMessage], true) }
        if let blocker = await relaunch.verifyAllStopped() {
            return stillCurrent() ? ([blocker], false) : nil
        }
        guard stillCurrent() else { return nil }
        // Rechecked after every await: a delayed deadline task never lets this attempt arm late.
        if isExpired(request) { return ([Self.timeoutMessage], true) }
        if !request.relaunchHelperReady {
            if let blocker = await relaunch.prepare(relaunchBudget(request)) {
                return stillCurrent() ? ([blocker], false) : nil
            }
            guard stillCurrent() else { return nil }
            request.relaunchHelperReady = true
            if isExpired(request) { return ([Self.timeoutMessage], true) }
        }
        // Step 4c: the pre-arm witness, recorded synchronously with no suspension before `arm` is
        // entered. It stays through a timeout while `arm` is in flight (abandonment may then report
        // the helper possibly armed); the next attempt clears it.
        request.relaunchArmSafetyProof = RelaunchArmSafetyProof(requestID: request.id, attemptID: attempt)
        // The helper is consumed by this arm attempt whatever its outcome.
        request.relaunchHelperReady = false
        if let blocker = await relaunch.arm(relaunchBudget(request)) {
            return stillCurrent() ? ([blocker], false) : nil
        }
        // A stale attempt's late `armed` never mutates the request (a replacement attempt or prompt
        // owns it); it is resolved by `abandon` before any prompt.
        guard stillCurrent() else { return nil }
        // Armed: completion terminates the app; the helper opens the bundle only after this exact
        // process's verified exit.
        request.relaunchArmed = true
        return ([], false)
    }

    /// The clean write's outcome; one that wrote nothing is released so a later attempt can
    /// authorize again (whether or not the awaiting attempt is still current).
    private func awaitCleanWrite(_ write: Task<Bool, Never>, of request: Request) async -> Bool {
        let written = await write.value
        if !written, request.cleanWrite == write {
            request.cleanWrite = nil
        }
        return written
    }

    private func finalizationFinished(_ request: Request, attempt: UUID, blockers: [String], timedOut: Bool) {
        guard isCurrent(request, attempt: attempt, phase: .tearingDown) else {
            AgentLifecycleShutdownDiagnostics.staleCompletionIgnored(request.id, attempt: attempt, stage: .finalization, phase: request.phase)
            return
        }
        request.deadlineTask?.cancel()
        request.deadlineTask = nil
        request.finalizationAttempts += 1
        var blockers = blockers
        var timedOut = timedOut
        if blockers.isEmpty, isExpired(request) {
            // Finished after the captured expiry: never completes late.
            blockers = [Self.timeoutMessage]
            timedOut = true
        }
        if timedOut, request.cleanWrite != nil {
            // Not a preservation failure: only the clean write's acknowledgement is missing (or,
            // for Restart safely, possibly the stopped-provider proof or the helper arm after it).
            blockers = [request.reason == .safeRestart ? Self.restartTimeoutMessage : Self.cleanExitAcknowledgementMessage]
        }
        AgentLifecycleShutdownDiagnostics.stageFinished(
            request.id,
            attempt: attempt,
            stage: .finalization,
            blockers: blockers.count,
            timedOut: timedOut
        )
        guard blockers.isEmpty else {
            request.phase = .finalizationFailed
            present(request, attempt: attempt, stage: .finalization, messages: blockers, timedOut: timedOut)
            return
        }
        complete(request)
    }

    /// Quit (Close) Anyway: completes now, without waiting for any pending write. A window close
    /// records that this launch never proves a clean exit. An app quit leaves the launch file with
    /// the `shutdownInProgress` mark Stage A verified, unless a clean write enqueued under a still
    /// valid proof lands (which is then true).
    private func proceedAnyway(_ request: Request) {
        if case .window = request.scope {
            hasUnfinalizedWindowClose = true
        }
        // Restart safely: Quit Anyway quits without relaunching; the prompt was shown only after
        // `abandon` proved no helper is armed.
        complete(request)
    }

    private func complete(_ request: Request) {
        guard !request.isFinished else { return }
        request.phase = .completed
        request.isFinished = true
        endRelaunchStopObservation(request)
        // Discards only the coordinator's eligibility witness; the driver keeps helper ownership.
        request.relaunchArmSafetyProof = nil
        AgentLifecycleShutdownDiagnostics.ended(request.id, outcome: "completed", reply: true)
        request.completion(true)
    }

    /// Step 4c, the explicit uncertain exit: completes the request once, without claiming the helper
    /// stopped. Not `proceedAnyway`: no helper hook (abandon, prepare, arm), launch or clean mark,
    /// finalization, teardown, or deadline follows; the relaunch driver keeps owning the possibly
    /// armed helper until the process exits (it may reopen the app, or may not).
    private func exitWithUncertainRelaunch(_ request: Request) {
        guard !request.isFinished else { return }
        request.relaunchUncertainExits += 1
        complete(request)
    }

    /// Step 4c admission, checked when the prompt is built and again when its answer arrives: the
    /// app's Stage B `.safeRestart` request, failed in Stage B, holding the pre-arm witness of
    /// exactly this request and `attempt` (the attempt whose `arm` preceded the `.unresolved` stop).
    private func admitsUncertainRelaunchExit(_ request: Request, attempt: UUID, stage: AgentLifecycleShutdownStage) -> Bool {
        guard stage == .finalization, request.scope == .application, request.reason == .safeRestart,
              request.isPastPointOfNoReturn, isCurrent(request, attempt: attempt, phase: .finalizationFailed),
              let proof = request.relaunchArmSafetyProof
        else { return false }
        return proof == RelaunchArmSafetyProof(requestID: request.id, attemptID: attempt)
    }

    // MARK: Failure prompt

    private func present(
        _ request: Request,
        attempt: UUID,
        stage: AgentLifecycleShutdownStage,
        messages: [String],
        timedOut: Bool
    ) {
        var failure = AgentLifecycleShutdownFailure(
            requestID: request.id,
            scope: request.scope,
            stage: stage,
            messages: messages,
            timedOut: timedOut,
            awaitsCleanExitAcknowledgement: stage == .finalization && request.cleanWrite != nil
        )
        request.lastFailure = failure
        // A new prompt supersedes the previous one: its answer and its stop observation are stale.
        let presentation = UUID()
        request.presentationID = presentation
        endRelaunchStopObservation(request)
        let failedPhase: AgentLifecycleShutdownPhase = stage == .preparation ? .preparationFailed : .finalizationFailed
        let relaunch = request.reason == .safeRestart ? environment.relaunch : nil
        Task { @MainActor [weak self] in
            if let relaunch {
                // No ordinary choice is offered while a helper may be ready or armed (a lost
                // `armed` acknowledgement included): Retry uses a fresh helper; Quit Anyway
                // relaunches nothing.
                request.relaunchHelperReady = false
                request.relaunchArmed = false
                let abandonment = await relaunch.abandon()
                // Fenced before any state, observation, or prompt: a superseded presentation, a
                // retried or finished request never shows an obsolete prompt.
                guard let self, request.presentationID == presentation,
                      isCurrent(request, attempt: attempt, phase: failedPhase)
                else { return }
                switch abandonment {
                case .safe:
                    // No helper can open anything: the uncertain exit has nothing to disclose.
                    request.relaunchArmSafetyProof = nil
                case let .unresolvedUnarmed(reason):
                    // Review R1 B N3: `arm` was never sent, so the retained helper can never open
                    // anything. The normal choices stay; the driver keeps the helper and refuses a
                    // fresh one (Retry reports it) until the helper's stop is proven.
                    request.relaunchArmSafetyProof = nil
                    failure = failure.appending(reason, relaunchHelperUnresolved: false)
                    request.lastFailure = failure
                case let .unresolved(reason):
                    // Review A P1-07: the helper may still be alive and armed. Ownership stays with
                    // the relaunch driver; no Retry, Cancel, Quit Anyway, or fresh helper. Step 4c:
                    // only the explicit uncertain exit, when this attempt's pre-arm witness admits
                    // it; otherwise the prompt only informs and the request stays unfinished.
                    let admitted = admitsUncertainRelaunchExit(request, attempt: attempt, stage: stage)
                    if admitted {
                        // Only the known restart-timeout text is replaced; other diagnostics stay.
                        // The restored ordinary prompt (Step 4b) keeps the original `messages`,
                        // which are true once the helper's stop is proven.
                        failure = failure.admittingUncertainRelaunchExit()
                    }
                    failure = failure.appending(
                        reason,
                        relaunchHelperUnresolved: true,
                        allowsUncertainRelaunchExit: admitted
                    )
                    request.lastFailure = failure
                    // Step 4b: registered before the prompt is shown (proof that already arrived
                    // is replayed), so a later proof restores the choices.
                    observeRelaunchHelperStop(
                        request,
                        attempt: attempt,
                        stage: stage,
                        messages: messages,
                        timedOut: timedOut,
                        presentation: presentation,
                        relaunch: relaunch
                    )
                }
            }
            guard let self else { return }
            // The same presentation may be shown again (Step 4c): no hook, observation, or deadline
            // is repeated, so the stop observation of this presentation stays valid.
            while true {
                AgentLifecycleShutdownDiagnostics.dialogPresented(failure, attempt: attempt, presentation: presentation)
                let choice = await environment.presentFailure(failure)
                // An answer to a dismissed or replaced prompt is ignored.
                let isCurrentAnswer = request.presentationID == presentation
                    && isCurrent(request, attempt: attempt, phase: failedPhase)
                AgentLifecycleShutdownDiagnostics.dialogChoice(
                    failure,
                    presentation: presentation,
                    choice: choice,
                    stale: !isCurrentAnswer
                )
                guard isCurrentAnswer else { return }
                if failure.relaunchHelperUnresolved {
                    if failure.offersUncertainRelaunchExit {
                        if choice == .exitMayReopen, admitsUncertainRelaunchExit(request, attempt: attempt, stage: stage) {
                            exitWithUncertainRelaunch(request)
                            return
                        }
                        // Keep Waiting, a dismissal, or an ordinary choice: ignored, and the same
                        // prompt is shown again so waiting never removes the only way out.
                        request.relaunchHelperUnresolvedPrompts += 1
                        continue
                    }
                    // No choice was offered (no pre-arm witness): any answer is ignored.
                    request.relaunchHelperUnresolvedPrompts += 1
                    return
                }
                guard choice != .exitMayReopen else {
                    // Never offered here: rejected, never reinterpreted as Cancel or Quit Anyway.
                    // The same prompt (and its ordinary choices) is shown again.
                    request.rejectedUncertainExitAnswers += 1
                    continue
                }
                handle(choice, for: request, stage: stage, attempt: attempt)
                return
            }
        }
    }

    /// Restart safely (lossless restart Step 4b): while the no-choice prompt of `presentation` is
    /// current, waits for the relaunch driver to prove that the retained (possibly armed) helper
    /// stopped and to release it. Then that prompt is dismissed and the same stage's failure is
    /// presented again with its normal choices (`abandon` is then `.safe`). Nothing else follows
    /// from the proof: no Retry, quit, fresh helper, persistence, clean mark, or renewed deadline;
    /// only an explicit Retry starts a fresh attempt. A stale or duplicate proof does nothing.
    private func observeRelaunchHelperStop(
        _ request: Request,
        attempt: UUID,
        stage: AgentLifecycleShutdownStage,
        messages: [String],
        timedOut: Bool,
        presentation: UUID,
        relaunch: AgentLifecycleRelaunchHooks
    ) {
        guard request.presentationID == presentation, !request.isFinished else { return }
        endRelaunchStopObservation(request)
        let failedPhase: AgentLifecycleShutdownPhase = stage == .preparation ? .preparationFailed : .finalizationFailed
        request.relaunchStopObservation = Task { @MainActor [weak self] in
            guard await relaunch.awaitRetainedHelperStop(), !Task.isCancelled, let self else { return }
            guard request.presentationID == presentation, isCurrent(request, attempt: attempt, phase: failedPhase) else { return }
            request.relaunchStopObservation = nil
            request.relaunchHelperStopRecoveries += 1
            // Invalidated before the dismissal can resume the old prompt's answer: a late
            // `.exitMayReopen` to it loses to this proof (Step 4c). The proven stop also ends the
            // uncertainty the witness admitted.
            request.presentationID = UUID()
            request.relaunchArmSafetyProof = nil
            environment.dismissFailure(request.scope)
            present(request, attempt: attempt, stage: stage, messages: messages, timedOut: timedOut)
        }
    }

    private func endRelaunchStopObservation(_ request: Request) {
        request.relaunchStopObservation?.cancel()
        request.relaunchStopObservation = nil
    }

    private func handle(
        _ choice: AgentLifecycleShutdownChoice,
        for request: Request,
        stage: AgentLifecycleShutdownStage,
        attempt: UUID
    ) {
        switch (stage, choice) {
        case (.preparation, .retry):
            startPreparationAttempt(request)
        case (.preparation, .cancel), (.preparation, .proceedAnyway):
            // Stage A never proceeds without proof; anything but Retry cancels.
            cancel(request)
        case (.finalization, .retry):
            startFinalizationAttempt(request, freshDeadline: true)
        case (.finalization, .proceedAnyway):
            proceedAnyway(request)
        case (.finalization, .cancel):
            // Stage B has no Cancel: the same prompt is shown again.
            present(
                request,
                attempt: attempt,
                stage: .finalization,
                messages: request.lastFailure?.messages ?? [Self.timeoutMessage],
                timedOut: request.lastFailure?.timedOut ?? false
            )
        case (_, .exitMayReopen):
            // Filtered by `present` (admitted only on an unresolved prompt, rejected elsewhere);
            // never reinterpreted as Cancel or Quit Anyway.
            break
        }
    }

    // MARK: Fences and deadlines

    private func isCurrent(_ request: Request, attempt: UUID, phase: AgentLifecycleShutdownPhase) -> Bool {
        !request.isFinished && request.attemptID == attempt && request.phase == phase
            && self.request(for: request.scope) === request
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }

    private func isExpired(_ request: Request) -> Bool {
        guard let expiry = request.expiry else { return false }
        return environment.now() >= expiry
    }

    /// The current attempt's absolute relaunch budget (never extended): helper work ends at the
    /// work expiry, every helper stop at the attempt's full deadline.
    private func relaunchBudget(_ request: Request) -> AgentLifecycleRelaunchBudget {
        let now = environment.now()
        let workExpiry = request.expiry ?? now
        return AgentLifecycleRelaunchBudget(
            workExpiry: workExpiry,
            cleanupExpiry: max(request.cleanupExpiry ?? workExpiry, workExpiry)
        )
    }

    /// One absolute deadline per user attempt. Its expiry is captured synchronously (a delayed
    /// deadline task never extends it); the task never joins the attempt's work and, on expiry,
    /// times out whichever stage is then current (Stage A, or Stage B on the remainder).
    /// Returns the attempt's effective work budget (`expiry - start`: the deadline minus Restart
    /// safely's cleanup reserve), for the log only.
    private func armDeadline(_ request: Request) -> Duration {
        request.deadlineTask?.cancel()
        let deadlineID = UUID()
        request.deadlineID = deadlineID
        // Restart safely: the helper's bounded cleanup is reserved inside the same deadline, so the
        // work (and every helper hook) ends early enough for `abandon` to finish by the deadline.
        let reserve = request.reason == .safeRestart ? (environment.relaunch?.cleanupReserve ?? .zero) : .zero
        let start = environment.now()
        let expiry = start + max(environment.deadline - reserve, .zero)
        request.expiry = expiry
        request.cleanupExpiry = max(start + environment.deadline, expiry)
        let sleepUntil = environment.sleepUntil
        request.deadlineTask = Task { @MainActor [weak self] in
            do {
                try await sleepUntil(expiry)
            } catch {
                return
            }
            guard let self, request.deadlineID == deadlineID, !request.isFinished else { return }
            AgentLifecycleShutdownDiagnostics.deadlineFired(request.id, attempt: request.attemptID, phase: request.phase)
            switch request.phase {
            case .preparing:
                preparationFinished(request, attempt: request.attemptID, blockers: [Self.timeoutMessage], timedOut: true)
            case .tearingDown:
                // `finalizationFinished` reports a pending clean write as a missing acknowledgement.
                finalizationFinished(request, attempt: request.attemptID, blockers: [Self.timeoutMessage], timedOut: true)
            case .preparationFailed, .finalizationFailed, .completed, .cancelled:
                break
            }
        }
        return expiry - start
    }
}
