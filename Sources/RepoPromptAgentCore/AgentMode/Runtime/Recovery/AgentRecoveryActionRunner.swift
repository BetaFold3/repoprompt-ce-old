import Foundation

// Lossless restart Phase 4 explicit recovery actions (phase4-plan "Durable action association",
// "Restart join", and the activation gates). One runner per window performs each user choice as:
//
//   gate (qualification AND active Phase 3 registration AND the target's provider qualified,
//         with a history performer when the choice reconciles)
//   → durable reservation (idempotent: a repeated click joins, never re-performs)
//   → history-only reconciliation (Reconcile, and R7 step 2 before every continuation when
//     history reconciliation is qualified)
//   → stop without sending when verified terminal evidence bound to the source run attempt shows
//     the interrupted turn finished (R7 step 3)
//   → fence (lane still valid for handoff)
//   → the EXISTING normal dispatch, exactly once
//   → durable outcome.
//
// Crash uncertainty never auto-sends: only a reservation committed by this very call may dispatch.
// A reservation found already present (a repeat after the first performance ended) is joined to the
// record and reported, never performed again. A previous launch's open action on the item is joined
// and returned typed (`priorAction`); only an explicit new choice naming it may replace it.

/// Activation of explicit recovery actions. Production takes it from
/// `AgentRecoveryActivation.production` (see O32 there); tests opt in explicitly.
package struct AgentRecoveryActionQualification: Equatable {
    /// Same-conversation Continue / Send saved / Answer as input through normal dispatch.
    package var sameConversationResume: Bool
    /// History-only reconciliation (Claude native history import, Codex observation).
    package var historyReconciliation: Bool
    /// Explicit fresh-conversation continuation after a failed Claude resume.
    package var freshClaudeConversation: Bool
    /// Restart safely (R4 + relaunch helper).
    package var safeRestart: Bool

    package init(
        sameConversationResume: Bool = false,
        historyReconciliation: Bool = false,
        freshClaudeConversation: Bool = false,
        safeRestart: Bool = false
    ) {
        self.sameConversationResume = sameConversationResume
        self.historyReconciliation = historyReconciliation
        self.freshClaudeConversation = freshClaudeConversation
        self.safeRestart = safeRestart
    }

    package func allows(_ kind: AgentRecoveryActionKind) -> Bool {
        switch kind {
        case .continueWithText, .sendSaved, .questionAnswerAsInput: sameConversationResume
        case .continueInNewConversation: freshClaudeConversation
        case .reconcileOnly: historyReconciliation
        }
    }
}

/// Completion evidence of one reconciliation.
package enum AgentRecoveryReconcileCompletion: Equatable {
    /// No verified terminal evidence (always the case for Claude).
    case unconfirmed
    /// Verified terminal evidence that this run attempt's turn finished.
    case confirmed(runAttemptID: UUID)
}

/// Result of one history-only reconciliation attempt.
package enum AgentRecoveryReconcileResult: Equatable {
    /// Rows, ledger, and receipt committed in one session save (the cursor followed), or, with
    /// `rowCount == 0`, nothing new but the observation itself carried `completion`.
    case imported(completion: AgentRecoveryReconcileCompletion, rowCount: Int)
    /// A SUCCESSFUL observation that proved neither completion nor new rows (the provider has no
    /// record of the turn, nothing new, or overlapping rows withheld). A continuation may follow.
    /// Claude's withheld import (9-live r3 T1) lands here only after its outbound claims matched
    /// Claude's user entries exactly and every other check passed: only output association failed.
    case nothingImported(String)
    /// The provider history could not be merged without association evidence this build lacks
    /// (or without the attempt's own pre-send baseline). Nothing changed; never completion, never
    /// "nothing new". Blocks every continuation (review A P1-02): it never falls through.
    case associationUnavailable(AgentProviderHistoryAssociationRefusal, String)
    /// The reconciliation itself failed (stale session or lane, cancellation, transport or read
    /// failure, unsupported record, busy session, pending or failed save). Blocks every
    /// continuation. `completion` keeps a confirmed expected-turn completion that was observed
    /// before the failure (for example rows that could not be saved yet), so it still stops a send.
    case blocked(String, completion: AgentRecoveryReconcileCompletion = .unconfirmed)
}

/// Result of the normal-dispatch performer.
package enum AgentRecoveryDispatchResult: Equatable {
    /// Normal submission accepted the input. This is NOT handoff: the runner then waits for the
    /// submission's exact settlement (`AgentRecoveryCoordinator.awaitRecoveryActionSettlement`).
    case dispatched
    /// Nothing was handed to a provider.
    case notDispatched(String)
}

package enum AgentRecoveryActionResult: Equatable {
    /// The capability is not activated; nothing was reserved.
    case disabled(String)
    /// The reservation was refused (stale revision, conflicting action, ineligible input).
    case refused(String)
    /// An existing reservation was found: reported, never performed again.
    case joined(AgentRecoveryActionJoin)
    /// A previous launch's open action holds the item (nothing was reserved). It is shown first;
    /// the user may choose again explicitly naming it (`supersedesActionID`).
    case priorAction(actionID: UUID, join: AgentRecoveryActionJoin)
    /// Performed and its outcome recorded.
    case completed(AgentRecoveryActionOutcomeKind, reason: String?)
    /// Performed, but the outcome could not be recorded (shown as interrupted on relaunch).
    case outcomeUnrecorded(AgentRecoveryActionOutcomeKind, reason: String?)
}

/// What one action performs, injected by the window (the dispatch closure is the existing normal
/// send path, given the action's coordinator-issued payload authorization to carry; reconciliation
/// is the history-only import transaction).
package struct AgentRecoveryActionPerformers {
    package var reconcile: (@MainActor (AgentRecoveryAction) async -> AgentRecoveryReconcileResult)?
    package var dispatch: @MainActor (AgentRecoveryAction, AgentRecoveryActionAuthorization) async -> AgentRecoveryDispatchResult

    package init(
        reconcile: (@MainActor (AgentRecoveryAction) async -> AgentRecoveryReconcileResult)? = nil,
        dispatch: @escaping @MainActor (AgentRecoveryAction, AgentRecoveryActionAuthorization) async -> AgentRecoveryDispatchResult
    ) {
        self.reconcile = reconcile
        self.dispatch = dispatch
    }
}

@MainActor
package final class AgentRecoveryActionRunner {
    package static let disabledText = "This recovery action is not available yet."
    package static let verifiedCompletionText =
        "The interrupted turn had already finished. Its result is shown; nothing was sent."
    package static let registrationInactiveText =
        "Recovery actions need verified provider process tracking, which is not active."
    package static let sessionActionInFlightText =
        "Another recovery choice for this session or workspace is in progress. Wait for it to finish."
    package static let recoveryUnavailableText = "Recovery isn't available for this session right now. Nothing was sent."
    package static let neverHandedOffText =
        "The interrupted message was never delivered. Send the saved message instead; nothing was sent."
    package static let notInterruptedText =
        "This run didn't end in an interruption, so there is nothing to continue. Nothing was sent."
    package static let recordUnreadableText = "This session's recovery data couldn't be read. Nothing was sent."
    package static let clearedConversationText =
        "The conversation was cleared after this run, so it can't be continued there. Nothing was sent."

    /// A qualified provider whose window supplied no history performer refuses every choice that
    /// reconciles, before anything is reserved.
    package static let historyUnavailableText = "Provider history isn't available for this session. Nothing was sent."
    /// O32: every provider sees the actions; one whose process ownership and provider history can't
    /// be verified refuses before anything is reserved.
    package static func unqualifiedProviderText(_ providerName: String) -> String {
        "Recovery for \(providerName) isn't qualified yet: RepoPrompt can't verify its process ownership and provider history. Nothing was sent."
    }

    /// The one activation this runner gates on (its composition's).
    package let activation: AgentRecoveryActivation
    private let registrationActive: @MainActor () -> Bool

    private var qualification: AgentRecoveryActionQualification {
        activation.actions
    }

    package init(
        activation: AgentRecoveryActivation,
        registrationActive: @escaping @MainActor () -> Bool
    ) {
        self.activation = activation
        self.registrationActive = registrationActive
    }

    package func isAvailable(_ kind: AgentRecoveryActionKind) -> Bool {
        qualification.allows(kind) && registrationActive()
    }

    /// Whether a dispatch by `agent` captures its pre-send history baseline: history reconciliation
    /// is qualified, verified provider tracking is active, and that provider's own pairs are covered
    /// (never a Claude-compatible backend or any provider this activation doesn't qualify). While
    /// the activation is `.off`: never (zero history reads, zero extra writes, ordinary sends).
    package func capturesDispatchBaselines(for agent: AgentProviderKind) -> Bool {
        qualification.historyReconciliation && registrationActive()
            && activation.coversProvider(AgentRuntimeProvider(agentKind: agent))
    }

    /// Performs (or joins) one explicit choice under the app-scoped coordinator's shared action hold
    /// (review A P1-01 / B F3a), acquired synchronously before the first await: from then until its
    /// outcome is recorded (reconciliation, observation cleanup, dispatch and the exact settlement of
    /// its deferred submission, outcome write), ordinary admission, dispatch, and handoff in the
    /// action's own durable session is refused in every window. Workspace-wide automatic work stays
    /// paused (`runAlongsideOtherSessions` included); sibling live input stays usable. An exact repeat (same request, same
    /// lane, any window) joins the running performance instead of reserving again.
    package func perform(
        _ request: AgentRecoveryActionRequest,
        lane: AgentRecoverySessionLane,
        performers: AgentRecoveryActionPerformers
    ) async -> AgentRecoveryActionResult {
        guard qualification.allows(request.kind) else { return .disabled(Self.disabledText) }
        guard registrationActive() else { return .disabled(Self.registrationInactiveText) }
        // O32 provider gate, before any hold or reservation (zero writes): the reserved target's own
        // provider must be qualified, and a choice that reconciles needs a history performer (a
        // missing one is a refusal, never a silent dispatch or "nothing imported").
        let providerKind = request.target.providerKindRaw.flatMap(AgentProviderKind.init(rawValue:))
        let needsHistory = request.kind == .reconcileOnly
            || (qualification.historyReconciliation && request.kind.reconcilesBeforeDispatch)
        guard activation.coversProvider(providerKind.flatMap(AgentRuntimeProvider.init(agentKind:))) else {
            return .disabled(Self.unqualifiedProviderText(providerKind?.displayName ?? "this provider"))
        }
        // A qualified provider whose window lent no history performer: nothing can reconcile.
        guard !needsHistory || performers.reconcile != nil else { return .disabled(Self.historyUnavailableText) }
        guard let coordinator = lane.recoveryCoordinator else { return .refused(Self.recoveryUnavailableText) }
        let authorization: AgentRecoveryActionAuthorization
        switch coordinator.beginRecoveryAction(request, lane: lane) {
        case let .joined(operation):
            return await operation.value
        case .refused:
            return .refused(Self.sessionActionInFlightText)
        case let .acquired(value):
            authorization = value
        }
        let reconcilesBeforeDispatch = qualification.historyReconciliation
        let task = Task { @MainActor in
            let result = await Self.run(
                request,
                lane: lane,
                performers: performers,
                reconcilesBeforeDispatch: reconcilesBeforeDispatch,
                authorization: authorization,
                coordinator: coordinator
            )
            // Released only after the settlement and the outcome write (or its explicit failure);
            // the token is revoked first and never revives.
            coordinator.revokeRecoveryAction(authorization)
            coordinator.endRecoveryAction(authorization)
            return result
        }
        coordinator.attachRecoveryActionOperation(authorization, task)
        return await task.value
    }

    private static func run(
        _ request: AgentRecoveryActionRequest,
        lane: AgentRecoverySessionLane,
        performers: AgentRecoveryActionPerformers,
        reconcilesBeforeDispatch: Bool,
        authorization: AgentRecoveryActionAuthorization,
        coordinator: AgentRecoveryCoordinator
    ) async -> AgentRecoveryActionResult {
        let receipt: AgentRecoveryActionReceipt
        switch await lane.reserveRecoveryAction(request) {
        case let .success(value):
            receipt = value
        case let .failure(.store(.priorLaunchAction(priorID))):
            let state = await (try? lane.readRecord().get()) ?? .absent
            guard case let .supported(record) = state, let prior = record.action(id: priorID) else {
                return .priorAction(actionID: priorID, join: .unknown)
            }
            return .priorAction(actionID: priorID, join: record.join(prior))
        case let .failure(failure):
            return .refused(describe(failure))
        }
        guard receipt.disposition == .committed else {
            // Not reserved by this call: join, never perform again.
            let state = await (try? lane.readRecord().get()) ?? .absent
            guard case let .supported(record) = state, let action = record.action(id: request.actionID)
            else {
                return .joined(.unknown)
            }
            return .joined(record.join(action))
        }
        let action = receipt.action
        var outcome: AgentRecoveryActionOutcomeKind
        var reason: String?
        var reconcileResult: AgentRecoveryReconcileResult?
        let reconciles = action.kind == .reconcileOnly
            || (reconcilesBeforeDispatch && action.kind?.reconcilesBeforeDispatch == true)
        if reconciles, let reconcile = performers.reconcile {
            reconcileResult = await reconcile(action)
        }
        if action.kind == .reconcileOnly {
            switch reconcileResult {
            case let .imported(completion, _):
                outcome = isBound(completion, to: action) ? .importedCompleted : .importedUnconfirmed
            case let .blocked(text, completion):
                outcome = isBound(completion, to: action) ? .importedCompleted : .notDispatched
                reason = text
            case let .nothingImported(text), let .associationUnavailable(_, text):
                outcome = .notDispatched
                reason = text
            case nil:
                outcome = .notDispatched
                reason = "Provider history is unavailable."
            }
        } else if let stop = await stopBeforeDispatch(action, reconcileResult: reconcileResult, lane: lane) {
            // R7 step 3 (verified completion), a blocking reconcile failure, or source-run evidence
            // that rules a continuation out: nothing is sent.
            outcome = stop.outcome
            reason = stop.reason
        } else if !lane.isValidForHandoff {
            outcome = .notDispatched
            reason = AgentRecoverySessionLane.sessionChangedHoldReason
        } else {
            let submitted = await performers.dispatch(action, authorization)
            if case let .notDispatched(text) = submitted {
                // Nothing more may use the authorization; a commit already made still owes evidence.
                coordinator.revokeRecoveryAction(authorization, reason: text)
            }
            // `.submitted` is not handoff: wait for the exact deferred submission to settle.
            switch await coordinator.awaitRecoveryActionSettlement(authorization) {
            case .handedOff:
                outcome = .dispatched
            case let .notHandedOff(text):
                outcome = .notDispatched
                if case let .notDispatched(submittedText) = submitted {
                    reason = submittedText
                } else {
                    reason = text ?? "The message couldn't be sent."
                }
            case let .uncertain(text):
                // A handoff may have happened: never recorded as not sent.
                outcome = .dispatched
                reason = text
            }
        }
        if let text = reason, text.count > 300 { reason = String(text.prefix(300)) }
        switch await lane.completeRecoveryAction(actionID: action.actionID, outcome: outcome, reason: reason) {
        case .success:
            return .completed(outcome, reason: reason)
        case .failure:
            return .outcomeUnrecorded(outcome, reason: reason)
        }
    }

    /// Completion evidence counts only when bound to the action's own source run attempt.
    private static func isBound(_ completion: AgentRecoveryReconcileCompletion, to action: AgentRecoveryAction) -> Bool {
        guard case let .confirmed(runAttemptID) = completion, let source = action.sourceRunAttemptID else { return false }
        return runAttemptID == source
    }

    /// Why a continuation must not dispatch, if it must not (review A P1-02/P1-03/P1-06, B F2/F4):
    ///  - this reconciliation proved the source attempt's expected turn finished, whether or not its
    ///    rows were saved (`importedCompleted`);
    ///  - the reconciliation failed or lacked association evidence (never a fallthrough);
    ///  - the record proves the source attempt completed (terminal evidence or an earlier action's
    ///    proof), ended in a non-interruption, or was never handed off (its saved intent is the
    ///    route), or the record can't be read.
    /// A successful unconfirmed observation (`nothingImported`, unconfirmed `imported`) continues.
    private static func stopBeforeDispatch(
        _ action: AgentRecoveryAction,
        reconcileResult: AgentRecoveryReconcileResult?,
        lane: AgentRecoverySessionLane
    ) async -> (outcome: AgentRecoveryActionOutcomeKind, reason: String)? {
        guard action.kind?.reconcilesBeforeDispatch == true else { return nil }
        switch reconcileResult {
        case let .imported(completion, _) where isBound(completion, to: action):
            return (.importedCompleted, verifiedCompletionText)
        case let .blocked(text, completion):
            return (isBound(completion, to: action) ? .importedCompleted : .notDispatched, text)
        case let .associationUnavailable(_, text):
            return (.notDispatched, text)
        case .imported, .nothingImported, nil:
            break
        }
        guard let source = action.sourceRunAttemptID else { return nil }
        let record: AgentRecoveryRecord
        switch await lane.readRecord() {
        case let .success(.supported(value)):
            record = value
        case .success(.absent):
            return nil
        default:
            return (.notDispatched, recordUnreadableText)
        }
        if record.hasVerifiedCompletion(ofRunAttempt: source) {
            return (.importedCompleted, verifiedCompletionText)
        }
        if record.isVerifiedNeverHandedOff(runAttemptID: source) {
            return (.notDispatched, neverHandedOffText)
        }
        if let run = record.runAttempt(id: source) {
            guard AgentRecoveryInterruptedTurn.Status.classify(attempt: run).isInterruption else {
                return (.notDispatched, notInterruptedText)
            }
            guard run.transcriptResetGeneration == action.transcriptResetGeneration else {
                return (.notDispatched, clearedConversationText)
            }
        }
        return nil
    }

    private static func describe(_ failure: AgentRecoveryControllerFailure) -> String {
        switch failure {
        case let .store(.actionIneligible(_, reason)):
            reason
        case .store(.actionConflict):
            "Another recovery choice for this item is already in progress."
        case let .store(.supersedeRefused(_, reason)):
            reason
        case .store(.revisionConflict):
            "This item changed. Review it and choose again."
        case let .store(.heldIntent(_, holds)):
            "The saved message is held (\(holds.map(\.rawValue).sorted().joined(separator: ", ")))."
        default:
            "The recovery choice could not be saved."
        }
    }
}

// MARK: - Lane wrappers (inside the foundation session gate)

package extension AgentRecoverySessionLane {
    func reserveRecoveryAction(
        _ request: AgentRecoveryActionRequest
    ) async -> Result<AgentRecoveryActionReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.reserveRecoveryAction(binding: binding, request: request)
        }
    }

    func completeRecoveryAction(
        actionID: UUID,
        outcome: AgentRecoveryActionOutcomeKind,
        reason: String?
    ) async -> Result<AgentRecoveryActionReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.completeRecoveryAction(binding: binding, actionID: actionID, outcome: outcome, reason: reason)
        }
    }

    func commitHistoryCursor(
        expectedPreviousImportID: UUID?,
        cursor: AgentRecoveryHistoryCursor
    ) async -> Result<AgentRecoveryLocalReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.commitHistoryCursor(
                binding: binding,
                expectedPreviousImportID: expectedPreviousImportID,
                cursor: cursor
            )
        }
    }
}
