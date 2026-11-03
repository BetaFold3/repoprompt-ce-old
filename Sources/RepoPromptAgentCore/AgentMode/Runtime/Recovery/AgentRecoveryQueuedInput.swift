// Queue identity and shared dispatch-evidence contracts for lossless app restart (Phase 1b).
//
// Every queued user input (generic follow-up, Claude and ACP steering, Codex fallback) carries an
// `AgentQueuedInputIdentity`: the transcript user item it belongs to and, when durable, the
// store-issued queue receipt naming its recovery intent. Untracked (legacy) identities exist only
// while the session's admission mode is `.inactive`; once activation sets `.mandatory`, they can no
// longer be constructed and a dispatch of one is refused, so activation cannot silently bypass
// durable admission.
//
// Provider workers use one two-step dispatch contract:
// 1. Before handoff: `AgentRecoveryDispatchEvidence.begin(...)` (async) commits `dispatching` plus
//    one attempt per constituent. No store gate is held across the provider call that follows.
// 2. After every await, the caller re-runs its own synchronous runtime freshness checks (session,
//    run ownership, controller) and, immediately before the provider boundary, the lane check
//    `isValidForHandoff(in:)` (the issuing lane is still the session's, unretired and not frozen by
//    reset preparation). If stale, it reports `noteNoHandoff` (the same intent returns to `queued`)
//    and does not hand off. A commit that lands on a retired or frozen lane is already settled and
//    refused by the lane (`dispatchStaleAfterCommit`).
// 3. After handoff: exactly the evidence the provider boundary proves — `noteAccepted`,
//    `noteDeliveryUnknown`, or `noteRejected` (verified rejection). `didSend`, fallback reasons,
//    transport creation, and cancelled responses are not acceptance.

import Foundation

/// Whether a session's queued input must carry durable admission.
package enum AgentRecoveryAdmissionMode: Equatable {
    /// Recovery is not active for this session: queues hold untracked (legacy) entries.
    case inactive
    /// Every queued input requires a store-issued receipt; untracked identities cannot be built.
    case mandatory
}

/// Identity of one queued user input.
package struct AgentQueuedInputIdentity: Equatable {
    package enum Durability: Equatable {
        /// Legacy input with no recovery intent (admission inactive).
        case untracked
        /// Durable `queued` intent; its intent ID and user-item ID come from the receipt.
        case durable(AgentRecoveryQueueReceipt)
    }

    /// Transcript user item this input belongs to (`nil` only for untracked input without a bubble).
    package let userItemID: UUID?
    package let durability: Durability
    /// The explicit recovery action whose own payload this is (review A P1-01). Carried unchanged
    /// through queues, deferred hydration, and provider tasks into the dispatch evidence; only the
    /// coordinator issues it, and a revoked one blocks every later commit and handoff.
    package let actionAuthorization: AgentRecoveryActionAuthorization?

    private init(userItemID: UUID?, durability: Durability, actionAuthorization: AgentRecoveryActionAuthorization? = nil) {
        self.userItemID = userItemID
        self.durability = durability
        self.actionAuthorization = actionAuthorization
    }

    /// Durable identity from a store-issued queue receipt.
    package init(receipt: AgentRecoveryQueueReceipt, actionAuthorization: AgentRecoveryActionAuthorization? = nil) {
        self.init(
            userItemID: receipt.intent.userItemID,
            durability: .durable(receipt),
            actionAuthorization: actionAuthorization
        )
    }

    /// Legacy identity. `nil` once `session` requires durable admission.
    @MainActor
    package static func untracked(userItemID: UUID?, in session: AgentTabSession) -> AgentQueuedInputIdentity? {
        guard session.recoveryAdmissionMode == .inactive else { return nil }
        return AgentQueuedInputIdentity(userItemID: userItemID, durability: .untracked)
    }

    package var queueReceipt: AgentRecoveryQueueReceipt? {
        if case let .durable(receipt) = durability {
            return receipt
        }
        return nil
    }

    /// Recovery intent ID (`nil` for untracked input).
    package var intentID: UUID? {
        queueReceipt?.intent.intentID
    }

    package var isDurable: Bool {
        queueReceipt != nil
    }
}

/// One entry of the generic follow-up queue (`AgentTabSession.pendingInstructions`): the provider
/// text and the ordered user inputs it delivers. A composer turn has one constituent; a coalesced
/// ACP steering requeue keeps every source input in order.
package struct AgentPendingInstruction: Equatable {
    package let text: String
    /// Ordered, never empty.
    package let constituents: [AgentQueuedInputIdentity]

    package init(text: String, identity: AgentQueuedInputIdentity) {
        self.text = text
        constituents = [identity]
    }

    /// `nil` when `constituents` is empty.
    package init?(coalescedText text: String, constituents: [AgentQueuedInputIdentity]) {
        guard !constituents.isEmpty else { return nil }
        self.text = text
        self.constituents = constituents
    }

    /// Any constituent has a durable intent: lifecycle cleanup preserves it and it is never
    /// restored to the composer as a draft or silently dropped.
    package var isDurable: Bool {
        constituents.contains(where: \.isDurable)
    }
}

/// Delivery evidence for one provider handoff of one or more queued inputs (in handoff order).
@MainActor
package final class AgentRecoveryDispatchEvidence {
    package enum Observation: Equatable {
        /// Dispatch committed; no handoff outcome reported yet.
        case open
        case accepted
        case deliveryUnknown
        /// The handoff never began; the same intents are back in `queued`.
        case notHandedOff
        /// The provider verifiably rejected the handoff; the same intents are back in `queued`.
        case rejected
    }

    /// Lane that issued the dispatch receipts (`nil` for an untracked handoff).
    private let lane: AgentRecoverySessionLane?
    /// One receipt per durable constituent, in handoff order (empty when untracked).
    package let receipts: [AgentRecoveryDispatchReceipt]
    /// The recovery action whose own payload this handoff carries (`nil` for ordinary input).
    package let actionAuthorization: AgentRecoveryActionAuthorization?
    /// Latest locally observed outcome (synchronous; durable writes follow in order).
    package private(set) var observation: Observation = .open
    /// Evidence writes that failed. Non-empty means recovery must keep treating the handoff as
    /// uncertain; it is never reported as resolved.
    package private(set) var writeFailures: [AgentRecoveryControllerFailure] = []
    private var writeTail: Task<Void, Never>?

    private init(
        lane: AgentRecoverySessionLane?,
        receipts: [AgentRecoveryDispatchReceipt],
        actionAuthorization: AgentRecoveryActionAuthorization? = nil
    ) {
        self.lane = lane
        self.receipts = receipts
        self.actionAuthorization = actionAuthorization
    }

    package var isDurable: Bool {
        !receipts.isEmpty
    }

    /// Final pre-handoff check (R06): the issuing lane is still `session`'s live lane, not retired,
    /// and not frozen by reset preparation, and the shared recovery-action hold (review A P1-01)
    /// admits exactly this handoff: no hold covers the session, or this evidence carries the
    /// holding action's current authorization for its one committed attempt. Untracked evidence has
    /// no lane; it is valid unless an action hold covers its session (the absence of a receipt is
    /// never an exemption).
    package func isValidForHandoff(in session: AgentTabSession) -> Bool {
        guard let lane else {
            return !Self.untrackedInputIsHeld(in: session)
        }
        return session.recoveryLane === lane
            && lane.permitsHandoff(attemptIDs: receipts.map(\.attemptID), action: actionAuthorization)
    }

    /// Untracked input (inactive admission) while an explicit recovery action holds its scope.
    private static func untrackedInputIsHeld(in session: AgentTabSession) -> Bool {
        let coordinator = session.recoveryLane?.recoveryCoordinator ?? session.recoveryCoordinator
        return coordinator?.recoveryActionBlocksUntrackedInput(sessionID: session.activeAgentSessionID) ?? false
    }

    /// The provider boundary of this handoff was entered (route-specific): an explicit recovery
    /// action's submission is handed off from here on, whatever acceptance later proves.
    package func noteHandoffBegan() {
        guard let actionAuthorization, let lane else { return }
        lane.recoveryCoordinator?.noteRecoveryActionHandoffBegan(actionAuthorization, attemptIDs: receipts.map(\.attemptID))
    }

    /// The single recovery-action authorization the constituents carry: `.none` for ordinary input,
    /// `nil` when mixed (some carry one, others not, or different ones): refused.
    private static func carriedAction(
        _ constituents: [AgentQueuedInputIdentity]
    ) -> AgentRecoveryActionAuthorization?? {
        let carried = constituents.compactMap(\.actionAuthorization)
        guard !carried.isEmpty else { return .some(nil) }
        guard carried.count == constituents.count, constituents.count == 1 else { return nil }
        return .some(carried[0])
    }

    /// The synchronous refusals `begin` applies before writing anything: no constituents, untracked
    /// input under mandatory admission, mixed durable and untracked input, a retired or missing
    /// lane, or receipts from another lifecycle binding. `nil` when a dispatch may be attempted.
    package static func dispatchRefusal(
        session: AgentTabSession,
        constituents: [AgentQueuedInputIdentity]
    ) -> AgentRecoveryAdmissionFailure? {
        guard !constituents.isEmpty else { return .refused(.untrackedInput) }
        // A coalesced or mixed payload never rides on one action's authority.
        guard carriedAction(constituents) != nil else { return .refused(.recoveryActionInProgress) }
        let receipts = constituents.compactMap(\.queueReceipt)
        if receipts.isEmpty {
            guard session.recoveryAdmissionMode == .inactive else { return .refused(.untrackedInput) }
            return untrackedInputIsHeld(in: session) ? .refused(.recoveryActionInProgress) : nil
        }
        guard receipts.count == constituents.count else { return .refused(.untrackedInput) }
        guard let lane = session.recoveryLane, !lane.isRetired else { return .refused(.laneRetired) }
        guard receipts.allSatisfy({ $0.intent.binding == lane.binding }) else { return .refused(.bindingMismatch) }
        if let refusal = lane.recoveryActionDispatchRefusal(
            intentIDs: receipts.map(\.intent.intentID),
            action: carriedAction(constituents) ?? nil
        ) {
            return .refused(refusal)
        }
        return nil
    }

    /// Before-handoff step. All untracked constituents (admission inactive) yield an untracked
    /// evidence that writes nothing. Durable constituents commit `dispatching` atomically through
    /// the session's current lane; mixed, or untracked under mandatory admission, is refused.
    package static func begin(
        session: AgentTabSession,
        constituents: [AgentQueuedInputIdentity],
        runAttemptID: UUID?,
        authorization: AgentRecoveryDispatchAuthorization = .liveQueue
    ) async -> Result<AgentRecoveryDispatchEvidence, AgentRecoveryAdmissionFailure> {
        if let refusal = dispatchRefusal(session: session, constituents: constituents) {
            return .failure(refusal)
        }
        let receipts = constituents.compactMap(\.queueReceipt)
        if receipts.isEmpty {
            return .success(AgentRecoveryDispatchEvidence(lane: nil, receipts: []))
        }
        guard let lane = session.recoveryLane else { return .failure(.refused(.laneRetired)) }
        let action = carriedAction(constituents) ?? nil
        // Every constituent is durable here (`dispatchRefusal`), so receipts align with constituents.
        let requests = zip(receipts, constituents).map { receipt, constituent in
            AgentRecoveryDispatchRequest(
                intentID: receipt.intent.intentID,
                attempt: AgentRecoveryAttemptStart(
                    attemptID: UUID(),
                    runAttemptID: runAttemptID,
                    transcriptTurnID: relocatedExecutionTurnID(of: constituent, in: session)
                )
            )
        }
        let result: Result<[AgentRecoveryDispatchReceipt], AgentRecoveryAdmissionFailure> = if requests.count == 1 {
            await lane.beginDispatch(
                intentID: requests[0].intentID,
                attempt: requests[0].attempt,
                authorization: authorization,
                action: action
            ).map { [$0] }
        } else {
            await lane.beginDispatches(requests, authorization: authorization, action: action)
        }
        return result.map { AgentRecoveryDispatchEvidence(lane: lane, receipts: $0, actionAuthorization: action) }
    }

    /// Before-handoff step under an existing run attempt (R07): for durable input the run attempt is
    /// recorded first (`ensureRunAttempt`, with its process-run join when known), so a handed-off
    /// intent always has discoverable open-run evidence, then the dispatch commits against it. Its
    /// transcript-turn join (R08) is the turn the first carried input's user item opens; the store
    /// keeps the run's first recorded turn, so later steering under the same run never replaces it.
    package static func begin(
        session: AgentTabSession,
        constituents: [AgentQueuedInputIdentity],
        ownership: AgentRunOwnership,
        processRunID: UUID?,
        authorization: AgentRecoveryDispatchAuthorization = .liveQueue
    ) async -> Result<AgentRecoveryDispatchEvidence, AgentRecoveryAdmissionFailure> {
        if !constituents.isEmpty, constituents.allSatisfy(\.isDurable) {
            // Refused (including by the shared action hold) before any run-attempt write.
            if let refusal = dispatchRefusal(session: session, constituents: constituents) {
                return .failure(refusal)
            }
            guard let lane = session.recoveryLane, !lane.isRetired else {
                return .failure(.refused(.laneRetired))
            }
            // Run evidence only from the session's current, compatibly bound run attempt; a stale or
            // pre-binding token is refused, never rewritten or replaced.
            guard ownershipIsCompatible(ownership, with: session) else {
                return .failure(.refused(.bindingMismatch))
            }
            if case let .failure(failure) = await lane.ensureRunAttempt(
                ownership: ownership,
                processRunID: processRunID,
                transcriptTurnID: executionTurnID(of: constituents.first, in: session),
                providerKindRaw: ownership.providerKindRaw,
                // The dispatch commit precedes the run's first provider write: its mark.
                runtimeRegistrationRaw: ownership.runtimeRegistrationRaw
            ) {
                return .failure(.commitFailed(failure))
            }
        }
        return await begin(
            session: session,
            constituents: constituents,
            runAttemptID: ownership.attemptID,
            authorization: authorization
        )
    }

    /// `begin(ownership:)` under the session's active run attempt (process run: the session's
    /// `runID`). Durable input requires that run attempt to exist and to be owned by this lane's
    /// persistent session: missing or incompatible ownership is refused (`bindingMismatch`) before
    /// any write, never dispatched unlinked, and no ownership token is mutated or invented. Only
    /// untracked input of an inactive admission (which writes nothing) passes without ownership;
    /// remote input is excluded by its own route.
    package static func beginUnderActiveRun(
        session: AgentTabSession,
        constituents: [AgentQueuedInputIdentity],
        authorization: AgentRecoveryDispatchAuthorization = .liveQueue
    ) async -> Result<AgentRecoveryDispatchEvidence, AgentRecoveryAdmissionFailure> {
        if let refusal = dispatchRefusal(session: session, constituents: constituents) {
            return .failure(refusal)
        }
        guard constituents.contains(where: \.isDurable) else {
            // Inactive admission, untracked input: nothing is written.
            return await begin(session: session, constituents: constituents, runAttemptID: nil, authorization: authorization)
        }
        guard let ownership = session.activeRunOwnership,
              ownershipIsCompatible(ownership, with: session)
        else {
            return .failure(.refused(.bindingMismatch))
        }
        return await begin(
            session: session,
            constituents: constituents,
            ownership: ownership,
            processRunID: session.runID,
            authorization: authorization
        )
    }

    /// The transcript turn the input's user item executes in: its own ID, or the distinct destination
    /// turn a relocated saved input was placed in (O11).
    package static func executionTurnID(of constituent: AgentQueuedInputIdentity?, in session: AgentTabSession) -> UUID? {
        constituent?.userItemID.map { session.transcript.executionTurnID(forUserItemID: $0) }
    }

    /// The delivery attempt's own turn join, recorded only when it differs from its user item's ID
    /// (a relocated saved input, O11); every other attempt keeps the user-item join unchanged.
    private static func relocatedExecutionTurnID(of constituent: AgentQueuedInputIdentity, in session: AgentTabSession) -> UUID? {
        guard let userItemID = constituent.userItemID,
              let turnID = executionTurnID(of: constituent, in: session),
              turnID != userItemID
        else { return nil }
        return turnID
    }

    /// Whether `ownership` can be run evidence for this session's lane: it is the current run
    /// attempt for the session's current binding (tab, persistent session and binding generation,
    /// binding transition, no transition in progress) and that persistent session is this lane's
    /// (the store's `requireOwnership` predicate).
    package static func ownershipIsCompatible(_ ownership: AgentRunOwnership, with session: AgentTabSession) -> Bool {
        guard let lane = session.recoveryLane, !lane.isRetired else { return false }
        return session.isCurrentRunAttemptForCurrentBinding(ownership)
            && ownership.binding.persistentSessionID == lane.sessionID
    }

    /// Affirmative provider acceptance. Refines any earlier outcome and is never downgraded.
    package func noteAccepted() {
        guard observation != .accepted else { return }
        observation = .accepted
        enqueueOutcome(.providerAccepted)
    }

    /// The handoff began but its result is not proven. Never downgrades acceptance.
    package func noteDeliveryUnknown() {
        guard observation == .open else { return }
        observation = .deliveryUnknown
        enqueueOutcome(.deliveryUnknown)
    }

    /// The handoff provably never began (including a failed post-await freshness check).
    package func noteNoHandoff(message: String? = nil) {
        guard observation == .open else { return }
        observation = .notHandedOff
        enqueueSettle(.preHandoff, message: message)
    }

    /// The caller drops this handoff's input without re-projecting it (no queue entry, no draft):
    /// its durable intents are presented as held input with `reason` (F5). Untracked input has no
    /// intent and records nothing.
    package func holdForUser(reason: String) {
        guard let lane, !receipts.isEmpty else { return }
        lane.noteProjectionRemoved(intentIDs: receipts.map(\.intent.intentID), reason: reason)
    }

    /// The provider verifiably rejected the handoff.
    package func noteRejected(message: String? = nil) {
        guard observation == .open else { return }
        observation = .rejected
        enqueueSettle(.verifiedRejection, message: message)
    }

    /// Awaits every evidence write enqueued so far and returns all write failures.
    package func settled() async -> [AgentRecoveryControllerFailure] {
        await writeTail?.value
        return writeFailures
    }

    private func enqueueOutcome(_ outcome: AgentRecoveryDeliveryOutcome) {
        enqueue { lane, receipt in
            await lane.recordDeliveryOutcome(
                intentID: receipt.intent.intentID,
                attemptID: receipt.attemptID,
                outcome: outcome
            ).map { _ in () }
        }
    }

    private func enqueueSettle(_ evidence: AgentRecoveryFailureKind, message: String?) {
        enqueue { lane, receipt in
            await lane.settleToQueue(
                intentID: receipt.intent.intentID,
                attemptID: receipt.attemptID,
                evidence: evidence,
                message: message
            ).map { _ in () }
        }
    }

    private func enqueue(
        _ write: @escaping @MainActor (AgentRecoverySessionLane, AgentRecoveryDispatchReceipt) async
            -> Result<Void, AgentRecoveryControllerFailure>
    ) {
        guard let lane, !receipts.isEmpty else { return }
        let receipts = receipts
        let previous = writeTail
        // Strong capture: a dropped evidence object still records its failures until written.
        let tail = Task { @MainActor in
            await previous?.value
            var failed = false
            for receipt in receipts {
                if case let .failure(failure) = await write(lane, receipt) {
                    writeFailures.append(failure)
                    failed = true
                }
            }
            // An explicit recovery action's submission settles on its written (or failed) evidence.
            lane.recoveryCoordinator?.noteRecoveryActionEvidence(
                actionAuthorization,
                attemptIDs: receipts.map(\.attemptID),
                observation: observation,
                writeFailed: failed || !writeFailures.isEmpty
            )
        }
        writeTail = tail
        // The lane signals when this write lands, so waiters never poll for late evidence.
        lane.trackDeliveryEvidenceWrite(tail)
    }
}

// MARK: - Explicit re-dispatch of an existing intent

/// An intent already committed for this session, re-dispatched only by an explicit user action
/// (Resend, a start-target picker retry), for example one left `deliveryUnknown` or `failed` across
/// a restart. It is read from the lane's own record, never minted: it carries no receipt and grants
/// no authority. The store re-validates binding, state, holds, target, and attachments at dispatch.
package struct AgentRecoveryExistingIntentReference: Equatable {
    package let binding: AgentRecoveryLifecycleBinding
    package let intentID: UUID
    package let userItemID: UUID
}

package extension AgentRecoverySessionLane {
    /// The newest non-withdrawn intent of this lane's generation shown as `userItemID`, if any.
    /// `nil` when the record is absent or unreadable (callers fail closed under mandatory admission).
    func existingIntentReference(forUserItemID userItemID: UUID) async -> AgentRecoveryExistingIntentReference? {
        guard !isRetired, case let .success(state) = await readRecord(), let record = state.record else { return nil }
        guard let intent = record.intents.last(where: {
            $0.userItemID == userItemID
                && $0.withdrawnAt == nil
                && $0.transcriptResetGeneration == binding.transcriptResetGeneration
        }) else { return nil }
        return AgentRecoveryExistingIntentReference(binding: binding, intentID: intent.intentID, userItemID: intent.userItemID)
    }
}

package extension AgentRecoveryDispatchEvidence {
    /// Before-handoff step for an explicit user re-dispatch of `intent` (authorization is always
    /// `.explicitUserAction`). Commits a new `dispatching` attempt through the session's current
    /// lane; refused when the lane is retired or bound to another generation, and by the store when
    /// the intent is not eligible. Never fabricates a queue receipt.
    static func beginExistingIntent(
        session: AgentTabSession,
        intent: AgentRecoveryExistingIntentReference,
        runAttemptID: UUID?
    ) async -> Result<AgentRecoveryDispatchEvidence, AgentRecoveryAdmissionFailure> {
        guard let lane = session.recoveryLane, !lane.isRetired else {
            return .failure(.refused(.laneRetired))
        }
        guard lane.binding == intent.binding else { return .failure(.refused(.bindingMismatch)) }
        return await lane.beginDispatch(
            intentID: intent.intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: runAttemptID),
            authorization: .explicitUserAction
        ).map { AgentRecoveryDispatchEvidence(lane: lane, receipts: [$0]) }
    }
}
