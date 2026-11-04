// Runner-side adapter over the shared Phase 1b dispatch-evidence contract
// (`AgentRecoveryDispatchEvidence`) for the Claude native, ACP, and headless provider routes.
//
// It adds only what a runner needs around one provider handoff:
// - recording/attaching the existing run attempt (`AgentRunOwnership.attemptID`) before the
//   provider is invoked;
// - remembering whether the provider boundary was actually entered, so a scope that ends without
//   reaching it settles the same intents back to `queued` (`noteNoHandoff`), while a scope that
//   did reach it without affirmative provider evidence records `deliveryUnknown`. A no-handoff
//   report after the boundary was entered is downgraded to uncertainty, never to a retryable
//   queue entry.
//
// Acceptance is reported only by the route-specific affirmative provider evidence (Claude: the
// expected turn's `turnCompleted(.completed)`; ACP: the `session/prompt` response; headless: model
// output on the provider stream). Transport writes, stream creation, `didSend`, and run start are
// never acceptance.

import Foundation
import os

@MainActor
final class AgentProviderHandoff {
    /// Committed dispatch evidence; `nil` while a run-start handoff is still deferred.
    private var committedEvidence: AgentRecoveryDispatchEvidence?
    /// Input this handoff carries (validated; all durable or all untracked).
    private let constituents: [AgentQueuedInputIdentity]
    /// Observation of a deferred handoff (nothing written: its intents stay `queued`).
    private var deferredObservation: AgentRecoveryDispatchEvidence.Observation = .open
    /// Run attempt a deferred handoff commits under (`attachRunAttempt`).
    private var boundOwnership: AgentRunOwnership?
    private var boundProcessRunID: UUID?
    /// Exact pending-handoff snapshot the provider text prepends, not yet attached to its carrier.
    private var unattachedPendingHandoff: AgentRecoveryPendingHandoffSnapshot?
    /// The provider boundary (transport write / provider call) was entered.
    private(set) var handoffStarted = false
    /// Run attempt this handoff's delivery attempts are recorded against.
    private(set) var runAttemptID: UUID?
    /// Staged next-turn input riding on this handoff's provider text.
    private(set) var carriedStagedInput = AgentCarriedStagedInput()
    /// The one stage-delivery outcome reported for `carriedStagedInput` (see `reportStagedInput`).
    private(set) var reportedStagedInputDisposition: AgentStagedInputDisposition?
    private var stagedInputReporter: ((AgentCarriedStagedInput, AgentStagedInputDisposition) -> Void)?
    /// User item whose turn a run attempt carrying this input is attributed to (F1): the last
    /// constituent with a user item. Durable input always names one (`AgentRecoveryIntent.userItemID`);
    /// `nil` only for untracked input without a bubble, which keeps the legacy terminal-time
    /// attribution. Never pinned to another transcript item.
    private(set) var attributedUserItemID: UUID?

    private init(evidence: AgentRecoveryDispatchEvidence, constituents: [AgentQueuedInputIdentity], runAttemptID: UUID?) {
        committedEvidence = evidence
        self.constituents = constituents
        self.runAttemptID = runAttemptID
    }

    private init(deferred constituents: [AgentQueuedInputIdentity]) {
        self.constituents = constituents
    }

    /// The committed dispatch evidence (a committed handoff only; tests and diagnostics).
    var evidence: AgentRecoveryDispatchEvidence {
        guard let committedEvidence else {
            preconditionFailure("AgentProviderHandoff.evidence read before its dispatch was committed")
        }
        return committedEvidence
    }

    /// Whether the dispatch commit was written (always true for `begin`; set by `commitDispatch`
    /// for a deferred run-start handoff).
    var isCommitted: Bool {
        committedEvidence != nil
    }

    var isDurable: Bool {
        committedEvidence?.isDurable ?? constituents.allSatisfy(\.isDurable)
    }

    var observation: AgentRecoveryDispatchEvidence.Observation {
        committedEvidence?.observation ?? deferredObservation
    }

    /// Immutable identity of a committed durable dispatch (Phase 4 history baseline): its first
    /// delivery attempt ID, run attempt, and ordered local user items. `nil` when untracked or not
    /// yet committed (no durable dispatch exists to bind a baseline to).
    var dispatchBaselineIdentity: AgentDispatchBaselineIdentity? {
        guard let evidence = committedEvidence, evidence.isDurable, let first = evidence.receipts.first else {
            return nil
        }
        // The baseline keeps its existing item list; completeness is stated, never inferred from
        // a list that silently dropped a constituent without a user item.
        let userItemIDs = constituents.compactMap(\.userItemID)
        return AgentDispatchBaselineIdentity(
            dispatchID: first.attemptID,
            runAttemptID: runAttemptID,
            userItemIDs: userItemIDs,
            hasCompleteUserItems: !userItemIDs.isEmpty && userItemIDs.count == constituents.count
                && Set(userItemIDs).count == userItemIDs.count
        )
    }

    /// Run-start handoff (adopted plan §5): validated now, committed later by `commitDispatch`,
    /// after provider preparation/bootstrap that can create the pending-handoff prefix and once
    /// that exact prefix is attached to the still-`queued` carrier. Nothing is written here.
    static func prepareRunStart(
        session: AgentTabSession,
        constituents: [AgentQueuedInputIdentity]
    ) -> Result<AgentProviderHandoff, AgentRecoveryAdmissionFailure> {
        if let refusal = AgentRecoveryDispatchEvidence.dispatchRefusal(session: session, constituents: constituents) {
            return .failure(refusal)
        }
        let handoff = AgentProviderHandoff(deferred: constituents)
        handoff.attributedUserItemID = attributedUserItemID(of: constituents)
        if handoff.isDurable {
            handoff.heldLane = session.recoveryLane
            // F1: the issuing lane knows this input is owned by a runner that owes its settlement.
            session.recoveryLane?.noteDeferredRunStartHandoffPrepared(intentIDs: handoff.durableIntentIDs)
        }
        return .success(handoff)
    }

    private static func attributedUserItemID(of constituents: [AgentQueuedInputIdentity]) -> UUID? {
        constituents.last(where: { $0.userItemID != nil })?.userItemID
    }

    private var durableIntentIDs: [UUID] {
        isDurable ? constituents.compactMap(\.intentID) : []
    }

    /// Before-handoff step. With `ownership`, the existing run attempt is recorded first (durable
    /// input only) and every delivery attempt carries its ID. Without it (common pre-runner gate),
    /// the runner attaches the run attempt via `attachRunAttempt` before invoking the provider.
    /// The caller re-runs its own synchronous freshness checks after this returns.
    static func begin(
        session: AgentTabSession,
        constituents: [AgentQueuedInputIdentity],
        ownership: AgentRunOwnership?,
        processRunID: UUID?,
        authorization: AgentRecoveryDispatchAuthorization = .liveQueue
    ) async -> Result<AgentProviderHandoff, AgentRecoveryAdmissionFailure> {
        let result = if let ownership {
            await AgentRecoveryDispatchEvidence.begin(
                session: session,
                constituents: constituents,
                ownership: ownership,
                processRunID: processRunID,
                authorization: authorization
            )
        } else {
            await AgentRecoveryDispatchEvidence.begin(
                session: session,
                constituents: constituents,
                runAttemptID: nil,
                authorization: authorization
            )
        }
        return result.map {
            let handoff = AgentProviderHandoff(evidence: $0, constituents: constituents, runAttemptID: ownership?.attemptID)
            handoff.attributedUserItemID = attributedUserItemID(of: constituents)
            handoff.recordPendingHandoffAtCommit(session)
            return handoff
        }
    }

    /// The session's stageable pending-handoff payload when this handoff's dispatch was committed.
    /// That payload was retained for a later send (not carried by this input); any other one was
    /// created after the commit.
    private var stageablePayloadAtCommit: String?

    private func recordPendingHandoffAtCommit(_ session: AgentTabSession) {
        stageablePayloadAtCommit = session.pendingHandoff.hasStageablePayload ? session.pendingHandoff.payload : nil
    }

    /// Whether preparation created a pending-handoff payload after this durable input's dispatch
    /// commit (late bootstrap work): sending would deliver the input without the history its new
    /// conversation needs, while its intent records no prefix. The caller blocks the send.
    func pendingHandoffCreatedAfterCommit(in session: AgentTabSession) -> Bool {
        guard isDurable, isCommitted, session.pendingHandoff.hasStageablePayload else { return false }
        return session.pendingHandoff.payload != stageablePayloadAtCommit
    }

    /// Why a dispatch commit did not happen. The caller must not hand off; the input stays saved.
    enum CommitFailure: Error, Equatable {
        /// A deferred handoff was never bound to its run attempt.
        case runAttemptNotBound
        /// The pending-handoff prefix could not be attached to the carrier intent.
        case pendingHandoffNotAttached(AgentRecoveryControllerFailure)
        /// A prefix was staged after this handoff's dispatch was already committed (late bootstrap
        /// work): sending would deliver a prefix its durable intent does not record.
        case pendingHandoffAfterCommit
        /// The deferred handoff was already settled (no handoff) before its commit.
        case alreadySettled
        case dispatch(AgentRecoveryAdmissionFailure)
        /// The pending-handoff prefix could not be staged with a durable payload ID.
        case pendingHandoffNotSaved

        /// Fixed, content-free reason for logs (several cases share `userText`).
        var diagnosticReason: String {
            switch self {
            case .runAttemptNotBound: "run_attempt_not_bound"
            case .pendingHandoffNotAttached: "pending_handoff_not_attached"
            case .pendingHandoffAfterCommit: "pending_handoff_after_commit"
            case .alreadySettled: "already_settled"
            case let .dispatch(failure): failure.diagnosticReason
            case .pendingHandoffNotSaved: "pending_handoff_not_saved"
            }
        }

        /// User-facing explanation; the input stays saved in every case.
        var userText: String {
            switch self {
            case .pendingHandoffNotAttached, .pendingHandoffAfterCommit, .pendingHandoffNotSaved:
                AgentPendingHandoffDispatchStaging.blockedReason
            case .runAttemptNotBound, .alreadySettled:
                AgentProviderHandoff.sessionChangedBeforeHandoffMessage
            case let .dispatch(failure):
                failure.dispatchFailureText
            }
        }
    }

    /// The exact pending-handoff snapshot this handoff's provider text prepends. A deferred durable
    /// handoff attaches it to its carrier before committing; a committed one cannot carry it
    /// (`commitDispatch` then fails). Untracked input records nothing.
    func notePendingHandoff(_ snapshot: AgentRecoveryPendingHandoffSnapshot) {
        guard isDurable else { return }
        unattachedPendingHandoff = snapshot
    }

    /// The dispatch commit, immediately before the route's final checks (adopted plan §5 order:
    /// stage payload → attach to the queued carrier → ensure the run attempt and commit
    /// `dispatching` → final check → handoff). A committed handoff succeeds unless a prefix was
    /// noted after its commit.
    func commitDispatch(session: AgentTabSession) async -> Result<Void, CommitFailure> {
        if committedEvidence != nil {
            return unattachedPendingHandoff == nil ? .success(()) : .failure(.pendingHandoffAfterCommit)
        }
        guard deferredObservation == .open else { return .failure(.alreadySettled) }
        guard let ownership = boundOwnership else { return .failure(.runAttemptNotBound) }
        // Attach and commit through the lane that validated this input; never a successor lane.
        let issuingLaneIsCurrent = { [weak self] in
            guard let self, isDurable else { return true }
            return heldLane != nil && session.recoveryLane === heldLane
        }
        if let snapshot = unattachedPendingHandoff {
            guard let carrierID = constituents.first?.intentID, issuingLaneIsCurrent(), let lane = heldLane else {
                return .failure(.pendingHandoffNotAttached(.retired))
            }
            if case let .failure(failure) = await lane.attachPendingHandoff(intentID: carrierID, snapshot: snapshot) {
                return .failure(.pendingHandoffNotAttached(failure))
            }
            unattachedPendingHandoff = nil
        }
        guard issuingLaneIsCurrent() else { return .failure(.dispatch(.refused(.laneRetired))) }
        switch await AgentRecoveryDispatchEvidence.begin(
            session: session,
            constituents: constituents,
            ownership: ownership,
            processRunID: boundProcessRunID
        ) {
        case let .failure(failure):
            return .failure(.dispatch(failure))
        case let .success(evidence):
            committedEvidence = evidence
            runAttemptID = ownership.attemptID
            recordPendingHandoffAtCommit(session)
            heldLane?.noteDeferredRunStartHandoffCommitted(intentIDs: durableIntentIDs)
            return .success(())
        }
    }

    /// Records the run attempt and attaches every durable delivery attempt to it. Untracked
    /// handoffs and already-attached ones succeed without writing. On failure the caller must not
    /// hand off (report `noteNoHandoff`).
    func attachRunAttempt(
        ownership: AgentRunOwnership,
        processRunID: UUID?,
        session: AgentTabSession
    ) async -> Result<Void, AgentRecoveryControllerFailure> {
        guard let evidence = committedEvidence else {
            // Deferred: bind only; `commitDispatch` records the run attempt and dispatch together.
            if let boundOwnership, boundOwnership.attemptID != ownership.attemptID {
                return .failure(.store(.runAttemptConflict(ownership.attemptID)))
            }
            boundOwnership = ownership
            boundProcessRunID = processRunID
            runAttemptID = ownership.attemptID
            return .success(())
        }
        guard evidence.isDurable else {
            // Untracked (inactive admission): nothing to write; the attempt still scopes the send.
            if runAttemptID == nil {
                runAttemptID = ownership.attemptID
            }
            return .success(())
        }
        if let runAttemptID {
            return runAttemptID == ownership.attemptID
                ? .success(())
                : .failure(.store(.runAttemptConflict(ownership.attemptID)))
        }
        guard let binding = evidence.receipts.first?.intent.binding,
              let lane = session.recoveryLane,
              lane.binding == binding
        else {
            return .failure(.retired)
        }
        guard AgentRecoveryDispatchEvidence.ownershipIsCompatible(ownership, with: session) else {
            return .failure(.store(.runAttemptConflict(ownership.attemptID)))
        }
        if case let .failure(failure) = await lane.ensureRunAttempt(
            ownership: ownership,
            processRunID: processRunID,
            transcriptTurnID: AgentRecoveryDispatchEvidence.executionTurnID(of: constituents.first, in: session),
            providerKindRaw: ownership.providerKindRaw,
            // The run-start dispatch commit precedes the run's first provider write: its mark.
            runtimeRegistrationRaw: ownership.runtimeRegistrationRaw
        ) {
            return .failure(failure)
        }
        for receipt in evidence.receipts {
            if case let .failure(failure) = await lane.attachDeliveryAttempt(
                attemptID: receipt.attemptID,
                ownership: ownership
            ) {
                return .failure(failure)
            }
        }
        runAttemptID = ownership.attemptID
        return .success(())
    }

    /// The final physical-handoff check (R06). Call immediately before the provider boundary, with
    /// no suspension between it and the provider call. `false` when the dispatching lane retired or
    /// reset preparation froze it since the commit: the same intents are settled back to `queued`
    /// (pre-handoff), the carried staged input is released, and the caller must not hand off.
    func enterProviderBoundary(in session: AgentTabSession) -> Bool {
        guard let evidence = committedEvidence, unattachedPendingHandoff == nil,
              evidence.isValidForHandoff(in: session)
        else {
            // Never hand off uncommitted input, or a prefix its durable intent does not record.
            noteNoHandoff(message: Self.sessionChangedBeforeHandoffMessage)
            reportStagedInput(stagedInputDisposition(sent: false))
            return false
        }
        handoffStarted = true
        evidence.noteHandoffBegan()
        // The run attempt's terminal outcome now belongs to this input's turn (steering included).
        if let runAttemptID, let attributedUserItemID {
            session.noteRunAttemptInput(attemptID: runAttemptID, userItemID: attributedUserItemID)
        }
        return true
    }

    /// Affirmative provider acceptance (refines uncertainty; never downgraded). Late acceptance also
    /// settles the exact staged input this handoff carried as sent.
    func noteAccepted() {
        guard let evidence = committedEvidence else { return }
        evidence.noteAccepted()
        reportStagedInput(.sent)
    }

    func noteDeliveryUnknown() {
        guard let evidence = committedEvidence else {
            // Uncommitted input never reached a provider boundary.
            noteDeferredOutcome(.notHandedOff, message: nil)
            return
        }
        evidence.noteDeliveryUnknown()
    }

    /// Proven pre-handoff only: once the boundary was entered this records uncertainty instead.
    func noteNoHandoff(message: String? = nil) {
        guard let evidence = committedEvidence else {
            noteDeferredOutcome(.notHandedOff, message: message)
            return
        }
        if handoffStarted {
            evidence.noteDeliveryUnknown()
        } else {
            evidence.noteNoHandoff(message: message)
        }
    }

    /// A deferred handoff wrote nothing: its intents are still `queued` with no attempt. The issuing
    /// lane records the settlement (with `message`) and signals waiters on this exact handoff (F1).
    private func noteDeferredOutcome(_ outcome: AgentRecoveryDispatchEvidence.Observation, message: String?) {
        guard deferredObservation == .open else { return }
        deferredObservation = outcome
        if outcome != .open {
            heldLane?.noteDeferredRunStartHandoffNotHandedOff(intentIDs: durableIntentIDs, message: message)
        }
        // No commit can follow a settled deferred handoff (`commitDispatch` refuses it): an explicit
        // recovery action carried here is fenced and settles as not handed off.
        if outcome != .open, let action = constituents.first?.actionAuthorization {
            heldLane?.recoveryCoordinator?.noteRecoveryActionSubmissionEnded(action)
        }
    }

    /// Held-input reason for a run's own input that is not re-queued after its run ended. Neutral on
    /// delivery: the presented delivery state says whether it may have reached the agent.
    static let runEndedHoldReason = "Its run ended, so it is no longer queued."

    /// The runner drops this handoff's input without re-projecting it; its durable intents are
    /// presented as held input (see `AgentRecoveryDispatchEvidence.holdForUser`).
    func holdForUser(reason: String = AgentProviderHandoff.runEndedHoldReason) {
        // One explanation per handoff: the first (most specific) reason wins.
        guard !heldForUser else { return }
        heldForUser = true
        guard let evidence = committedEvidence else {
            let intentIDs = constituents.compactMap(\.intentID)
            guard !intentIDs.isEmpty, let heldLane else { return }
            heldLane.noteProjectionRemoved(intentIDs: intentIDs, reason: reason)
            return
        }
        evidence.holdForUser(reason: reason)
    }

    /// Lane a deferred handoff's held input is presented through (the lane that validated it).
    private weak var heldLane: AgentRecoverySessionLane?
    private var heldForUser = false

    // MARK: Document boundary authority (DOC-02)

    /// Final document authority of input carrying document references; `nil` for input without any.
    private var documentAuthority: AgentDocumentBoundaryAuthority?
    /// The reason this handoff was refused at its provider boundary for its documents (settled).
    private(set) var documentRefusalReason: String?

    /// Installs the document authority the provider's send seam consults at its final boundary.
    func installDocumentAuthority(_ authority: AgentDocumentBoundaryAuthority?) {
        documentAuthority = authority
    }

    /// The final document check at the provider's send boundary (DOC-02). Call synchronously at the
    /// boundary, after every provider startup/preparation await and with none before the write: just
    /// before `enterProviderBoundary`, and again inside a transport's pre-byte write admission.
    /// Returns the refusal when a referenced original no longer passes preflight: nothing is handed
    /// off (proven not written once the boundary was entered), carried staged input is released,
    /// durable input is held with the reason, and the route's settlement runs exactly once (it
    /// returns untracked input to the composer). `nil` admits the handoff. A refusal is sticky: a
    /// repeated check (a transport re-entering write admission) returns the same reason and never
    /// admits or settles the already-settled input again.
    func documentRefusalAtProviderBoundary() -> String? {
        if let documentRefusalReason { return documentRefusalReason }
        guard let authority = documentAuthority, let reason = authority.refusal() else { return nil }
        documentAuthority = nil
        documentRefusalReason = reason
        if handoffStarted {
            noteProvenNotWritten(message: reason)
        } else {
            noteNoHandoff(message: reason)
        }
        reportStagedInput(stagedInputDisposition(sent: false))
        if isDurable {
            holdForUser(reason: reason)
        }
        authority.settleRefused(reason)
        return reason
    }

    /// A dispatch commit (or the pending-handoff staging before it) failed: nothing was handed off,
    /// the carried staged input is released, and the durable input is presented as held with the
    /// failure's explanation. Its intents stay saved (`queued` before a commit).
    func blockBeforeHandoff(_ failure: CommitFailure) {
        AgentDeliveryRecordDiagnostics.blockedBeforeHandoff(failure, runAttemptID: runAttemptID)
        noteNoHandoff(message: failure.userText)
        reportStagedInput(stagedInputDisposition(sent: false))
        holdForUser(reason: failure.userText)
    }

    /// The boundary was entered but the provider's documented contract proves the input was never
    /// written (Claude: thrown before the stdin write; ACP: thrown without `onSubmitted`).
    func noteProvenNotWritten(message: String? = nil) {
        guard let evidence = committedEvidence else {
            noteDeferredOutcome(.notHandedOff, message: message)
            return
        }
        evidence.noteNoHandoff(message: message)
    }

    /// Verified provider rejection.
    func noteRejected(message: String? = nil) {
        guard let evidence = committedEvidence else {
            noteDeferredOutcome(.rejected, message: message)
            return
        }
        evidence.noteRejected(message: message)
    }

    /// End of the handoff's owning scope: never reached the provider → no handoff; reached it with
    /// no recorded outcome → delivery unknown. Recorded outcomes are left untouched.
    func settleIfUnresolved() {
        guard let evidence = committedEvidence else {
            noteDeferredOutcome(.notHandedOff, message: nil)
            reportStagedInput(stagedInputDisposition(sent: false))
            return
        }
        if evidence.observation == .open {
            if handoffStarted {
                evidence.noteDeliveryUnknown()
            } else {
                evidence.noteNoHandoff()
            }
        }
        // Staged input never left without an outcome: the scope's final evidence classifies it.
        reportStagedInput(stagedInputDisposition(sent: false))
    }

    /// End of a run's own initial-input scope (the runner was admitted, so no caller re-queues it):
    /// settles like `settleIfUnresolved`, then presents input that provably never reached the
    /// provider (or was verifiably rejected, both back in `queued`) as held input (F5). Uncertain
    /// or accepted input is not re-presented here.
    func settleRunInputScope() {
        settleIfUnresolved()
        switch observation {
        case .notHandedOff, .rejected:
            holdForUser()
        case .open, .accepted, .deliveryUnknown:
            break
        }
    }

    // MARK: Staged next-turn input

    /// Installs the receiver of this handoff's staged-input outcomes (once; later calls are ignored).
    func installStagedInputReporter(
        _ reporter: @escaping (AgentCarriedStagedInput, AgentStagedInputDisposition) -> Void
    ) {
        guard stagedInputReporter == nil else { return }
        stagedInputReporter = reporter
    }

    /// Records staged input that rides on this handoff's provider text (the first stage of each kind
    /// wins). A stage added after an outcome was already reported receives that outcome now.
    func carryStagedInput(_ input: AgentCarriedStagedInput) {
        var added = AgentCarriedStagedInput()
        if let stage = input.pendingHandoffStage, carriedStagedInput.pendingHandoffStage == nil {
            carriedStagedInput.pendingHandoffStage = stage
            added.pendingHandoffStage = stage
        }
        if let stageID = input.delegatedQuestionStageID, carriedStagedInput.delegatedQuestionStageID == nil {
            carriedStagedInput.delegatedQuestionStageID = stageID
            added.delegatedQuestionStageID = stageID
        }
        guard !added.isEmpty, let reported = reportedStagedInputDisposition else { return }
        stagedInputReporter?(added, reported)
    }

    /// Reports the stage-delivery outcome of the carried staged input. Duplicates are ignored, `.sent`
    /// is final, uncertainty may later resolve either way, and a verified `.notSent` only yields to
    /// late affirmative acceptance. Exact-stage identity keeps any late report away from newer stages.
    func reportStagedInput(_ disposition: AgentStagedInputDisposition) {
        switch (reportedStagedInputDisposition, disposition) {
        case (nil, _), (.deliveryUnknown?, .sent), (.deliveryUnknown?, .notSent), (.notSent?, .sent):
            break
        default:
            return
        }
        reportedStagedInputDisposition = disposition
        guard !carriedStagedInput.isEmpty else { return }
        stagedInputReporter?(carriedStagedInput, disposition)
    }

    /// Reports the staged-input outcome after a send attempt (`sent`: the route's stage-delivery
    /// boundary was reached) from this handoff's evidence.
    func settleStagedInput(sent: Bool) {
        reportStagedInput(stagedInputDisposition(sent: sent))
    }

    /// User-facing text for a committed dispatch whose lane retired or froze before handoff.
    static let sessionChangedBeforeHandoffMessage =
        "This message was not sent because the session changed before it was handed off. It stays saved."

    /// User-facing text for a dispatch that could not be committed before handoff.
    static func dispatchFailureText(_ failure: AgentRecoveryAdmissionFailure) -> String {
        failure.dispatchFailureText
    }

    /// F6: the delivery could not be recorded, with a plain cause (never the raw failure; callers
    /// log that privately through `AgentDeliveryRecordDiagnostics`).
    static func deliveryNotRecordedText(_ failure: AgentRecoveryControllerFailure) -> String {
        AgentRecoveryAdmissionFailure.deliveryNotRecordedText(cause: failure.userFacingDescription)
    }

    /// Headless provider streams: model output proves the provider processed the input. Stream
    /// creation, lifecycle, usage, and error results do not.
    nonisolated static func streamResultProvesProviderAcceptance(_ result: AIStreamResult) -> Bool {
        switch result.type {
        case "content", "reasoning":
            let hasText = !(result.text ?? "").isEmpty
            let hasReasoning = !(result.reasoning ?? "").isEmpty
            return hasText || hasReasoning
        case "tool_call":
            return true
        default:
            return false
        }
    }
}

/// Final document authority carried by a provider handoff (DOC-02): `refusal` re-runs the
/// document preflight for the input's references (nil when they all still pass); `settleRefused`
/// is the route's settlement of refused input (untracked input back to the composer with its
/// documents and the reason; durable input is already held by the handoff).
@MainActor
package struct AgentDocumentBoundaryAuthority {
    package let refusal: @MainActor () -> String?
    package let settleRefused: @MainActor (_ reason: String) -> Void

    package init(
        refusal: @escaping @MainActor () -> String?,
        settleRefused: @escaping @MainActor (_ reason: String) -> Void
    ) {
        self.refusal = refusal
        self.settleRefused = settleRefused
    }
}

/// What a send attempt means for staged next-turn input that rode on one handoff (the tab's staged
/// pending-handoff payload and delegated child-question notices). These are stage-delivery boundary
/// semantics, not provider acceptance: an intent's durable delivery state advances only on
/// route-specific affirmative acceptance evidence.
package enum AgentStagedInputDisposition: Equatable {
    /// The route's established stage-delivery boundary was reached (or acceptance was affirmed):
    /// consume or acknowledge that exact stage. Never downgraded by a later outcome.
    case sent
    /// Verified non-handoff, or a rejection proving the staged input was not delivered: release it
    /// for a later send.
    case notSent
    /// The provider boundary was entered without proof either way. Neither consumed nor released:
    /// replaying could deliver it twice, consuming could lose it.
    case deliveryUnknown
}

extension AgentProviderHandoff {
    /// Untracked input (explicit inactive admission) keeps its legacy two-way outcome.
    func stagedInputDisposition(sent: Bool) -> AgentStagedInputDisposition {
        if sent || observation == .accepted {
            return .sent
        }
        guard isDurable, handoffStarted else { return .notSent }
        switch observation {
        case .notHandedOff, .rejected:
            return .notSent
        case .open, .deliveryUnknown, .accepted:
            return .deliveryUnknown
        }
    }
}

/// Staged next-turn input carried by one provider input: the tab's staged pending-handoff payload
/// (exact stage) and/or the delegated child-question notice stage.
package struct AgentCarriedStagedInput: Equatable {
    package var pendingHandoffStage: AgentPendingHandoffStage?
    package var delegatedQuestionStageID: UUID?

    package init(pendingHandoffStage: AgentPendingHandoffStage? = nil, delegatedQuestionStageID: UUID? = nil) {
        self.pendingHandoffStage = pendingHandoffStage
        self.delegatedQuestionStageID = delegatedQuestionStageID
    }

    package var isEmpty: Bool {
        pendingHandoffStage == nil && delegatedQuestionStageID == nil
    }
}

/// A pending-handoff stage prepared for a durable dispatch (adopted plan §5): the snapshot is
/// attached to the carrier by `AgentProviderHandoff.commitDispatch` before the dispatch commit.
package enum AgentPendingHandoffDispatchStaging {
    /// Nothing was staged; the text is sent unchanged.
    case none
    /// Staged, with a durable payload ID and the exact prefix this send prepends.
    case staged(AgentStagedProviderText, AgentRecoveryPendingHandoffSnapshot)
    /// The payload ID could not be saved; the stage was released and the send must not proceed.
    case failed

    /// Why a durable send was blocked because its conversation handoff could not be made part of
    /// its saved input before dispatch. Shown to the user; the input stays saved.
    package static let blockedReason = "This message was not sent: the conversation history it needs could not be saved with it. The message stays saved."
}

/// Provider-facing text plus the exact pending-handoff stage its assembly created (nil when this
/// assembly prepended nothing, e.g. the payload was already staged or held elsewhere).
package struct AgentStagedProviderText: Equatable {
    package let text: String
    package let pendingHandoffStage: AgentPendingHandoffStage?
    /// Set when this send must not proceed: its pending-handoff prefix could not be made part of its
    /// intent before dispatch (adopted plan §5), or an attached document failed preflight. The input
    /// stays saved; nothing staged.
    package let blockedReason: String?

    /// A blocked result carries no sendable text (empty), so a caller that missed `blockedReason`
    /// still cannot deliver the input without its handoff prefix or document manifest. Drafts are
    /// restored from each carrier's own draft text, never from this value.
    package init(text: String, pendingHandoffStage: AgentPendingHandoffStage? = nil, blockedReason: String? = nil) {
        self.text = blockedReason == nil ? text : ""
        self.pendingHandoffStage = pendingHandoffStage
        self.blockedReason = blockedReason
    }
}

extension AgentModeRunService.Hooks {
    /// Delivers both staged-input kinds' exact-stage outcome. A nil stage of either kind is a no-op
    /// for that kind's owner.
    @MainActor
    func recordStagedInputOutcome(
        _ session: AgentTabSession,
        _ input: AgentCarriedStagedInput,
        _ disposition: AgentStagedInputDisposition
    ) {
        recordPendingHandoffSendOutcome(session, input.pendingHandoffStage, disposition)
        if input.delegatedQuestionStageID != nil {
            recordDelegatedQuestionNoticeSendOutcome(session, input.delegatedQuestionStageID, disposition)
        }
    }

    /// Binds `input` to `handoff`: every later outcome of the handoff (explicit send outcome, late
    /// acceptance, or end-of-scope settlement) settles exactly these stages, once.
    @MainActor
    func carryStagedInput(_ input: AgentCarriedStagedInput, on handoff: AgentProviderHandoff, session: AgentTabSession) {
        handoff.installStagedInputReporter { [weak session] carried, disposition in
            guard let session else { return }
            recordStagedInputOutcome(session, carried, disposition)
        }
        handoff.carryStagedInput(input)
    }

    /// Settles the staged input `handoff` carries after a provider send attempt (`sent`: the
    /// route's stage-delivery boundary was reached). An uncertain durable delivery reports
    /// `.deliveryUnknown`: the stages are neither consumed nor released.
    @MainActor
    func recordStagedInputSendOutcome(handoff: AgentProviderHandoff, sent: Bool) {
        handoff.settleStagedInput(sent: sent)
    }
}

/// Always-on, content-free diagnostics for run input that was not sent because its delivery could
/// not be recorded (F1). Several sources share one user-facing text ("…its delivery could not be
/// recorded…"); the logged reason names the source. Failure details are logged privately.
package enum AgentDeliveryRecordDiagnostics {
    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "DeliveryRecord")

    /// A runner could not record its run attempt against the input's delivery attempts.
    enum RunAttemptRoute: String {
        case claude
        case acp
        case headless
    }

    static func runAttemptNotRecorded(
        route: RunAttemptRoute,
        runAttemptID: UUID,
        failure: AgentRecoveryControllerFailure
    ) {
        logger.notice(
            "not_sent reason=\(route.rawValue, privacy: .public)_run_attempt_not_recorded runAttempt=\(runAttemptID.uuidString, privacy: .public) detail=\(String(describing: failure), privacy: .private)"
        )
    }

    /// A deferred dispatch commit (or the staging before it) failed before handoff; a
    /// `dispatch_commit_failed` reason is `AgentRecoveryAdmissionFailure.commitFailed`.
    static func blockedBeforeHandoff(_ failure: AgentProviderHandoff.CommitFailure, runAttemptID: UUID?) {
        logger.notice(
            "not_sent reason=\(failure.diagnosticReason, privacy: .public) runAttempt=\(runAttemptID?.uuidString ?? "nil", privacy: .public) detail=\(String(describing: failure), privacy: .private)"
        )
    }

    /// A scheduled send failed because its run-start handoff settled without a handoff. The schedule
    /// banner shows the generic scheduled explanation; the handoff's own reason (if any) is logged.
    package static func scheduledNotHandedOff(scheduleID: UUID, sourceMessage: String?) {
        let source = (sourceMessage?.isEmpty ?? true) ? "none" : "handoff_message"
        logger.notice(
            "not_sent reason=scheduled_not_handed_off schedule=\(scheduleID.uuidString, privacy: .public) source=\(source, privacy: .public) detail=\(sourceMessage ?? "", privacy: .private)"
        )
    }

    /// The run service refused a start because its input's dispatch could not be validated.
    static func runStartRefused(_ failure: AgentRecoveryAdmissionFailure) {
        logger.notice(
            "not_sent reason=run_start_\(failure.diagnosticReason, privacy: .public) detail=\(String(describing: failure), privacy: .private)"
        )
    }
}

/// Observes ACP `ACPAgentSessionController.prompt`'s `onSubmitted` callback, which runs once on the
/// controller actor immediately after the `session/prompt` request was written and never when
/// building or writing it failed. It proves the write only — not acceptance.
final class ACPPromptWriteObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var written = false
    private let forward: (@Sendable () -> Void)?

    init(forwarding forward: (@Sendable () -> Void)? = nil) {
        self.forward = forward
    }

    var onSubmitted: @Sendable () -> Void {
        { [self] in
            lock.withLock { written = true }
            forward?()
        }
    }

    var wasWritten: Bool {
        lock.withLock { written }
    }

    private var failedAfterReceipt = false

    /// O49: passed as `prompt(onFailure:)`; records that prompt's own receipt evidence.
    var onFailure: @Sendable (_ receivedByAgent: Bool) -> Void {
        { [self] receivedByAgent in
            lock.withLock { failedAfterReceipt = receivedByAgent }
        }
    }

    /// O49: the observed prompt threw after the agent began it and RepoPrompt's own Stop or steer
    /// cancelled it (the prompt's own evidence, never another prompt's).
    var failedAfterAgentReceipt: Bool {
        lock.withLock { failedAfterReceipt }
    }
}
