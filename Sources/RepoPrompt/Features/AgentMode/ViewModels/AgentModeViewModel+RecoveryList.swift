import Foundation
import RepoPromptAgentCore

// Lossless-restart Phase 1b basic recovery list: held recovered input (View / Edit / Remove),
// crash holds, interrupted turns, held schedule transfers, and unknown recovery status, backed by
// the recovery coordinator's authoritative startup results (closed sessions included). Opening a
// row never starts a provider; every action revalidates the session's lane, lifecycle, and the
// durable record before it writes, and a row disappears only after its action committed.

extension AgentModeViewModel {
    // MARK: Props

    func recoveryListProps(forActiveSession activeSession: AgentTabSession?) -> AgentRecoveryListProps? {
        if let failure = recoveryCompositionFailure {
            return AgentRecoveryListProps(
                // `failure` is already a complete plain sentence (`startupFailureDescription`).
                status: .failed("\(failure) Sending stays paused."),
                rows: [],
                canRetry: false
            )
        }
        guard let coordinator = recoveryCoordinator else { return nil }
        let status: AgentRecoveryListProps.Status = switch coordinator.startupState {
        case .notStarted, .loading:
            .loading
        case .ready:
            .ready
        case let .failed(message):
            // `message` is already a complete plain sentence (`startupFailureDescription`).
            .failed("\(message) Sending stays paused until this succeeds.")
        }
        var rows: [AgentRecoveryListRowProps] = []
        var otherItemCount = 0
        if status == .ready {
            let catalog = coordinator.catalog
            let sessionID = activeSession?.activeAgentSessionID
            let workspaceID = persistenceWorkspace?.id
            // Sending stays paused while a crash hold blocks: its card, even when dismissed, keeps a
            // compact non-dismissible indicator with the confirmation.
            if let sessionID, catalog.blockers[sessionID] == .crashHold,
               let hold = catalog.items.first(where: { $0.sessionID == sessionID && $0.kind == .crashHold && $0.isDismissed })
            {
                rows.append(recoveryListRow(for: hold, coordinator: coordinator, activeSession: activeSession, pausedIndicator: true))
            }
            // The banner is an exact session (and tab) filter of the catalog's needs-action items
            // (O34-1: informational notes live only in Needs Attention). Schedule items stay
            // with the scheduled-send surfaces: a schedule awaiting confirmation is already presented
            // by the session's own scheduled-send banner, and an unchecked index is listed in Needs
            // Attention.
            // R6: a runtime blocking this session's sends (or the global ownership warning) is
            // app-scoped in the catalog; the banner shows it for the session it pauses.
            let runtimeItems = recoveryListRuntimeBannerItems(catalog: catalog, coordinator: coordinator, sessionID: sessionID)
            let bannerItems = runtimeItems + catalog.bannerItems(sessionID: sessionID, workspaceID: workspaceID, tabID: activeSession?.tabID)
                .filter { $0.attention == .needsAction && !Self.isScheduleDomainItem($0) }
            rows += bannerItems.map { recoveryListRow(for: $0, coordinator: coordinator, activeSession: activeSession) }
            let shownIDs = Set(bannerItems.map(\.id))
            // Needs-action items elsewhere (the header's Needs Attention button while this banner is
            // shown); they never keep the banner visible on their own.
            otherItemCount = catalog.items.count { item in
                item.isOpenNeedsAction && !shownIDs.contains(item.id)
                    && !(item.kind == .scheduleNeedsConfirmation && item.sessionID == sessionID)
            }
        }
        let canRetry = if case .failed = status { recoveryStartupRetry != nil } else { false }
        let props = AgentRecoveryListProps(status: status, rows: rows, canRetry: canRetry, otherItemCount: otherItemCount)
        return props.isEmpty ? nil : props
    }

    /// Rows of the app-wide Needs Attention sheet: every catalog item in snapshot order (dismissed
    /// and automatically cleared ones only when asked), formatted for this window.
    func recoveryNeedsAttentionRows(includeDismissed: Bool, activeSession: AgentTabSession?) -> [AgentRecoveryNeedsAttentionRow] {
        guard let coordinator = recoveryCoordinator, coordinator.startupState == .ready else { return [] }
        let workspaceID = persistenceWorkspace?.id
        return coordinator.catalog.needsAttentionItems(includeDismissed: includeDismissed).map { item in
            AgentRecoveryNeedsAttentionRow(
                row: recoveryListRow(for: item, coordinator: coordinator, activeSession: activeSession),
                isDismissed: item.isDismissed,
                isOtherWorkspace: item.workspaceID != nil && item.workspaceID != workspaceID,
                attention: item.attention,
                automaticClear: item.automaticClear,
                item: item
            )
        }
    }

    /// Needs-action, undismissed catalog items (the sidebar's Needs Attention count; O34-1:
    /// informational notes are not counted).
    var recoveryNeedsAttentionCount: Int {
        guard let coordinator = recoveryCoordinator, coordinator.startupState == .ready else { return 0 }
        return coordinator.catalog.openNeedsActionCount
    }

    /// Asks this window's root to present the app-wide Needs Attention sheet (reachable with any
    /// number of items, so dismissed ones stay reviewable) and re-reads index-only schedules. The
    /// request stays pending until the window's sheet host consumes it, so a window that is still
    /// appearing presents it once it is mounted. Starts and hydrates nothing.
    func presentRecoveryNeedsAttention() {
        recoveryNeedsAttentionRequestPending = true
        recoveryCoordinator?.requestIndexedScheduleRefresh()
        NotificationCenter.default.post(name: .agentRecoveryNeedsAttentionRequested, object: self)
    }

    /// Consumes a pending Needs Attention request (the window's sheet host presents it once).
    func consumeRecoveryNeedsAttentionRequest() -> Bool {
        guard recoveryNeedsAttentionRequestPending else { return false }
        recoveryNeedsAttentionRequestPending = false
        return true
    }

    /// The global runtime-ownership warning, or the runtime pausing sends to `sessionID`.
    private func recoveryListRuntimeBannerItems(
        catalog: AgentRecoveryCatalog,
        coordinator: AgentRecoveryCoordinator,
        sessionID: UUID?
    ) -> [AgentRecoveryCatalogItem] {
        if coordinator.runtimeRestrictions.hasGlobalUncertainty {
            return catalog.item(id: AgentRecoveryCatalogProjection.runtimeOwnershipUnknownItemID).map { [$0] } ?? []
        }
        guard let sessionID, let restriction = coordinator.runtimeSendRestriction(sessionID: sessionID) else { return [] }
        return catalog.item(id: AgentRecoveryCatalogProjection.runtimeItemID(runtimeID: restriction.runtimeID)).map { [$0] } ?? []
    }

    /// Schedule-domain items are presented by the scheduled-send surfaces and Needs Attention, never
    /// by the composer's recovery banner.
    private static func isScheduleDomainItem(_ item: AgentRecoveryCatalogItem) -> Bool {
        switch item.payload {
        case .scheduleNeedsConfirmation, .scheduleIndexUnavailable: true
        default: false
        }
    }

    private static func recoveryListError(_ state: AgentRecoveryCatalogActionState?) -> String? {
        if case let .failed(message)? = state { message } else { nil }
    }

    /// 9-live R4a: a row's inline error. When the card's typed continuation was not sent, the note
    /// saying so comes first, so a truncated line drops the reason, never the note.
    static func recoveryListRowError(_ state: AgentRecoveryCatalogActionState?, hasUnsentContinuation: Bool) -> String? {
        guard let reason = recoveryListError(state) else { return nil }
        return hasUnsentContinuation ? "\(recoveryListUnsentContinuationNote) \(reason)" : reason
    }

    /// 9-live R4b/R5: the text the Continue editor opens with: the app-wide in-memory draft of the
    /// row, then the card's unsent typed text, then the default.
    static func recoveryContinuationOpeningText(draft: String?, unsentText: String?) -> String {
        draft ?? unsentText ?? recoveryContinueDefaultText
    }

    /// The Continue editor's in-memory draft of `rowID` (read when the editor opens). Kept on the
    /// app-wide recovery coordinator (review B L2), so every window sees the same draft.
    func recoveryContinuationDraft(rowID: String) -> String? {
        recoveryCoordinator?.continuationDraftsByRowID[rowID]
    }

    /// Every edit in the Continue editor of `rowID` (no UI refresh; nothing is written to disk).
    func updateRecoveryContinuationDraft(rowID: String, text: String) {
        recoveryCoordinator?.continuationDraftsByRowID[rowID] = text
    }

    /// Formats one catalog item for this window: full actions for the active session (or the tab
    /// owning a draft in this window), Open for another session with a tab, and Dismiss for an item
    /// with a durable acknowledgement. Never rediscovers or removes anything.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func recoveryListRow(
        for item: AgentRecoveryCatalogItem,
        coordinator: AgentRecoveryCoordinator,
        activeSession: AgentTabSession?,
        pausedIndicator: Bool = false
    ) -> AgentRecoveryListRowProps {
        let sessionID = item.sessionID
        let isActive = sessionID != nil && sessionID == activeSession?.activeAgentSessionID
        let tabSession = sessionID.flatMap { recoveryListTabSession(sessionID: $0) }
        // A tab of this window that owns the item (a tab-keyed item may have no session yet).
        let localTabID = item.composeTabID.flatMap { sessions[$0] != nil ? $0 : nil }
        let name: String = if let tabSession {
            resolvedSessionDisplayName(for: tabSession.tabID)
        } else if let localTabID {
            resolvedSessionDisplayName(for: localTabID)
        } else if let sessionName = item.sessionName {
            sessionName
        } else if let sessionID {
            "Session \(sessionID.uuidString.prefix(8))"
        } else {
            "This workspace"
        }
        let openAction: [AgentRecoveryListRowProps.Action] = isActive || item.composeTabID == nil ? [] : [.open]
        // The same rule as bulk Dismiss eligibility (`AgentRecoveryCatalogItem.offersDismiss`).
        let dismiss: [AgentRecoveryListRowProps.Action] = item.offersDismiss ? [.dismiss] : []
        let liveIsEmpty: Bool = {
            guard let tabSession, let lane = tabSession.recoveryLane else { return false }
            return recoveryInputContent(for: tabSession, store: lane.store, sessionID: lane.sessionID)?.isEmpty ?? false
        }()
        let rowID = pausedIndicator ? "\(Self.recoveryListPausedRowPrefix)\(sessionID?.uuidString ?? "")" : item.id
        let state = coordinator.catalogActionStates[rowID]
        let isRunCard = switch item.payload {
        case .turn, .outcomeTurn, .recoveryOnlyRun: true
        default: false
        }
        // R4a: a run card's refusal keeps the unsent-text note visible (the error replaces the detail).
        let error = Self.recoveryListRowError(
            state,
            hasUnsentContinuation: isRunCard && item.actionFacts.hasUnsentContinuation
        )
        func row(
            _ title: String,
            _ detail: String,
            text: String? = nil,
            attachmentNames: [String] = [],
            actions: [AgentRecoveryListRowProps.Action] = [],
            confirmation: String? = nil
        ) -> AgentRecoveryListRowProps {
            let continues = actions.contains(.continueTurn) || actions.contains(.continueInNewConversation)
            return AgentRecoveryListRowProps(
                id: rowID,
                sessionID: sessionID,
                sessionName: name,
                title: title,
                detail: detail,
                text: text,
                attachmentNames: attachmentNames,
                actions: actions,
                isWorking: state == .working,
                error: error,
                confirmation: confirmation,
                continuationText: continues
                    ? Self.recoveryContinuationOpeningText(
                        draft: recoveryContinuationDraft(rowID: rowID),
                        unsentText: item.actionFacts.unsentContinuationText
                    )
                    : nil,
                continuationWarning: continues ? recoveryPriorActionWarning(for: item.acknowledgement?.key) : nil
            )
        }
        switch item.payload {
        case let .workspaceFailure(reason):
            return row("Interrupted work could not be checked", "\(reason) Sending and scheduling in this workspace stay paused.")
        case let .nonactionable(reason):
            return row("Recovery status unknown", "\(Self.recoveryListDescription(of: reason)) Its saved data is kept unchanged; sending to it stays paused.")
        case .duplicateDestination:
            return row("Recovery status unknown", "More than one workspace holds this session, so recovery can't choose one. Sending to it stays paused.")
        case .noDestination:
            return row("Recovery status unknown", "Recovered messages exist for a session whose saved conversation wasn't found. They are kept unchanged.")
        case let .crashHold(hold):
            if pausedIndicator {
                return row("Sending is paused", "The previous run may still be running. Confirm it stopped to send again.", actions: [.confirmStopped])
            }
            return row(
                "The previous run may still be running",
                hold.previousExitProvenClean
                    ? "RepoPrompt closed while this session was working. Sending to it is paused until you confirm the previous run has stopped."
                    : "RepoPrompt quit unexpectedly while this session was working. Sending to it is paused until you confirm the previous run has stopped.",
                actions: [.confirmStopped] + openAction + dismiss
            )
        case let .scheduleTransfer(message):
            return row(
                "Scheduled message held",
                "\(message) It won't be sent until this is resolved.",
                actions: [.cancelSchedule] + openAction,
                confirmation: "Cancel this pending schedule? The message stays listed with its delivery unconfirmed; it won't be sent again automatically."
            )
        case let .turn(turn):
            let (title, detail) = Self.recoveryListTurnText(turn)
            let runActions = recoveryRunActions(session: isActive ? activeSession : nil, status: turn.status, facts: item.actionFacts)
            let children = recoveryDelegatedChildPresentation(
                item.actionFacts.delegatedChildLinks,
                parentSessionID: sessionID,
                parentInOtherWorkspace: recoveryListItemIsInOtherWorkspace(item)
            )
            return row(
                title,
                detail + Self.recoveryRunUnsentNote(item.actionFacts) + children.detail,
                text: children.text,
                actions: runActions + children.actions + dismiss + openAction
            )
        case let .outcomeTurn(outcome):
            let (title, detail) = Self.recoveryListOutcomeTurnText(outcome)
            let runActions = recoveryRunActions(session: isActive ? activeSession : nil, status: outcome.status, facts: item.actionFacts)
            let children = recoveryDelegatedChildPresentation(
                item.actionFacts.delegatedChildLinks,
                parentSessionID: sessionID,
                parentInOtherWorkspace: recoveryListItemIsInOtherWorkspace(item)
            )
            return row(
                title,
                detail + Self.recoveryRunUnsentNote(item.actionFacts) + children.detail,
                text: children.text,
                actions: runActions + children.actions + dismiss + openAction
            )
        case let .recoveryOnlyRun(attempt):
            // R1a: a run whose turn was never saved is still listed from its recovery evidence. A
            // finished run (R09) shows its recorded outcome; it holds nothing.
            let (title, detail) = Self.recoveryOnlyRunRowText(attempt)
            let status = AgentRecoveryInterruptedTurn.Status.classify(terminal: attempt.terminal, shutdown: attempt.shutdown)
            let runActions = recoveryRunActions(session: isActive ? activeSession : nil, status: status, facts: item.actionFacts)
            let children = recoveryDelegatedChildPresentation(
                item.actionFacts.delegatedChildLinks,
                parentSessionID: sessionID,
                parentInOtherWorkspace: recoveryListItemIsInOtherWorkspace(item)
            )
            return row(
                title,
                detail + Self.recoveryRunUnsentNote(item.actionFacts) + children.detail,
                text: children.text,
                actions: runActions + children.actions + dismiss + openAction
            )
        case let .intent(intent, context):
            let settled = item.actionFacts.settledByExitProof
            var detail = if settled {
                Self.recoveryListSettledByExitProofDetail
            } else if context.isRemote && intent.deliveryState == .deliveryUnknown {
                Self.recoveryListRemoteUncertainty
            } else {
                Self.recoveryListCertainty(
                    of: intent.deliveryState,
                    earlierLaunch: context.isEarlierLaunch,
                    runsEndedWithRecordedEvidence: context.runsEndedWithRecordedEvidence
                )
            }
            if let heldReason = context.heldReason {
                detail += " \(heldReason)"
            } else if !context.isEarlierLaunch {
                detail += " \(AgentRecoverySessionLane.sessionChangedHoldReason)"
            }
            if !context.sameGeneration {
                detail += " It was written before the conversation was cleared, so it can't be moved into it."
            }
            let actions = isActive
                ? recoveryIntentActions(intent, facts: item.actionFacts) + Self.recoveryListIntentActions(
                    intent.deliveryState,
                    sameGeneration: context.sameGeneration,
                    settledByExitProof: settled
                )
                : openAction
            return row(
                Self.recoveryListTitle(of: intent.deliveryState),
                detail,
                text: intent.payload.text,
                attachmentNames: Self.recoveryListAttachmentNames(intent.payload),
                actions: actions + dismiss
            )
        case let .question(snapshot, isCurrentLaunch):
            // R4: historical text only; the old request is never resumed. Its text can be copied
            // into an empty message box. A saved question does not prove it went unanswered (an
            // answer may have been sent before its removal was saved), so its status is uncertain.
            let ended = isCurrentLaunch
                ? "The agent's question expired (its window or tab closed, or the request ended)."
                : "The agent asked this question before RepoPrompt closed. That request has ended."
            let uncertainty = "Whether an answer reached the agent is uncertain; check the conversation before answering again."
            let actions: [AgentRecoveryListRowProps.Action] = isActive
                ? recoveryQuestionActions(snapshot, facts: item.actionFacts) + (liveIsEmpty ? [.restoreDraft, .removeSavedQuestion] : [.removeSavedQuestion])
                : openAction
            return row(
                "Expired question",
                liveIsEmpty || !isActive
                    ? "\(ended) \(uncertainty) You can copy the question and any partial answer into the message box."
                    : "\(ended) \(uncertainty) Clear the message box to copy it there, or remove it.",
                text: snapshot.composerText,
                actions: actions + dismiss
            )
        case let .editProposal(proposal, isCurrentLaunch):
            // Step 5a: historical data only (View, Copy, Discard); never applied from here.
            var props = row(
                // Pending is known not written (never accepted, or accepted but stopped before writing).
                proposal.state == .applicationStarted ? "Edit may have been applied" : "Edit proposal not applied",
                Self.recoveryListEditProposalDetail(proposal, isCurrentLaunch: isCurrentLaunch),
                text: Self.recoveryListEditProposalText(proposal),
                actions: [.copyProposal] + (isActive ? [.discardProposal] : openAction),
                confirmation: "Discard this edit proposal? The file is not changed; only the saved proposal is removed. This can't be undone."
            )
            props.inspectsOnView = true
            return props
        case let .heldDraft(snapshot):
            guard tabSession != nil else {
                return row("Draft from before the conversation was cleared", "Open the session to restore or discard it.", text: snapshot.content.text, actions: dismiss)
            }
            return row(
                "Draft from before the conversation was cleared",
                liveIsEmpty
                    ? "It was kept when the conversation was cleared. Restore it into the message box, or discard it."
                    : "The message box has new text, so it can't be restored now; both are kept. Discarding it saves your current text.",
                text: snapshot.content.text,
                attachmentNames: Self.recoveryListAttachmentNames(snapshot.content),
                actions: (liveIsEmpty ? [.restoreDraft, .discardDraft] : [.discardDraft]) + dismiss,
                confirmation: liveIsEmpty
                    ? "Discard the draft from before the conversation was cleared? This can't be undone."
                    : "Discard the draft from before the conversation was cleared and save your current text?"
            )
        case let .closedSessionDraft(snapshot, fromClearedConversation):
            // Review A F05: kept in the session's recovery record; opening the session restores it
            // into the message box (or offers it, when it predates a cleared conversation).
            return row(
                fromClearedConversation ? "Draft from before the conversation was cleared" : "Saved draft",
                fromClearedConversation
                    ? "It was kept when the conversation was cleared. Open the session to restore or discard it."
                    : "This session has unsent text in its message box. Open the session to continue it.",
                text: snapshot.content.text,
                attachmentNames: Self.recoveryListAttachmentNames(snapshot.content),
                actions: openAction + dismiss
            )
        case let .composerRestoreFailed(failure):
            return row(
                "Saved draft couldn't be loaded",
                "\(Self.recoveryListDescription(of: failure)) It is kept unchanged; sending from the message box stays paused until it loads.",
                actions: tabSession == nil ? [] : [.retrySave]
            )
        case let .unsavedPredecessor(entry, count):
            let suffix = Self.recoveryListFailureSuffix(entry.failure)
            let choice = liveIsEmpty
                ? "Restore it into the message box, or discard it."
                : "Clear the message box to restore it, or discard it."
            return row(
                count == 1 ? "Unsaved draft" : "Unsaved draft (1 of \(count))",
                "This draft couldn't be saved\(suffix). \(choice) Sending in this session is paused until it is resolved.",
                text: entry.content.text,
                attachmentNames: Self.recoveryListAttachmentNames(entry.content),
                actions: tabSession == nil ? [] : (liveIsEmpty ? [.restoreDraft, .discardDraft] : [.discardDraft]),
                confirmation: "Discard this unsaved draft? This can't be undone."
            )
        case let .composerWriteFailed(failure):
            return row(
                "Message box not saved",
                "Your latest text couldn't be saved (\(Self.recoveryListDescription(of: failure))). It is still in the message box.",
                actions: tabSession == nil ? [] : [.retrySave]
            )
        case let .questionSaveFailed(failure, unsentAnswer):
            // Runtime only, never dismissible: it clears once a question write commits and no
            // answer is held. A held answer is never sent before it is saved.
            let reason = failure.map { " (\(Self.recoveryListDescription(of: $0)))" } ?? ""
            return row(
                unsentAnswer ? "Answer not sent" : "Question not saved",
                unsentAnswer
                    ? "Your answer couldn't be saved for crash recovery\(reason), so it wasn't sent. It is still in the question card; submit it again."
                    : "The agent's question or your partial answer couldn't be saved for crash recovery\(reason). It is still shown in the session.",
                actions: tabSession == nil ? [] : [.retrySave]
            )
        case let .ownerlessDraft(entry):
            // R02: a restored draft whose rollback is still owed is saved, but only an open session
            // can resolve it (durably); it offers no discard here.
            let awaitsRollback = entry.restoreRollback != nil
            return row(
                awaitsRollback ? "Restored draft" : "Unsaved draft",
                awaitsRollback
                    ? "Its tab closed before this restored draft could be put back\(Self.recoveryListFailureSuffix(entry.failure)). It is kept. Open the session to resolve it."
                    : "Its tab closed before this draft could be saved\(Self.recoveryListFailureSuffix(entry.failure)). Open the session to restore it, or discard it.",
                text: entry.content.text,
                attachmentNames: Self.recoveryListAttachmentNames(entry.content),
                actions: awaitsRollback ? [] : [.discardDraft],
                confirmation: awaitsRollback ? nil : "Discard this unsaved draft? This can't be undone."
            )
        case let .composerPreparationFailed(failure):
            // Runtime only (no durable authority yet): retried from the window owning the tab, never
            // dismissed. It clears once a retry, hand-off, or discard clears the obligation.
            return row(
                "Message box not saved yet",
                localTabID == nil
                    ? "A message box in another window couldn't be prepared for saving (\(Self.recoveryListDescription(of: failure))). Its text is still there; retry from that window."
                    : "Your current text couldn't be prepared for saving (\(Self.recoveryListDescription(of: failure))). It is still in the message box.",
                actions: localTabID == nil ? [] : [.retrySave]
            )
        case let .scheduleIndexUnavailable(workspaceName):
            return row(
                "Scheduled messages couldn't be checked",
                "\(workspaceName) has saved sessions but no readable session list, so a scheduled message waiting for confirmation there may be missing here. Open that workspace to review its scheduled messages; nothing is sent automatically."
            )
        case let .runtimeOwnershipUnknown(count, failure):
            let cause = if failure != nil {
                // F6: `failure` is an opaque raw error string (logged by the registry); never shown.
                "The saved records of agent processes couldn't be read."
            } else if count == 1 {
                "A saved record of an agent process couldn't be read."
            } else {
                "\(count) saved records of agent processes couldn't be read."
            }
            return row(
                "Agent processes couldn't be checked",
                "\(cause) RepoPrompt can't tell which conversations they may still be writing, so sending and scheduled work stay paused. Nothing is stopped automatically.",
                actions: [.refreshProcesses]
            )
        case let .survivingRuntime(restriction):
            let (title, detail) = Self.recoveryListRuntimeText(restriction)
            let canLetFinish = !restriction.letFinish && restriction.revision != nil && !restriction.isUnreadable
            return row(title, detail, actions: [.refreshProcesses] + (canLetFinish ? [.letProcessFinish] : []))
        case let .scheduleNeedsConfirmation(summary):
            let reason = switch summary.reason {
            case .missedWhileClosed?: "Its time passed while RepoPrompt was closed."
            case .missedDuringSleep?: "Its time passed while the Mac was asleep."
            default: "It needs your confirmation before it is sent."
            }
            return row(
                "Scheduled message needs confirmation",
                "\(reason) Open the session to send or cancel it; it won't be sent automatically.",
                text: summary.previewText.isEmpty ? nil : summary.previewText,
                actions: openAction + dismiss
            )
        }
    }

    static let recoveryListUnsentContinuationNote = "The message you typed to continue it was not sent."

    /// Why a run card asks for a decision when typed continuation text was never sent (ATT1-R2-3):
    /// appended to the run row's detail with a leading space, or empty.
    static func recoveryRunUnsentNote(_ facts: AgentRecoveryCatalogActionFacts) -> String {
        facts.hasUnsentContinuation ? " \(recoveryListUnsentContinuationNote)" : ""
    }

    /// A catalog item recorded for a workspace other than this window's persistence workspace.
    private func recoveryListItemIsInOtherWorkspace(_ item: AgentRecoveryCatalogItem) -> Bool {
        item.workspaceID != nil && item.workspaceID != persistenceWorkspace?.id
    }

    /// Step 5b: honest status of the delegated children linked under a run attempt, with Open for
    /// each child found in this workspace. A link proves only that the child's stub was saved
    /// before its dispatch was attempted, never that it started; nothing is recreated or resent.
    /// Every durable link is kept; status and Open are shown once per child session. The inline
    /// detail stays one short sentence; the full per-child status is the row's viewable text. A
    /// parent row from another workspace is never resolved here (open the parent to check).
    func recoveryDelegatedChildPresentation(
        _ links: [AgentRecoveryDelegatedChildLink],
        parentSessionID: UUID?,
        parentInOtherWorkspace: Bool = false
    ) -> (detail: String, text: String?, actions: [AgentRecoveryListRowProps.Action]) {
        var seen = Set<UUID>()
        let childSessionIDs = links.map(\.childSessionID).filter { seen.insert($0).inserted }
        guard !childSessionIDs.isEmpty else { return ("", nil, []) }
        let never = "Delegated work is never restarted automatically."
        let countText = childSessionIDs.count == 1
            ? "This run is linked to a delegated session"
            : "This run is linked to \(childSessionIDs.count) delegated sessions"
        if parentInOtherWorkspace {
            let lines = childSessionIDs.map {
                "Delegated session \($0.uuidString.prefix(8)): open the parent session to check it."
            }
            return (" \(countText); open the parent to check. \(never)", (lines + [never]).joined(separator: "\n"), [])
        }
        var lines: [String] = []
        var actions: [AgentRecoveryListRowProps.Action] = []
        for childSessionID in childSessionIDs {
            let name = "Delegated session \(childSessionID.uuidString.prefix(8))"
            guard let child = recoveryDelegatedChild(childSessionID) else {
                lines.append("\(name) was linked to this run but can't be found in this workspace.")
                continue
            }
            actions.append(.openDelegatedSession(childSessionID))
            if child.parentSessionID == nil || child.parentSessionID != parentSessionID {
                lines.append("\(name) was linked to this run, but its saved data names a different parent; check it before relying on it.")
            } else {
                switch child.hasConversation {
                case false?:
                    lines.append("\(name) was created for this run but has no saved messages, so it may never have started.")
                case true?:
                    lines.append("\(name) was created for this run and has saved messages; open it to check its state.")
                case nil:
                    lines.append("\(name) was created for this run; whether it started is unknown. Open it to check.")
                }
            }
        }
        let detail = lines.count == 1
            ? " \(lines[0]) \(never)"
            : " \(countText); view the details for each one's status. \(never)"
        return (detail, (lines + [never]).joined(separator: "\n"), actions)
    }

    private struct RecoveryDelegatedChild {
        let tabID: UUID
        let parentSessionID: UUID?
        /// Nil when the saved conversation content is unknown.
        let hasConversation: Bool?
    }

    /// The existing child session in this workspace (owner-validated index first, then a hydrated
    /// live session). Never creates or hydrates anything.
    private func recoveryDelegatedChild(_ childSessionID: UUID) -> RecoveryDelegatedChild? {
        if let entry = ownerValidatedSessionIndex[childSessionID] {
            return RecoveryDelegatedChild(
                tabID: entry.tabID,
                parentSessionID: entry.parentSessionID,
                hasConversation: entry.hasUnknownConversationContent ? nil : entry.itemCount > 0
            )
        }
        if let live = try? authoritativeLiveSession(for: childSessionID), live.hasLoadedPersistedState {
            return RecoveryDelegatedChild(
                tabID: live.tabID,
                parentSessionID: live.parentSessionID,
                hasConversation: hasPersistableConversationContent(live)
            )
        }
        return nil
    }

    /// Opens the existing delegated child's tab (switch or unstash) without starting anything.
    private func openRecoveryDelegatedSession(_ childSessionID: UUID) async -> String? {
        guard let child = recoveryDelegatedChild(childSessionID) else {
            return "The delegated session can't be found in this workspace. It was not recreated."
        }
        return await openRecoveryListTab(child.tabID)
    }

    /// This window's tab owning `sessionID` with a live lane, if any.
    private func recoveryListTabSession(sessionID: UUID) -> AgentTabSession? {
        sessions.values.first { session in
            guard let lane = session.recoveryLane else { return false }
            return !lane.isRetired && lane.sessionID == sessionID
        }
    }

    static func recoveryListQuestionRowID(sessionID: UUID, interactionID: UUID) -> String {
        "question-\(sessionID.uuidString)-\(interactionID.uuidString)"
    }

    /// Catalog item identities (one formula shared with the catalog projection).
    static func recoveryListHeldDraftRowID(sessionID: UUID, revision: AgentRecoveryComposerRevision) -> String {
        AgentRecoveryCatalogProjection.heldDraftItemID(sessionID: sessionID, revision: revision)
    }

    /// Identity of one displayed unsaved entry within this process (row IDs carry it, so an action
    /// applies only to exactly the entry that was shown).
    static func recoveryListFingerprint(_ entry: AgentRecoveryUnsavedComposerInput) -> String {
        AgentRecoveryCatalogProjection.fingerprint(entry)
    }

    private static func recoveryListAttachmentNames(_ content: AgentRecoveryInputContent) -> [String] {
        content.images.map { $0.title ?? $0.managedFileName ?? "Image" } + content.taggedFiles.map(\.displayName)
            + content.documents.map(\.originalFilename)
    }

    private static func recoveryListFailureSuffix(_ failure: AgentRecoveryControllerFailure?) -> String {
        failure.map { " (\(recoveryListDescription(of: $0)))" } ?? ""
    }

    /// User-facing wording only: raw store errors and gate reasons can describe local paths.
    static func recoveryListDescription(of failure: AgentRecoveryControllerFailure) -> String {
        failure.userFacingDescription
    }

    private static func recoveryListDescription(of failure: AgentRecoveryComposerPreparationFailure) -> String {
        switch failure {
        case .authorityUnavailable:
            "the session isn't ready"
        case .ownerReplaced:
            "the tab changed"
        case .imagePromotionFailed:
            "an image couldn't be saved"
        }
    }

    /// O46: the detail of a saved message a crash-hold confirmation settled (title unchanged).
    /// Path-neutral: Check's process proof and the user's "It stopped" produce the same row.
    static let recoveryListSettledByExitProofDetail =
        "Its run stopped before the provider confirmed it. It won't be sent again."

    /// Actions the store can honour (F-12): Edit moves the text into the message box and withdraws
    /// the intent, so it is offered only for input that was never delivered (`queued`, `failed`)
    /// or, O46, for possibly delivered input whose run is settled as exited (the user decides
    /// whether to send it again); other possibly delivered input (`deliveryUnknown`) can only be
    /// removed; a handoff still in progress (`dispatching`) is view-only. Never Send saved.
    static func recoveryListIntentActions(
        _ state: AgentRecoveryDeliveryState,
        sameGeneration: Bool,
        settledByExitProof: Bool = false
    ) -> [AgentRecoveryListRowProps.Action] {
        switch state {
        case .queued, .failed:
            sameGeneration ? [.edit, .remove] : [.remove]
        case .deliveryUnknown:
            settledByExitProof && sameGeneration ? [.edit, .remove] : [.remove]
        case .dispatching, .providerAccepted, .withdrawn:
            []
        }
    }

    /// Held input that may still need a user decision. Accepted and withdrawn intents need none.
    private static func recoveryListShowsIntent(_ intent: AgentRecoveryIntent) -> Bool {
        switch intent.deliveryState {
        case .queued, .dispatching, .deliveryUnknown, .failed:
            true
        case .providerAccepted, .withdrawn:
            false
        }
    }

    private static func recoveryListTitle(of state: AgentRecoveryDeliveryState) -> String {
        switch state {
        case .queued:
            "Saved message, not sent"
        case .failed:
            "Message not sent"
        case .dispatching, .deliveryUnknown:
            "Message may have been delivered"
        case .providerAccepted:
            "Message delivered"
        case .withdrawn:
            "Message removed"
        }
    }

    /// F-3: a remote session's host-RPC response is not provider evidence. Never "not sent".
    static let recoveryListRemoteUncertainty =
        "The host received the command; provider delivery is unconfirmed. Retrying may duplicate it."

    /// O50: "RepoPrompt closed" wording only when the exit was unclean; uncertainty whose runs all
    /// ended with recorded evidence says plainly that the agent did not confirm it.
    static func recoveryListCertainty(
        of state: AgentRecoveryDeliveryState,
        earlierLaunch: Bool,
        runsEndedWithRecordedEvidence: Bool
    ) -> String {
        switch state {
        case .queued:
            earlierLaunch
                ? "It was saved before RepoPrompt closed and was never handed to the agent."
                : "It is saved and was never handed to the agent."
        case .failed:
            "Sending it failed; it was not delivered."
        case .dispatching, .deliveryUnknown:
            if runsEndedWithRecordedEvidence {
                "The agent didn't confirm it received it. Sending it again could deliver it twice."
            } else if earlierLaunch {
                "RepoPrompt closed while sending it. Sending it again could deliver it twice."
            } else {
                "Sending it started but wasn't confirmed. Sending it again could deliver it twice."
            }
        case .providerAccepted:
            "The agent received it."
        case .withdrawn:
            "You removed it."
        }
    }

    /// Row text for a run attempt the saved transcript does not represent. A finished run states
    /// its recorded outcome and that its transcript turn is missing; it is never shown as running.
    static func recoveryOnlyRunRowText(_ attempt: AgentRecoveryRunAttempt) -> (title: String, detail: String) {
        guard let terminal = attempt.terminal else {
            return (
                "Run interrupted before it was saved",
                "A run started but its turn was not saved before RepoPrompt stopped. Its output may be missing."
            )
        }
        // The shared classifier: a failed or cancelled run is never presented as completed.
        let outcome = switch AgentRecoveryInterruptedTurn.Status.classify(terminal: terminal, shutdown: attempt.shutdown) {
        case .completedTailMayBeMissing: "The run completed"
        case .interrupted: "The run was interrupted"
        case .failed: "The run failed"
        case .stopped: "The run was stopped"
        case .cancelledByUser: "The run was cancelled"
        case .unknown: "The run ended"
        }
        return (
            "Run finished, but its turn wasn't saved",
            "\(outcome), but its turn was not saved before RepoPrompt stopped. Its output is missing from the conversation."
        )
    }

    /// Row text for a stamped turn, from the shared classifier.
    static func recoveryListTurnText(_ turn: AgentRecoveryInterruptedTurn) -> (title: String, detail: String) {
        recoveryListTurnText(status: turn.status, reason: turn.interruption.reason)
    }

    /// Row text for a turn saved open whose run's recorded outcome closed it (never an interruption).
    static func recoveryListOutcomeTurnText(_ outcome: AgentRecoveryOutcomeTurn) -> (title: String, detail: String) {
        recoveryListTurnText(status: outcome.status, reason: .unknown)
    }

    private static func recoveryListTurnText(
        status: AgentRecoveryInterruptedTurn.Status,
        reason: AgentTranscriptTurnInterruption.Reason
    ) -> (title: String, detail: String) {
        switch status {
        case .interrupted:
            (
                "Turn interrupted",
                "\(recoveryListDescription(of: reason)) The saved conversation stops where it was interrupted."
            )
        case .completedTailMayBeMissing:
            ("Completed; transcript tail may be missing", "The run completed, but the end of its transcript may be missing.")
        case .failed:
            ("Run failed", "The run failed, and the end of its transcript may be missing.")
        case .stopped:
            ("Run stopped", "The run was stopped, and the end of its transcript may be missing.")
        case .cancelledByUser:
            // Explicit cancels include agent- and tool-requested ones, so the wording stays neutral.
            ("Run cancelled", "This run was cancelled; the end of its transcript may be missing.")
        case .unknown:
            ("Run status unknown", "RepoPrompt can't tell how this run ended. The saved conversation is kept unchanged.")
        }
    }

    private static func recoveryListDescription(of reason: AgentTranscriptTurnInterruption.Reason) -> String {
        switch reason {
        case .appCrash:
            // 9-live S4: a row outlives later normal quits; name the launch that crashed.
            "In an earlier launch, RepoPrompt quit unexpectedly during this turn."
        case .appQuit:
            "RepoPrompt was quit during this turn."
        case .windowClose:
            "The window was closed during this turn."
        case .safeRestart:
            "RepoPrompt restarted during this turn."
        case .providerProcessLost:
            "The agent process stopped during this turn."
        case .unknown:
            "RepoPrompt closed during this turn; the cause is unknown."
        }
    }

    private static func recoveryListDescription(of reason: AgentSessionRecoveryNonactionableReason) -> String {
        switch reason {
        case .sessionFileUnavailable:
            "The saved conversation couldn't be found."
        case .authorityMismatch:
            "The recovered data doesn't match the saved conversation."
        case .authorityUnreadable:
            "The saved conversation couldn't be read."
        case .unreadableRecord:
            "The recovered data couldn't be read."
        }
    }

    // MARK: Actions

    /// Performs one row action; failures stay visible inline on the row (repeat the action to retry).
    /// Progress and failures are the coordinator's shared action state, so every surface (banner and
    /// Needs Attention sheet, any window) shows the same. A row leaves only once its backing state
    /// changed (committed), never by a local mark.
    func performRecoveryListAction(rowID: String, action: AgentRecoveryListRowProps.Action) async {
        guard let coordinator = recoveryCoordinator, coordinator.catalogActionStates[rowID] != .working else { return }
        coordinator.setCatalogActionState(.working, for: rowID)
        refreshRecoveryListUI()
        // Captured before the await: the action may resolve (or remove) the item.
        let sessionID = recoveryListCatalogItem(rowID)?.sessionID
        var failure: String? = switch action {
        case .edit:
            await editRecoveredIntent(rowID: rowID)
        case .remove:
            await removeRecoveredIntent(rowID: rowID)
        case .open:
            await openRecoveryListSession(rowID: rowID)
        case .confirmStopped:
            await confirmRecoveryCrashHold(rowID: rowID)
        case .dismiss:
            await dismissRecoveryListItem(rowID: rowID)
        case .restoreDraft:
            await resolveRecoveryListDraft(rowID: rowID, choice: .restoreToComposer)
        case .discardDraft, .removeSavedQuestion:
            await resolveRecoveryListDraft(rowID: rowID, choice: .discard)
        case .retrySave:
            await retryRecoveryListSave(rowID: rowID)
        case .cancelSchedule:
            await cancelRecoveryScheduleTransfer(rowID: rowID)
        case .refreshProcesses:
            await refreshRecoveryRuntimes()
        case .letProcessFinish:
            await letRecoveryRuntimeFinish(rowID: rowID)
        case .continueTurn, .sendSaved, .answerAsInput, .reconcileHistory, .continueInNewConversation:
            await performRecoveryResumeAction(rowID: rowID, action: action)
        case let .openDelegatedSession(childSessionID):
            await openRecoveryDelegatedSession(childSessionID)
        case .copyProposal:
            copyRecoveryEditProposal(rowID: rowID)
        case .discardProposal:
            await discardRecoveryEditProposal(rowID: rowID)
        }
        // Review B N1: a Continue draft of this session whose card stopped offering Continue (here
        // a Reconcile that proved the turn finished, or a saved draft resolved after N3 kept one).
        if let moved = rescueOrphanedRecoveryContinuationDrafts(sessionID: sessionID, rowID: rowID) {
            failure = moved
        }
        coordinator.setCatalogActionState(failure.map { .failed($0) }, for: rowID)
        refreshRecoveryListUI()
    }

    /// A continuation chosen from the card's editor: the exact edited text is reserved and sent.
    func performRecoveryListContinuation(
        rowID: String,
        action: AgentRecoveryListRowProps.Action,
        text: String,
        acknowledgedWarning: String?
    ) async {
        guard action == .continueTurn || action == .continueInNewConversation,
              let coordinator = recoveryCoordinator,
              coordinator.catalogActionStates[rowID] != .working
        else { return }
        coordinator.setCatalogActionState(.working, for: rowID)
        refreshRecoveryListUI()
        // Captured before the await: a choice that proves the turn finished resolves the card.
        let sessionID = recoveryListCatalogItem(rowID)?.sessionID
        let report = RecoveryResumeActionReport()
        var failure = await performRecoveryResumeAction(
            rowID: rowID,
            action: action,
            continuationText: text,
            acknowledgedWarning: acknowledgedWarning,
            report: report
        )
        // R4b/R5, review B L1/L3: once the action was recorded the record holds the text (sent,
        // carried by a saved intent, or the card's unsent text again), so the draft goes; a text
        // the record neither sent nor shows moves to the message box. A refusal keeps the draft.
        // Only the sent text is removed: an edit made during the await is newer and survives.
        switch Self.recoveryContinuationDraftDisposition(report.result) {
        case .keep:
            break
        case .clear:
            removeRecoveryContinuationDraft(rowID: rowID, ifEqualTo: text)
        case .moveToComposer:
            // Review A R1-01: neither the submitted text nor an edit made during the await was
            // sent, so both move (the submitted text first, in one placement).
            let unsent = Self.recoveryUnsentContinuationText(
                submitted: text,
                newer: coordinator.continuationDraftsByRowID[rowID]
            )
            if let unsent, let host = sessionID.flatMap({ recoveryComposerHost(sessionID: $0) }) {
                failure = host.viewModel.moveRecoveryContinuationTextToComposer(
                    unsent,
                    rowID: rowID,
                    session: host.session,
                    message: Self.recoveryContinuationMovedToComposerText(report.result)
                )
            } else {
                // Review A R1-02: no window hosts the session now; the text is kept, never dropped,
                // and Open (a list action) brings it to the message box.
                coordinator.continuationDraftsByRowID[rowID] = unsent
                if unsent != nil { failure = Self.recoveryContinuationOpenSessionText }
            }
        }
        // Review B N1: a leftover newer edit whose card no longer offers Continue (for example
        // after a dispatched send) moves too; the sent text itself never does.
        if let moved = rescueOrphanedRecoveryContinuationDrafts(sessionID: sessionID, rowID: rowID) {
            failure = moved
        }
        coordinator.setCatalogActionState(failure.map { .failed($0) }, for: rowID)
        refreshRecoveryListUI()
    }

    /// Review B N1 / A R1-01: every Continue draft of `sessionID` (plus `rowID`'s, whose item may
    /// have left the catalog) whose card no longer offers Continue moves to the session's message
    /// box; a blank or default draft is dropped. A draft whose card still offers Continue, or whose
    /// session no window hosts (R1-02), or whose message box isn't in a normal state (N3) is kept.
    /// Returns the acted row's message when its draft moved or was held back.
    func rescueOrphanedRecoveryContinuationDrafts(sessionID: UUID?, rowID: String) -> String? {
        guard let coordinator = recoveryCoordinator, let sessionID else { return nil }
        var rowIDs = coordinator.continuationDraftsByRowID.keys.filter { coordinator.catalog.item(id: $0)?.sessionID == sessionID }
        if coordinator.continuationDraftsByRowID[rowID] != nil, !rowIDs.contains(rowID) { rowIDs.append(rowID) }
        guard !rowIDs.isEmpty, let host = recoveryComposerHost(sessionID: sessionID) else { return nil }
        var actedRowMessage: String?
        for id in rowIDs.sorted() {
            guard let draft = coordinator.continuationDraftsByRowID[id] else { continue }
            // Review A R2-02 / B P1-A: another row's action still in flight disposes of its own draft
            // (its text may have been sent already).
            if id != rowID, coordinator.catalogActionStates[id] == .working { continue }
            if let item = coordinator.catalog.item(id: id), host.viewModel.recoveryCardOffersContinue(item, session: host.session) {
                continue
            }
            if Self.isRecoveryContinuationDraftDisposable(draft) {
                coordinator.continuationDraftsByRowID[id] = nil
                continue
            }
            let message = host.viewModel.moveRecoveryContinuationTextToComposer(
                draft,
                rowID: id,
                session: host.session,
                message: Self.recoveryContinuationLeftoverMovedText
            )
            if id == rowID {
                actedRowMessage = message
            } else {
                coordinator.setCatalogActionState(.failed(message), for: id)
            }
        }
        return actedRowMessage
    }

    /// Whether `item` is a run card that still offers Continue for `session` (the row builder's
    /// own rule, `recoveryRunActions`).
    func recoveryCardOffersContinue(_ item: AgentRecoveryCatalogItem, session: AgentTabSession) -> Bool {
        let status: AgentRecoveryInterruptedTurn.Status
        switch item.payload {
        case let .turn(turn):
            status = turn.status
        case let .outcomeTurn(outcome):
            status = outcome.status
        case let .recoveryOnlyRun(attempt):
            status = AgentRecoveryInterruptedTurn.Status.classify(terminal: attempt.terminal, shutdown: attempt.shutdown)
        default:
            return false
        }
        let actions = recoveryRunActions(session: session, status: status, facts: item.actionFacts)
        return actions.contains(.continueTurn) || actions.contains(.continueInNewConversation)
    }

    /// A draft with nothing the user typed: blank, or the unchanged default text.
    static func isRecoveryContinuationDraftDisposable(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == recoveryContinueDefaultText
    }

    /// Review A R1-01: what a continuation that was neither sent nor shown again by its card moves
    /// to the message box: the submitted text, then a differing newer edit, after a blank line.
    /// Blank and default texts are left out; `nil` when nothing is left.
    static func recoveryUnsentContinuationText(submitted: String, newer: String?) -> String? {
        var texts: [String] = []
        for text in [submitted, newer].compactMap(\.self)
            where !isRecoveryContinuationDraftDisposable(text) && !texts.contains(text)
        {
            texts.append(text)
        }
        guard let first = texts.first else { return nil }
        return texts.dropFirst().reduce(first) { recoveryComposerAppending($1, to: $0) }
    }

    /// The window hosting `sessionID`'s message box: this one, else another window on the same
    /// recovery coordinator (review A R1-02: the session moved). `nil` when no window hosts it.
    func recoveryComposerHost(sessionID: UUID) -> (viewModel: AgentModeViewModel, session: AgentTabSession)? {
        if let session = recoveryListTabSession(sessionID: sessionID) { return (self, session) }
        for window in WindowStatesManager.shared.allWindows {
            let other = window.agentModeViewModel
            guard other !== self, other.recoveryCoordinator === recoveryCoordinator,
                  let session = other.recoveryListTabSession(sessionID: sessionID)
            else { continue }
            return (other, session)
        }
        return nil
    }

    /// Moves `text` into `session`'s message box (hosted by this window) and removes `rowID`'s
    /// draft; returns the row's message. Review B N3: only while the session's recovered composer
    /// is in its normal state (restored, nothing held, no unsaved predecessor input); otherwise the
    /// text stays the row's draft, and the next list action on the session moves it.
    func moveRecoveryContinuationTextToComposer(
        _ text: String,
        rowID: String,
        session: AgentTabSession,
        message: String
    ) -> String {
        guard let lane = session.recoveryLane, !lane.isRetired, lane.composerState == .ready,
              lane.unsavedPredecessorInputs.isEmpty
        else {
            recoveryCoordinator?.continuationDraftsByRowID[rowID] = text
            return Self.recoveryContinuationComposerBusyText
        }
        placeUnsentRecoveryContinuationInComposer(text, session: session, message: message)
        recoveryCoordinator?.continuationDraftsByRowID[rowID] = nil
        return message
    }

    /// What a continuation's result means for its row's Continue draft.
    enum RecoveryContinuationDraftDisposition: Equatable {
        /// Nothing was recorded by this choice (it never reached the runner, or was disabled,
        /// refused, joined, or held by a prior action): the draft is the only copy.
        case keep
        /// The action and its outcome were recorded, and the record now holds the text: it was
        /// sent (`dispatched`), or it ended unsent (`notDispatched`, `importedUnconfirmed`), so the
        /// card shows it again as its unsent text unless a saved intent carries it.
        case clear
        /// The action was recorded but its text was neither sent nor shown again by the card: the
        /// turn had already finished (`importedCompleted` resolves the card), or the outcome of an
        /// unsent choice couldn't be recorded (the action stays open, so the card has no unsent
        /// text). The text moves to the session's message box.
        case moveToComposer
    }

    static func recoveryContinuationDraftDisposition(_ result: AgentRecoveryActionResult?) -> RecoveryContinuationDraftDisposition {
        switch result {
        case nil, .disabled?, .refused?, .joined?, .priorAction?:
            .keep
        case .completed(.dispatched, _)?, .completed(.notDispatched, _)?, .completed(.importedUnconfirmed, _)?,
             .outcomeUnrecorded(.dispatched, _)?:
            .clear
        case .completed(.importedCompleted, _)?, .outcomeUnrecorded(.importedCompleted, _)?,
             .outcomeUnrecorded(.notDispatched, _)?, .outcomeUnrecorded(.importedUnconfirmed, _)?:
            .moveToComposer
        }
    }

    static let recoveryContinuationFinishedMovedText =
        "The interrupted turn had already finished, so your message wasn't sent. It's now in the message box."
    static let recoveryContinuationUnrecordedMovedText =
        "Nothing was sent, but that couldn't be recorded. Your message is now in the message box."
    static let recoveryContinuationLeftoverMovedText =
        "This card no longer offers Continue, so the message you typed for it wasn't sent. It's now in the message box."
    static let recoveryContinuationOpenSessionText =
        "Your message wasn't sent. Open this session to get it back in the message box."
    static let recoveryContinuationComposerBusyText =
        "Your message wasn't sent. Resolve this session's saved draft first; your message is kept and then moves to the message box."

    /// The row's message once its unsent continuation text moved to the message box.
    static func recoveryContinuationMovedToComposerText(_ result: AgentRecoveryActionResult?) -> String {
        switch result {
        case .completed(.importedCompleted, _)?, .outcomeUnrecorded(.importedCompleted, _)?:
            recoveryContinuationFinishedMovedText
        default:
            recoveryContinuationUnrecordedMovedText
        }
    }

    /// Removes the row's draft only while it still is `text` (a newer edit survives).
    private func removeRecoveryContinuationDraft(rowID: String, ifEqualTo text: String) {
        guard let coordinator = recoveryCoordinator, coordinator.continuationDraftsByRowID[rowID] == text else { return }
        coordinator.continuationDraftsByRowID[rowID] = nil
    }

    /// Review B L1: puts a continuation's unsent text into `session`'s message box: the text alone
    /// when the box is empty, otherwise after its current text and a blank line. Its current text
    /// is never replaced. The change is an ordinary composer edit (saved like typing).
    func placeUnsentRecoveryContinuationInComposer(_ text: String, session: AgentTabSession, message: String) {
        // The session's draft is current: the input bar stores every edit, and the recovered-draft
        // paths (Restore, retry load) store theirs synchronously before this runs.
        let result = Self.recoveryComposerAppending(text, to: session.draftText)
        storeDraftText(for: session.tabID, result)
        if session.tabID == currentTabID {
            // Review A R2-01 / B P1-B: the event carries the whole stored result, so the input bar
            // shows exactly it; events coalesced in one turn lose nothing, and a repeat is a no-op.
            draftRestorationEvent = DraftRestorationEvent(
                id: UUID(),
                tabID: session.tabID,
                text: text,
                message: message,
                strategy: .appendAfterBlankLine(result: result)
            )
        }
        syncComposerUIState(tabID: session.tabID)
    }

    /// `text` alone when `base` is blank, otherwise `base`, a blank line, and `text`.
    static func recoveryComposerAppending(_ text: String, to base: String) -> String {
        base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : base + "\n\n" + text
    }

    /// The input bar's new text for an `appendAfterBlankLine(result:)` event: the view model's
    /// stored `result`, or `nil` when the composer already shows it (review B N2: a repeat is a no-op).
    static func recoveryComposerAppendUpdate(live: String, result: String) -> String? {
        live == result ? nil : result
    }

    /// Refresh: one fresh discovery of every unresolved runtime. It never signals anything.
    private func refreshRecoveryRuntimes() async -> String? {
        await recoveryCoordinator?.refreshRuntimeOwnership()
        return nil
    }

    /// Let finish of exactly the displayed runtime revision (it stays restricted until it exits).
    private func letRecoveryRuntimeFinish(rowID: String) async -> String? {
        guard let coordinator = recoveryCoordinator else { return nil }
        guard let item = coordinator.catalog.item(id: rowID),
              case let .survivingRuntime(restriction) = item.payload,
              let revision = restriction.revision
        else { return "This process changed. Review it again." }
        return await coordinator.letRuntimeFinish(runtimeID: restriction.runtimeID, expectedRevision: revision)
    }

    /// Title and detail of a surviving-runtime row: provider, state, conversation, worktree and
    /// discovered processes. Once the root is seen exited, only the remaining processes are named.
    /// Stop is not offered (recovered Stop is disabled in production).
    static func recoveryListRuntimeText(_ restriction: AgentRuntimeRestriction) -> (String, String) {
        let provider = restriction.family.map(recoveryListRuntimeFamilyName) ?? "An agent"
        let rootExited = !restriction.isUnreadable && restriction.rootAlive == false
        // Only complete discovery saw every recorded member alive: `.live` and `.toolsRemaining` imply
        // it; `discoveryComplete` also covers a runtime detached at quit. An unresolved (`.unknown`)
        // projection is never verified.
        let verified = restriction.state == .live || restriction.state == .toolsRemaining
            || (restriction.discoveryComplete && restriction.state != .unknown)
        let remainingPIDs = recoveryListUniquePIDs(restriction.memberPIDs)
        let title: String = switch restriction.kind {
        case .toolsOnly:
            "Tools started by an agent are still running"
        case .possibleWriter where restriction.isUnreadable:
            "Agent process status unknown"
        case .possibleWriter where rootExited && restriction.writerPID == nil && !remainingPIDs.isEmpty:
            switch (remainingPIDs.count == 1, verified) {
            case (true, true): "A process started by an agent is still running"
            case (true, false): "A process started by an agent may still be running"
            case (false, true): "Processes started by an agent are still running"
            case (false, false): "Processes started by an agent may still be running"
            }
        case .possibleWriter where rootExited:
            verified ? "An agent process is still running" : "An agent process may still be running"
        case .possibleWriter:
            restriction.state == .unknown ? "An agent process may still be running" : "An agent process is still running"
        }
        var parts: [String] = []
        let origin = restriction.isPreviousInstance ? "from an earlier launch of RepoPrompt" : "started by this launch"
        if restriction.isUnreadable {
            parts.append("Its saved record couldn't be read, so its processes can't be checked.")
        } else if rootExited {
            parts.append(contentsOf: recoveryListExitedRootText(
                restriction,
                provider: provider,
                origin: origin,
                remainingPIDs: remainingPIDs,
                verified: verified
            ))
        } else {
            let processes = restriction.memberCount == 1 ? "1 process" : "\(restriction.memberCount) processes"
            // 9-live S5: the root is often a launcher shim; name the agent's own PID when known
            // (review P3-8: two PIDs never read as contradicting the count).
            let pids = switch (restriction.rootPID, restriction.writerPID) {
            case let (root?, writer?): "; launcher PID \(root), agent PID \(writer)"
            case let (nil, writer?): "; agent PID \(writer)"
            case let (root?, nil): ", started as PID \(root)"
            case (nil, nil): ""
            }
            parts.append("\(provider) \(origin) (\(processes) found\(pids)).")
        }
        if let worktree = restriction.worktreePaths.first {
            parts.append("Worktree: \(worktree).")
        }
        if let conversation = restriction.conversationIDs.first {
            parts.append("Conversation: \(conversation).")
        }
        let untilExit = switch (rootExited, remainingPIDs.count) {
        case (true, 0): "until RepoPrompt confirms they exited"
        case (true, 2...): "until they exit"
        default: "until it exits"
        }
        switch restriction.kind {
        case .toolsOnly:
            parts.append("It no longer writes the conversation, but scheduled work in this worktree stays paused until its tools exit.")
        case .possibleWriter where restriction.conversationIDs.isEmpty:
            parts.append("Sending in this worktree stays paused \(untilExit).")
        case .possibleWriter:
            parts.append("Sending to that conversation stays paused \(untilExit).")
        }
        if restriction.letFinish {
            parts.append("You chose to let it finish; RepoPrompt keeps watching it.")
        }
        parts.append("Nothing is stopped automatically.")
        return (title, parts.joined(separator: " "))
    }

    /// The detail sentences once the root (often a launcher) is known to have exited. Processes are
    /// called running only when discovery verified them (`verified`); quit advice appears only then,
    /// and never while an agent (writer) is recorded.
    private static func recoveryListExitedRootText(
        _ restriction: AgentRuntimeRestriction,
        provider: String,
        origin: String,
        remainingPIDs: [Int32],
        verified: Bool
    ) -> [String] {
        /// The verb phrase for one process or several.
        func running(single: Bool) -> String {
            guard verified else { return "may still be running" }
            return single ? "is still running" : "are still running"
        }
        if let writer = restriction.writerPID {
            let launcher = restriction.rootPID.map { "its launcher (PID \($0)) has exited" } ?? "its launcher has exited"
            var parts = ["\(provider) \(origin) \(running(single: true)) as PID \(writer); \(launcher)."]
            let others = remainingPIDs.filter { $0 != writer }
            if !others.isEmpty {
                let list = recoveryListPIDList(others)
                let also = switch (verified, others.count == 1) {
                case (true, _): "Also running: \(list)."
                case (false, true): "Another process it started may also be running: \(list)."
                case (false, false): "Other processes it started may also be running: \(list)."
                }
                parts.append(also)
            }
            return parts
        }
        let root = restriction.rootPID.map { " (PID \($0))" } ?? ""
        guard !remainingPIDs.isEmpty else {
            return ["\(provider) \(origin)\(root) has exited, but RepoPrompt couldn't confirm that every process it started did."]
        }
        let single = remainingPIDs.count == 1
        let count = single
            ? "1 process it started \(running(single: true))"
            : "\(remainingPIDs.count) processes it started \(running(single: false))"
        var parts = ["\(provider) \(origin)\(root) has exited, but \(count): \(recoveryListPIDList(remainingPIDs))."]
        if verified {
            let advice = single
                ? "If it is stuck, check that PID's command and start time first; then you can quit it yourself. RepoPrompt notices when it exits."
                : "If they are stuck, check each PID's command and start time first; then you can quit them yourself. RepoPrompt notices when they exit."
            parts.append(advice)
        }
        return parts
    }

    /// `pids` once each, in order.
    private static func recoveryListUniquePIDs(_ pids: [Int32]) -> [Int32] {
        var seen: Set<Int32> = []
        return pids.filter { seen.insert($0).inserted }
    }

    private static let recoveryListMaxNamedPIDs = 5

    /// "PID 1, PID 2", naming at most `recoveryListMaxNamedPIDs` followed by "and N more".
    private static func recoveryListPIDList(_ pids: [Int32]) -> String {
        let named = pids.prefix(recoveryListMaxNamedPIDs).map { "PID \($0)" }.joined(separator: ", ")
        let rest = pids.count - recoveryListMaxNamedPIDs
        return rest > 0 ? "\(named) and \(rest) more" : named
    }

    private static func recoveryListRuntimeFamilyName(_ family: AgentRuntimeFamily) -> String {
        switch family {
        case .claudeNative: "Claude"
        case .claudeCompatible: "A Claude-compatible agent"
        case .claudeHeadless: "Claude (headless)"
        case .codexAppServer: "Codex"
        case .codexExec: "Codex (exec)"
        case .acp: "An ACP agent"
        }
    }

    /// Dismiss: durably acknowledges exactly the displayed item in its displayed state. Nothing else
    /// changes (the turn, input, question, draft, schedule, or crash hold stays as it is).
    private func dismissRecoveryListItem(rowID: String) async -> String? {
        guard let coordinator = recoveryCoordinator else { return nil }
        guard let item = coordinator.catalog.item(id: rowID) else { return "This item changed. Review it again." }
        return await coordinator.dismissCatalogItem(item)
    }

    static let recoveryListDraftRowPrefix = "draft-"

    /// The session UUID following `prefix` in a draft row ID (`draft-<kind>-<UUID>[-<token>]`).
    private func recoveryListDraftRowID(_ rowID: String, kind: String) -> UUID? {
        let prefix = "\(Self.recoveryListDraftRowPrefix)\(kind)-"
        guard rowID.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(rowID.dropFirst(prefix.count).prefix(36)))
    }

    /// Restore / Discard of exactly the displayed held draft, unsaved predecessor draft, or ownerless
    /// draft. The row ID carries the displayed revision or entry identity; a changed draft is never
    /// resolved in its place.
    private func resolveRecoveryListDraft(rowID: String, choice: AgentRecoveryHeldComposerChoice) async -> String? {
        if rowID.hasPrefix("question-") {
            return await resolveRecoveryListQuestion(rowID: rowID, choice: choice)
        }
        let changed = "This draft changed. Review it again."
        if let sessionID = recoveryListDraftRowID(rowID, kind: "ownerless") {
            guard choice == .discard,
                  let coordinator = recoveryCoordinator,
                  let entry = coordinator.ownerlessUnsavedInputs[sessionID]?.inputs.first,
                  rowID == "draft-ownerless-\(sessionID.uuidString)-\(Self.recoveryListFingerprint(entry))"
            else { return changed }
            return coordinator.discardOwnerlessUnsavedInput(sessionID: sessionID, expected: entry) ? nil : changed
        }
        if let sessionID = recoveryListDraftRowID(rowID, kind: "held") {
            guard let session = recoveryListTabSession(sessionID: sessionID),
                  let lane = session.recoveryLane,
                  case let .held(snapshot) = lane.composerState,
                  rowID == Self.recoveryListHeldDraftRowID(sessionID: sessionID, revision: snapshot.revision)
            else { return changed }
            switch await resolveHeldRecoveryComposer(choice, expectedHeldRevision: snapshot.revision, for: session) {
            case .success:
                return nil
            case let .failure(failure):
                return Self.recoveryListDraftFailureText(failure)
            }
        }
        if let sessionID = recoveryListDraftRowID(rowID, kind: "unsaved") {
            guard let session = recoveryListTabSession(sessionID: sessionID),
                  let lane = session.recoveryLane,
                  let entry = lane.unsavedPredecessorInputs.first,
                  rowID == "draft-unsaved-\(sessionID.uuidString)-\(Self.recoveryListFingerprint(entry))"
            else { return changed }
            let liveIsEmpty = recoveryInputContent(for: session, store: lane.store, sessionID: sessionID)?.isEmpty ?? false
            switch await lane.resolveUnsavedPredecessorInput(choice, expected: entry, liveComposerIsEmpty: liveIsEmpty) {
            case let .failure(failure):
                return Self.recoveryListDraftFailureText(failure)
            case let .success(content):
                guard session.recoveryLane === lane else { return nil }
                if let content {
                    // Already forwarded to the lane as its live composer; shown without a new edit.
                    applyRecoveredComposer(content, lane: lane, to: session)
                } else {
                    // Current typing (kept) is forwarded again now that admission can reopen.
                    recoveryComposerDidMutate(session: session)
                }
                return nil
            }
        }
        return changed
    }

    /// R4: copies an earlier launch's unanswered question into the empty message box (saved first),
    /// or dismisses it. Never resumes the old request; the snapshot is removed only afterwards.
    private func resolveRecoveryListQuestion(rowID: String, choice: AgentRecoveryHeldComposerChoice) async -> String? {
        let ids = rowID.dropFirst("question-".count)
        guard ids.count == 73,
              let sessionID = UUID(uuidString: String(ids.prefix(36))),
              let interactionID = UUID(uuidString: String(ids.suffix(36)))
        else { return "This question is no longer available." }
        guard let (session, lane) = recoveryListLane(sessionID: sessionID) else {
            return "Open this session to use this question."
        }
        let questions: [AgentRecoveryQuestionSnapshot]
        switch await lane.readRecord() {
        case let .failure(failure):
            AgentRecoveryFailureDiagnostics.presentationFailure(site: "recovery_list_question_unreadable", failure: failure)
            return "The saved question couldn't be read (\(Self.recoveryListDescription(of: failure))). Nothing was changed."
        case let .success(state):
            switch state {
            case .preserved:
                return "The saved question data is unreadable and is kept unchanged."
            case .absent:
                return nil
            case let .supported(record):
                questions = record.questions
            }
        }
        guard let snapshot = questions.first(where: { $0.interactionID == interactionID }) else { return nil }
        if choice == .restoreToComposer {
            guard session.recoveryLane === lane, !lane.isRetired,
                  recoveryInputContent(for: session, store: lane.store, sessionID: lane.sessionID)?.isEmpty == true
            else {
                return "Clear the message box first. Your current text and this question are both kept."
            }
            applyRecoveredComposer(AgentRecoveryInputContent(text: snapshot.composerText), lane: lane, to: session)
            recoveryComposerDidMutate(session: session)
            if case let .failed(failure) = await lane.flushComposer() {
                return "The question was copied into the message box but couldn't be saved (\(Self.recoveryListDescription(of: failure))). It is still listed here."
            }
        }
        if case let .failure(failure) = await lane.updateQuestionSnapshots(.init(removing: [interactionID])) {
            return "The question couldn't be removed from this list (\(Self.recoveryListDescription(of: failure)))."
        }
        return nil
    }

    private static func recoveryListDraftFailureText(_ failure: AgentRecoveryControllerFailure) -> String {
        switch failure {
        case .liveComposerHasUnsavedContent:
            "Clear the message box first. Your current text and this draft are both kept."
        case .composerChangedDuringRestore:
            "The message box changed while restoring, so the draft was kept as it was. Your current text and this draft are both kept."
        case .heldInputChanged, .noHeldComposer:
            "This draft changed. Review it again."
        default:
            "The draft couldn't be updated (\(recoveryListDescription(of: failure))). Nothing was discarded."
        }
    }

    private static func recoveryListRouteFailure(_ result: AgentSessionRouteResult) -> String? {
        switch result {
        case .routed:
            nil
        case .workspaceUnavailable:
            "That workspace isn't available. Open it from the Workspaces menu."
        case let .workspaceSwitchBlocked(message):
            message ?? "RepoPrompt couldn't switch to that workspace."
        case .blockedByActiveDifferentSession:
            "Another session is active in that tab. Open this session from the sidebar."
        case .tabUnavailable, .sessionUnavailable, .sessionMismatch:
            "This session can't be opened from here. Open it from the sidebar."
        }
    }

    /// Retry save (write failure), retry load (restore failure), or restart preparation.
    private func retryRecoveryListSave(rowID: String) async -> String? {
        if rowID.hasPrefix("savefail-question-") {
            guard let sessionID = recoveryListSessionID(rowID),
                  let session = recoveryListTabSession(sessionID: sessionID),
                  let lane = AgentRecoveryLiveQuestions.lane(for: session)
            else { return "This session is no longer open here." }
            if case let .failed(failure) = await lane.questionPersistence.flush() {
                return "The question still couldn't be saved (\(Self.recoveryListDescription(of: failure)))."
            }
            // A held answer is sent only by submitting it again (its card still holds it).
            return lane.questionPersistence.unsentAnswerIDs.isEmpty ? nil : "Saved. Submit your answer again to send it."
        }
        if let tabIDString = rowID.hasPrefix("draft-prep-") ? String(rowID.dropFirst("draft-prep-".count)) : nil {
            guard let tabID = UUID(uuidString: tabIDString), let session = sessions[tabID] else {
                return "This tab is no longer open."
            }
            recoveryComposerDidMutate(session: session)
            return nil
        }
        if let sessionID = recoveryListDraftRowID(rowID, kind: "restorefail") {
            guard let session = recoveryListTabSession(sessionID: sessionID) else { return "This session is no longer open here." }
            if case let .failed(failure) = await retryRecoveryComposerRestore(for: session) {
                return "The saved draft still couldn't be loaded (\(Self.recoveryListDescription(of: failure)))."
            }
            return nil
        }
        if let sessionID = recoveryListDraftRowID(rowID, kind: "savefail") {
            guard let session = recoveryListTabSession(sessionID: sessionID), let lane = session.recoveryLane else {
                return "This session is no longer open here."
            }
            // Re-forward the live composer so its current content is what is written.
            recoveryComposerDidMutate(session: session)
            if case let .failed(failure) = await lane.flushComposer() {
                return "The message box still couldn't be saved (\(Self.recoveryListDescription(of: failure))). Your text is still there."
            }
            return nil
        }
        return nil
    }

    func retryRecoveryStartup() {
        recoveryStartupRetry?()
        refreshRecoveryListUI()
    }

    /// Publishes the current tab's composer (its recovery list) once and re-reports every other
    /// open tab's scheduler busy state. Never publishes another tab's props (F7), and never
    /// materializes a session: a current tab without one gets a non-submittable snapshot.
    func refreshRecoveryListUI() {
        let ownerTabID = currentTabID
        if let ownerTabID {
            if sessions[ownerTabID] != nil {
                syncComposerUIState(tabID: ownerTabID)
            } else {
                // The only composer publication besides `syncComposerUIState`: current-tab props only.
                ui.composer.update(makeComposerProps(tabID: ownerTabID, materializingSession: false))
            }
        } else {
            syncComposerUIState()
        }
        let otherTabIDs = Set(sessions.keys.filter { $0 != ownerTabID })
        if !otherTabIDs.isEmpty {
            notifyScheduledSendBusyStateMayHaveChanged(tabIDs: otherTabIDs)
        }
    }

    /// The session and intent named by an `intent-<session>-<intent>` row (startup results or this
    /// launch's held input).
    private func recoveryListIntentRow(_ rowID: String) -> (sessionID: UUID, intentID: UUID)? {
        let parts = rowID.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "intent", recoveryCoordinator != nil else { return nil }
        // "<session UUID>-<intent UUID>": both are 36 characters.
        let ids = parts[1]
        guard ids.count == 73,
              let sessionID = UUID(uuidString: String(ids.prefix(36))),
              let intentID = UUID(uuidString: String(ids.suffix(36)))
        else { return nil }
        return (sessionID, intentID)
    }

    /// Row ID of a session's compact paused indicator (its crash-hold card is dismissed).
    static let recoveryListPausedRowPrefix = "paused-"

    /// The catalog item a row acts on: the item itself, or for the paused indicator its session's
    /// crash-hold item. Actions resolve sessions from the current catalog, never by re-parsing.
    func recoveryListCatalogItem(_ rowID: String) -> AgentRecoveryCatalogItem? {
        guard let coordinator = recoveryCoordinator else { return nil }
        if rowID.hasPrefix(Self.recoveryListPausedRowPrefix) {
            return coordinator.catalog.item(id: "crash-\(rowID.dropFirst(Self.recoveryListPausedRowPrefix.count))")
        }
        return coordinator.catalog.item(id: rowID)
    }

    private func recoveryListSessionID(_ rowID: String) -> UUID? {
        if let sessionID = recoveryListCatalogItem(rowID)?.sessionID { return sessionID }
        if rowID.hasPrefix(Self.recoveryListPausedRowPrefix) {
            return UUID(uuidString: String(rowID.dropFirst(Self.recoveryListPausedRowPrefix.count)))
        }
        // A row whose item just left the catalog (`<kind>-<session UUID>[-…]`).
        guard let dash = rowID.firstIndex(of: "-") else { return nil }
        return UUID(uuidString: String(rowID[rowID.index(after: dash)...].prefix(36)))
    }

    /// The open session's live lane, revalidated against the row's session and (for startup rows)
    /// the startup lifecycle. The lane's own record read validates everything else.
    func recoveryListLane(sessionID: UUID) -> (AgentTabSession, AgentRecoverySessionLane)? {
        guard let session = activeSession,
              session.activeAgentSessionID == sessionID,
              let lane = session.recoveryLane,
              !lane.isRetired,
              lane.sessionID == sessionID
        else { return nil }
        if let resolution = recoveryCoordinator?.reconciliation.resolution(for: sessionID),
           let startupBinding = resolution.binding,
           startupBinding.incarnationID != lane.binding.incarnationID
        {
            return nil
        }
        return (session, lane)
    }

    private enum RecoveredIntentLookup {
        /// The record could not be read or is preserved; nothing may be changed.
        case unavailable(String)
        /// The intent no longer needs a decision (already resolved elsewhere).
        case settled
        case current(AgentRecoveryIntent)
    }

    /// The intent as currently recorded (never the startup snapshot) when it still needs a decision.
    private func currentRecoveredIntent(
        _ intentID: UUID,
        lane: AgentRecoverySessionLane
    ) async -> RecoveredIntentLookup {
        switch await lane.readRecord() {
        case let .failure(failure):
            AgentRecoveryFailureDiagnostics.presentationFailure(site: "recovery_list_message_unreadable", failure: failure)
            return .unavailable("The saved message couldn't be read (\(Self.recoveryListDescription(of: failure))). Nothing was changed.")
        case let .success(state):
            switch state {
            case .preserved:
                return .unavailable("The saved message data is unreadable and is kept unchanged.")
            case .absent:
                return .settled
            case let .supported(record):
                guard let intent = record.intent(id: intentID), Self.recoveryListShowsIntent(intent) else { return .settled }
                return .current(intent)
            }
        }
    }

    /// R04: how Edit keeps a carrier's exact pending-handoff association.
    enum RecoveryEditPendingHandoffPlan: Equatable {
        /// The session already holds exactly this payload (same identity and text).
        case reuse
        /// The session holds no payload: restore the snapshot through the session save first.
        case restore
        /// The session holds a different payload: refuse, changing neither.
        case conflict
    }

    static func recoveryEditPendingHandoffPlan(
        _ snapshot: AgentRecoveryPendingHandoffSnapshot,
        session pending: AgentPendingHandoffState
    ) -> RecoveryEditPendingHandoffPlan {
        guard pending.hasPayload else { return .restore }
        return pending.payloadID == snapshot.payloadID && pending.payload == snapshot.payload ? .reuse : .conflict
    }

    /// Edit: moves the held input into this session's empty composer (written durably first), then
    /// withdraws the original. Newer typing is never replaced, and input from another reset
    /// generation is never adopted into the current conversation. Only a withdrawable intent
    /// (`queued`, `failed`) is edited. R04: an intent carrying a pending-handoff snapshot keeps that
    /// exact association — an identical session payload is reused, an absent one is restored and
    /// saved before anything else changes, a conflicting one refuses with nothing changed — and the
    /// pending-handoff join reruns after the withdrawal, so the next explicit send inherits the
    /// prefix once (never pasted into the user's text, never a second bubble).
    private func editRecoveredIntent(rowID: String) async -> String? {
        guard let (sessionID, intentID) = recoveryListIntentRow(rowID) else { return "This message is no longer available." }
        guard let (session, lane) = recoveryListLane(sessionID: sessionID) else {
            return "Open this session to edit its message."
        }
        let intent: AgentRecoveryIntent
        switch await currentRecoveredIntent(intentID, lane: lane) {
        case let .unavailable(message):
            return message
        case .settled:
            return nil
        case let .current(value):
            intent = value
        }
        guard intent.transcriptResetGeneration == lane.binding.transcriptResetGeneration else {
            return "This message was written before the conversation was cleared, so it can't be moved into it. You can still view or remove it."
        }
        // O46: a message settled by a crash-hold confirmation may move too (the user decides
        // whether to send it again); other possibly delivered input stays view-or-remove.
        let settled = intent.deliveryState == .deliveryUnknown
            && recoveryListCatalogItem(rowID)?.actionFacts.settledByExitProof == true
        guard intent.deliveryState == .queued || intent.deliveryState == .failed || settled else {
            return "This message may already have been delivered, so it can only be viewed or removed."
        }
        func composerIsEmpty() -> Bool {
            session.recoveryLane === lane && !lane.isRetired
                && recoveryInputContent(for: session, store: lane.store, sessionID: lane.sessionID)?.isEmpty == true
        }
        guard composerIsEmpty() else {
            return "Clear the message box first. Your current text and this saved message are both kept."
        }
        if let snapshot = intent.pendingHandoff {
            switch Self.recoveryEditPendingHandoffPlan(snapshot, session: session.pendingHandoff) {
            case .reuse:
                break
            case .conflict:
                return "This message carries earlier conversation history that differs from the history waiting in this session. Nothing was changed."
            case .restore:
                // Restored only while every carrier of this payload provably delivered nothing: a
                // sibling's accepted or uncertain delivery may already have consumed it.
                let recordState = await lane.readRecord()
                let join = Self.pendingHandoffRecoveryJoin(payloadID: snapshot.payloadID, recordState: recordState)
                guard join == .carriedByIntent else {
                    return "The conversation history this message carries may already have been delivered, so it can't be moved into the message box. You can still view or remove it."
                }
                guard composerIsEmpty(), !session.pendingHandoff.hasPayload else {
                    return "The session changed. The original message is still saved here."
                }
                let previous = session.pendingHandoff
                var restored = AgentPendingHandoffState(
                    payload: snapshot.payload,
                    createdAt: snapshot.createdAt?.date,
                    sourceItemID: snapshot.sourceItemID,
                    payloadID: snapshot.payloadID
                )
                // Still carried by the queued intent until it is withdrawn below.
                restored.deliveryHold = .recoveryCarriedByIntent
                session.pendingHandoff = restored
                session.isDirty = true
                guard await saveSession(for: session.tabID) else {
                    if session.pendingHandoff == restored { session.pendingHandoff = previous }
                    return "The conversation history this message carries couldn't be saved. Nothing was changed."
                }
                guard session.pendingHandoff.payloadID == snapshot.payloadID else {
                    return "The session changed. The original message is still saved here."
                }
            }
        }
        guard composerIsEmpty() else {
            return "Clear the message box first. Your current text and this saved message are both kept."
        }
        applyRecoveredComposer(intent.payload, lane: lane, to: session)
        guard let placed = recoveryInputContent(for: session, store: lane.store, sessionID: lane.sessionID),
              placed.text == intent.payload.text,
              placed.images.count == intent.payload.images.count,
              placed.taggedFiles.count == intent.payload.taggedFiles.count,
              placed.documents.map(\.id) == intent.payload.documents.map(\.id)
        else {
            return "The saved message couldn't be placed into the message box (an attachment is missing). It is still saved here."
        }
        // The composer is written under this lane before the original is withdrawn.
        recoveryComposerDidMutate(session: session)
        if case let .failed(failure) = await lane.flushComposer() {
            AgentRecoveryFailureDiagnostics.presentationFailure(site: "recovery_list_edit_composer_not_saved", failure: failure)
            return "The message box couldn't be saved (\(Self.recoveryListDescription(of: failure))). The original message is still saved here."
        }
        guard session.recoveryLane === lane, !lane.isRetired else {
            return "The session changed. The original message is still saved here."
        }
        if case let .failure(failure) = await lane.withdraw(intentID: intentID) {
            AgentRecoveryFailureDiagnostics.presentationFailure(site: "recovery_list_edit_original_not_withdrawn", failure: failure)
            return "The message was moved into the message box, but the original couldn't be removed (\(Self.recoveryListDescription(of: failure)))."
        }
        await awaitPendingHandoffRecoveryJoin(for: session)
        return nil
    }

    /// Remove: commits the withdrawal before the row disappears. Accepted evidence is never erased
    /// (the store refuses withdrawal after acceptance or during a possible handoff).
    private func removeRecoveredIntent(rowID: String) async -> String? {
        guard let (sessionID, intentID) = recoveryListIntentRow(rowID) else { return "This message is no longer available." }
        guard let (session, lane) = recoveryListLane(sessionID: sessionID) else {
            return "Open this session to remove its message."
        }
        switch await currentRecoveredIntent(intentID, lane: lane) {
        case let .unavailable(message):
            return message
        case .settled:
            return nil
        case .current:
            break
        }
        if case let .failure(failure) = await lane.withdraw(intentID: intentID) {
            AgentRecoveryFailureDiagnostics.presentationFailure(site: "recovery_list_remove_not_withdrawn", failure: failure)
            return "The message couldn't be removed (\(Self.recoveryListDescription(of: failure))). It is still saved."
        }
        // A withdrawn carrier no longer reserves its pending-handoff payload.
        if session.recoveryLane === lane {
            await awaitPendingHandoffRecoveryJoin(for: session)
        }
        return nil
    }

    /// R10 "Cancel pending schedule": opens the session when needed, then cancels its held transfer
    /// through its owner (decision committed, then the exact schedule cleared). The linked message's
    /// own uncertain delivery stays presented; nothing is resent.
    private func cancelRecoveryScheduleTransfer(rowID: String) async -> String? {
        guard recoveryCoordinator != nil, let sessionID = recoveryListSessionID(rowID) else { return nil }
        if recoveryListTabSession(sessionID: sessionID) == nil, let failure = await openRecoveryListSession(rowID: rowID) {
            return failure
        }
        guard let session = recoveryListTabSession(sessionID: sessionID) else {
            return "Open this session to cancel its pending schedule."
        }
        return await cancelHeldScheduledSendTransfer(session: session, sessionID: sessionID)
    }

    /// "It stopped": durably acknowledges exactly the displayed hold through the session's lane (F-2),
    /// opening the session first when no lane is live. The row stays until the commit succeeds.
    private func confirmRecoveryCrashHold(rowID: String) async -> String? {
        guard let coordinator = recoveryCoordinator,
              let sessionID = recoveryListSessionID(rowID),
              let hold = coordinator.crashHold(for: sessionID)
        else { return nil }
        if coordinator.lane(for: sessionID) == nil, let failure = await openRecoveryListSession(rowID: rowID) {
            return failure
        }
        guard let lane = coordinator.lane(for: sessionID), !lane.isRetired else {
            return "Open this session to confirm the previous run has stopped."
        }
        return await coordinator.confirmCrashHold(hold, lane: lane)
            ? nil
            : "The confirmation couldn't be saved, or the session's status changed. Review it again."
    }

    typealias RecoveryListSessionRouter = @MainActor (AgentSessionDeepLinkRoute) async -> AgentSessionRouteResult

    /// Production `recoveryListRouteToSession`: the existing agent-session navigation route.
    static func routeRecoveryListSessionThroughDeepLinks(_ route: AgentSessionDeepLinkRoute) async -> AgentSessionRouteResult {
        await AppDeepLinkRouter.shared.route(agentSession: route)
    }

    /// Opens the row's session tab (switch or unstash) without starting anything. A session in
    /// another workspace is opened through the existing agent-session navigation route (it switches
    /// to, or finds a window showing, that workspace).
    private func openRecoveryListSession(rowID: String) async -> String? {
        let unavailable = "This session can't be opened from here. Open it from the sidebar."
        guard let coordinator = recoveryCoordinator, let sessionID = recoveryListSessionID(rowID) else { return unavailable }
        let item = recoveryListCatalogItem(rowID)
        let resolution = coordinator.reconciliation.resolution(for: sessionID)
        guard let tabID = item?.composeTabID ?? resolution?.composeTabID else { return unavailable }
        if let workspaceID = item?.workspaceID ?? resolution?.workspaceID, workspaceID != persistenceWorkspace?.id {
            let route = AgentSessionDeepLinkRoute(workspaceID: workspaceID, tabID: tabID, sessionID: sessionID)
            let result = await recoveryListRouteToSession(route)
            return Self.recoveryListRouteFailure(result)
        }
        return await openRecoveryListTab(tabID)
    }

    /// Switches to (or unstashes) one of this workspace's tabs and hydrates it; starts nothing.
    private func openRecoveryListTab(_ tabID: UUID) async -> String? {
        let unavailable = "This session can't be opened from here. Open it from the sidebar."
        guard let promptManager else { return unavailable }
        if promptManager.currentComposeTabs.contains(where: { $0.id == tabID }) {
            await promptManager.switchComposeTab(tabID)
        } else if promptManager.currentStashedTabs.contains(where: { $0.id == tabID }) {
            await promptManager.unstashTab(tabID)
        } else {
            return unavailable
        }
        _ = await ensureHydrated(tabID: tabID)
        return nil
    }
}
