import Foundation

// Lossless-restart Phase 4 store mutations: durable recovery action reservation/completion and the
// provider-history cursor compare-and-swap (phase4-plan "Durable action association", "Exact
// transaction boundary"). Every mutation goes through the same lifecycle validation, revision CAS,
// and atomic replacement as the rest of the store; callers hold the foundation session gate.

package extension AgentRecoveryStore {
    /// Reserves one explicit recovery action before any provider work.
    ///
    /// - An exact repeat (same action ID and parameters) is `unchanged`, at any revision: a repeated
    ///   click joins the reservation.
    /// - The same action ID with different parameters, or another open action of this launch for the
    ///   same item, conflicts. Nothing is written.
    /// - An open action of a previous launch is never re-performed: the request is refused with
    ///   `priorLaunchAction` so it is joined and shown first. An explicit new choice naming it
    ///   (`supersedesActionID`) replaces it when its join proves nothing was handed off; when its
    ///   delivery is uncertain only an explicitly confirmed new continuation may follow it. The old
    ///   action, its intent and attempts are kept unchanged; no outcome is written for it.
    /// - `sendSaved` atomically claims its single saved intent for this launch (the intent's owning
    ///   instance changes only on an explicit user dispatch). It must still be `queued`, never handed
    ///   off, session-targeted, unscheduled, not withdrawn, and free of every hold except
    ///   `previousInstance`; stale targets and missing attachments still refuse.
    func reserveRecoveryAction(
        binding: AgentRecoveryLifecycleBinding,
        request: AgentRecoveryActionRequest
    ) throws -> AgentRecoveryActionReceipt {
        guard request.itemKey.incarnationID == binding.incarnationID else {
            throw AgentRecoveryStoreError.staleIncarnation(expected: binding.incarnationID, actual: request.itemKey.incarnationID)
        }
        let current = try writableRecord(binding: binding)
        if let current, let existing = current.action(id: request.actionID) {
            guard existing.hasSameParameters(as: request) else {
                throw AgentRecoveryStoreError.actionConflict(request.actionID)
            }
            return AgentRecoveryActionReceipt(
                binding: binding,
                recordRevision: current.revision,
                disposition: .unchanged,
                action: existing
            )
        }
        try requireRevision(request.expectedRevision, current: current)
        if let current, let open = current.unresolvedAction(for: request.itemKey) {
            guard open.appInstanceID != appInstanceID else {
                throw AgentRecoveryStoreError.actionConflict(open.actionID)
            }
            guard request.supersedesActionID == open.actionID else {
                throw AgentRecoveryStoreError.priorLaunchAction(open.actionID)
            }
            try validateSupersession(request, of: open, in: current)
        } else if request.supersedesActionID != nil {
            throw AgentRecoveryStoreError.actionIneligible(
                actionID: request.actionID,
                reason: "The earlier choice this replaces is no longer open. Review the item and choose again."
            )
        }
        var intents = current?.intents ?? []
        try validateActionParameters(request, in: current)
        if request.kind == .sendSaved {
            intents = try claimSavedIntent(request, in: current, binding: binding)
        }
        let action = AgentRecoveryAction(
            actionID: request.actionID,
            itemKey: request.itemKey,
            kindRaw: request.kind.rawValue,
            expectedRevision: request.expectedRevision,
            incarnationID: binding.incarnationID,
            transcriptResetGeneration: binding.transcriptResetGeneration,
            sourceIntentIDs: request.sourceIntentIDs,
            sourceRunAttemptID: request.sourceRunAttemptID,
            sourceInteractionID: request.sourceInteractionID,
            target: request.target,
            text: request.text,
            plannedUserItemID: request.plannedUserItemID,
            supersedesActionID: request.supersedesActionID,
            confirmedUncertainPriorDelivery: request.confirmsUncertainPriorDelivery,
            appInstanceID: appInstanceID,
            reservedAt: AgentRecoveryTimestamp(now())
        )
        let record = try replace(
            current,
            binding: binding,
            composer: current?.composer,
            intents: intents,
            attempts: current?.attempts ?? [],
            runAttempts: current?.runAttempts ?? [],
            actions: (current?.actions ?? []) + [action]
        )
        return AgentRecoveryActionReceipt(binding: binding, recordRevision: record.revision, disposition: .committed, action: action)
    }

    /// Records an action's outcome once. An identical repeat is `unchanged`; a different outcome
    /// for an already-resolved action conflicts (outcomes are never rewritten).
    func completeRecoveryAction(
        binding: AgentRecoveryLifecycleBinding,
        actionID: UUID,
        outcome kind: AgentRecoveryActionOutcomeKind,
        reason: String?
    ) throws -> AgentRecoveryActionReceipt {
        guard let current = try writableRecord(binding: binding), let existing = current.action(id: actionID) else {
            throw AgentRecoveryStoreError.actionNotFound(actionID)
        }
        if let recorded = existing.outcome {
            guard recorded.kindRaw == kind.rawValue, recorded.reason == reason else {
                throw AgentRecoveryStoreError.actionConflict(actionID)
            }
            return AgentRecoveryActionReceipt(binding: binding, recordRevision: current.revision, disposition: .unchanged, action: existing)
        }
        var resolved = existing
        resolved.outcome = AgentRecoveryActionOutcome(kind: kind, reason: reason, recordedAt: AgentRecoveryTimestamp(now()))
        let record = try replace(
            current,
            binding: binding,
            composer: current.composer,
            intents: current.intents,
            attempts: current.attempts,
            runAttempts: current.runAttempts,
            actions: current.actions.map { $0.actionID == actionID ? resolved : $0 }
        )
        return AgentRecoveryActionReceipt(binding: binding, recordRevision: record.revision, disposition: .committed, action: resolved)
    }

    /// Advances one provider conversation's history cursor by compare-and-swap on the import ID it
    /// followed (`nil` = no cursor yet). Called only after the session save that committed the
    /// imported rows and the same import receipt; an exact repeat (same file, offset and prefix
    /// proof) is `unchanged`, any other value under the same import ID conflicts.
    func commitHistoryCursor(
        binding: AgentRecoveryLifecycleBinding,
        expectedPreviousImportID: UUID?,
        cursor: AgentRecoveryHistoryCursor
    ) throws -> AgentRecoveryLocalReceipt {
        let current = try writableRecord(binding: binding)
        let existing = current?.historyCursor(providerRaw: cursor.providerRaw, conversationID: cursor.conversationID)
        if let current, let existing, existing.importID == cursor.importID {
            guard existing.file == cursor.file, existing.completeLineOffset == cursor.completeLineOffset,
                  existing.prefixSHA256 == cursor.prefixSHA256
            else {
                throw AgentRecoveryStoreError.historyCursorConflict
            }
            return AgentRecoveryLocalReceipt(
                binding: binding,
                recordRevision: current.revision,
                disposition: .unchanged,
                composerRevision: current.composer?.revision
            )
        }
        guard existing?.importID == expectedPreviousImportID else {
            throw AgentRecoveryStoreError.historyCursorConflict
        }
        var cursors = (current?.historyCursors ?? []).filter {
            !($0.providerRaw == cursor.providerRaw && $0.conversationID == cursor.conversationID)
        }
        cursors.append(cursor)
        let record = try replace(
            current,
            binding: binding,
            composer: current?.composer,
            intents: current?.intents ?? [],
            attempts: current?.attempts ?? [],
            runAttempts: current?.runAttempts ?? [],
            historyCursors: cursors
        )
        return AgentRecoveryLocalReceipt(
            binding: binding,
            recordRevision: record.revision,
            disposition: .committed,
            composerRevision: record.composer?.revision
        )
    }

    // MARK: Private

    /// A previous launch's open action may be replaced only by an explicit choice: freely when its
    /// join proves nothing was handed off, otherwise only by a confirmed new continuation.
    private func validateSupersession(
        _ request: AgentRecoveryActionRequest,
        of open: AgentRecoveryAction,
        in current: AgentRecoveryRecord
    ) throws {
        switch current.join(open) {
        case .notDispatched, .notHandedOff:
            return
        case .dispatchEvidence, .unknown:
            guard request.kind.mayFollowUncertainPriorAction, request.confirmsUncertainPriorDelivery else {
                throw AgentRecoveryStoreError.supersedeRefused(
                    actionID: open.actionID,
                    reason: "An earlier choice on this item may have reached the agent. Only a new continuation you confirm can follow it."
                )
            }
        case .resolved:
            throw AgentRecoveryStoreError.actionConflict(open.actionID)
        }
    }

    private func validateActionParameters(_ request: AgentRecoveryActionRequest, in current: AgentRecoveryRecord?) throws {
        func ineligible(_ reason: String) -> AgentRecoveryStoreError {
            .actionIneligible(actionID: request.actionID, reason: reason)
        }
        if request.confirmsUncertainPriorDelivery, request.supersedesActionID == nil {
            throw ineligible("The confirmation doesn't name an earlier choice.")
        }
        // An item already resolved by a send, or by proof that its turn finished, never takes a
        // duplicate send (review B F3b). Reconcile stays available.
        if request.kind.dispatches, current?.resolvingAction(for: request.itemKey) != nil {
            throw ineligible("This item was already resolved. Check the conversation; nothing was sent.")
        }
        switch request.kind {
        case .continueWithText, .questionAnswerAsInput, .continueInNewConversation:
            guard let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ineligible("The message is empty.")
            }
            guard let itemID = request.plannedUserItemID, request.sourceIntentIDs.isEmpty else {
                throw ineligible("The action has no message identity.")
            }
            if current?.intents.contains(where: { $0.userItemID == itemID }) == true
                || current?.actions.contains(where: { $0.plannedUserItemID == itemID }) == true
            {
                throw ineligible("The message identity is already in use.")
            }
            if request.kind == .questionAnswerAsInput, request.sourceInteractionID == nil {
                throw ineligible("The answer has no question.")
            }
        case .sendSaved:
            guard request.sourceIntentIDs.count == 1, request.text == nil, request.plannedUserItemID == nil else {
                throw ineligible("Send one saved message at a time.")
            }
        case .reconcileOnly:
            guard request.text == nil, request.plannedUserItemID == nil, request.sourceIntentIDs.isEmpty else {
                throw ineligible("Reconciliation never sends input.")
            }
        }
    }

    private func claimSavedIntent(
        _ request: AgentRecoveryActionRequest,
        in current: AgentRecoveryRecord?,
        binding: AgentRecoveryLifecycleBinding
    ) throws -> [AgentRecoveryIntent] {
        func ineligible(_ reason: String) -> AgentRecoveryStoreError {
            .actionIneligible(actionID: request.actionID, reason: reason)
        }
        guard let current, let intentID = request.sourceIntentIDs.first, var intent = current.intent(id: intentID) else {
            throw ineligible("The saved message no longer exists.")
        }
        guard intent.deliveryState == .queued, intent.withdrawnAt == nil else {
            // Crash uncertainty never becomes a one-click send: dispatching/deliveryUnknown/failed
            // input keeps its own explicit Resend/Edit choices.
            throw ineligible("The saved message is no longer waiting to be sent.")
        }
        guard intent.target.liveRun == nil else {
            throw ineligible("The saved message targeted a run that ended. Edit it to send it again.")
        }
        guard intent.scheduleReference == nil, intent.origin != .scheduled else {
            throw ineligible("Scheduled messages are confirmed from the schedule, not resumed.")
        }
        let holds = holdReasons(for: intent, sessionID: current.sessionID, currentGeneration: binding.transcriptResetGeneration)
            .subtracting([.previousInstance])
        guard holds.isEmpty else {
            throw AgentRecoveryStoreError.heldIntent(intentID: intentID, holds: holds)
        }
        intent.appInstanceID = appInstanceID
        return current.intents.map { $0.intentID == intentID ? intent : $0 }
    }
}
