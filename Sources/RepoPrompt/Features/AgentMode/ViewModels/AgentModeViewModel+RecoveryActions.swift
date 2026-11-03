import Foundation
import RepoPromptAgentCore

// Lossless restart Phase 4 explicit recovery actions in the window view model (phase4-plan
// "Durable action association", "History ledger", "Exact transaction boundary").
//
// Every choice goes through `AgentRecoveryActionRunner` (gate → durable reservation → fence →
// the EXISTING normal dispatch, once → durable outcome). Nothing here adds a second send path:
// continuations are new ordinary user input admitted by `submitUserTurnAdmittingRecoveryInput`
// under the action's planned user item ID; Send saved hands the single claimed saved intent to
// `submitUserTurn` under a store-issued queue receipt. History reconciliation commits rows, the
// native-ID ledger and the import receipt in ONE owner session save before the recovery cursor's
// compare-and-swap. Which actions are offered and may execute comes from the app's one activation
// (`AgentRecoveryActivation.production`, on since 9-live round 4 passed, 2026-10-29); the runner
// refuses a choice for a provider that activation doesn't qualify before anything is reserved (O32).

extension AgentModeViewModel {
    /// One recovery item and one choice on it (the stable-request key).
    struct RecoveryActionSlot: Hashable {
        let item: AgentRecoveryCardKey
        let kindRaw: String
    }

    /// A previous launch's open action shown on an item (joined, never re-performed).
    struct RecoveryPriorAction: Equatable {
        let actionID: UUID
        let join: AgentRecoveryActionJoin

        /// Its join proves nothing was handed off, so any explicit new choice may replace it.
        var isProvenNotHandedOff: Bool {
            switch join {
            case .notDispatched, .notHandedOff: true
            case .dispatchEvidence, .unknown, .resolved: false
            }
        }
    }

    /// R7 default continuation text (shown editable in the card before the choice).
    static let recoveryContinueDefaultText = AgentRecoveryActionRequest.defaultContinuationText
    static let recoveryActionStaleText = "This session changed. Review the item and choose again."
    /// A recovery continuation that could not be durably admitted (it never falls back to an
    /// untracked submit of the composer's state).
    static let recoveryReservedPayloadUnadmittedMessage =
        "The continuation couldn't be saved before sending. Nothing was sent."
    /// Shown in the continuation editor when an earlier choice may have reached the agent; sending
    /// from that editor is the explicit confirmation.
    static let recoveryUncertainPriorWarning =
        "An earlier choice on this item, made before RepoPrompt restarted, may have reached the agent. Check the conversation first. Sending starts a new continuation; the earlier one is not retried."

    // MARK: Row actions (all gated OFF in production)

    /// Explicit recovery choices offered on a run row of the open session. A continuation is offered
    /// only for an interruption (review B F4) of the lane's own reset generation that no action
    /// resolved yet (B F3b) and whose input was handed off (A P1-06: a never-delivered run's saved
    /// message is the route). Reconcile stays available. The runner re-checks all of it durably.
    func recoveryRunActions(
        session: AgentTabSession?,
        status: AgentRecoveryInterruptedTurn.Status,
        facts: AgentRecoveryCatalogActionFacts
    ) -> [AgentRecoveryListRowProps.Action] {
        guard let session else { return [] }
        var actions: [AgentRecoveryListRowProps.Action] = []
        let sameGeneration = facts.runTranscriptResetGeneration.map { generation in
            session.recoveryLane.map { $0.binding.transcriptResetGeneration == generation } ?? false
        } ?? true
        let continuable = status.isInterruption && !facts.resolvedByAction && !facts.runNeverHandedOff && sameGeneration
        if continuable, recoveryActionRunner.isAvailable(.continueWithText) { actions.append(.continueTurn) }
        if recoveryActionRunner.isAvailable(.reconcileOnly), recoveryActionTarget(for: session).providerConversationID != nil {
            actions.append(.reconcileHistory)
        }
        if continuable, recoveryActionRunner.isAvailable(.continueInNewConversation),
           let unavailable = session.recoveryResumeUnavailableConversationID,
           unavailable == session.providerSessionID
        {
            actions.append(.continueInNewConversation)
        }
        return actions
    }

    /// Send saved on a queued intent row of the open session.
    func recoveryIntentActions(
        _ intent: AgentRecoveryIntent,
        facts: AgentRecoveryCatalogActionFacts = .init()
    ) -> [AgentRecoveryListRowProps.Action] {
        guard !facts.resolvedByAction, recoveryActionRunner.isAvailable(.sendSaved),
              intent.deliveryState == .queued,
              intent.pendingHandoff == nil,
              intent.scheduleReference == nil,
              intent.target.liveRun == nil
        else { return [] }
        return [.sendSaved]
    }

    /// Answer as input on a saved question row whose partial answer is non-empty.
    func recoveryQuestionActions(
        _ snapshot: AgentRecoveryQuestionSnapshot,
        facts: AgentRecoveryCatalogActionFacts = .init()
    ) -> [AgentRecoveryListRowProps.Action] {
        guard !facts.resolvedByAction, recoveryActionRunner.isAvailable(.questionAnswerAsInput),
              snapshot.items.contains(where: { !($0.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return [] }
        return [.answerAsInput]
    }

    // MARK: Perform

    /// Warning for the continuation editor of `key` when a previous launch's open action with
    /// uncertain delivery holds it.
    func recoveryPriorActionWarning(for key: AgentRecoveryCardKey?) -> String? {
        guard let key, let prior = recoveryPriorActionsByItem[key], !prior.isProvenNotHandedOff else { return nil }
        return Self.recoveryUncertainPriorWarning
    }

    /// Performs one explicit recovery choice for a row. Returns the row's inline failure text, or
    /// `nil` once the choice was performed (or found already performed). `continuationText` is the
    /// card's edited continuation (frozen into the reservation exactly as given);
    /// `acknowledgedWarning` is the uncertain-prior warning the editor showed when the user sent.
    /// `report`, when given, receives the runner's typed result and the history observation it ran
    /// (Check and resolve reports from them; it stays empty when the choice never reached the runner).
    func performRecoveryResumeAction(
        rowID: String,
        action: AgentRecoveryListRowProps.Action,
        continuationText: String? = nil,
        acknowledgedWarning: String? = nil,
        report: RecoveryResumeActionReport? = nil
    ) async -> String? {
        guard let item = recoveryListCatalogItem(rowID), let sessionID = item.sessionID else {
            return "This item is no longer available."
        }
        guard let (session, lane) = recoveryListLane(sessionID: sessionID) else {
            return "Open this session to continue it."
        }
        guard let key = item.acknowledgement?.key else { return "This item can't be continued." }
        let target = recoveryActionTarget(for: session)
        let kind: AgentRecoveryActionKind
        var text: String?
        var sourceIntentIDs: [UUID] = []
        var sourceRunAttemptID: UUID?
        var sourceInteractionID: UUID?
        var codexTurnID: String?
        var runTurnID: UUID?
        var readsRecordedProviderTurn = false
        switch (action, item.payload) {
        case let (.continueTurn, payload), let (.reconcileHistory, payload), let (.continueInNewConversation, payload):
            guard let run = Self.recoveryRunReference(payload) else { return "This item can't be continued." }
            sourceRunAttemptID = run.runAttemptID
            runTurnID = run.turnID
            readsRecordedProviderTurn = true
            codexTurnID = run.turnID.flatMap { turnID in
                session.transcript.turns.first { $0.id == turnID }?.responseSpans.last { $0.providerTurnID != nil }?.providerTurnID
            }
            switch action {
            case .continueTurn:
                kind = .continueWithText
                text = continuationText ?? Self.recoveryContinueDefaultText
            case .reconcileHistory:
                kind = .reconcileOnly
            default:
                kind = .continueInNewConversation
                text = continuationText ?? Self.recoveryContinueDefaultText
            }
        case let (.sendSaved, .intent(intent, _)):
            kind = .sendSaved
            sourceIntentIDs = [intent.intentID]
        case let (.answerAsInput, .question(snapshot, _)):
            kind = .questionAnswerAsInput
            sourceInteractionID = snapshot.interactionID
            sourceRunAttemptID = snapshot.runAttemptID
            text = snapshot.composerText
        default:
            return "This choice doesn't apply to this item."
        }
        let expectedRevision: AgentRecoveryRecordRevision?
        var runAttempts: [AgentRecoveryRunAttempt] = []
        switch await lane.readRecord() {
        case let .success(.supported(record)):
            expectedRevision = record.revision
            runAttempts = record.runAttempts
        case .success(.absent):
            expectedRevision = nil
        case .success(.preserved):
            return "This session's recovery data is unreadable and is kept unchanged."
        case let .failure(failure):
            AgentRecoveryFailureDiagnostics.presentationFailure(site: "recovery_action_record_unreadable", failure: failure)
            return "This session's recovery data couldn't be read (\(Self.recoveryListDescription(of: failure)))."
        }
        // 9-live R2: the native turn recorded on the run attempt wins over a transcript span. A cleared
        // record (`null`: a non-user turn became authoritative) is authoritative too, so the span
        // fallback applies only when nothing was recorded (a legacy or unrecorded attempt).
        if readsRecordedProviderTurn, let sourceRunAttemptID,
           let runAttempt = runAttempts.first(where: { $0.runAttemptID == sourceRunAttemptID }),
           runAttempt.hasProviderTurnRecord
        {
            codexTurnID = runAttempt.recordedProviderTurnID
        }
        // A choice that acts on the run attempt (Continue, Reconcile) is performed only by the
        // provider the run was started with (recorded at run start); nothing reserved or written.
        if kind == .continueWithText || kind == .reconcileOnly,
           let refusal = Self.recoveryRunProviderRefusal(
               sourceRunAttemptID: sourceRunAttemptID, runAttempts: runAttempts, current: session.selectedAgent
           )
        {
            return refusal
        }
        // A previous launch's open action, already shown: this explicit choice names it. Uncertain
        // delivery admits only a continuation sent from the editor that showed the warning.
        var supersedesActionID: UUID?
        var confirmsUncertainPrior = false
        if let prior = recoveryPriorActionsByItem[key] {
            if prior.isProvenNotHandedOff {
                supersedesActionID = prior.actionID
            } else if kind.mayFollowUncertainPriorAction, acknowledgedWarning == Self.recoveryUncertainPriorWarning {
                supersedesActionID = prior.actionID
                confirmsUncertainPrior = true
            } else {
                return Self.recoveryPriorActionText(prior.join)
            }
        }
        let slot = RecoveryActionSlot(item: key, kindRaw: kind.rawValue)
        // A repeat joins only an identical choice; edited text or a different replacement target
        // is a new explicit choice with a new action ID.
        let cached = recoveryActionRequestsBySlot[slot].flatMap { cached in
            cached.text == text && cached.supersedesActionID == supersedesActionID
                && cached.confirmsUncertainPriorDelivery == confirmsUncertainPrior ? cached : nil
        }
        let request = cached ?? AgentRecoveryActionRequest(
            actionID: UUID(),
            itemKey: key,
            kind: kind,
            expectedRevision: expectedRevision,
            sourceIntentIDs: sourceIntentIDs,
            sourceRunAttemptID: sourceRunAttemptID,
            sourceInteractionID: sourceInteractionID,
            target: target,
            text: text,
            plannedUserItemID: kind.dispatches && kind != .sendSaved ? UUID() : nil,
            supersedesActionID: supersedesActionID,
            confirmsUncertainPriorDelivery: confirmsUncertainPrior
        )
        // Round-0 review P1-1: a choice is performed only by the provider its target names. A request
        // whose target names another provider than the session's current one (a cached or earlier
        // request from before a switch) is refused before the runner: nothing reserved or written.
        if let mismatch = Self.recoveryProviderMismatchText(target: request.target, current: session.selectedAgent) {
            recoveryActionRequestsBySlot[slot] = nil
            return mismatch
        }
        recoveryActionRequestsBySlot[slot] = request
        var performers = recoveryActionPerformers(
            kind: kind,
            session: session,
            lane: lane,
            codexTurnID: codexTurnID,
            runTurnID: runTurnID
        )
        if let report, let reconcile = performers.reconcile {
            performers.reconcile = { @MainActor action in
                let observed = await reconcile(action)
                report.observed = observed
                return observed
            }
        }
        let result: AgentRecoveryActionResult
        #if DEBUG
            if let override = test_recoveryActionResult {
                result = await override(request)
            } else {
                result = await recoveryActionRunner.perform(request, lane: lane, performers: performers)
            }
        #else
            result = await recoveryActionRunner.perform(request, lane: lane, performers: performers)
        #endif
        report?.result = result
        // The session's action hold ended: automatic work it paused is re-evaluated.
        scheduledSendCoordinator?.recordDidChange()
        refreshRecoveryListUI()
        switch result {
        case let .disabled(message), let .refused(message):
            recoveryActionRequestsBySlot[slot] = nil
            return message
        case let .priorAction(priorID, join):
            recoveryActionRequestsBySlot[slot] = nil
            recoveryPriorActionsByItem[key] = RecoveryPriorAction(actionID: priorID, join: join)
            refreshRecoveryListUI()
            return Self.recoveryPriorActionText(join)
        case let .joined(join):
            return Self.recoveryActionJoinText(join)
        case let .completed(outcome, reason):
            recoveryActionRequestsBySlot[slot] = nil
            recoveryPriorActionsByItem[key] = nil
            switch outcome {
            case .dispatched, .importedUnconfirmed:
                return nil
            case .notDispatched:
                return reason ?? "Nothing was sent."
            case .importedCompleted:
                return reason
            }
        case let .outcomeUnrecorded(outcome, _):
            recoveryActionRequestsBySlot[slot] = nil
            return outcome == .notDispatched
                ? "Nothing was sent, but that couldn't be recorded."
                : "The choice was performed, but its result couldn't be recorded. Check the conversation before choosing again."
        }
    }

    /// Neutral run-provider refusals (Continue, Reconcile and Check alike).
    static let recoveryRunProviderNotRecordedText =
        "This card's provider wasn't recorded, so RepoPrompt can't act on it safely. Nothing was changed."

    /// The refusal when `target` names a provider other than the session's `current` one, or `nil`
    /// (a cached or earlier request built before a provider switch).
    static func recoveryProviderMismatchText(target: AgentRecoveryActionTarget, current: AgentProviderKind) -> String? {
        guard let raw = target.providerKindRaw else { return nil }
        return recoveryProviderMismatchText(providerKindRaw: raw, current: current)
    }

    /// The run-provider refusal of a Continue/Reconcile on the run `sourceRunAttemptID` of `runAttempts`
    /// (the record's). Fails closed: a card without a run attempt (a legacy interrupted turn) or whose
    /// attempt is not in the record has no recorded provider.
    static func recoveryRunProviderRefusal(
        sourceRunAttemptID: UUID?,
        runAttempts: [AgentRecoveryRunAttempt],
        current: AgentProviderKind
    ) -> String? {
        let attempt = sourceRunAttemptID.flatMap { id in runAttempts.first { $0.runAttemptID == id } }
        return recoveryRunProviderRefusal(recorded: attempt?.recordedProviderKindRaw, current: current)
    }

    /// The refusal for a run card whose run was started with `recorded` (its run attempt's
    /// run-start provider) when the session now uses `current`; a run recorded without a provider
    /// (before this was captured) is refused rather than guessed.
    static func recoveryRunProviderRefusal(recorded: String?, current: AgentProviderKind) -> String? {
        guard let recorded else { return recoveryRunProviderNotRecordedText }
        return recoveryProviderMismatchText(providerKindRaw: recorded, current: current)
    }

    private static func recoveryProviderMismatchText(providerKindRaw raw: String, current: AgentProviderKind) -> String? {
        guard raw != current.rawValue else { return nil }
        let name = AgentProviderKind(rawValue: raw)?.displayName ?? "another provider"
        return "This card is from a \(name) run, but the session now uses \(current.displayName). Switch back to act on it. Nothing was changed."
    }

    /// The provider conversation a choice is decided against (fenced at every await).
    func recoveryActionTarget(for session: AgentTabSession) -> AgentRecoveryActionTarget {
        let conversationID = session.selectedAgent == .codexExec ? session.codexConversationID : session.providerSessionID
        return AgentRecoveryActionTarget(providerKindRaw: session.selectedAgent.rawValue, providerConversationID: conversationID)
    }

    /// Lifecycle + target fence: the same tab, live lane, incarnation, reset generation, and (unless
    /// the choice is the explicit new conversation, which retires the target itself) target.
    func recoveryActionStillCurrent(
        _ action: AgentRecoveryAction,
        session: AgentTabSession,
        lane: AgentRecoverySessionLane,
        checksTarget: Bool = true
    ) -> Bool {
        guard sessions[session.tabID] === session,
              session.recoveryLane === lane,
              !lane.isRetired,
              lane.binding.incarnationID == action.incarnationID,
              lane.binding.transcriptResetGeneration == action.transcriptResetGeneration
        else { return false }
        return !checksTarget || recoveryActionTarget(for: session).matches(action.target)
    }

    // MARK: Performers

    private func recoveryActionPerformers(
        kind: AgentRecoveryActionKind,
        session: AgentTabSession,
        lane: AgentRecoverySessionLane,
        codexTurnID: String?,
        runTurnID: UUID?
    ) -> AgentRecoveryActionPerformers {
        var reconcile: (@MainActor (AgentRecoveryAction) async -> AgentRecoveryReconcileResult)?
        // R7 step 2: continuations reconcile first (the runner runs it only when history
        // reconciliation is qualified). Only providers with a history mechanism (Claude Code, Codex)
        // get a performer; for any other provider the runner refuses every choice that reconciles
        // (and, under O32, every choice for a provider it doesn't qualify) before reserving.
        let reconcilesProviderHistory = session.selectedAgent == .claudeCode || session.selectedAgent == .codexExec
        if reconcilesProviderHistory, kind == .reconcileOnly || kind.reconcilesBeforeDispatch {
            reconcile = { @MainActor [weak self] (action: AgentRecoveryAction) async -> AgentRecoveryReconcileResult in
                guard let self else { return .blocked(AgentModeViewModel.recoveryActionStaleText) }
                return await reconcileRecoveryHistory(
                    action,
                    session: session,
                    lane: lane,
                    codexTurnID: codexTurnID,
                    runTurnID: runTurnID
                )
            }
        }
        let dispatch: @MainActor (AgentRecoveryAction, AgentRecoveryActionAuthorization) async -> AgentRecoveryDispatchResult = {
            @MainActor [weak self] action, authorization in
            guard let self else { return .notDispatched(AgentModeViewModel.recoveryActionStaleText) }
            return await dispatchRecoveryAction(action, authorization: authorization, session: session, lane: lane)
        }
        return AgentRecoveryActionPerformers(reconcile: reconcile, dispatch: dispatch)
    }

    private func dispatchRecoveryAction(
        _ action: AgentRecoveryAction,
        authorization: AgentRecoveryActionAuthorization,
        session: AgentTabSession,
        lane: AgentRecoverySessionLane
    ) async -> AgentRecoveryDispatchResult {
        switch action.kind {
        case .sendSaved?:
            await dispatchRecoverySavedIntent(action, authorization: authorization, session: session, lane: lane)
        case .continueWithText?, .questionAnswerAsInput?, .continueInNewConversation?:
            await dispatchRecoveryContinuation(action, authorization: authorization, session: session, lane: lane)
        case .reconcileOnly?, nil:
            .notDispatched("Nothing is sent for this choice.")
        }
    }

    /// A continuation: a new editable user message through normal admission and dispatch, shown
    /// under the action's planned user item. Same-conversation Claude dispatch suppresses the
    /// implicit fresh-conversation fallback; the explicit new-conversation choice retires the
    /// failed conversation first (existing reset detach), never implicitly.
    private func dispatchRecoveryContinuation(
        _ action: AgentRecoveryAction,
        authorization: AgentRecoveryActionAuthorization,
        session: AgentTabSession,
        lane: AgentRecoverySessionLane
    ) async -> AgentRecoveryDispatchResult {
        guard let text = action.text, let userItemID = action.plannedUserItemID else {
            return .notDispatched("The message has no identity.")
        }
        guard recoveryActionStillCurrent(action, session: session, lane: lane) else {
            return .notDispatched(Self.recoveryActionStaleText)
        }
        if let blocked = newWorkBlockedMessage(for: session) { return .notDispatched(blocked) }
        guard !session.runState.isActive else { return .notDispatched("The session is working. Wait for it to finish.") }
        let conversationID = action.target.providerConversationID
        let isNewConversation = action.kind == .continueInNewConversation
        let usesClaude = session.selectedAgent.usesClaudeNativeRuntime
        if isNewConversation {
            guard usesClaude,
                  let conversationID,
                  session.recoveryResumeUnavailableConversationID == conversationID,
                  session.providerSessionID == conversationID
            else {
                return .notDispatched("The previous conversation can no longer be replaced. Review the item again.")
            }
            claudeCoordinator.prepareForConversationResetSync(session)
            session.providerSessionID = nil
            session.recoveryResumeFallbackSuppressedConversationID = nil
            session.recoveryResumeUnavailableConversationID = nil
            session.isDirty = true
        } else if usesClaude, let conversationID {
            session.recoveryResumeFallbackSuppressedConversationID = conversationID
        }
        let result = await submitUserTurnAdmittingRecoveryInput(
            text: text,
            tabID: session.tabID,
            origin: .followUp,
            userItemID: userItemID,
            reservedPayloadOnly: true,
            actionAuthorization: authorization,
            isStillCurrent: { [weak self] in
                self?.recoveryActionStillCurrent(action, session: session, lane: lane, checksTarget: !isNewConversation) ?? false
            }
        )
        switch result {
        case .submitted:
            return .dispatched
        case .scheduled:
            return .notDispatched("The message was scheduled instead of sent.")
        case let .blocked(message):
            if !isNewConversation, session.recoveryResumeFallbackSuppressedConversationID == conversationID {
                session.recoveryResumeFallbackSuppressedConversationID = nil
            }
            return .notDispatched(message.isEmpty ? "The message couldn't be sent." : message)
        }
    }

    /// Why Send saved did not hand its saved input to the normal submit (O11). Nothing was sent.
    struct RecoverySavedRefusal: Error, Equatable {
        let message: String
    }

    /// O11: where Send saved's one saved input executes now.
    struct RecoverySavedPlacement: Equatable {
        /// The same user item (ID, payload, provenance, original timestamp) at the execution end.
        let userItem: AgentChatItem
        /// The clean destination turn the next attempt joins (distinct from every historical turn).
        let executionTurnID: UUID
    }

    static let recoverySavedBubbleMismatchText =
        "The message shown in the conversation differs from the saved message. Edit it to send it."
    /// O11: the saved input is not (or no longer) committed as the clean request at the end of the
    /// conversation, so this submission must not send it.
    static let recoverySavedNotReadyText =
        "This saved message isn’t ready to send at the end of the conversation. Nothing was sent. Review it and choose Send saved again."
    /// O11: the saved message's earlier place in the conversation has a shape that moving it would
    /// change (kept unchanged; Edit stays available).
    static let recoverySavedHistoryNotMovableText =
        "This saved message can’t be moved to the end of the conversation without changing earlier history. Nothing was sent. Edit it to send it."
    /// O11: the conversation is not (or no longer) fully loaded with save authority, so the saved
    /// message is not placed or sent.
    static let recoverySavedNotHydratedText =
        "The conversation hasn’t finished loading. Nothing was sent. Wait for it to load, then choose Send saved again."
    /// O11: the placement at the end of the conversation was not proven durable before sending.
    static let recoverySavedNotCommittedText =
        "The saved message couldn’t be saved at the end of the conversation. Nothing was sent. Choose Send saved again."

    /// Whether `item` is shown exactly as the saved payload's bubble (text, image IDs, tagged-file
    /// IDs, workflow).
    static func recoverySavedOccurrenceMatches(
        _ item: AgentChatItem,
        trimmedText: String,
        attachments: [AgentImageAttachment],
        taggedFiles: [AgentTaggedFileAttachment],
        workflow: AgentWorkflowDefinition?
    ) -> Bool {
        item.kind == .user
            && item.text == userBubbleText(
                trimmedText: trimmedText,
                attachments: attachments,
                taggedFiles: taggedFiles,
                workflow: workflow
            )
            && item.attachments.map(\.id) == attachments.map(\.id)
            && item.taggedFileAttachments.map(\.id) == taggedFiles.map(\.id)
            && item.workflow?.id == workflow?.id
    }

    /// Turns that recovery attempts already join (run attempts' own turns, and the turns their
    /// dispatches executed in): such a turn is historical and never receives a new execution.
    static func recoverySavedReferencedTurnIDs(in record: AgentRecoveryRecord) -> Set<UUID> {
        var turnIDs = Set(record.runAttempts.compactMap(\.transcriptTurnID))
        for attempt in record.attempts where attempt.runAttemptID != nil {
            turnIDs.insert(attempt.transcriptTurnID ?? attempt.userItemID)
        }
        return turnIDs
    }

    private static func recoverySavedRefusal(
        for refusal: AgentTranscriptSavedInputRelocationRefusal
    ) -> RecoverySavedRefusal {
        switch refusal {
        case .conflictingOccurrences, .inconsistentOccurrence:
            RecoverySavedRefusal(message: recoverySavedBubbleMismatchText)
        case .unsynchronizedWorkingItems, .destinationCollision, .postconditionFailed:
            RecoverySavedRefusal(message: recoverySavedNotReadyText)
        case .historicalEnvelopeNotReconcilable:
            RecoverySavedRefusal(message: recoverySavedHistoryNotMovableText)
        }
    }

    /// The working items and the canonical transcript describe the same conversation before the
    /// saved input is resolved (the same synchronous catch-up an owner save performs).
    private func synchronizeDerivedTranscriptForRecoverySavedInput(_ session: AgentTabSession) {
        guard session.derivedTranscriptRefreshTask != nil || session.pendingDerivedTranscriptRefreshReason != nil else {
            return
        }
        refreshDerivedTranscriptState(
            for: session,
            reason: session.pendingDerivedTranscriptRefreshReason ?? .liveMutation
        )
    }

    /// O11 pure resolution of the saved input against the session's current canonical transcript
    /// and working items (see `AgentTranscriptIO.relocatingSavedInput`). The saved item is the
    /// intent's own user item, reconstructed from its payload under its durable creation time.
    private func recoverySavedRelocation(
        userItemID: UUID,
        createdAt: Date?,
        payloadText: String,
        images: [AgentImageAttachment],
        taggedFiles: [AgentTaggedFileAttachment],
        workflow: AgentWorkflowDefinition?,
        referencedTurnIDs: Set<UUID>,
        session: AgentTabSession,
        proposedExecutionTurnID: UUID
    ) -> AgentTranscriptSavedInputRelocation {
        synchronizeDerivedTranscriptForRecoverySavedInput(session)
        let trimmedText = payloadText.trimmingCharacters(in: .whitespacesAndNewlines)
        var savedItem = AgentChatItem.user(
            Self.userBubbleText(trimmedText: trimmedText, attachments: images, taggedFiles: taggedFiles, workflow: workflow),
            id: userItemID,
            attachments: images,
            taggedFileAttachments: taggedFiles,
            workflow: workflow
        )
        if let createdAt {
            savedItem = savedItem.replacingTimestamp(createdAt)
        }
        return AgentTranscriptIO.relocatingSavedInput(
            in: session.transcript,
            workingItems: session.items,
            savedItem: savedItem,
            isConsistentOccurrence: { item in
                Self.recoverySavedOccurrenceMatches(
                    item,
                    trimmedText: trimmedText,
                    attachments: images,
                    taggedFiles: taggedFiles,
                    workflow: workflow
                )
            },
            referencedTurnIDs: referencedTurnIDs,
            terminalState: session.runState,
            nextSequenceIndex: session.nextSequenceIndex,
            proposedExecutionTurnID: proposedExecutionTurnID
        )
    }

    /// O11 synchronous preparation (main actor, no suspension between resolution and
    /// installation): the saved input is either already the clean request of the final turn and
    /// the last working item, or the same item (reconstructed from the intent when no occurrence
    /// survives) is placed in a new clean destination turn at the execution end, its historical
    /// envelope and every other turn kept. A prepared placement is installed and marked dirty.
    func prepareRecoverySavedInputPlacement(
        intent: AgentRecoveryIntent,
        images: [AgentImageAttachment],
        referencedTurnIDs: Set<UUID>,
        session: AgentTabSession,
        proposedExecutionTurnID: UUID = UUID()
    ) -> Result<RecoverySavedPlacement, RecoverySavedRefusal> {
        let relocation = recoverySavedRelocation(
            userItemID: intent.userItemID,
            createdAt: intent.createdAt.date,
            payloadText: intent.payload.text,
            images: images,
            taggedFiles: intent.payload.taggedFiles.map(\.attachment),
            workflow: intent.payload.workflow?.definition,
            referencedTurnIDs: referencedTurnIDs,
            session: session,
            proposedExecutionTurnID: proposedExecutionTurnID
        )
        switch relocation {
        case let .unchanged(userItem, executionTurnID):
            return .success(RecoverySavedPlacement(userItem: userItem, executionTurnID: executionTurnID))
        case let .prepared(candidate):
            installRecoverySavedInputPlacement(candidate, in: session)
            return .success(RecoverySavedPlacement(userItem: candidate.userItem, executionTurnID: candidate.executionTurnID))
        case let .refused(refusal):
            return .failure(Self.recoverySavedRefusal(for: refusal))
        }
    }

    /// Whether `placement` is still the saved input's clean destination at the execution end.
    private func recoverySavedPlacementIsCurrent(
        _ placement: RecoverySavedPlacement,
        intent: AgentRecoveryIntent,
        images: [AgentImageAttachment],
        referencedTurnIDs: Set<UUID>,
        session: AgentTabSession
    ) -> Bool {
        let relocation = recoverySavedRelocation(
            userItemID: intent.userItemID,
            createdAt: intent.createdAt.date,
            payloadText: intent.payload.text,
            images: images,
            taggedFiles: intent.payload.taggedFiles.map(\.attachment),
            workflow: intent.payload.workflow?.definition,
            referencedTurnIDs: referencedTurnIDs,
            session: session,
            proposedExecutionTurnID: UUID()
        )
        guard case let .unchanged(userItem, executionTurnID) = relocation else { return false }
        return executionTurnID == placement.executionTurnID && userItem.id == placement.userItem.id
    }

    /// Synchronous submit gate (O11): an authorized saved-input resend reuses its bubble only under
    /// its own still-current preparation, as the clean final request and last working item. It
    /// never appends: a missing, stale, or moved placement refuses.
    func recoverySavedPreparedBubble(
        _ admitted: AdmittedUserTurnInput,
        session: AgentTabSession,
        trimmedText: String,
        attachments: [AgentImageAttachment],
        taggedFiles: [AgentTaggedFileAttachment],
        workflow: AgentWorkflowDefinition?
    ) -> Result<AgentChatItem, RecoverySavedRefusal> {
        guard let preparation = admitted.savedPreparation,
              preparation.tabID == session.tabID,
              preparation.authorizationToken == admitted.identity.actionAuthorization?.token,
              preparation.intentID == admitted.identity.intentID,
              preparation.userItemID == admitted.identity.userItemID
        else {
            return .failure(RecoverySavedRefusal(message: Self.recoverySavedNotReadyText))
        }
        let relocation = recoverySavedRelocation(
            userItemID: preparation.userItemID,
            createdAt: nil,
            payloadText: trimmedText,
            images: attachments,
            taggedFiles: taggedFiles,
            workflow: workflow,
            referencedTurnIDs: [],
            session: session,
            proposedExecutionTurnID: UUID()
        )
        switch relocation {
        case let .unchanged(userItem, executionTurnID) where executionTurnID == preparation.executionTurnID:
            return .success(userItem)
        case .refused(.conflictingOccurrences), .refused(.inconsistentOccurrence):
            return .failure(RecoverySavedRefusal(message: Self.recoverySavedBubbleMismatchText))
        default:
            return .failure(RecoverySavedRefusal(message: Self.recoverySavedNotReadyText))
        }
    }

    /// O11: one real owner write covering the installed placement, before the queue receipt and any
    /// provider byte. The save is forced (dirty) even for an unchanged placement; a save already in
    /// flight is joined and followed by at most one further explicit flush. Only a `.written`
    /// receipt covering the capture under the same owner, binding, and persistence context
    /// qualifies; suppressed, reset-only, deferred, and non-writing outcomes never do. Also proves a
    /// new delegated child's stub durable before its parent link (Step 5b).
    func commitRecoverySavedPlacement(_ session: AgentTabSession) async -> Bool {
        session.isDirty = true
        let capture = captureTranscriptSaveState(session)
        var outcome = await recoverySavedPlacementSave(session)
        if outcome == .deferredBehindInFlightSave {
            if let sessionID = session.activeAgentSessionID {
                await awaitInFlightSave(sessionID: sessionID)
            }
            guard sessions[session.tabID] === session else { return false }
            outcome = await recoverySavedPlacementSave(session)
        }
        guard case let .written(receipt) = outcome else { return false }
        return staleWriteCoversCapture(receipt, capture, session: session)
    }

    private func recoverySavedPlacementSave(_ session: AgentTabSession) async -> SessionSaveOutcome {
        #if DEBUG
            if let override = test_recoverySavedPlacementSaveOutcomeOverride,
               let outcome = await override(session)
            {
                return outcome
            }
        #endif
        return await flushSaveDetailed(for: session.tabID)
    }

    /// Send saved: the one saved intent the reservation claimed, handed to normal dispatch under a
    /// store-issued queue receipt carrying the action's coordinator-issued authorization. Refused
    /// (kept, never withdrawn) when it carries a pending handoff or any earlier attempt may have
    /// delivered it (no uncertain-delivery retry); Edit stays available for those.
    ///
    /// O11 ordering: the same saved input is first placed at the conversation's execution end
    /// (its historical envelope and every other turn kept; reconstructed from the intent when no
    /// occurrence survives) and that placement is proven durable by a covering owner write; the
    /// queue receipt and the synchronous submit follow, each after revalidating the action, owner,
    /// idle local state, and destination. The submit reuses the placed bubble (`.reused`), so a
    /// failed send leaves the same input unsent there.
    func dispatchRecoverySavedIntent(
        _ action: AgentRecoveryAction,
        authorization: AgentRecoveryActionAuthorization,
        session: AgentTabSession,
        lane: AgentRecoverySessionLane
    ) async -> AgentRecoveryDispatchResult {
        guard action.sourceIntentIDs.count == 1, let intentID = action.sourceIntentIDs.first else {
            return .notDispatched("Send one saved message at a time.")
        }
        func stillCurrent() -> String? {
            guard recoveryActionStillCurrent(action, session: session, lane: lane) else { return Self.recoveryActionStaleText }
            // The placement edits the hydrated transcript and is committed by an owner save: it
            // needs the same paired hydration authority a covering save does (never an unloaded,
            // loading, unresolved, failed, or suppressed hydration).
            guard hasTranscriptSaveHydrationAuthority(session) else { return Self.recoverySavedNotHydratedText }
            if let blocked = newWorkBlockedMessage(for: session) { return blocked }
            guard !session.runState.isActive else { return "The session is working. Wait for it to finish." }
            guard session.remoteHost == nil else { return Self.recoveryActionSessionBusyMessage }
            return nil
        }
        if let stale = stillCurrent() { return .notDispatched(stale) }
        guard case let .success(.supported(record)) = await lane.readRecord(), let intent = record.intent(id: intentID) else {
            return .notDispatched("The saved message couldn't be read.")
        }
        if let stale = stillCurrent() { return .notDispatched(stale) }
        guard intent.pendingHandoff == nil else {
            return .notDispatched("This message carries earlier conversation history. Edit it to send it.")
        }
        // No uncertain-delivery retry: only a queued intent whose every earlier attempt is
        // conclusively not delivered may be sent again (its shown bubble is then reused).
        guard intent.deliveryState == .queued,
              AgentColdRestoreInterruptionContext.unacceptedDelivery(
                  state: intent.deliveryState,
                  attempts: record.attempts(forIntent: intentID),
                  // Only `.notSent` matters here; the flag changes the uncertain wording alone.
                  runsEndedWithRecordedEvidence: record.intentRunsEndedWithRecordedEvidence(intentID: intentID)
              ) == .notSent
        else {
            return .notDispatched("This message may already have been delivered. Check the conversation, then edit it to send it again.")
        }
        var images: [AgentImageAttachment] = []
        for reference in intent.payload.images {
            guard let attachment = lane.store.attachment(for: reference, sessionID: lane.sessionID) else {
                return .notDispatched("An attachment of the saved message is missing. Edit it to send it.")
            }
            images.append(attachment)
        }
        let referencedTurnIDs = Self.recoverySavedReferencedTurnIDs(in: record)
        let placement: RecoverySavedPlacement
        switch prepareRecoverySavedInputPlacement(
            intent: intent,
            images: images,
            referencedTurnIDs: referencedTurnIDs,
            session: session
        ) {
        case let .success(value):
            placement = value
        case let .failure(refusal):
            return .notDispatched(refusal.message)
        }
        func placementStillCurrent() -> String? {
            if let stale = stillCurrent() { return stale }
            guard recoverySavedPlacementIsCurrent(
                placement,
                intent: intent,
                images: images,
                referencedTurnIDs: referencedTurnIDs,
                session: session
            ) else { return Self.recoverySavedNotReadyText }
            return nil
        }
        // The placement is durable before the queue receipt and before any provider byte.
        guard await commitRecoverySavedPlacement(session) else {
            return .notDispatched(Self.recoverySavedNotCommittedText)
        }
        if let stale = placementStillCurrent() { return .notDispatched(stale) }
        let receipt: AgentRecoveryQueueReceipt
        switch await lane.issueQueueReceipt(intentID: intentID) {
        case let .success(value):
            receipt = value
        case let .failure(failure):
            return .notDispatched("The saved message can't be sent now (\(Self.recoveryListDescription(of: failure))).")
        }
        if let stale = placementStillCurrent() { return .notDispatched(stale) }
        let identity = AgentQueuedInputIdentity(receipt: receipt, actionAuthorization: authorization)
        guard identity.intentID == intentID, identity.userItemID == placement.userItem.id else {
            return .notDispatched(Self.recoverySavedNotReadyText)
        }
        let admitted = AdmittedUserTurnInput(
            identity: identity,
            content: intent.payload,
            attachments: images,
            taggedFiles: intent.payload.taggedFiles.map(\.attachment),
            workflow: intent.payload.workflow?.definition,
            interviewFirst: intent.payload.interviewFirst,
            consumesComposer: false,
            savedPreparation: RecoverySavedInputPreparation(
                authorizationToken: authorization.token,
                intentID: intentID,
                userItemID: placement.userItem.id,
                executionTurnID: placement.executionTurnID,
                tabID: session.tabID
            )
        )
        switch submitUserTurn(text: intent.payload.text, tabID: session.tabID, codexAttemptID: nil, admitted: admitted) {
        case .submitted:
            return .dispatched
        case .scheduled:
            return .notDispatched("The message was scheduled instead of sent.")
        case let .blocked(message):
            return .notDispatched(message.isEmpty ? "The saved message couldn't be sent." : message)
        }
    }

    /// Review A P1-01: an action payload is only started as a local run; never queued behind a live
    /// run or sent through a remote host.
    static let recoveryActionSessionBusyMessage =
        "The session is working. Wait for it to finish, then choose again."

    /// Review A P1-01: a run start that provably handed the action's payload off to nothing ends its
    /// submission (revoked: a later queue drain or retry can never use the token). Codex
    /// `queuedFallback` is restart-held, not handoff, and `nil` means the runtime changed before
    /// send started. A sent, delivery-unknown, or admitted (non-Codex `nil`) start settles through
    /// its dispatch evidence or provider handoff instead.
    func noteRecoveryActionStartReturned(
        _ identity: AgentQueuedInputIdentity,
        outcome: CodexAgentModeCoordinator.NativeSendOutcome?,
        isCodex: Bool
    ) {
        guard let authorization = identity.actionAuthorization else { return }
        let ended: Bool = if isCodex {
            switch outcome {
            case .queuedFallback?, .stale?, .failed?, .cancelled?, nil:
                true
            case .sent?, .deliveryUnknown?:
                false
            }
        } else {
            Self.runStartDidNotHandOff(outcome)
        }
        guard ended else { return }
        let reason: String? = switch outcome {
        case let .stale(reason)?: reason
        case let .failed(message)?: message
        case .queuedFallback?: "The message was held instead of sent."
        default: nil
        }
        recoveryCoordinator?.noteRecoveryActionSubmissionEnded(authorization, reason: reason)
    }

    // MARK: Dispatch baseline (pre-send history position)

    /// Outcome of one Claude dispatch's pre-byte baseline admission.
    enum RecoveryDispatchBaselineAdmission: Equatable {
        /// Not qualified (production), not Claude, or no durable dispatch: nothing read or written.
        case notCaptured
        /// This dispatch already has its recorded boundary (a re-entered admission).
        case alreadyRecorded
        /// Captured, committed in a zero-row session receipt, then the cursor was seeded if absent.
        case committed
        /// `committed`, and this call's baseline carries the outbound user-message claim for this
        /// UUID (its exact receipt committed and the session was still current afterwards).
        case committedWithOutboundUserMessage(UUID)
        /// No boundary can be taken before the bytes; recorded, and the ordinary send proceeds.
        case unsupported(String)
        /// The enabled baseline could not be persisted (or the session changed): zero bytes.
        case refused(String)

        var admitsWrite: Bool {
            if case .refused = self { return false }
            return true
        }
    }

    func admitClaudeDispatchBaseline(
        _ identity: AgentDispatchBaselineIdentity?,
        outboundUserMessage: AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage?,
        session: AgentTabSession
    ) async -> AgentRuntimeWriteAdmission {
        #if DEBUG
            if let override = test_claudeDispatchBaselineAdmission {
                return await override(identity, outboundUserMessage, session)
            }
        #endif
        switch await captureClaudeDispatchBaseline(identity, outboundUserMessage: outboundUserMessage, session: session) {
        case .refused:
            return .denied
        case let .committedWithOutboundUserMessage(uuid):
            return .admitted(outboundUserMessageUUID: uuid)
        case .notCaptured, .alreadyRecorded, .committed, .unsupported:
            // Re-entered (including a joined pending receipt), legacy, unsupported or ungated: the
            // ordinary send, never reusing or minting an identity.
            return .admittedWithoutIdentity
        }
    }

    /// Captures the dispatch's pre-send boundary (validated `.baseline` read off the main actor),
    /// commits it as a zero-row import receipt through ONE owner session save, verifies that exact
    /// receipt committed, and only then seeds the recovery cursor (compare-and-swap on "none"). A
    /// boundary is per dispatch and immutable; a missing conversation identity or history location
    /// is recorded as unsupported (never backfilled later) and the send proceeds ordinarily.
    func captureClaudeDispatchBaseline(
        _ identity: AgentDispatchBaselineIdentity?,
        outboundUserMessage: AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage? = nil,
        session: AgentTabSession
    ) async -> RecoveryDispatchBaselineAdmission {
        // Production OFF: zero history reads, zero extra writes, ordinary send behavior.
        guard session.selectedAgent == .claudeCode,
              recoveryActionRunner.capturesDispatchBaselines(for: session.selectedAgent)
        else { return .notCaptured }
        guard let identity, let lane = session.recoveryLane, !lane.isRetired else { return .notCaptured }
        let generation = lane.binding.transcriptResetGeneration
        func stillCurrent(_ conversationID: String?) -> Bool {
            sessions[session.tabID] === session && session.recoveryLane === lane && !lane.isRetired
                && lane.binding.transcriptResetGeneration == generation
                && session.providerSessionID == conversationID
        }
        /// A dispatch that already has its boundary never records (or claims) another one.
        func admitRecorded() async -> RecoveryDispatchBaselineAdmission? {
            guard let existing = session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID) else {
                return nil
            }
            guard existing.status == .captured, let commitID = existing.baselineCommitID,
                  session.pendingHistoryImportCommit?.importID == commitID
            else { return .alreadyRecorded }
            // Its receipt is still pending from an earlier admission: it must commit before bytes.
            return await commitPendingBaselineReceipt(commitID, session: session)
                ? .alreadyRecorded
                : .refused("The pre-send history position couldn't be saved.")
        }
        if let recorded = await admitRecorded() { return recorded }
        func recordUnsupported(_ reason: String, conversationID: String?) async -> RecoveryDispatchBaselineAdmission {
            // Re-checked after this admission's awaits: a concurrent admission of the same dispatch
            // may have recorded its boundary meanwhile.
            if let recorded = await admitRecorded() { return recorded }
            var ledger = session.providerHistoryRecovery ?? AgentSessionProviderHistoryRecovery()
            ledger.dispatchBaselines.append(.init(
                dispatchID: identity.dispatchID,
                runAttemptID: identity.runAttemptID,
                transcriptResetGeneration: generation,
                providerRaw: ClaudeSessionHistoryReader.providerRaw,
                conversationID: conversationID,
                userItemIDs: identity.userItemIDs,
                file: nil,
                completeLineOffset: 0,
                baselineCommitID: nil,
                profileName: ClaudeSessionHistoryReader.profileName,
                status: .unsupported(reason),
                recordedAt: Date()
            ))
            session.providerHistoryRecovery = ledger
            session.isDirty = true
            scheduleSave(for: session.tabID)
            return .unsupported(reason)
        }
        guard let conversationID = session.providerSessionID, !conversationID.isEmpty else {
            return await recordUnsupported("no Claude conversation identity before sending", conversationID: nil)
        }
        let location = await recoveryClaudeHistoryRoots(conversationID: conversationID)
        guard stillCurrent(conversationID) else { return .refused(Self.recoveryActionStaleText) }
        let roots: [URL]
        switch location {
        case let .roots(found):
            roots = found
        case .unknown:
            return await recordUnsupported("Claude history location unknown", conversationID: conversationID)
        case .ambiguous:
            return await recordUnsupported(Self.recoveryClaudeHistoryAmbiguousReason, conversationID: conversationID)
        case .uninspectable:
            return await recordUnsupported(Self.recoveryClaudeHistoryUninspectableReason, conversationID: conversationID)
        }
        // The previous latest receipt's proven target must still hold before this boundary may
        // replace it as the latest receipt (verified on the same captured bytes).
        let fencedReceipt = session.providerHistoryRecovery?.lastImportCommit
        let read = await Self.readClaudeHistory(RecoveryHistoryReadInput(
            conversationID: conversationID,
            roots: roots,
            mode: .baseline,
            ledger: nil,
            fences: AgentProviderHistoryAssociationPreflight.claudeBaselineFences(
                ledger: session.providerHistoryRecovery,
                conversationID: conversationID
            )
        ))
        guard stillCurrent(conversationID) else { return .refused(Self.recoveryActionStaleText) }
        let candidate: ClaudeSessionHistoryReader.Candidate
        switch read {
        case let .candidate(value):
            candidate = value
        case let .unavailable(reason):
            return await recordUnsupported(Self.recoveryHistoryText(reason), conversationID: conversationID)
        case .unsupported(.rewrittenHistory):
            return await recordUnsupported(Self.recoveryBaselineRewrittenReason, conversationID: conversationID)
        case .unsupported(.prefixProofUnavailable):
            // Distinct from a changed history (review B P3-02): the last target was lost or unproven.
            return await recordUnsupported(Self.recoveryBaselineUnprovenReason, conversationID: conversationID)
        case let .unsupported(other):
            return await recordUnsupported(Self.recoveryBaselineUnsupportedReason(other), conversationID: conversationID)
        }
        // A pending receipt (a reset or an earlier import still saving) is flushed first; one
        // that cannot commit leaves no room for this boundary: zero bytes.
        if session.pendingTranscriptResetReceipt != nil || session.pendingHistoryImportCommit != nil {
            _ = await saveSession(for: session.tabID)
            guard stillCurrent(conversationID),
                  session.pendingTranscriptResetReceipt == nil,
                  session.pendingHistoryImportCommit == nil
            else { return .refused("An earlier save of this session is still pending.") }
        }
        // Re-checked after every read/save await above and immediately before the append (no
        // suspension between): two admissions of one dispatch can never both record a boundary.
        if let recorded = await admitRecorded() { return recorded }
        // The receipt the read fenced must still be the latest one. A real ownership change was
        // refused above; when only the receipt moved (e.g. a concurrent admission's boundary), this
        // boundary is recorded unsupported (no claim, no UUID, no proof) and the ordinary send
        // proceeds (review B P2-02). No reread: the unsupported entry never replaces that receipt.
        guard session.providerHistoryRecovery?.lastImportCommit == fencedReceipt else {
            guard stillCurrent(conversationID) else { return .refused(Self.recoveryActionStaleText) }
            return await recordUnsupported(Self.recoveryBaselineReceiptMovedReason, conversationID: conversationID)
        }
        let claim = outboundUserMessage.flatMap {
            Self.qualifiedOutboundUserMessageClaim($0, identity: identity, session: session)
        }
        let commitID = UUID()
        let now = Date()
        // The zero-row receipt binds the same target its baseline owns.
        let receipt = AgentSessionProviderHistoryRecovery.ImportCommit(
            importID: commitID,
            providerRaw: ClaudeSessionHistoryReader.providerRaw,
            conversationID: conversationID,
            committedAt: now,
            rowCount: 0,
            target: AgentRecoveryHistoryPrefixFence(
                file: candidate.file,
                completeLineOffset: candidate.completeLineOffset,
                prefixSHA256: candidate.prefixSHA256
            )
        )
        let baseline = AgentSessionProviderHistoryRecovery.DispatchBaseline(
            dispatchID: identity.dispatchID,
            runAttemptID: identity.runAttemptID,
            transcriptResetGeneration: generation,
            providerRaw: ClaudeSessionHistoryReader.providerRaw,
            conversationID: conversationID,
            userItemIDs: identity.userItemIDs,
            file: candidate.file,
            completeLineOffset: candidate.completeLineOffset,
            prefixSHA256: candidate.prefixSHA256,
            baselineCommitID: commitID,
            profileName: ClaudeSessionHistoryReader.profileName,
            status: .captured,
            recordedAt: now,
            outboundUserMessage: claim
        )
        var ledger = session.providerHistoryRecovery ?? AgentSessionProviderHistoryRecovery()
        ledger.dispatchBaselines.append(baseline)
        ledger.lastImportCommit = receipt
        session.providerHistoryRecovery = ledger
        session.pendingHistoryImportCommit = receipt
        guard await commitPendingBaselineReceipt(commitID, session: session) else {
            // The receipt stays pending for the next owner save (a pre-byte boundary of a write that
            // never happened is harmless); the cursor did not move and nothing is sent.
            return .refused("The pre-send history position couldn't be saved.")
        }
        guard stillCurrent(conversationID), let cursor = baseline.cursor else {
            return .refused(Self.recoveryActionStaleText)
        }
        // Cursor second, and only when none exists: the session baseline is the authority.
        _ = await lane.commitHistoryCursor(expectedPreviousImportID: nil, cursor: cursor)
        // The claim's exact receipt committed above; it reaches the wire only while still current.
        guard let claim, stillCurrent(conversationID),
              session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID)?.outboundUserMessage == claim
        else { return .committed }
        return .committedWithOutboundUserMessage(claim.uuid)
    }

    /// The candidate claim, only for a complete dispatch identity whose every ordered constituent is
    /// exactly one canonical user item of this session (all-or-nothing); otherwise no claim and the
    /// ordinary send. The claim UUID must be the dispatch's own ID.
    private static func qualifiedOutboundUserMessageClaim(
        _ candidate: AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage,
        identity: AgentDispatchBaselineIdentity,
        session: AgentTabSession
    ) -> AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage? {
        let constituents = identity.userItemIDs
        guard candidate.uuid == identity.dispatchID, identity.hasCompleteUserItems, !constituents.isEmpty,
              Set(constituents).count == constituents.count
        else { return nil }
        let wanted = Set(constituents)
        var userMatches: [UUID: Int] = [:]
        for item in session.items where wanted.contains(item.id) {
            guard item.kind == .user else { return nil }
            userMatches[item.id, default: 0] += 1
        }
        guard constituents.allSatisfy({ userMatches[$0] == 1 }) else { return nil }
        return candidate
    }

    /// A zero-row baseline receipt is a real commit: saved through the owner save path and verified.
    private func commitPendingBaselineReceipt(_ commitID: UUID, session: AgentTabSession) async -> Bool {
        for _ in 0 ..< 2 {
            session.isDirty = true
            _ = await saveSession(for: session.tabID)
            if session.committedHistoryImportID == commitID { return true }
            guard session.pendingHistoryImportCommit?.importID == commitID else { return false }
        }
        return false
    }

    // MARK: History-only reconciliation

    /// Reads the provider's own record of the conversation (off the main actor), validates the
    /// whole candidate, then merges inert rows + native-ID ledger + import receipt through ONE owner
    /// session save; only after that save committed this receipt does the recovery cursor advance
    /// (compare-and-swap on the previous import). Never dispatches and never confirms Claude
    /// completion. Every failure is `.blocked` (never "nothing new", review A P1-02); a confirmed
    /// expected-turn completion survives a failed row save or a session change after the read
    /// (A P1-03 / B F2).
    func reconcileRecoveryHistory(
        _ action: AgentRecoveryAction,
        session: AgentTabSession,
        lane: AgentRecoverySessionLane,
        codexTurnID: String?,
        runTurnID: UUID? = nil
    ) async -> AgentRecoveryReconcileResult {
        guard recoveryActionStillCurrent(action, session: session, lane: lane) else {
            return .blocked(Self.recoveryActionStaleText)
        }
        guard let conversationID = action.target.providerConversationID else {
            return .blocked("No provider conversation is recorded for this session, so its history can't be checked.")
        }
        guard !session.runState.isActive else { return .blocked("The session is working. Reconcile after it finishes.") }
        guard session.pendingTranscriptResetReceipt == nil, session.pendingHistoryImportCommit == nil else {
            return .blocked("An earlier save of this session is still pending. Try again shortly.")
        }
        let record: AgentRecoveryRecord?
        switch await lane.readRecord() {
        case let .success(.supported(value)):
            record = value
        case .success(.absent):
            record = nil
        default:
            return .blocked("This session's recovery data couldn't be read.")
        }
        let ledgerAtStart = session.providerHistoryRecovery
        // Claude: the interrupted attempt's OWN pre-send baseline (its earliest dispatch) is the only
        // starting boundary; the conversation-level cursor is never a fallback. Checked before any read.
        var claudeBaseline: AgentSessionProviderHistoryRecovery.DispatchBaseline?
        if session.selectedAgent == .claudeCode {
            claudeBaseline = action.sourceRunAttemptID.flatMap { ledgerAtStart?.firstDispatchBaseline(runAttemptID: $0) }
            if let refusal = AgentProviderHistoryAssociationPreflight.baselineRefusal(
                baseline: claudeBaseline,
                hasUnreadableBaselines: !(ledgerAtStart?.unreadableDispatchBaselines.isEmpty ?? true),
                expectedRunAttemptID: action.sourceRunAttemptID,
                providerRaw: ClaudeSessionHistoryReader.providerRaw,
                conversationID: conversationID,
                transcriptResetGeneration: lane.binding.transcriptResetGeneration
            ) {
                return .associationUnavailable(refusal, Self.recoveryAssociationText(refusal, baseline: claudeBaseline))
            }
        }
        // Claude: the attempt's whole dispatch window (its boundary first). The persisted record
        // cursor, when present, is one more byte fence (never the frontier or a fallback); a
        // missing or malformed proof on it fails closed.
        let claudeWindow = action.sourceRunAttemptID.map { runAttemptID in
            ledgerAtStart?.dispatchBaselines.filter { $0.runAttemptID == runAttemptID } ?? []
        } ?? []
        let recordCursorFence = record?.historyCursor(
            providerRaw: ClaudeSessionHistoryReader.providerRaw,
            conversationID: conversationID
        )?.prefixFence
        let observation: AgentProviderHistoryObservation
        switch await recoveryHistoryObservation(
            action: action,
            session: session,
            lane: lane,
            conversationID: conversationID,
            claudeBoundary: claudeBaseline?.cursor,
            claudeFences: AgentProviderHistoryAssociationPreflight.claudePrefixFences(
                window: claudeWindow,
                ledger: ledgerAtStart,
                conversationID: conversationID
            ) + [recordCursorFence].compactMap(\.self),
            ledger: ledgerAtStart,
            codexTurnID: codexTurnID
        ) {
        case let .success(value):
            observation = value
        case let .failure(failure):
            // Only a successful observation that proved nothing (Codex has no usable record of the
            // turn) lets a continuation follow; every other failure blocks it.
            return failure.isUnconfirmedObservation ? .nothingImported(failure.message) : .blocked(failure.message)
        }
        // Completion counts only for the expected turn of the action's own source run attempt. It
        // is decided from the observation itself, independently of whether any row can be saved.
        let completion: AgentRecoveryReconcileCompletion = if observation.completionConfirmed,
                                                              let runAttemptID = action.sourceRunAttemptID
        {
            .confirmed(runAttemptID: runAttemptID)
        } else {
            .unconfirmed
        }
        // History-only merge: revalidated on the main actor against an unchanged session.
        guard recoveryActionStillCurrent(action, session: session, lane: lane),
              !session.runState.isActive,
              session.pendingTranscriptResetReceipt == nil,
              session.pendingHistoryImportCommit == nil,
              session.providerHistoryRecovery == ledgerAtStart
        else {
            return .blocked("The session changed while its history was read. Nothing was imported.", completion: completion)
        }
        let canonical = AgentProviderHistoryCanonicalView(transcript: session.transcript, suffixItems: session.items)
        // Claude: canonical import needs explicit native ↔ canonical associations (canonical turns,
        // compacted ones included, plus the mutable suffix): the attempt's exactly matched outbound
        // claims (Step 4d2) or ledger associations. Live output persisted under its own IDs has none:
        // without exact claims it refuses (blocking a continuation); with exact claims and every other
        // check passed (9-live r3 T1), the whole import is withheld as "nothing imported" so a
        // continuation may follow. Both leave rows, ledger, receipt and cursor unchanged.
        if session.selectedAgent == .claudeCode,
           let refusal = AgentProviderHistoryAssociationPreflight.check(
               observation: observation,
               baseline: claudeBaseline,
               hasUnreadableBaselines: !(ledgerAtStart?.unreadableDispatchBaselines.isEmpty ?? true),
               expectedRunAttemptID: action.sourceRunAttemptID,
               transcriptResetGeneration: lane.binding.transcriptResetGeneration,
               canonical: canonical,
               ledger: ledgerAtStart,
               dispatchWindow: claudeWindow
           )
        {
            if refusal == .canonicalOutputImportWithheld, case .unconfirmed = completion {
                let hasNativeOutput = observation.rows.contains { $0.item != nil }
                return .nothingImported(hasNativeOutput ? Self.recoveryClaudeOutputWithheldText : Self.recoveryClaudeOutputUnmatchedText)
            }
            return .associationUnavailable(refusal, Self.recoveryAssociationText(refusal, baseline: claudeBaseline))
        }
        // Codex: no native → canonical mapping exists for live Codex items, so rows that could
        // overlap output already in the conversation are withheld entirely (zero rows, zero writes,
        // no cursor movement); a confirmed completion stays honest (review A P1-04 / B F1).
        if session.selectedAgent == .codexExec {
            let turnUserItemIDs = Set(runTurnID.flatMap { turnID in
                session.transcript.turns.first { $0.id == turnID }?.request.map { [$0.id] }
            } ?? [])
            if AgentProviderHistoryAssociationPreflight.codexOverlapRefusal(
                observation: observation,
                turnUserItemIDs: turnUserItemIDs,
                canonical: canonical,
                ledger: ledgerAtStart
            ) != nil {
                if case .confirmed = completion { return .imported(completion: completion, rowCount: 0) }
                return .nothingImported(Self.recoveryCodexOverlapText)
            }
        }
        let previousCursor = record?.historyCursor(providerRaw: observation.provider.rawValue, conversationID: conversationID)
        // Claude plans against every canonical ID (persisted turns, requests included, plus the
        // suffix), after the preflight compared any overlap: a row held only by a persisted turn is
        // recorded, never appended again (Step 4d3a). Codex keeps the suffix.
        let existingItemIDs = session.selectedAgent == .claudeCode
            ? Set(AgentProviderHistoryAssociationPreflight.canonicalItemIDs(canonical))
            : Set(session.items.map(\.id))
        let plan = AgentProviderHistoryImportPlanner.plan(
            observation: observation,
            existingItemIDs: existingItemIDs,
            ledger: ledgerAtStart,
            previousCursor: previousCursor,
            importID: UUID(),
            now: Date()
        )
        guard !plan.appendedItems.isEmpty || plan.ledger.nativeItems.count != (ledgerAtStart?.nativeItems.count ?? 0) else {
            if case .confirmed = completion { return .imported(completion: completion, rowCount: 0) }
            return .nothingImported("The provider has no new history for this conversation.")
        }
        session.providerHistoryRecovery = plan.ledger
        session.pendingHistoryImportCommit = plan.importCommit
        for item in plan.appendedItems {
            session.appendItem(item)
        }
        session.isDirty = true
        _ = await saveSession(for: session.tabID)
        guard session.committedHistoryImportID == plan.importID else {
            // The rows and receipt stay pending for the next owner save; the cursor did not move,
            // so a later reconcile rescans and the ledger keeps it idempotent. A confirmed
            // completion still stops a continuation.
            if case .confirmed = completion {
                return .blocked(
                    "The interrupted turn had already finished, but its recovered output couldn't be saved yet. Nothing was sent.",
                    completion: completion
                )
            }
            return .blocked("The recovered history couldn't be saved yet. Its position was not advanced. Nothing was sent.")
        }
        // Cursor second. A lost cursor commit is safe: the next import rescans and deduplicates.
        _ = await lane.commitHistoryCursor(expectedPreviousImportID: plan.previousImportID, cursor: plan.cursor)
        return .imported(completion: completion, rowCount: plan.appendedItems.count)
    }

    private struct RecoveryHistoryFailure: Error {
        let message: String
        /// The observation itself succeeded but proved nothing (not a failure of the check).
        var isUnconfirmedObservation = false
    }

    /// 9-live r3 T1: Claude's history has output after the interrupted send that couldn't be matched
    /// to this conversation's own output, so none of it was imported.
    static let recoveryClaudeOutputWithheldText =
        "Claude's history has output RepoPrompt couldn't safely match to this conversation. Nothing was imported, so some of it may not show here; Claude still has it."
    /// 9-live r3 T1: this conversation shows output Claude's history doesn't match, and Claude has no
    /// other output to import.
    static let recoveryClaudeOutputUnmatchedText =
        "RepoPrompt couldn't safely match this conversation's output to Claude's history. Nothing was imported."

    static let recoveryCodexOverlapText =
        "Codex's record of the turn overlaps output already shown in this conversation, so nothing was imported."

    /// Immutable reader inputs handed off the main actor (value types, never mutated).
    private struct RecoveryHistoryReadInput: @unchecked Sendable {
        let conversationID: String
        let roots: [URL]
        let mode: ClaudeSessionHistoryReader.Mode
        let ledger: AgentSessionProviderHistoryRecovery?
        var fences: [AgentRecoveryHistoryPrefixFence] = []
    }

    private nonisolated static func readClaudeHistory(_ input: RecoveryHistoryReadInput) async -> ClaudeSessionHistoryReader.Result {
        ClaudeSessionHistoryReader.read(
            nativeSessionID: input.conversationID,
            projectsDirectories: input.roots,
            mode: input.mode,
            ledger: input.ledger,
            fences: input.fences
        )
    }

    static let recoveryClaudeHistoryAmbiguousReason = "Claude history for this conversation exists in more than one location"
    static let recoveryClaudeHistoryUninspectableReason = "Claude history location couldn't be checked"

    enum RecoveryClaudeHistoryLocation: Equatable {
        /// The `projects` roots to read (never empty).
        case roots([URL])
        case unknown
        /// The fallback search found the conversation's file under more than one home: baseline is
        /// recorded unsupported (the send proceeds); reconcile fails.
        case ambiguous
        /// A fallback candidate couldn't be inspected, so a single hit isn't proven unique: baseline
        /// is recorded unsupported (the send proceeds); reconcile fails.
        case uninspectable
    }

    /// Where this conversation's Claude history lives (O42). First the homes the registry recorded
    /// for this conversation's own runtimes; when none is recorded yet (discovery may not have seen
    /// the real CLI since spawn), at most one registry refresh per lookup (only while a runtime may still reveal its home, up to
    /// a small per-runtime cap) and a re-read;
    /// then the bounded `ClaudeHistoryLocator` search over every recorded Claude home, the app's
    /// `CLAUDE_CONFIG_DIR` and `~/.claude`, which must find exactly one home holding
    /// `<conversationID>.jsonl` with every candidate inspected. Baseline and reconcile share this
    /// selection logic but resolve at different times, so they may pick different roots (for
    /// example, a home recorded after a locator-found baseline); the cursor's file identity is what
    /// guards a reconcile against reading a different file.
    private func recoveryClaudeHistoryRoots(conversationID: String) async -> RecoveryClaudeHistoryLocation {
        #if DEBUG
            test_recoveryClaudeHistoryAccessCount += 1
        #endif
        func projects(_ home: URL) -> URL {
            home.appendingPathComponent("projects", isDirectory: true)
        }
        var homes = await recoveryClaudeRecordedHomes(conversationID: conversationID)
        if homes.isEmpty {
            homes = await recoveryClaudeRefreshedHomes(conversationID: conversationID)
        }
        if !homes.isEmpty {
            return .roots(homes.map { projects(URL(fileURLWithPath: $0, isDirectory: true)) })
        }
        let candidates = await recoveryClaudeLocatorHomes()
        switch await Self.locateClaudeHistory(sessionID: conversationID, homes: candidates) {
        case let .unique(home):
            return .roots([projects(home)])
        case .ambiguous:
            return .ambiguous
        case .uninspectable:
            return .uninspectable
        case nil:
            return .unknown
        }
    }

    @concurrent
    private nonisolated static func locateClaudeHistory(sessionID: String, homes: [URL]) async -> ClaudeHistoryLocator.Location? {
        ClaudeHistoryLocator.locate(sessionID: sessionID, homes: homes)
    }

    /// The registry's recorded homes for this conversation's own runtimes.
    private func recoveryClaudeRecordedHomes(conversationID: String) async -> [String] {
        #if DEBUG
            if let override = test_recoveryClaudeHistoryHomes {
                return await override(conversationID).filter { !$0.isEmpty }
            }
        #endif
        return await recoveryHistoryRegistry?.claudeProviderHomes(conversationID: conversationID) ?? []
    }

    /// The recorded homes after at most one discovery pass (only while a runtime may still reveal
    /// its home, up to a small per-runtime cap), so a just-spawned
    /// CLI's `CLAUDE_CONFIG_DIR` can be recorded.
    private func recoveryClaudeRefreshedHomes(conversationID: String) async -> [String] {
        #if DEBUG
            // A fixture home lookup stands in for the registry: never refresh a real one.
            if test_recoveryClaudeHistoryHomes != nil {
                await test_recoveryRefreshHistoryRegistry?()
                return await recoveryClaudeRecordedHomes(conversationID: conversationID)
            }
        #endif
        return await recoveryHistoryRegistry?.claudeProviderHomesRefreshingIfPending(conversationID: conversationID) ?? []
    }

    /// The fallback search's candidate homes.
    private func recoveryClaudeLocatorHomes() async -> [URL] {
        #if DEBUG
            if let override = test_recoveryClaudeHistoryLocatorHomes {
                return await override().map { URL(fileURLWithPath: $0, isDirectory: true) }
            }
            // Under XCTest the fallback never reaches the developer's real `~/.claude` or the
            // runner's own `CLAUDE_CONFIG_DIR`.
            if !AgentRecoveryStore.isProductionCompositionActive { return [] }
        #endif
        let recorded = await recoveryHistoryRegistry?.allClaudeProviderHomes() ?? []
        return ClaudeHistoryLocator.candidateHomes(
            recorded: recorded,
            environment: ProcessInfo.processInfo.environment,
            userHome: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    private func recoveryHistoryObservation(
        action: AgentRecoveryAction,
        session: AgentTabSession,
        lane: AgentRecoverySessionLane,
        conversationID: String,
        claudeBoundary: AgentRecoveryHistoryCursor?,
        claudeFences: [AgentRecoveryHistoryPrefixFence],
        ledger: AgentSessionProviderHistoryRecovery?,
        codexTurnID: String?
    ) async -> Result<AgentProviderHistoryObservation, RecoveryHistoryFailure> {
        switch session.selectedAgent {
        case .codexExec:
            guard let codexTurnID else {
                return .failure(RecoveryHistoryFailure(message: "The interrupted Codex turn wasn't identified, so its history can't be matched."))
            }
            do {
                // The coordinator owns the observation transport: it borrows a compatible live
                // controller or creates (and joins the shutdown of) a temporary one after a cold
                // relaunch. The session's run, controller and event handling are never touched.
                let observed = try await codexCoordinator.observeRecovery(
                    session: session,
                    actionID: action.actionID,
                    threadID: conversationID,
                    expectedTurnID: codexTurnID,
                    sourceRunAttemptID: action.sourceRunAttemptID,
                    timeout: 15,
                    isCurrent: { [weak self, weak session] in
                        guard let self, let session else { return false }
                        return recoveryActionStillCurrent(action, session: session, lane: lane)
                    }
                )
                guard let observation = CodexRecoveryAdapter.historyObservation(observed) else {
                    return .failure(RecoveryHistoryFailure(
                        message: CodexRecoveryAdapter.unusableObservationText(observed),
                        isUnconfirmedObservation: true
                    ))
                }
                return .success(observation)
            } catch {
                return .failure(RecoveryHistoryFailure(message: Self.recoveryCodexObservationText(error)))
            }
        case .claudeCode:
            guard let cursor = claudeBoundary else {
                return .failure(RecoveryHistoryFailure(message: Self.recoveryAssociationText(.baselineUnavailable)))
            }
            let roots: [URL]
            switch await recoveryClaudeHistoryRoots(conversationID: conversationID) {
            case let .roots(found):
                roots = found
            case .unknown:
                return .failure(RecoveryHistoryFailure(message: "Claude's history location for this conversation is unknown."))
            case .ambiguous:
                return .failure(RecoveryHistoryFailure(message: Self.recoveryClaudeHistoryAmbiguousReason + "."))
            case .uninspectable:
                return .failure(RecoveryHistoryFailure(message: Self.recoveryClaudeHistoryUninspectableReason + "."))
            }
            let input = RecoveryHistoryReadInput(
                conversationID: conversationID,
                roots: roots,
                mode: .importAfter(cursor),
                ledger: ledger,
                fences: claudeFences
            )
            switch await Self.readClaudeHistory(input) {
            case let .candidate(candidate):
                return .success(ClaudeSessionHistoryReader.observation(candidate))
            case let .unavailable(reason):
                return .failure(RecoveryHistoryFailure(message: Self.recoveryHistoryText(reason)))
            case .unsupported(.ledgerConflict), .unsupported(.rewrittenHistory):
                return .failure(RecoveryHistoryFailure(message: Self.recoveryHistoryChangedText))
            case .unsupported(.prefixProofUnavailable):
                return .failure(RecoveryHistoryFailure(message: Self.recoveryHistoryUnprovenText))
            case .unsupported:
                return .failure(RecoveryHistoryFailure(message: Self.recoveryHistoryUnsupportedText))
            }
        default:
            return .failure(RecoveryHistoryFailure(message: "History reconciliation isn't supported for this provider."))
        }
    }

    // MARK: Text

    static func recoveryHistoryText(_ reason: ClaudeSessionHistoryReader.Unavailable) -> String {
        switch reason {
        case .invalidSessionID:
            "The saved conversation identity isn't valid."
        case .notFound:
            "Claude's history for this conversation wasn't found."
        case .ambiguous:
            "More than one Claude history file matches this conversation, so none was chosen."
        case .unreadable:
            "Claude's history file couldn't be read."
        case .tooLarge:
            "Claude's history file is too large to check."
        case .unstableFile:
            "Claude's history file changed while it was read. Try again."
        case .baselineRequired:
            "No history position was saved before the interrupted run, so its history can't be matched safely."
        case .inspectionFailed:
            "Claude's history location couldn't be checked, so its contents are unknown."
        case .partialTrailingRecord:
            "Claude's history ends in an incomplete record, so no safe position could be taken."
        }
    }

    static let recoveryHistoryChangedText =
        "Claude's history no longer matches what was already recovered for this conversation. Nothing was imported or sent."

    static let recoveryHistoryUnsupportedText =
        "Claude's history contains records this version doesn't support. Nothing was imported or sent."

    static let recoveryHistoryUnprovenText =
        "A saved history position for this conversation has no integrity proof this version can check, so its history can't be matched safely. Nothing was imported or sent."

    /// Unsupported-baseline reasons (diagnostics recorded on the dispatch baseline; the send proceeds).
    static let recoveryBaselineRewrittenReason = "Claude history no longer matches its last recovered position"
    static let recoveryBaselineUnprovenReason =
        "Claude history's last recovered position has no integrity proof this version can check"
    static let recoveryBaselineReceiptMovedReason =
        "Another history position was saved for this session while this one was read"

    /// S1: the specific unsupported case, by schema name and line only (never a payload or ID).
    static func recoveryBaselineUnsupportedReason(_ unsupported: ClaudeSessionHistoryReader.Unsupported) -> String {
        func name(_ raw: String) -> String {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
            return raw.count <= 48 && raw.unicodeScalars.allSatisfy(allowed.contains) ? raw : "unrecognized"
        }
        let detail = switch unsupported {
        case let .malformedLine(line): "malformed record, line \(line)"
        case let .entryType(type, line): "record type \(name(type)), line \(line)"
        case let .fileHistorySnapshot(line): "file-history-snapshot, line \(line)"
        case let .metadata(key, line): "metadata \(name(key)), line \(line)"
        case let .contentBlock(type, line): "content block \(name(type)), line \(line)"
        case let .sessionMismatch(line): "another session's record, line \(line)"
        case .conflictingDuplicate: "conflicting duplicate entry"
        case .missingParent: "missing parent entry"
        case .multipleRoots: "more than one root entry"
        case .cycle: "entry cycle"
        case .ambiguousBranch: "ambiguous branch"
        case .toolAssociation: "unmatched tool call or result"
        case let .attachment(type?, line): "attachment \(name(type)), line \(line)"
        case let .attachment(nil, line): "attachment, line \(line)"
        case let .operationalRecord(type, line): "\(name(type)) record with entry identity, line \(line)"
        case let .semanticMarker(key, line): "marker \(name(key)), line \(line)"
        case .ledgerConflict: "an already recovered entry changed"
        case .rewrittenHistory: "history changed before its last recovered position"
        case .prefixProofUnavailable: "unproven recovered position"
        }
        // Saved with the baseline and shown later, possibly by a newer version (P3-9).
        return "Claude history contains records the version that sent it doesn't support (\(detail))"
    }

    static func recoveryCodexObservationText(_ error: Error) -> String {
        switch error as? CodexRecoveryObservationError {
        case .registeredTransportRequired:
            "Codex history can't be checked safely in this build. Nothing was imported."
        case .staleContext, .staleTransportGeneration:
            "The session or Codex connection changed while its history was read. Nothing was imported."
        case .sessionBusy:
            "The session is working. Reconcile after it finishes."
        case .missingIdentity:
            "The interrupted Codex turn wasn't identified, so its history can't be matched."
        case .unsupported, nil:
            "Codex history couldn't be read. Nothing was imported."
        }
    }

    /// S1: a missing baseline whose dispatch was recorded unsupported names that saved reason.
    static func recoveryAssociationText(
        _ refusal: AgentProviderHistoryAssociationRefusal,
        baseline: AgentSessionProviderHistoryRecovery.DispatchBaseline?
    ) -> String {
        guard refusal == .baselineUnavailable, case let .unsupported(reason)? = baseline?.status, !reason.isEmpty else {
            return recoveryAssociationText(refusal)
        }
        return "No history position could be saved when the interrupted run was sent: \(reason). Its history can't be matched safely. Nothing was imported."
    }

    static func recoveryAssociationText(_ refusal: AgentProviderHistoryAssociationRefusal) -> String {
        switch refusal {
        case .baselineUnavailable:
            "No history position was saved before the interrupted run, so its history can't be matched safely. Nothing was imported."
        case .baselineTargetMismatch:
            "The saved history position doesn't belong to this conversation and run. Nothing was imported."
        case .nativeUserAssociationUnavailable:
            "A message of yours couldn't be safely matched between this conversation and Claude's history. Nothing was imported or sent."
        case .canonicalOutputAssociationUnavailable:
            "Output shown in this conversation couldn't be safely checked against Claude's history. Nothing was imported or sent."
        case .canonicalOutputImportWithheld:
            recoveryClaudeOutputUnmatchedText
        case .outboundClaimUnmatched:
            "Claude's history doesn't show exactly the messages recorded for this run, so it can't be matched safely. Nothing was imported or sent again."
        case .canonicalPayloadUnavailable:
            "Messages already matched to Claude's history are no longer fully available in this conversation, so they can't be checked. Nothing was imported."
        case .canonicalPayloadMismatch:
            "Messages already matched to Claude's history no longer match it or its order, so it can't be matched safely. Nothing was imported."
        }
    }

    /// A previous launch's open action, shown before any new choice replaces it.
    static func recoveryPriorActionText(_ join: AgentRecoveryActionJoin) -> String {
        switch join {
        case .notDispatched:
            "An earlier choice on this item, made before RepoPrompt restarted, didn't send anything. It is kept. Choose again to replace it."
        case .notHandedOff:
            "An earlier choice on this item, made before RepoPrompt restarted, saved a message that wasn't sent. It stays listed. Choose again to replace the choice."
        case .dispatchEvidence, .unknown, .resolved:
            "An earlier choice on this item, made before RepoPrompt restarted, may have reached the agent; its status is unknown. Check the conversation. Only a new continuation you confirm can follow it."
        }
    }

    static func recoveryActionJoinText(_ join: AgentRecoveryActionJoin) -> String? {
        switch join {
        case let .resolved(outcome):
            outcome.kind == .notDispatched ? (outcome.reason ?? "Nothing was sent.") : nil
        case .notDispatched:
            "An earlier choice on this item didn't send anything. It is kept for review."
        case .notHandedOff:
            "An earlier choice on this item saved a message that wasn't sent. Review it in the list."
        case .dispatchEvidence:
            "An earlier choice on this item was interrupted; its delivery status is unknown. Check the conversation before choosing again."
        case .unknown:
            "An earlier choice on this item can't be checked by this version."
        }
    }

    /// Run identity of a run row (interrupted turn, recorded outcome, or recovery-only run).
    private static func recoveryRunReference(_ payload: AgentRecoveryCatalogPayload) -> (runAttemptID: UUID?, turnID: UUID?)? {
        switch payload {
        case let .turn(turn):
            (turn.interruption.runAttemptID, turn.turnID)
        case let .outcomeTurn(outcome):
            (outcome.runAttempt.runAttemptID, outcome.turnID)
        case let .recoveryOnlyRun(attempt):
            (attempt.runAttemptID, attempt.transcriptTurnID)
        default:
            nil
        }
    }
}
