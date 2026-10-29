import Foundation

// Lossless-restart Phase 2 recovery catalog: one immutable, app-wide projection of everything that
// needs the user's attention after a restart or an interrupted run, owned and published by the
// recovery coordinator. Both surfaces render it: the per-session banner is an exact session filter
// of the snapshot, and the app-wide Needs Attention sheet renders the snapshot itself. Presentation
// adapters format rows and choose actions for their navigation context; they never rediscover or
// remove items. Building a catalog constructs no provider, controller, or view model.

/// Phase-2 item kinds.
package enum AgentRecoveryCatalogItemKind: String, CaseIterable {
    case interruptedTurn
    case terminalOutcome
    case savedInput
    case savedDraft
    case unansweredQuestion
    case scheduleNeedsConfirmation
    case crashHold
    case heldScheduleTransfer
    case statusUnknown
    case saveFailure
    /// Spec R6: an agent process family that may still be running (or whose ownership is unknown).
    case survivingProcess
    /// Step 5a: an `apply_edits` proposal whose live review ended without an apply or a rejection.
    case pendingEditReview
}

/// Step 8-attention (O34-3): whether an item asks the user for a decision (something is paused, or
/// text or a decision stays unsent if the user does nothing) or is a note (nothing is paused or
/// lost). Derived at projection time from the payload and the item's action facts; never persisted.
package enum AgentRecoveryCatalogAttention: Equatable {
    case needsAction
    case informational
}

/// Step 8-attention-2 (O34): why an informational run card is cleared from ordinary presentation.
/// Derived at projection time, never written: a cleared card stays in the catalog, is not counted
/// or listed in Information, and is shown with its reason only under "Show dismissed and cleared".
/// No age-based expiry.
package enum AgentRecoveryCatalogAutomaticClear: Equatable {
    /// A recovery action on the card sent, or proved its turn finished (`resolvedByAction`).
    case resolved
    /// The conversation was cleared after the run (its reset generation is older than current).
    case conversationCleared
    /// A later run attempt exists in the run's own conversation generation.
    case sessionContinued
}

/// Shared progress or failure of one item's action (the same on every surface).
package enum AgentRecoveryCatalogActionState: Equatable {
    case working
    case failed(String)
}

/// Why sending to an item's session stays paused (non-dismissible: a dismissed card keeps it).
/// A restricted session is refused by admission itself (`AgentRecoveryAdmissionRefusal.restricted`);
/// the catalog kept no reader for a restriction blocker, so it carries none (review B F16).
package enum AgentRecoveryCatalogBlocker: Equatable {
    case crashHold
}

/// Durable Dismiss state of a dismissible item: its semantic key and current freshness, and whether
/// the stored acknowledgement covers exactly this state.
package struct AgentRecoveryCatalogAcknowledgement: Equatable {
    package let key: AgentRecoveryCardKey
    package let freshness: AgentRecoveryCardFreshness
    package let isAcknowledged: Bool
}

/// Formatting context of held input (the adapter's wording and action choice).
package struct AgentRecoveryCatalogIntentContext: Equatable {
    package let isEarlierLaunch: Bool
    /// Why it is held this launch (its projection was removed, or it is uncertain after its run).
    package let heldReason: String?
    /// Typed under the session's current reset generation.
    package let sameGeneration: Bool
    /// The session executes on an authoritative remote host (F-3).
    package let isRemote: Bool
    /// O50: every run of the intent ended with recorded evidence, so its uncertainty did not come
    /// from an unclean exit (`AgentRecoveryRecord.intentRunsEndedWithRecordedEvidence`).
    package let runsEndedWithRecordedEvidence: Bool
}

/// The typed display payload a presentation adapter formats.
package enum AgentRecoveryCatalogPayload: Equatable {
    case workspaceFailure(reason: String)
    case nonactionable(AgentSessionRecoveryNonactionableReason)
    case duplicateDestination
    case noDestination
    case crashHold(AgentRecoveryCrashHold)
    case scheduleTransfer(message: String)
    case turn(AgentRecoveryInterruptedTurn)
    /// A turn saved open that cold restoration closed with its attempt's ordinary outcome.
    case outcomeTurn(AgentRecoveryOutcomeTurn)
    case recoveryOnlyRun(AgentRecoveryRunAttempt)
    case intent(AgentRecoveryIntent, AgentRecoveryCatalogIntentContext)
    /// A saved question whose request has ended (an earlier launch's, or this launch's once its
    /// owning request expired). Historical text only; never resumed.
    case question(AgentRecoveryQuestionSnapshot, isCurrentLaunch: Bool)
    /// Step 5a: a reviewed edit proposal whose live review ended (an earlier launch's, or this
    /// launch's once its review expired, timed out, or was closed). Historical data only (View,
    /// Copy, Discard): never applied, never answered back to the agent.
    case editProposal(AgentRecoveryEditProposal, isCurrentLaunch: Bool)
    /// A composer typed before the conversation was cleared (a live lane's held draft).
    case heldDraft(AgentRecoveryComposerSnapshot)
    /// A session without a live lane whose recovery record holds a saved, non-empty composer
    /// (review A F05). `fromClearedConversation` when it was typed before the conversation was cleared.
    case closedSessionDraft(AgentRecoveryComposerSnapshot, fromClearedConversation: Bool)
    case composerRestoreFailed(AgentRecoveryControllerFailure)
    case unsavedPredecessor(AgentRecoveryUnsavedComposerInput, count: Int)
    case composerWriteFailed(AgentRecoveryControllerFailure)
    /// Input a released lane could not persist while no later lane inherited it.
    case ownerlessDraft(AgentRecoveryUnsavedComposerInput)
    /// A tab's composer input that could not be prepared for saving yet (no lane, no durable
    /// authority). Runtime only: never persisted, never dismissible.
    case composerPreparationFailed(AgentRecoveryComposerPreparationFailure)
    /// A live question's snapshot or removal could not be saved (`failure`), or a submitted answer
    /// was not sent because it could not be preserved first (`unsentAnswer`). Runtime only, never
    /// dismissible: it clears once a write commits and no answer is held.
    case questionSaveFailed(AgentRecoveryControllerFailure?, unsentAnswer: Bool)
    case scheduleNeedsConfirmation(AgentScheduledSendConfirmationSummary)
    /// A workspace holds session files but no current metadata index, so schedules awaiting
    /// confirmation there could not be checked (index-only discovery never rebuilds it).
    case scheduleIndexUnavailable(workspaceName: String)
    /// Spec R6: a runtime that may still hold a conversation or worktree (Refresh, Let finish;
    /// recovered Stop is not offered). Never dismissible: it clears when discovery proves exit.
    case survivingRuntime(AgentRuntimeRestriction)
    /// Spec R6 global warning: runtime records whose bindings are unknown, or an unreadable runtime
    /// directory. Ownership-dependent work stays paused everywhere until Refresh can check them.
    case runtimeOwnershipUnknown(unidentifiedRecordCount: Int, failure: String?)
}

/// The latest index-only read of schedules awaiting confirmation, across every known workspace.
package struct AgentRecoveryIndexedSchedules: Equatable {
    package let summaries: [AgentScheduledSendConfirmationSummary]
    package let unavailableWorkspaces: [AgentRecoveryWorkspaceDestination]

    package static let empty = AgentRecoveryIndexedSchedules(summaries: [], unavailableWorkspaces: [])
}

package struct AgentRecoveryCatalogItem: Equatable, Identifiable {
    /// Stable row identity (the recovery list's existing row ID formats).
    package let id: String
    package let kind: AgentRecoveryCatalogItemKind
    package let sessionID: UUID?
    package let workspaceID: UUID?
    /// Saved session name when known; adapters fall back to their own display names.
    package let sessionName: String?
    /// Tab to open the session from (never starts a provider).
    package let composeTabID: UUID?
    package let payload: AgentRecoveryCatalogPayload
    /// `nil` when the item offers no durable Dismiss (save failures, unknown or unreadable authority,
    /// held transfers).
    package let acknowledgement: AgentRecoveryCatalogAcknowledgement?
    /// Durable action evidence of the item's card (offers no duplicate or invalid sends).
    package var actionFacts = AgentRecoveryCatalogActionFacts()

    package var isDismissed: Bool {
        acknowledgement?.isAcknowledged == true
    }

    /// O34-3 classification (derived, never stored).
    package var attention: AgentRecoveryCatalogAttention {
        AgentRecoveryCatalogProjection.attention(for: payload, facts: actionFacts)
    }

    /// Shown by the banner and counted by Needs Attention badges: needs action and not dismissed.
    package var isOpenNeedsAction: Bool {
        attention == .needsAction && !isDismissed
    }

    /// Why the card is cleared from ordinary presentation (derived, never stored). Only an
    /// informational run card can be cleared: a needs-action card (an unfinished action, a hold, an
    /// unsent continuation) never is.
    package var automaticClear: AgentRecoveryCatalogAutomaticClear? {
        guard attention == .informational else { return nil }
        switch payload {
        case .turn, .outcomeTurn, .recoveryOnlyRun:
            return actionFacts.automaticClear
        case .workspaceFailure, .nonactionable, .duplicateDestination, .noDestination,
             .crashHold, .scheduleTransfer, .intent, .question, .editProposal,
             .heldDraft, .closedSessionDraft,
             .composerRestoreFailed, .unsavedPredecessor, .composerWriteFailed, .ownerlessDraft,
             .composerPreparationFailed, .questionSaveFailed,
             .scheduleNeedsConfirmation, .scheduleIndexUnavailable,
             .survivingRuntime, .runtimeOwnershipUnknown:
            return nil
        }
    }

    /// Hidden from the Needs Attention sections unless "Show dismissed and cleared" is on.
    package var isHidden: Bool {
        isDismissed || automaticClear != nil
    }
}

/// What the current record says about explicit recovery actions on one card.
package struct AgentRecoveryCatalogActionFacts: Equatable {
    /// An action already resolved the item by sending, or by proving its turn finished (B F3b).
    package var resolvedByAction = false
    /// A recovery action on the card is unfinished: reserved without a recorded outcome (and not
    /// replaced by a later choice: "Resume was interrupted; status unknown" until the user decides),
    /// or holding its session right now (from before its reservation until after its outcome write).
    package var hasUnfinishedAction = false
    /// Typed text chosen on the card was never sent and exists only on its action
    /// (`AgentRecoveryRecord.hasUnsentContinuation(for:)`): the latest action with non-empty text
    /// ended without sending or proving completion (or was replaced before it had an outcome).
    /// Cleared only by a saved intent carrying that text or a later action that resolves the card;
    /// a later textless Reconcile that does not resolve it never clears it.
    package var hasUnsentContinuation = false
    /// 9-live R4b: the unsent typed text itself, from the same action `hasUnsentContinuation`
    /// selects (`AgentRecoveryRecord.unsentContinuationText(for:)`); `nil` exactly when
    /// `hasUnsentContinuation` is false. The Continue editor reopens with it.
    package var unsentContinuationText: String?
    /// Run cards only: the projection-time clearing rule that matched
    /// (`AgentRecoveryCatalogProjection.automaticClear`). Applied only while the card is
    /// informational (`AgentRecoveryCatalogItem.automaticClear`).
    package var automaticClear: AgentRecoveryCatalogAutomaticClear?
    /// The run card's attempt verifiably never delivered its input (A P1-06): its saved intent
    /// is the route, never a generic continuation.
    package var runNeverHandedOff = false
    /// The run card's attempt reset generation when recorded (a run from before a conversation
    /// clear is never continued into the cleared conversation).
    package var runTranscriptResetGeneration: UInt64?
    /// Step 5b: delegated sessions `agent_run.start` linked under the run card's attempt, in commit
    /// order. Discovery only: a link is not proof the child started, and nothing is replayed.
    package var delegatedChildLinks: [AgentRecoveryDelegatedChildLink] = []
    /// O46, saved-input cards only: the record's crash-hold acknowledgement settled this message
    /// to `deliveryUnknown` because every process of its run exited
    /// (`AgentRecoveryRecord.isSettledByCrashHoldExitProof`). The card is informational; it is
    /// never resent.
    package var settledByExitProof = false

    package init(
        resolvedByAction: Bool = false,
        hasUnfinishedAction: Bool = false,
        hasUnsentContinuation: Bool = false,
        unsentContinuationText: String? = nil,
        automaticClear: AgentRecoveryCatalogAutomaticClear? = nil,
        runNeverHandedOff: Bool = false,
        runTranscriptResetGeneration: UInt64? = nil,
        delegatedChildLinks: [AgentRecoveryDelegatedChildLink] = [],
        settledByExitProof: Bool = false
    ) {
        self.settledByExitProof = settledByExitProof
        self.resolvedByAction = resolvedByAction
        self.hasUnfinishedAction = hasUnfinishedAction
        self.hasUnsentContinuation = hasUnsentContinuation
        self.unsentContinuationText = unsentContinuationText
        self.automaticClear = automaticClear
        self.runNeverHandedOff = runNeverHandedOff
        self.runTranscriptResetGeneration = runTranscriptResetGeneration
        self.delegatedChildLinks = delegatedChildLinks
    }
}

/// One immutable catalog snapshot. Items are in stable display order.
package struct AgentRecoveryCatalog: Equatable {
    package let generation: UInt64
    package let items: [AgentRecoveryCatalogItem]
    /// Sessions whose sending stays paused, with why (shown even when their cards are dismissed).
    package let blockers: [UUID: AgentRecoveryCatalogBlocker]

    package init(generation: UInt64, items: [AgentRecoveryCatalogItem], blockers: [UUID: AgentRecoveryCatalogBlocker]) {
        self.generation = generation
        self.items = items
        self.blockers = blockers
    }

    package static let empty = AgentRecoveryCatalog(generation: 0, items: [], blockers: [:])

    package func item(id: String) -> AgentRecoveryCatalogItem? {
        items.first { $0.id == id }
    }

    /// The exact items of the Needs Attention sheet, in snapshot order. `includeDismissed` also
    /// includes automatically cleared run notes ("Show dismissed and cleared").
    package func needsAttentionItems(includeDismissed: Bool) -> [AgentRecoveryCatalogItem] {
        includeDismissed ? items : items.filter { !$0.isHidden }
    }

    /// Needs-action, not-dismissed items (the sidebar's Needs Attention badge).
    package var openNeedsActionCount: Int {
        items.count { $0.isOpenNeedsAction }
    }

    /// The banner's exact session filter: the session's items, a tab-keyed item of its tab that has
    /// no session yet, and scope-level items of its workspace (a workspace that could not be
    /// checked). Dismissed items are excluded.
    package func bannerItems(sessionID: UUID?, workspaceID: UUID?, tabID: UUID? = nil) -> [AgentRecoveryCatalogItem] {
        items.filter { item in
            guard !item.isDismissed else { return false }
            if let sessionID, item.sessionID == sessionID { return true }
            if item.sessionID == nil, let tabID, item.composeTabID == tabID { return true }
            return item.sessionID == nil && item.composeTabID == nil && item.workspaceID != nil && item.workspaceID == workspaceID
        }
    }
}

// MARK: - Projection

/// Builds the catalog from the coordinator's current authoritative state: tabs' failed composer
/// preparations, startup results overlaid by committed records, crash holds and restrictions, this
/// launch's held and ownerless input, live lanes' composer state, and schedules awaiting
/// confirmation (scheduler and index summaries, merged by the coordinator). Linear in the
/// inspected records and items (maps are built once), plus the stable display order.
@MainActor
package enum AgentRecoveryCatalogProjection {
    static func build(
        coordinator: AgentRecoveryCoordinator,
        schedules: [AgentScheduledSendConfirmationSummary],
        unavailableScheduleIndexes: [AgentRecoveryWorkspaceDestination] = [],
        generation: UInt64
    ) -> AgentRecoveryCatalog {
        guard coordinator.startupState == .ready else {
            return AgentRecoveryCatalog(generation: generation, items: [], blockers: [:])
        }
        var builder = Builder(coordinator: coordinator)
        // 9-live R7: app-scoped runtime items (a live process, or unknown process ownership) come
        // first, ahead of every per-session item. Their IDs don't depend on the order.
        builder.addRuntimeRestrictions()
        builder.addComposerPreparations()
        builder.addStartupResults()
        builder.addHeldInputOfUnlistedSessions()
        builder.addLaneComposerState()
        builder.addOwnerlessInput()
        builder.addSchedules(schedules)
        builder.addUnavailableScheduleIndexes(unavailableScheduleIndexes)
        builder.removeDeletedSessions()
        return AgentRecoveryCatalog(generation: generation, items: builder.items, blockers: builder.blockers)
    }

    /// O34-3: exhaustive per-payload classification (a new payload must be classified to compile).
    /// Run cards are notes (the transcript is saved and the crash hold is its own item) unless a
    /// recovery action on them is unfinished or their latest typed continuation was not sent; a
    /// saved message settled by a crash-hold confirmation (O46) is a note unless an action on it is
    /// unfinished; everything else asks the user for a decision.
    package nonisolated static func attention(
        for payload: AgentRecoveryCatalogPayload,
        facts: AgentRecoveryCatalogActionFacts
    ) -> AgentRecoveryCatalogAttention {
        switch payload {
        case .turn, .outcomeTurn, .recoveryOnlyRun:
            facts.hasUnfinishedAction || facts.hasUnsentContinuation ? .needsAction : .informational
        case .intent:
            facts.settledByExitProof && !facts.hasUnfinishedAction ? .informational : .needsAction
        case .workspaceFailure, .nonactionable, .duplicateDestination, .noDestination,
             .crashHold, .scheduleTransfer, .question, .editProposal,
             .heldDraft, .closedSessionDraft,
             .composerRestoreFailed, .unsavedPredecessor, .composerWriteFailed, .ownerlessDraft,
             .composerPreparationFailed, .questionSaveFailed,
             .scheduleNeedsConfirmation, .scheduleIndexUnavailable,
             .survivingRuntime, .runtimeOwnershipUnknown:
            .needsAction
        }
    }

    /// Step 8-attention-2: projection-only clearing of a run card (no writes; the caller applies it
    /// only while the card is informational). First match wins:
    /// 1. a recovery action resolved the card (`resolvedByAction`) → `.resolved`;
    /// 2. the run's reset generation is older than the session's current one → `.conversationCleared`;
    /// 3. a later attempt of the same reset generation follows it in `runAttempts` →
    ///    `.sessionContinued` (a later attempt that verifiably never delivered its input continues
    ///    nothing and is ignored; review B F4).
    /// A run with delegated-child links is never cleared: its card is their only discovery pointer
    /// (review B F4).
    /// Relies on `runAttempts` being in first-record order: `AgentRecoveryStore.ensureRunAttempt` is
    /// its only producer, appends a new attempt at the end, updates existing ones in place, and
    /// nothing reorders or removes them (the codec keeps array order). A card without a run attempt
    /// (a legacy turn keyed by its turn ID, or an attempt missing from the record) is cleared only by
    /// rule 1. No age-based expiry.
    package nonisolated static func automaticClear(
        resolvedByAction: Bool,
        runAttemptID: UUID?,
        runAttempts: [AgentRecoveryRunAttempt],
        currentGeneration: UInt64,
        hasDelegatedChildren: Bool = false,
        isVerifiedNeverHandedOff: (UUID) -> Bool = { _ in false }
    ) -> AgentRecoveryCatalogAutomaticClear? {
        if hasDelegatedChildren { return nil }
        if resolvedByAction { return .resolved }
        guard let runAttemptID, let index = runAttempts.firstIndex(where: { $0.runAttemptID == runAttemptID }) else { return nil }
        let generation = runAttempts[index].transcriptResetGeneration
        if generation < currentGeneration { return .conversationCleared }
        if runAttempts[(index + 1)...].contains(where: {
            $0.transcriptResetGeneration == generation && !isVerifiedNeverHandedOff($0.runAttemptID)
        }) {
            return .sessionContinued
        }
        return nil
    }

    /// Row identity of a surviving runtime.
    package static func runtimeItemID(runtimeID: UUID) -> String {
        "runtime-\(runtimeID.uuidString)"
    }

    /// Row identity of the global runtime-ownership warning.
    package static let runtimeOwnershipUnknownItemID = "runtime-ownership-unknown"

    /// Row identity of a tab's failed composer preparation.
    package static func preparationItemID(tabID: UUID) -> String {
        "draft-prep-\(tabID.uuidString)"
    }

    /// Row identity of a session's live-question save failure.
    package static func questionSaveFailureItemID(sessionID: UUID) -> String {
        "savefail-question-\(sessionID.uuidString)"
    }

    /// Freshness of a turn's or run's classified outcome (and interruption cause).
    static func runFreshness(status: AgentRecoveryInterruptedTurn.Status, reason: AgentTranscriptTurnInterruption.Reason?) -> AgentRecoveryCardFreshness {
        AgentRecoveryCardFreshness("\(status)|\(reason?.rawValue ?? "-")")
    }

    /// Freshness of held input: its delivery classification and typed hold/blocker state.
    static func intentFreshness(_ intent: AgentRecoveryIntent, held: Bool) -> AgentRecoveryCardFreshness {
        AgentRecoveryCardFreshness("\(intent.deliveryState.rawValue)|held:\(held)|stale:\(intent.staleTargetMarkedAt != nil)")
    }

    /// A question card is fresh per interaction: partial-answer edits never unhide it.
    static let questionFreshness = AgentRecoveryCardFreshness("asked")
    /// A draft card is fresh per composer revision.
    static let draftFreshness = AgentRecoveryCardFreshness("held")

    static func scheduleFreshness(_ summary: AgentScheduledSendConfirmationSummary) -> AgentRecoveryCardFreshness {
        AgentRecoveryCardFreshness(
            "\(summary.attemptID?.uuidString ?? "-")|\(summary.reason?.rawValue ?? "-")|\(Int64((summary.notBefore.timeIntervalSince1970 * 1000).rounded()))"
        )
    }

    static func crashHoldFreshness(_ hold: AgentRecoveryCrashHold) -> AgentRecoveryCardFreshness {
        func ids(_ set: Set<UUID>) -> String {
            set.map(\.uuidString).sorted().joined(separator: ",")
        }
        return AgentRecoveryCardFreshness(
            "r:\(ids(hold.uncertainRunAttemptIDs))|i:\(ids(hold.uncertainIntentIDs))|t:\(ids(hold.uncertainTranscriptTurnIDs))"
        )
    }

    @MainActor
    private struct Builder {
        let coordinator: AgentRecoveryCoordinator
        let currentInstanceID: UUID
        var items: [AgentRecoveryCatalogItem] = []
        var blockers: [UUID: AgentRecoveryCatalogBlocker] = [:]
        var listedSessionIDs: Set<UUID> = []
        /// Incarnation and current record per session (startup snapshot overlaid by later commits).
        var bindings: [UUID: AgentRecoveryLifecycleBinding] = [:]
        var records: [UUID: AgentRecoveryRecord] = [:]

        init(coordinator: AgentRecoveryCoordinator) {
            self.coordinator = coordinator
            currentInstanceID = coordinator.store.appInstanceID
        }

        // swiftlint:disable:next function_parameter_count
        mutating func append(
            _ id: String,
            kind: AgentRecoveryCatalogItemKind,
            sessionID: UUID?,
            workspaceID: UUID?,
            sessionName: String?,
            composeTabID: UUID?,
            payload: AgentRecoveryCatalogPayload,
            card: (key: AgentRecoveryCardKey, freshness: AgentRecoveryCardFreshness)? = nil
        ) {
            let record = sessionID.flatMap { records[$0] }
            let acknowledgement = card.map { card in
                AgentRecoveryCatalogAcknowledgement(
                    key: card.key,
                    freshness: card.freshness,
                    isAcknowledged: record?.isCardAcknowledged(card.key, freshness: card.freshness) ?? false
                )
            }
            var facts = AgentRecoveryCatalogActionFacts()
            if let sessionID, let key = card?.key {
                facts.hasUnfinishedAction = coordinator.hasRecoveryActionHold(sessionID: sessionID, itemKey: key)
            }
            if let record, let key = card?.key {
                facts.resolvedByAction = record.resolvingAction(for: key) != nil
                facts.hasUnfinishedAction = facts.hasUnfinishedAction || record.unresolvedAction(for: key) != nil
                facts.unsentContinuationText = record.unsentContinuationText(for: key)
                facts.hasUnsentContinuation = facts.unsentContinuationText != nil
                if key.kindRaw == AgentRecoveryCardKey.Kind.savedInput.rawValue, let intentID = UUID(uuidString: key.entityID) {
                    facts.settledByExitProof = record.isSettledByCrashHoldExitProof(intentID: intentID)
                }
                if key.kindRaw == AgentRecoveryCardKey.Kind.run.rawValue {
                    let runAttemptID = UUID(uuidString: key.entityID)
                    facts.runNeverHandedOff = record.isVerifiedNeverHandedOff(runAttemptID: runAttemptID)
                    facts.runTranscriptResetGeneration = runAttemptID.flatMap { record.runAttempt(id: $0) }?.transcriptResetGeneration
                    facts.delegatedChildLinks = runAttemptID.map { record.delegatedChildLinks(parentRunAttemptID: $0) } ?? []
                    // The session's current generation, as its held input is judged (`addIntents`).
                    let currentGeneration = sessionID.flatMap { coordinator.lane(for: $0)?.binding.transcriptResetGeneration }
                        ?? max(sessionID.flatMap { bindings[$0]?.transcriptResetGeneration } ?? 0, record.transcriptResetGeneration)
                    facts.automaticClear = AgentRecoveryCatalogProjection.automaticClear(
                        resolvedByAction: facts.resolvedByAction,
                        runAttemptID: runAttemptID,
                        runAttempts: record.runAttempts,
                        currentGeneration: currentGeneration,
                        hasDelegatedChildren: !facts.delegatedChildLinks.isEmpty,
                        isVerifiedNeverHandedOff: { record.isVerifiedNeverHandedOff(runAttemptID: $0) }
                    )
                }
            }
            items.append(AgentRecoveryCatalogItem(
                id: id,
                kind: kind,
                sessionID: sessionID,
                workspaceID: workspaceID,
                sessionName: sessionName,
                composeTabID: composeTabID,
                payload: payload,
                acknowledgement: acknowledgement,
                actionFacts: facts
            ))
        }

        /// F8: a deleted session's items go with it. Startup rows come from the launch's
        /// reconciliation snapshot (never re-run), so a live absent record alone would leave its
        /// crash hold, run cards and status rows listed until the next launch. Surviving-process
        /// items always stay, whatever session they name: deleting a session neither stops its
        /// process nor lifts its runtime restriction (the registry's, which deletion never touches;
        /// the blocker cleared here is the session's crash hold), and the item is the only place
        /// to act on it.
        mutating func removeDeletedSessions() {
            let deleted = coordinator.deletedSessionIDs
            guard !deleted.isEmpty else { return }
            items.removeAll { item in
                item.kind != .survivingProcess && (item.sessionID.map(deleted.contains) ?? false)
            }
            for sessionID in deleted {
                blockers[sessionID] = nil
            }
        }

        func currentRecord(sessionID: UUID, startup: AgentRecoveryRecord?, incarnationID: UUID) -> AgentRecoveryRecord? {
            guard let live = coordinator.liveRecordState(for: sessionID) else { return startup }
            switch live {
            case let .supported(record):
                return record.incarnationID == incarnationID ? record : nil
            case .absent:
                return nil
            }
        }

        mutating func addStartupResults() {
            for failure in coordinator.reconciliation.workspaceFailures {
                append(
                    "workspace-\(failure.workspaceID.uuidString)",
                    kind: .statusUnknown,
                    sessionID: nil,
                    workspaceID: failure.workspaceID,
                    sessionName: nil,
                    composeTabID: nil,
                    payload: .workspaceFailure(reason: failure.reason)
                )
            }
            for resolution in coordinator.reconciliation.sessions {
                addResolution(resolution)
            }
        }

        mutating func addResolution(_ resolution: AgentSessionRecoveryResolution) {
            let sessionID = resolution.sessionID
            let key = sessionID.uuidString
            let workspaceID = resolution.workspaceID
            let name = resolution.sessionName
            let tabID = resolution.composeTabID
            let unknownPayload: AgentRecoveryCatalogPayload? = switch resolution.classification {
            case .idle, .tombstoned, .actionable: nil
            case let .nonactionable(reason): .nonactionable(reason)
            case .duplicateDestination: .duplicateDestination
            case .noDestination: .noDestination
            }
            if let unknownPayload {
                append("status-\(key)", kind: .statusUnknown, sessionID: sessionID, workspaceID: workspaceID, sessionName: name, composeTabID: tabID, payload: unknownPayload)
                return
            }
            guard case .actionable = resolution.classification, let binding = resolution.binding else { return }
            bindings[sessionID] = binding
            listedSessionIDs.insert(sessionID)
            let record = currentRecord(sessionID: sessionID, startup: resolution.record?.record, incarnationID: binding.incarnationID)
            if let record { records[sessionID] = record }

            if let hold = coordinator.crashHold(for: sessionID), coordinator.blockingCrashHold(for: binding) != nil {
                blockers[sessionID] = .crashHold
                append(
                    "crash-\(key)",
                    kind: .crashHold,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    sessionName: name,
                    composeTabID: tabID,
                    payload: .crashHold(hold),
                    card: (
                        AgentRecoveryCardKey(kind: .crashHold, incarnationID: hold.incarnationID, transcriptResetGeneration: hold.transcriptResetGeneration, entityID: "crashHold"),
                        AgentRecoveryCatalogProjection.crashHoldFreshness(hold)
                    )
                )
            }

            if case let .held(message) = resolution.scheduleTransfer,
               coordinator.restrictions.sessionRestriction(sessionID) != nil
            {
                append("transfer-\(key)", kind: .heldScheduleTransfer, sessionID: sessionID, workspaceID: workspaceID, sessionName: name, composeTabID: tabID, payload: .scheduleTransfer(message: message))
            }

            /// Startup rows are re-classified from the current record's run evidence (a later terminal
            /// commit or shutdown of the same attempt updates the row; freshness unhides it).
            func currentAttempt(_ attemptID: UUID?) -> AgentRecoveryRunAttempt? {
                guard let attemptID else { return nil }
                return record?.runAttempts.first { $0.runAttemptID == attemptID }
            }
            var representedRuns = Set<UUID>()
            for startupTurn in resolution.interruptedTurns {
                let turn = currentAttempt(startupTurn.interruption.runAttemptID).map {
                    AgentRecoveryInterruptedTurn(
                        turnID: startupTurn.turnID,
                        interruption: startupTurn.interruption,
                        status: .classify(attempt: $0),
                        isLastTurn: startupTurn.isLastTurn
                    )
                } ?? startupTurn
                // A turn joined to a run attempt is identified by that attempt (deduplicated with a
                // recovery-only representation of the same run); a legacy turn by its own ID.
                let entityID = turn.interruption.runAttemptID?.uuidString ?? turn.turnID.uuidString
                if let attemptID = turn.interruption.runAttemptID { representedRuns.insert(attemptID) }
                append(
                    "turn-\(key)-\(turn.turnID.uuidString)",
                    kind: turn.status.isInterruption ? .interruptedTurn : .terminalOutcome,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    sessionName: name,
                    composeTabID: tabID,
                    payload: .turn(turn),
                    card: (
                        AgentRecoveryCardKey(kind: .run, incarnationID: binding.incarnationID, transcriptResetGeneration: nil, entityID: entityID),
                        AgentRecoveryCatalogProjection.runFreshness(status: turn.status, reason: turn.status.isInterruption ? turn.interruption.reason : nil)
                    )
                )
            }
            for startupOutcome in resolution.outcomeTurns where !representedRuns.contains(startupOutcome.runAttempt.runAttemptID) {
                let outcome = AgentRecoveryOutcomeTurn(
                    turnID: startupOutcome.turnID,
                    runAttempt: currentAttempt(startupOutcome.runAttempt.runAttemptID) ?? startupOutcome.runAttempt
                )
                representedRuns.insert(outcome.runAttempt.runAttemptID)
                append(
                    "turn-\(key)-\(outcome.turnID.uuidString)",
                    kind: outcome.status.isInterruption ? .interruptedTurn : .terminalOutcome,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    sessionName: name,
                    composeTabID: tabID,
                    payload: .outcomeTurn(outcome),
                    card: (
                        AgentRecoveryCardKey(kind: .run, incarnationID: binding.incarnationID, transcriptResetGeneration: nil, entityID: outcome.runAttempt.runAttemptID.uuidString),
                        AgentRecoveryCatalogProjection.runFreshness(status: outcome.status, reason: nil)
                    )
                )
            }
            for startupAttempt in resolution.recoveryOnlyRunAttempts where !representedRuns.contains(startupAttempt.runAttemptID) {
                let attempt = currentAttempt(startupAttempt.runAttemptID) ?? startupAttempt
                representedRuns.insert(attempt.runAttemptID)
                let status = AgentRecoveryInterruptedTurn.Status.classify(terminal: attempt.terminal, shutdown: attempt.shutdown)
                append(
                    "run-\(key)-\(attempt.runAttemptID.uuidString)",
                    kind: attempt.terminal == nil ? .interruptedTurn : .terminalOutcome,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    sessionName: name,
                    composeTabID: tabID,
                    payload: .recoveryOnlyRun(attempt),
                    card: (
                        AgentRecoveryCardKey(kind: .run, incarnationID: binding.incarnationID, transcriptResetGeneration: nil, entityID: attempt.runAttemptID.uuidString),
                        AgentRecoveryCatalogProjection.runFreshness(status: status, reason: nil)
                    )
                )
            }

            guard let record else { return }
            addLiveRunInterruptions(
                sessionID: sessionID,
                workspaceID: workspaceID,
                name: name,
                tabID: tabID,
                record: record,
                represented: representedRuns
            )
            addIntents(
                sessionID: sessionID,
                workspaceID: workspaceID,
                name: name,
                tabID: tabID,
                record: record,
                currentGeneration: coordinator.lane(for: sessionID)?.binding.transcriptResetGeneration
                    ?? max(binding.transcriptResetGeneration, record.transcriptResetGeneration),
                isRemote: resolution.remoteHostID != nil
            )
            addQuestions(sessionID: sessionID, workspaceID: workspaceID, name: name, tabID: tabID, record: record)
            addEditProposals(sessionID: sessionID, workspaceID: workspaceID, name: name, tabID: tabID, record: record)
            addDurableComposer(
                sessionID: sessionID,
                workspaceID: workspaceID,
                name: name,
                tabID: tabID,
                record: record,
                currentGeneration: max(binding.transcriptResetGeneration, record.transcriptResetGeneration)
            )
        }

        /// Review A F05: a saved, non-empty composer of a session no live lane represents (closed,
        /// or its lane released) is listed from the current record, by composer revision (the same
        /// identity and card key a live lane's held draft uses), so preserved draft text stays
        /// discoverable. A live lane's composer state represents it instead.
        mutating func addDurableComposer(
            sessionID: UUID,
            workspaceID: UUID?,
            name: String?,
            tabID: UUID?,
            record: AgentRecoveryRecord,
            currentGeneration: UInt64
        ) {
            guard let snapshot = record.composer, !snapshot.content.isEmpty else { return }
            if let lane = coordinator.lane(for: sessionID), !lane.isRetired { return }
            append(
                AgentRecoveryCatalogProjection.heldDraftItemID(sessionID: sessionID, revision: snapshot.revision),
                kind: .savedDraft,
                sessionID: sessionID,
                workspaceID: workspaceID,
                sessionName: name,
                composeTabID: tabID,
                payload: .closedSessionDraft(snapshot, fromClearedConversation: snapshot.transcriptResetGeneration != currentGeneration),
                card: (
                    AgentRecoveryCardKey(kind: .savedDraft, incarnationID: record.incarnationID, transcriptResetGeneration: snapshot.transcriptResetGeneration, entityID: String(describing: snapshot.revision)),
                    AgentRecoveryCatalogProjection.draftFreshness
                )
            )
        }

        /// This launch's runs whose terminal commit recorded an interruption cause (provider process
        /// loss, window close, app quit) after startup, from the current committed record: listed
        /// by run attempt, joined to the latest transcript turn the attempt dispatched into (its own
        /// turn, or a later steer: the turn its terminal closed; review B F1).
        /// An active run has no terminal evidence and is never listed; an attempt a startup row
        /// already represents is skipped. Earlier launches' runs are covered by startup reconciliation.
        mutating func addLiveRunInterruptions(
            sessionID: UUID,
            workspaceID: UUID?,
            name: String?,
            tabID: UUID?,
            record: AgentRecoveryRecord,
            represented: Set<UUID>
        ) {
            let key = sessionID.uuidString
            let join = AgentRecoveryRunTurnJoin(runAttempts: record.runAttempts, intentAttempts: record.attempts)
            for attempt in record.runAttempts where attempt.appInstanceID == currentInstanceID && !represented.contains(attempt.runAttemptID) {
                guard let terminal = attempt.terminal, let reason = terminal.cause?.interruptionReason else { continue }
                let status = AgentRecoveryInterruptedTurn.Status.classify(attempt: attempt)
                let card = (
                    key: AgentRecoveryCardKey(kind: .run, incarnationID: record.incarnationID, transcriptResetGeneration: nil, entityID: attempt.runAttemptID.uuidString),
                    freshness: AgentRecoveryCatalogProjection.runFreshness(status: status, reason: status.isInterruption ? reason : nil)
                )
                if let turnID = join.latestTurnID(of: attempt) {
                    let turn = AgentRecoveryInterruptedTurn(
                        turnID: turnID,
                        interruption: AgentTranscriptTurnInterruption(
                            reason: reason,
                            observedAt: terminal.recordedAt.date,
                            lastConfirmedActivityAt: attempt.shutdown?.lastConfirmedActivityAt?.date,
                            runAttemptID: attempt.runAttemptID
                        ),
                        status: status,
                        isLastTurn: false
                    )
                    append(
                        "turn-\(key)-\(turnID.uuidString)",
                        kind: status.isInterruption ? .interruptedTurn : .terminalOutcome,
                        sessionID: sessionID,
                        workspaceID: workspaceID,
                        sessionName: name,
                        composeTabID: tabID,
                        payload: .turn(turn),
                        card: card
                    )
                } else {
                    append(
                        "run-\(key)-\(attempt.runAttemptID.uuidString)",
                        kind: status.isInterruption ? .interruptedTurn : .terminalOutcome,
                        sessionID: sessionID,
                        workspaceID: workspaceID,
                        sessionName: name,
                        composeTabID: tabID,
                        payload: .recoveryOnlyRun(attempt),
                        card: card
                    )
                }
            }
        }

        /// Held input of one session from its current record. Earlier-launch intents that need a
        /// decision are listed; this launch's intents when held (their projection was removed),
        /// stale-marked, or uncertain after their run ended. Any other one is still projected by a
        /// live queue or an active run.
        mutating func addIntents(
            sessionID: UUID,
            workspaceID: UUID?,
            name: String?,
            tabID: UUID?,
            record: AgentRecoveryRecord,
            currentGeneration: UInt64,
            isRemote: Bool
        ) {
            let key = sessionID.uuidString
            let heldReasons = coordinator.heldIntents(sessionID: sessionID, incarnationID: record.incarnationID)
            for intent in record.intents where AgentRecoveryCatalogProjection.needsDecision(intent) {
                let isEarlierLaunch = intent.appInstanceID != currentInstanceID
                let heldReason = heldReasons[intent.intentID]
                    ?? (isEarlierLaunch ? nil : AgentRecoveryCoordinator.uncertainInputHoldReason(intent, in: record))
                guard isEarlierLaunch || heldReason != nil || intent.staleTargetMarkedAt != nil else { continue }
                append(
                    "intent-\(key)-\(intent.intentID.uuidString)",
                    kind: .savedInput,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    sessionName: name,
                    composeTabID: tabID,
                    payload: .intent(intent, AgentRecoveryCatalogIntentContext(
                        isEarlierLaunch: isEarlierLaunch,
                        heldReason: heldReason,
                        sameGeneration: intent.transcriptResetGeneration == currentGeneration,
                        isRemote: isRemote,
                        runsEndedWithRecordedEvidence: record.intentRunsEndedWithRecordedEvidence(intentID: intent.intentID)
                    )),
                    card: (
                        AgentRecoveryCardKey(kind: .savedInput, incarnationID: record.incarnationID, transcriptResetGeneration: intent.transcriptResetGeneration, entityID: intent.intentID.uuidString),
                        AgentRecoveryCatalogProjection.intentFreshness(intent, held: heldReason != nil)
                    )
                )
            }
        }

        /// Saved questions whose request has ended: every earlier launch's, and this launch's whose
        /// owning lane no longer holds its live request (closed window or tab, expired transport).
        /// A live question stays in its live card only.
        mutating func addQuestions(sessionID: UUID, workspaceID: UUID?, name: String?, tabID: UUID?, record: AgentRecoveryRecord) {
            let live = coordinator.lane(for: sessionID)?.questionPersistence.liveInteractionIDs ?? []
            for snapshot in record.questions where !live.contains(snapshot.interactionID) {
                append(
                    "question-\(sessionID.uuidString)-\(snapshot.interactionID.uuidString)",
                    kind: .unansweredQuestion,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    sessionName: name,
                    composeTabID: tabID,
                    payload: .question(snapshot, isCurrentLaunch: snapshot.appInstanceID == currentInstanceID),
                    card: (
                        AgentRecoveryCardKey(kind: .question, incarnationID: record.incarnationID, transcriptResetGeneration: snapshot.transcriptResetGeneration, entityID: snapshot.interactionID.uuidString),
                        AgentRecoveryCatalogProjection.questionFreshness
                    )
                )
            }
        }

        /// Step 5a: stored edit proposals whose live review has ended: every earlier launch's, and
        /// this launch's no live lane still reviews or writes. Not dismissible (Discard withdraws it).
        mutating func addEditProposals(sessionID: UUID, workspaceID: UUID?, name: String?, tabID: UUID?, record: AgentRecoveryRecord) {
            let live = coordinator.lane(for: sessionID)?.liveEditProposalIDs ?? []
            for proposal in record.editProposals where !live.contains(proposal.reviewID) {
                append(
                    AgentRecoveryCatalogProjection.editProposalItemID(sessionID: sessionID, reviewID: proposal.reviewID),
                    kind: .pendingEditReview,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    sessionName: name,
                    composeTabID: tabID,
                    payload: .editProposal(proposal, isCurrentLaunch: proposal.appInstanceID == currentInstanceID)
                )
            }
        }

        /// This launch's held input and saved questions of sessions absent from the startup results
        /// (created this launch, or first written since).
        mutating func addHeldInputOfUnlistedSessions() {
            var sessionIDs = Set(coordinator.heldIntentSessions.keys)
            for lane in coordinator.liveLanes where !lane.isRetired {
                sessionIDs.insert(lane.sessionID)
            }
            for sessionID in coordinator.liveRecordSessionIDs {
                sessionIDs.insert(sessionID)
            }
            for sessionID in sessionIDs.sorted(by: { $0.uuidString < $1.uuidString }) where !listedSessionIDs.contains(sessionID) {
                guard case let .supported(record)? = coordinator.liveRecordState(for: sessionID) else { continue }
                let lane = coordinator.lane(for: sessionID)
                let held = coordinator.heldIntentSessions[sessionID]
                if let held, held.incarnationID != record.incarnationID { continue }
                if let lane, lane.binding.incarnationID != record.incarnationID { continue }
                records[sessionID] = record
                bindings[sessionID] = lane?.binding
                let workspaceID = held?.workspaceID ?? lane?.persistenceState.stamp.workspaceID
                    ?? coordinator.knownWorkspaceID(for: sessionID)
                // Review R1 (A P2): a closed session's items keep its compose tab for Open.
                let tabID = coordinator.knownComposeTabID(for: sessionID)
                addLiveRunInterruptions(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    name: nil,
                    tabID: tabID,
                    record: record,
                    represented: []
                )
                addIntents(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    name: nil,
                    tabID: tabID,
                    record: record,
                    currentGeneration: lane?.binding.transcriptResetGeneration ?? record.transcriptResetGeneration,
                    isRemote: false
                )
                addQuestions(sessionID: sessionID, workspaceID: workspaceID, name: nil, tabID: tabID, record: record)
                addEditProposals(sessionID: sessionID, workspaceID: workspaceID, name: nil, tabID: tabID, record: record)
                addDurableComposer(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    name: nil,
                    tabID: tabID,
                    record: record,
                    currentGeneration: lane?.binding.transcriptResetGeneration ?? record.transcriptResetGeneration
                )
            }
        }

        /// Live lanes' composer recovery state (held or unsaved drafts, restore and write failures).
        mutating func addLaneComposerState() {
            for lane in coordinator.liveLanes.sorted(by: { $0.sessionID.uuidString < $1.sessionID.uuidString }) where !lane.isRetired {
                let sessionID = lane.sessionID
                let key = sessionID.uuidString
                let workspaceID = lane.persistenceState.stamp.workspaceID
                let name = coordinator.reconciliation.resolution(for: sessionID)?.sessionName
                if records[sessionID] == nil, case let .supported(record)? = coordinator.liveRecordState(for: sessionID),
                   record.incarnationID == lane.binding.incarnationID
                {
                    records[sessionID] = record
                }
                switch lane.composerState {
                case let .held(snapshot):
                    append(
                        AgentRecoveryCatalogProjection.heldDraftItemID(sessionID: sessionID, revision: snapshot.revision),
                        kind: .savedDraft,
                        sessionID: sessionID,
                        workspaceID: workspaceID,
                        sessionName: name,
                        composeTabID: nil,
                        payload: .heldDraft(snapshot),
                        card: (
                            AgentRecoveryCardKey(kind: .savedDraft, incarnationID: lane.binding.incarnationID, transcriptResetGeneration: snapshot.transcriptResetGeneration, entityID: String(describing: snapshot.revision)),
                            AgentRecoveryCatalogProjection.draftFreshness
                        )
                    )
                case let .restoreFailed(failure):
                    append("draft-restorefail-\(key)", kind: .saveFailure, sessionID: sessionID, workspaceID: workspaceID, sessionName: name, composeTabID: nil, payload: .composerRestoreFailed(failure))
                case .unrestored, .restoring, .ready:
                    break
                }
                if let entry = lane.unsavedPredecessorInputs.first {
                    append(
                        "draft-unsaved-\(key)-\(AgentRecoveryCatalogProjection.fingerprint(entry))",
                        kind: .saveFailure,
                        sessionID: sessionID,
                        workspaceID: workspaceID,
                        sessionName: name,
                        composeTabID: nil,
                        payload: .unsavedPredecessor(entry, count: lane.unsavedPredecessorInputs.count)
                    )
                }
                if let failure = lane.composer.lastWriteFailure {
                    // A held composer blocks writes until it is resolved; its own item presents it.
                    if case .store(.heldComposerUnresolved) = failure {} else {
                        append("draft-savefail-\(key)", kind: .saveFailure, sessionID: sessionID, workspaceID: workspaceID, sessionName: name, composeTabID: nil, payload: .composerWriteFailed(failure))
                    }
                }
                let questions = lane.questionPersistence
                if questions.lastWriteFailure != nil || !questions.unsentAnswerIDs.isEmpty {
                    append(
                        AgentRecoveryCatalogProjection.questionSaveFailureItemID(sessionID: sessionID),
                        kind: .saveFailure,
                        sessionID: sessionID,
                        workspaceID: workspaceID,
                        sessionName: name,
                        composeTabID: nil,
                        payload: .questionSaveFailed(questions.lastWriteFailure, unsentAnswer: !questions.unsentAnswerIDs.isEmpty)
                    )
                }
            }
        }

        /// Unsaved input of a released lane whose owner went away (no lane inherited it yet).
        mutating func addOwnerlessInput() {
            for (sessionID, ownerless) in coordinator.ownerlessUnsavedInputs.sorted(by: { $0.key.uuidString < $1.key.uuidString })
                where coordinator.lane(for: sessionID) == nil
            {
                guard let entry = ownerless.inputs.first else { continue }
                append(
                    "draft-ownerless-\(sessionID.uuidString)-\(AgentRecoveryCatalogProjection.fingerprint(entry))",
                    kind: .saveFailure,
                    sessionID: sessionID,
                    workspaceID: ownerless.workspaceID,
                    sessionName: coordinator.reconciliation.resolution(for: sessionID)?.sessionName,
                    composeTabID: coordinator.reconciliation.resolution(for: sessionID)?.composeTabID,
                    payload: .ownerlessDraft(entry)
                )
            }
        }

        /// A tab's composer input that could not be prepared for saving (runtime only; its item
        /// clears when a retry, hand-off, or discard clears the obligation).
        mutating func addComposerPreparations() {
            let failed = coordinator.failedComposerPreparations.compactMap { entry -> (AgentTabSession, AgentRecoveryComposerPreparationFailure)? in
                (entry.owner as? AgentTabSession).map { ($0, entry.failure) }
            }
            for (owner, failure) in failed.sorted(by: { $0.0.tabID.uuidString < $1.0.tabID.uuidString }) {
                let sessionID = owner.activeAgentSessionID
                append(
                    AgentRecoveryCatalogProjection.preparationItemID(tabID: owner.tabID),
                    kind: .saveFailure,
                    sessionID: sessionID,
                    workspaceID: nil,
                    sessionName: sessionID.flatMap { coordinator.reconciliation.resolution(for: $0)?.sessionName },
                    composeTabID: owner.tabID,
                    payload: .composerPreparationFailed(failure)
                )
            }
        }

        /// Ordinary schedules awaiting explicit confirmation, one item per schedule identity (the
        /// coordinator already merged its sources and left out a schedule whose exact attempt is held
        /// for transfer).
        mutating func addSchedules(_ schedules: [AgentScheduledSendConfirmationSummary]) {
            for summary in schedules {
                let resolution = coordinator.reconciliation.resolution(for: summary.sessionID)
                let incarnationID = bindings[summary.sessionID]?.incarnationID
                    ?? coordinator.lane(for: summary.sessionID)?.binding.incarnationID
                    ?? resolution?.binding?.incarnationID
                append(
                    "schedule-\(summary.sessionID.uuidString)-\(summary.scheduleID.uuidString)",
                    kind: .scheduleNeedsConfirmation,
                    sessionID: summary.sessionID,
                    workspaceID: summary.workspaceID,
                    sessionName: summary.sessionName ?? resolution?.sessionName,
                    composeTabID: summary.tabID ?? resolution?.composeTabID,
                    payload: .scheduleNeedsConfirmation(summary),
                    // Review R1 (A P2): a legacy index entry without its attempt must be opened first.
                    card: summary.requiresOpenBeforeDismiss ? nil : incarnationID.map {
                        (
                            AgentRecoveryCardKey(kind: .schedule, incarnationID: $0, transcriptResetGeneration: nil, entityID: summary.scheduleID.uuidString),
                            AgentRecoveryCatalogProjection.scheduleFreshness(summary)
                        )
                    }
                )
            }
        }

        /// Spec R6: one item per restricting runtime, plus one global warning for unknown bindings.
        /// App-scoped (no session or workspace): the banner adds a session's blocking runtime itself.
        mutating func addRuntimeRestrictions() {
            guard coordinator.hasProcessRegistry else { return }
            let snapshot = coordinator.runtimeRestrictions
            if snapshot.hasGlobalUncertainty {
                append(
                    AgentRecoveryCatalogProjection.runtimeOwnershipUnknownItemID,
                    kind: .survivingProcess,
                    sessionID: nil,
                    workspaceID: nil,
                    sessionName: nil,
                    composeTabID: nil,
                    payload: .runtimeOwnershipUnknown(
                        unidentifiedRecordCount: snapshot.unidentifiedRecordCount,
                        failure: snapshot.storageFailure
                    )
                )
            }
            for restriction in snapshot.restrictions {
                append(
                    AgentRecoveryCatalogProjection.runtimeItemID(runtimeID: restriction.runtimeID),
                    kind: .survivingProcess,
                    sessionID: nil,
                    workspaceID: nil,
                    sessionName: nil,
                    composeTabID: nil,
                    payload: .survivingRuntime(restriction)
                )
            }
        }

        /// Workspaces whose schedules could not be checked from their index (not already listed
        /// as a workspace startup could not check).
        mutating func addUnavailableScheduleIndexes(_ workspaces: [AgentRecoveryWorkspaceDestination]) {
            let failed = Set(coordinator.reconciliation.workspaceFailures.map(\.workspaceID))
            for workspace in workspaces where !failed.contains(workspace.id) {
                append(
                    "schedule-index-\(workspace.id.uuidString)",
                    kind: .statusUnknown,
                    sessionID: nil,
                    workspaceID: workspace.id,
                    sessionName: nil,
                    composeTabID: nil,
                    payload: .scheduleIndexUnavailable(workspaceName: workspace.name)
                )
            }
        }
    }

    /// Store-side revalidation of a Dismiss, atomically with its write: record-backed items must
    /// still exist in the displayed record state (input with the same delivery classification and
    /// stale mark, a still-saved question). Other kinds were revalidated against the projection.
    package nonisolated static func recordStillMatches(
        key: AgentRecoveryCardKey,
        freshness: AgentRecoveryCardFreshness,
        record: AgentRecoveryRecord?
    ) -> Bool {
        switch key.kind {
        case .savedInput?:
            guard let intent = record?.intents.first(where: { $0.intentID.uuidString == key.entityID }) else { return false }
            let token = freshness.token
            return token.hasPrefix("\(intent.deliveryState.rawValue)|")
                && token.hasSuffix("|stale:\(intent.staleTargetMarkedAt != nil)")
        case .question?:
            return record?.questions.contains { $0.interactionID.uuidString == key.entityID } ?? false
        case .run?, .savedDraft?, .schedule?, .crashHold?, nil:
            return true
        }
    }

    /// Held input that may still need a user decision. Accepted and withdrawn intents need none.
    package static func needsDecision(_ intent: AgentRecoveryIntent) -> Bool {
        switch intent.deliveryState {
        case .queued, .dispatching, .deliveryUnknown, .failed:
            true
        case .providerAccepted, .withdrawn:
            false
        }
    }

    package static func editProposalItemID(sessionID: UUID, reviewID: UUID) -> String {
        "proposal-\(sessionID.uuidString)-\(reviewID.uuidString)"
    }

    package static func heldDraftItemID(sessionID: UUID, revision: AgentRecoveryComposerRevision) -> String {
        "draft-held-\(sessionID.uuidString)-\(token(String(describing: revision)))"
    }

    /// Identity of one displayed unsaved entry within this process (item IDs carry it, so an action
    /// applies only to exactly the entry that was shown).
    package static func fingerprint(_ entry: AgentRecoveryUnsavedComposerInput) -> String {
        token(String(describing: entry))
    }

    private static func token(_ value: String) -> String {
        var hasher = Hasher()
        hasher.combine(value)
        return String(UInt(bitPattern: hasher.finalize()), radix: 16)
    }
}
