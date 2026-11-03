import Foundation

package extension AgentTranscriptTurn {
    /// Whether the user item `itemID` belongs to this turn: the turn it opened, its request
    /// anchor, or a mid-turn user activity (review B R1-F1).
    func containsUserItem(_ itemID: UUID) -> Bool {
        id == itemID || request?.id == itemID || userActivityIDs.contains(itemID)
    }

    /// IDs of the user activities inside this turn's response spans.
    var userActivityIDs: [UUID] {
        responseSpans.flatMap { span in span.activities.filter { $0.itemKind == .user }.map(\.id) }
    }
}

package extension AgentTranscript {
    /// The execution turn of the user item `userItemID`: the turn whose request it is (a saved input
    /// re-sent at the execution end runs in its own destination turn, O11), else the item's own ID
    /// (the turn an ordinary user item opens, or the steering key of a mid-turn user activity).
    func executionTurnID(forUserItemID userItemID: UUID) -> UUID {
        turns.last(where: { $0.request?.id == userItemID })?.id ?? userItemID
    }
}

/// Ambiguity-aware joins between recovery run attempts and saved transcript turns (R08/F-14).
///
/// A run attempt's own transcript turn (`transcriptTurnID`) is authoritative. A process run ID is
/// only a fallback, because Claude reuses one process run across turns: it joins an attempt only
/// when exactly one attempt without its own turn carries that process run, and it joins a saved
/// turn only when no attempt already claims that turn as its own. An older turn that shares a
/// process run never stands in for a newer attempt.
package struct AgentRecoveryRunTurnJoin: Equatable {
    private let attemptsByTurnID: [UUID: [AgentRecoveryRunAttempt]]
    /// Attempts without their own turn, by process run.
    private let unkeyedAttemptsByProcessRunID: [UUID: [AgentRecoveryRunAttempt]]
    /// Review B F1: input dispatched under an already-running attempt (steering) opens its own
    /// transcript turn (the user item's ID) while the run attempt keeps its start turn. Those turns
    /// join the run attempt their dispatch recorded; a turn claimed by several run attempts is
    /// ambiguous and joins none. A run attempt's own turn always wins.
    private let steeredAttemptsByTurnID: [UUID: AgentRecoveryRunAttempt]
    /// Each run attempt's latest dispatched transcript turn (its own turn, or a later steer).
    private let latestTurnIDByRunAttemptID: [UUID: UUID]

    package init(runAttempts: [AgentRecoveryRunAttempt], intentAttempts: [AgentRecoveryAttempt] = []) {
        var byTurn: [UUID: [AgentRecoveryRunAttempt]] = [:]
        var unkeyedByRun: [UUID: [AgentRecoveryRunAttempt]] = [:]
        for attempt in runAttempts {
            if let turnID = attempt.transcriptTurnID {
                byTurn[turnID, default: []].append(attempt)
            } else if let runID = attempt.processRunID {
                unkeyedByRun[runID, default: []].append(attempt)
            }
        }
        let runAttemptsByID = Dictionary(runAttempts.map { ($0.runAttemptID, $0) }, uniquingKeysWith: { first, _ in first })
        var steeredRunIDs: [UUID: Set<UUID>] = [:]
        var latest: [UUID: (turnID: UUID, at: AgentRecoveryTimestamp?)] = [:]
        for attempt in runAttempts {
            if let turnID = attempt.transcriptTurnID { latest[attempt.runAttemptID] = (turnID, nil) }
        }
        for dispatch in intentAttempts {
            guard let runAttemptID = dispatch.runAttemptID, runAttemptsByID[runAttemptID] != nil else { continue }
            // A dispatch that recorded its execution turn (a relocated saved input, O11) joins that
            // turn, never a historical turn that happens to share its user item's ID.
            let dispatchTurnID = dispatch.transcriptTurnID ?? dispatch.userItemID
            if byTurn[dispatchTurnID] == nil {
                steeredRunIDs[dispatchTurnID, default: []].insert(runAttemptID)
            }
            // The own turn (no dispatch time) precedes every dispatch into its run; ties keep the first.
            if let at = latest[runAttemptID]?.at, at.date >= dispatch.dispatchedAt.date { continue }
            latest[runAttemptID] = (dispatchTurnID, dispatch.dispatchedAt)
        }
        attemptsByTurnID = byTurn
        unkeyedAttemptsByProcessRunID = unkeyedByRun
        steeredAttemptsByTurnID = steeredRunIDs.compactMapValues { ids in
            ids.count == 1 ? ids.first.flatMap { runAttemptsByID[$0] } : nil
        }
        latestTurnIDByRunAttemptID = latest.mapValues(\.turnID)
    }

    /// The latest transcript turn `runAttempt` dispatched into (its own turn, or a later steer):
    /// the turn its terminal closed. `nil` when the attempt has no turn join key.
    package func latestTurnID(of runAttempt: AgentRecoveryRunAttempt) -> UUID? {
        latestTurnIDByRunAttemptID[runAttempt.runAttemptID] ?? runAttempt.transcriptTurnID
    }

    /// The single run attempt a saved turn belongs to; `nil` when none or ambiguous. Several
    /// attempts claiming one turn resolve only to their single open attempt (the one that can have
    /// been interrupted).
    package func attempt(for turn: AgentTranscriptTurn) -> AgentRecoveryRunAttempt? {
        if let owners = attemptsByTurnID[turn.id] {
            if owners.count == 1 { return owners[0] }
            let open = owners.filter { $0.terminal == nil }
            return open.count == 1 ? open[0] : nil
        }
        if let steered = steeredAttemptsByTurnID[turn.id] { return steered }
        // Review B R1-F1: steering recorded as a mid-turn user activity joins the run attempt its
        // dispatch recorded (one attempt only; several are ambiguous).
        let activitySteered = Set(turn.userActivityIDs.compactMap { steeredAttemptsByTurnID[$0]?.runAttemptID })
        if activitySteered.count == 1, let steered = turn.userActivityIDs.lazy.compactMap({ self.steeredAttemptsByTurnID[$0] }).first {
            return steered
        }
        if activitySteered.count > 1 { return nil }
        var candidates: [UUID: AgentRecoveryRunAttempt] = [:]
        for runID in Set(turn.responseSpans.compactMap(\.runID)) {
            guard let unkeyed = unkeyedAttemptsByProcessRunID[runID] else { continue }
            guard unkeyed.count == 1 else { return nil }
            candidates[unkeyed[0].runAttemptID] = unkeyed[0]
        }
        return candidates.count == 1 ? candidates.values.first : nil
    }

    /// Whether `attempt` has a saved transcript turn among `turns`: its own turn is saved, or it is
    /// the only attempt without its own turn on its process run and a saved turn that no attempt
    /// claims carries that process run. `nil` when the attempt has no join key at all (nothing it
    /// recorded can show whether its transcript was saved).
    package func hasSavedTurn(_ attempt: AgentRecoveryRunAttempt, in turns: [AgentTranscriptTurn]) -> Bool? {
        if let turnID = attempt.transcriptTurnID {
            return turns.contains { $0.id == turnID }
        }
        guard let runID = attempt.processRunID else { return nil }
        guard unkeyedAttemptsByProcessRunID[runID]?.count == 1 else { return false }
        return turns.contains { turn in
            attemptsByTurnID[turn.id] == nil && turn.responseSpans.contains { $0.runID == runID }
        }
    }

    /// Run attempts the saved transcript does not represent (R1a recovery-only rows): open attempts
    /// without a saved turn (including ones with no join key), and terminal attempts of
    /// `currentGeneration` that have a join key and no saved turn (R09: the run finished, but its
    /// turn was not saved). Terminal attempts of earlier reset generations belong to a cleared
    /// transcript and are not listed.
    package func unrepresentedAttempts(
        _ runAttempts: [AgentRecoveryRunAttempt],
        in turns: [AgentTranscriptTurn],
        currentGeneration: UInt64
    ) -> [AgentRecoveryRunAttempt] {
        runAttempts.filter { attempt in
            let saved = hasSavedTurn(attempt, in: turns)
            if attempt.terminal == nil { return saved != true }
            return saved == false && attempt.transcriptResetGeneration == currentGeneration
        }
    }
}

/// Evidence for the R5 interruption stamp that cold restore writes on each turn it closes. Built under
/// the session gate from the session's recovery record before normalization; `nil` (no stamp) when
/// no recovery store is composed. Joins only existing identities (run-attempt turn, or an
/// unambiguous process run: `AgentRecoveryRunTurnJoin`); a legacy turn without one gets no
/// invented run ID. The reason comes from per-attempt evidence
/// first, then the captured launch state; it is `unknown` only when neither says anything.
package struct AgentColdRestoreInterruptionContext: Equatable {
    package struct AttemptEvidence: Equatable {
        package let runAttemptID: UUID
        package let shutdownReason: AgentRecoveryShutdownReason?
        /// Phase 2 terminal cause recorded with the attempt's terminal evidence, if any.
        package let terminalCause: AgentRunTerminalCause?
    }

    /// R1a: an earlier launch's intent with affirmative provider acceptance whose deterministic
    /// bubble may be missing from the saved transcript (crash before the save).
    package struct AcceptedBubble: Equatable {
        package let userItemID: UUID
        package let incarnationID: UUID
        package let transcriptResetGeneration: UInt64
        package let text: String
        package let attachments: [AgentImageAttachment]
        package let taggedFiles: [AgentTaggedFileAttachment]
        package let workflow: AgentWorkflowDefinition?

        package init(
            userItemID: UUID,
            incarnationID: UUID,
            transcriptResetGeneration: UInt64,
            text: String,
            attachments: [AgentImageAttachment],
            taggedFiles: [AgentTaggedFileAttachment],
            workflow: AgentWorkflowDefinition?
        ) {
            self.userItemID = userItemID
            self.incarnationID = incarnationID
            self.transcriptResetGeneration = transcriptResetGeneration
            self.text = text
            self.attachments = attachments
            self.taggedFiles = taggedFiles
            self.workflow = workflow
        }
    }

    /// R1a: an earlier launch's intent without affirmative provider acceptance. Its deterministic
    /// saved bubble is presented as `delivery` (verified not sent, or unconfirmed), never as sent.
    package struct UnacceptedBubble: Equatable {
        package let userItemID: UUID
        package let incarnationID: UUID
        package let transcriptResetGeneration: UInt64
        package let delivery: AgentUserItemRecoveryDelivery

        package init(
            userItemID: UUID,
            incarnationID: UUID,
            transcriptResetGeneration: UInt64,
            delivery: AgentUserItemRecoveryDelivery
        ) {
            self.userItemID = userItemID
            self.incarnationID = incarnationID
            self.transcriptResetGeneration = transcriptResetGeneration
            self.delivery = delivery
        }
    }

    package let observedAt: Date
    package let providerConversationID: String?
    package let runJoin: AgentRecoveryRunTurnJoin
    package let acceptedBubbles: [AcceptedBubble]
    package let unacceptedBubbles: [UnacceptedBubble]
    /// Reason from the captured previous-launch state, used when per-attempt evidence has none.
    /// `nil` when the launch state proves nothing (no, unreadable, or same-instance mark).
    package let launchReason: AgentTranscriptTurnInterruption.Reason?
    /// Whether launch evidence had been captured when this context was built. Without it, an
    /// `unknown` stamp is provisional and is refined once evidence exists.
    package let launchStateCaptured: Bool
    /// Turns this process stamped `unknown` before launch evidence was captured. Their unresolved
    /// `unknown` reason is refined to the evidence-derived reason; the stamp itself is never erased.
    package let provisionalUnknownTurnIDs: Set<UUID>
    /// F-7: run attempts the current launch still owns live: recorded by `currentInstanceID`, with
    /// neither terminal nor shutdown evidence. A legacy attempt without an instance is unknown, not
    /// current. Only these runs (and their exact turns) are excluded from cold restoration.
    private let currentLaunchLiveRuns: [AgentRecoveryRunAttempt]

    package init(
        observedAt: Date,
        providerConversationID: String?,
        runAttempts: [AgentRecoveryRunAttempt],
        intentAttempts: [AgentRecoveryAttempt] = [],
        acceptedBubbles: [AcceptedBubble] = [],
        unacceptedBubbles: [UnacceptedBubble] = [],
        launchReason: AgentTranscriptTurnInterruption.Reason? = nil,
        launchStateCaptured: Bool = false,
        provisionalUnknownTurnIDs: Set<UUID> = [],
        currentInstanceID: UUID? = nil
    ) {
        self.observedAt = observedAt
        self.providerConversationID = providerConversationID
        self.acceptedBubbles = acceptedBubbles
        self.unacceptedBubbles = unacceptedBubbles
        self.launchReason = launchReason
        self.launchStateCaptured = launchStateCaptured
        self.provisionalUnknownTurnIDs = launchReason == nil ? [] : provisionalUnknownTurnIDs
        runJoin = AgentRecoveryRunTurnJoin(runAttempts: runAttempts, intentAttempts: intentAttempts)
        currentLaunchLiveRuns = currentInstanceID.map { current in
            runAttempts.filter {
                $0.appInstanceID == current && $0.terminal == nil && $0.shutdown == nil
            }
        } ?? []
    }

    private init(copying other: AgentColdRestoreInterruptionContext, providerConversationID: String?) {
        observedAt = other.observedAt
        self.providerConversationID = providerConversationID
        runJoin = other.runJoin
        acceptedBubbles = other.acceptedBubbles
        unacceptedBubbles = other.unacceptedBubbles
        launchReason = other.launchReason
        launchStateCaptured = other.launchStateCaptured
        provisionalUnknownTurnIDs = other.provisionalUnknownTurnIDs
        currentLaunchLiveRuns = other.currentLaunchLiveRuns
    }

    /// Whether the current launch still owns a live run in this record (its saved active run state
    /// belongs to that run, not to a previous execution).
    package var hasCurrentLaunchLiveRun: Bool {
        !currentLaunchLiveRuns.isEmpty
    }

    /// Whether `turn` is exactly the turn of a run the current launch still owns live: the run's own
    /// transcript turn, or the turn its unambiguous process-run join resolves to. Any other turn of
    /// the same record (earlier-launch or unknown-owner runs, legacy turns) is not excluded.
    package func isOwnedByCurrentLaunchLiveRun(_ turn: AgentTranscriptTurn) -> Bool {
        guard !currentLaunchLiveRuns.isEmpty else { return false }
        if currentLaunchLiveRuns.contains(where: { $0.transcriptTurnID == turn.id }) { return true }
        guard let joined = runJoin.attempt(for: turn) else { return false }
        return currentLaunchLiveRuns.contains { $0.runAttemptID == joined.runAttemptID }
    }

    /// Delivery presentation of unaccepted bubbles by deterministic item ID, for a transcript of
    /// `lifecycle` (same incarnation and reset generation only).
    package func unacceptedDeliveries(lifecycle: AgentSessionLifecycle?) -> [UUID: AgentUserItemRecoveryDelivery] {
        guard let lifecycle else { return [:] }
        var deliveries: [UUID: AgentUserItemRecoveryDelivery] = [:]
        for bubble in unacceptedBubbles where bubble.incarnationID == lifecycle.incarnationID
            && bubble.transcriptResetGeneration == lifecycle.transcriptResetGeneration
        {
            // Several intents can never share an item; if they did, uncertainty (crash first) wins.
            switch (deliveries[bubble.userItemID], bubble.delivery) {
            case (.unconfirmed?, _), (.notConfirmedByAgent?, .notSent):
                continue
            default:
                deliveries[bubble.userItemID] = bubble.delivery
            }
        }
        return deliveries
    }

    /// The presentation an earlier launch's unaccepted intent implies: unconfirmed while a handoff
    /// may have happened (`dispatching`, `deliveryUnknown`, or any attempt without conclusive
    /// non-delivery, superseded outcomes included); otherwise verified not sent. O50: uncertainty
    /// whose runs all ended with recorded evidence (`runsEndedWithRecordedEvidence`) did not come
    /// from an unclean exit and is presented as not confirmed by the agent instead.
    package static func unacceptedDelivery(
        state: AgentRecoveryDeliveryState,
        attempts: [AgentRecoveryAttempt],
        runsEndedWithRecordedEvidence: Bool
    ) -> AgentUserItemRecoveryDelivery {
        let uncertain: AgentUserItemRecoveryDelivery = runsEndedWithRecordedEvidence ? .notConfirmedByAgent : .unconfirmed
        switch state {
        case .dispatching, .deliveryUnknown, .providerAccepted:
            return uncertain
        case .queued, .failed, .withdrawn:
            return AgentRecoveryStore.hasOnlyAffirmativeNonDelivery(attempts) ? .notSent : uncertain
        }
    }

    /// The R5 reason implied by launch state: a proven clean exit closed an open turn by quitting;
    /// another instance's unclean (`running`) mark is a crash. Nothing else proves a cause.
    package static func launchReason(
        previousLaunch: AgentRecoveryPreviousLaunch,
        currentInstanceID: UUID
    ) -> AgentTranscriptTurnInterruption.Reason? {
        guard case let .mark(mark) = previousLaunch, mark.appInstanceID != currentInstanceID else { return nil }
        switch mark.state {
        case .cleanExit:
            return .appQuit
        case .running:
            return .appCrash
        case .shutdownInProgress:
            // A quit that never reached its clean mark proves neither a quit nor a crash.
            return nil
        }
    }

    /// Bubbles to restore once into a transcript of `lifecycle` that lacks their deterministic item:
    /// only the same incarnation and reset generation (old-generation input is never inserted).
    package func missingAcceptedBubbles(
        lifecycle: AgentSessionLifecycle?,
        presentItemIDs: Set<UUID>
    ) -> [AgentChatItem] {
        guard let lifecycle else { return [] }
        return acceptedBubbles.filter {
            $0.incarnationID == lifecycle.incarnationID
                && $0.transcriptResetGeneration == lifecycle.transcriptResetGeneration
                && !presentItemIDs.contains($0.userItemID)
        }.map {
            AgentChatItem.user(
                $0.text,
                id: $0.userItemID,
                attachments: $0.attachments,
                taggedFileAttachments: $0.taggedFiles,
                workflow: $0.workflow
            )
        }
    }

    /// The same evidence with the session's existing provider conversation identity.
    package func withProviderConversationID(_ id: String?) -> AgentColdRestoreInterruptionContext {
        AgentColdRestoreInterruptionContext(copying: self, providerConversationID: id)
    }

    private func evidence(for turn: AgentTranscriptTurn) -> AttemptEvidence? {
        runJoin.attempt(for: turn).map {
            AttemptEvidence(
                runAttemptID: $0.runAttemptID,
                shutdownReason: $0.shutdown?.reason,
                terminalCause: $0.terminal?.cause
            )
        }
    }

    /// Per-attempt evidence first (a recorded interruption terminal cause, then the shutdown
    /// reason), then the launch state; `unknown` only when none applies.
    private func reason(for evidence: AttemptEvidence?) -> AgentTranscriptTurnInterruption.Reason {
        if let causeReason = evidence?.terminalCause?.interruptionReason {
            return causeReason
        }
        return switch evidence?.shutdownReason {
        case .appQuit?: .appQuit
        case .windowClose?: .windowClose
        case .safeRestart?: .safeRestart
        case .providerProcessLost?: .providerProcessLost
        case nil: launchReason ?? .unknown
        }
    }

    /// The authoritative ordinary outcome of the turn's joined run attempt: its terminal commit
    /// recorded a non-interruption. A completed commit is always ordinary (completion wins against a
    /// provisional Stage A shutdown reason); a failed or cancelled commit is ordinary only with an
    /// explicit `ordinary` or `userCancel` cause (pre-Phase 2 evidence without a cause proves
    /// nothing). `nil` when no such evidence exists.
    func ordinaryTerminalOutcome(for turn: AgentTranscriptTurn) -> AgentSessionRunState? {
        guard let terminal = runJoin.attempt(for: turn)?.terminal else { return nil }
        switch terminal.terminalState {
        case .completed:
            return .completed
        case .failed, .cancelled:
            guard let cause = terminal.cause, cause.interruptionReason == nil else { return nil }
            return terminal.terminalState
        default:
            return nil
        }
    }

    /// The durable marker for a turn cold restore closes as its joined attempt's ordinary outcome
    /// (review A F03-R1); `nil` when there is no such outcome.
    func recoveredOutcome(for turn: AgentTranscriptTurn) -> AgentTranscriptTurnRecoveredOutcome? {
        guard ordinaryTerminalOutcome(for: turn) != nil, let attempt = runJoin.attempt(for: turn) else { return nil }
        return AgentTranscriptTurnRecoveredOutcome(runAttemptID: attempt.runAttemptID, observedAt: observedAt)
    }

    /// Whether the turn carries a provisional, unresolved `unknown` stamp this process wrote.
    func hasProvisionalUnknownStamp(_ turn: AgentTranscriptTurn) -> Bool {
        guard let existing = turn.interruption else { return false }
        return existing.reason == .unknown && existing.resolution == nil && provisionalUnknownTurnIDs.contains(turn.id)
    }

    /// A provisional `unknown` stamp this process wrote before launch evidence existed, refined
    /// conservatively: only an unresolved `unknown` changes, and only its reason.
    func refinedInterruption(of turn: AgentTranscriptTurn) -> AgentTranscriptTurnInterruption? {
        guard var existing = turn.interruption,
              existing.reason == .unknown,
              existing.resolution == nil,
              provisionalUnknownTurnIDs.contains(turn.id)
        else { return nil }
        let refined = reason(for: evidence(for: turn))
        guard refined != .unknown else { return nil }
        existing.reason = refined
        return existing
    }

    /// The stamp for an open turn cold restore closes, or `nil` when its run attempt's terminal
    /// evidence records an ordinary outcome (completed, an ordinary failure or cancel, or an explicit
    /// user cancel): such a turn closes as that outcome, never as an interruption.
    func interruption(for turn: AgentTranscriptTurn) -> AgentTranscriptTurnInterruption? {
        if ordinaryTerminalOutcome(for: turn) != nil { return nil }
        let evidence = evidence(for: turn)
        if evidence?.terminalCause == .userCancel { return nil }
        return AgentTranscriptTurnInterruption(
            reason: reason(for: evidence),
            observedAt: observedAt,
            lastConfirmedActivityAt: turn.lastActivityAt
                ?? turn.responseSpans.compactMap { $0.lastActivityAt ?? $0.startedAt }.max(),
            runAttemptID: evidence?.runAttemptID,
            providerConversationID: providerConversationID
        )
    }
}

package enum AgentSessionRestoreSupport {
    package static func normalizedSessionTitle(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Agent Session" : trimmed
    }

    static func shouldPreferSidebarEntry(_ lhs: AgentSessionIndexEntry, over rhs: AgentSessionIndexEntry) -> Bool {
        if lhs.lastUserMessageAt != rhs.lastUserMessageAt {
            return shouldListBefore(
                lhsID: lhs.id,
                lhsDate: lhs.lastUserMessageAt,
                rhsID: rhs.id,
                rhsDate: rhs.lastUserMessageAt
            )
        }
        if lhs.savedAt != rhs.savedAt {
            return lhs.savedAt > rhs.savedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func sidebarSortDates(
        from sessionIndex: [UUID: AgentSessionIndexEntry]
    ) -> [UUID: Date] {
        var sortDates: [UUID: Date] = [:]
        let entriesWithSortDates = sessionIndex.values.lazy.filter { $0.lastUserMessageAt != nil }
        for (tabID, entry) in preferredEntriesByTabID(from: entriesWithSortDates) {
            if let date = entry.lastUserMessageAt {
                sortDates[tabID] = date
            }
        }
        return sortDates
    }

    package static func preferredEntriesByTabID(
        from entries: some Sequence<AgentSessionIndexEntry>
    ) -> [UUID: AgentSessionIndexEntry] {
        var preferredEntryByTabID: [UUID: AgentSessionIndexEntry] = [:]
        for entry in entries {
            if let existing = preferredEntryByTabID[entry.tabID] {
                if shouldPreferSidebarEntry(entry, over: existing) {
                    preferredEntryByTabID[entry.tabID] = entry
                }
            } else {
                preferredEntryByTabID[entry.tabID] = entry
            }
        }
        return preferredEntryByTabID
    }

    package static func sidebarActivityDate(for entry: AgentSessionIndexEntry) -> Date {
        sidebarActivityDate(lastUserMessageAt: entry.lastUserMessageAt, savedAt: entry.savedAt)
    }

    package static func sidebarActivityDate(lastUserMessageAt: Date?, savedAt: Date) -> Date {
        lastUserMessageAt ?? savedAt
    }

    static func normalizeColdRestoredRunState(_ persisted: AgentSessionRunState?) -> AgentSessionRunState {
        guard let persisted else { return .idle }
        switch persisted {
        case .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
            return .idle
        case .idle, .completed, .cancelled, .failed:
            return persisted
        }
    }

    static func coldRestoredLastRunStateRaw(_ raw: String?) -> String? {
        guard let raw,
              let persisted = AgentSessionRunState(rawValue: raw),
              persisted.isActive
        else {
            return raw
        }
        return normalizeColdRestoredRunState(persisted).rawValue
    }

    static func sanitizeColdRestoredTranscript(
        _ transcript: AgentTranscript,
        interruptionContext: AgentColdRestoreInterruptionContext? = nil,
        unacceptedDeliveries: [UUID: AgentUserItemRecoveryDelivery] = [:],
        protectedItemIDs: Set<UUID>
    ) -> AgentTranscript {
        var restored = transcript
        for turnIndex in restored.turns.indices {
            sanitizeColdRestoredTurn(
                &restored.turns[turnIndex],
                interruptionContext: interruptionContext,
                unacceptedDeliveries: unacceptedDeliveries,
                protectedItemIDs: protectedItemIDs
            )
        }
        return restored
    }

    private static func hasSavedProviderOutput(_ turn: AgentTranscriptTurn) -> Bool {
        // A compacted turn was answered before its activities were summarized.
        turn.summary != nil || turn.responseSpans.contains { span in
            span.activities.contains { activity in
                switch activity.itemKind {
                case .assistant, .assistantInline, .toolCall, .toolResult, .thinking:
                    true
                case .user, .system, .error:
                    false
                }
            }
        }
    }

    private static func sanitizeColdRestoredTurn(
        _ turn: inout AgentTranscriptTurn,
        interruptionContext: AgentColdRestoreInterruptionContext?,
        unacceptedDeliveries: [UUID: AgentUserItemRecoveryDelivery],
        protectedItemIDs: Set<UUID>
    ) {
        // F-7: the turn of a run this launch still owns live (another owner hydrating the same
        // session) is left exactly as saved: not cancelled, stamped, refined, or re-presented.
        if interruptionContext?.isOwnedByCurrentLaunchLiveRun(turn) == true { return }
        // R1a (R11/F-13): an unaccepted intent's deterministic bubble is presented by its own
        // recovery evidence, joined by user-item ID across the request anchor and mid-turn user
        // activities: verified not sent, or unconfirmed. Never the remote-resend flag, never sent.
        // - The request: a saved provider response in its own turn answers it (acceptance evidence),
        //   so an answered request is left unchanged.
        // - A mid-turn user item: turn-wide output does not prove it was received, so only its
        //   intent's evidence applies.
        // - A provider-accepted schedule receipt is acceptance; a saved-in-queue or legacy receipt
        //   proves no delivery and does not exempt the bubble.
        if !unacceptedDeliveries.isEmpty {
            if var request = turn.request,
               let delivery = unacceptedDeliveries[request.id],
               request.scheduledSend?.isProviderAccepted != true,
               request.recoveryDelivery != delivery,
               !hasSavedProviderOutput(turn)
            {
                request.recoveryDelivery = delivery
                turn.request = request
            }
            for spanIndex in turn.responseSpans.indices {
                for activityIndex in turn.responseSpans[spanIndex].activities.indices {
                    let activity = turn.responseSpans[spanIndex].activities[activityIndex]
                    guard activity.itemKind == .user,
                          let delivery = unacceptedDeliveries[activity.id],
                          activity.scheduledSend?.isProviderAccepted != true,
                          activity.recoveryDelivery != delivery
                    else { continue }
                    turn.responseSpans[spanIndex].activities[activityIndex].recoveryDelivery = delivery
                }
            }
        }
        // Authoritative ordinary terminal evidence (completed, or an ordinary failure or cancel)
        // decides the turn's outcome: a provisional `unknown` stamp this process wrote is withdrawn
        // and the turn's envelope takes that outcome instead of an interruption.
        let ordinaryOutcome = interruptionContext?.ordinaryTerminalOutcome(for: turn)
        if let ordinaryOutcome, interruptionContext?.hasProvisionalUnknownStamp(turn) == true {
            turn.interruption = nil
            if turn.terminalState?.isActive != true {
                // Review B R1-F7: spans the provisional close cancelled take the outcome's lifecycle.
                let provisionalLifecycle = closedSpanLifecycle(for: .cancelled)
                let outcomeLifecycle = closedSpanLifecycle(for: ordinaryOutcome)
                if turn.terminalState == .cancelled, outcomeLifecycle != provisionalLifecycle {
                    for spanIndex in turn.responseSpans.indices where turn.responseSpans[spanIndex].lifecycle == provisionalLifecycle {
                        turn.responseSpans[spanIndex].lifecycle = outcomeLifecycle
                    }
                }
                turn.terminalState = ordinaryOutcome
            }
            // The provisional stamp closed a saved-open turn: its tail may be missing too.
            turn.recoveredOutcome = turn.recoveredOutcome ?? interruptionContext?.recoveredOutcome(for: turn)
        } else if let interruptionContext, let refined = interruptionContext.refinedInterruption(of: turn) {
            turn.interruption = refined
        }
        let activeToolExecutionIDs = activeToolExecutionIDsNeedingColdRestoreCancellation(in: turn)
        let hadActiveTurnState = turn.terminalState?.isActive == true
        let hasOpenSpan = turn.responseSpans.contains { $0.lifecycle == .open }
        let shouldCancelTurn = hadActiveTurnState
            || (turn.terminalState == nil && (hasOpenSpan || !activeToolExecutionIDs.isEmpty))

        // R5: the open-turn evidence is recorded before sanitizing closes it, in the same value.
        if shouldCancelTurn, turn.interruption == nil, ordinaryOutcome == nil, let interruptionContext {
            turn.interruption = interruptionContext.interruption(for: turn)
        }
        if shouldCancelTurn {
            turn.terminalState = ordinaryOutcome ?? .cancelled
            // Review A F03-R1: a saved-open turn closed as its ordinary outcome keeps a durable
            // tail-may-be-missing marker; turns that were already closed are never marked.
            if ordinaryOutcome != nil, turn.recoveredOutcome == nil {
                turn.recoveredOutcome = interruptionContext?.recoveredOutcome(for: turn)
            }
        }
        if shouldCancelTurn || (turn.completedAt == nil && !(turn.terminalState?.isActive ?? false)) {
            turn.completedAt = turn.completedAt
                ?? turn.lastActivityAt
                ?? turn.responseSpans.map { $0.lastActivityAt ?? $0.startedAt }.max()
                ?? turn.request?.timestamp
                ?? turn.startedAt
        }
        if shouldCancelTurn, turn.terminalState != .completed, var summary = turn.summary {
            summary.hadError = true
            turn.summary = summary
        }

        for spanIndex in turn.responseSpans.indices {
            sanitizeColdRestoredSpan(
                &turn.responseSpans[spanIndex],
                terminalState: turn.terminalState,
                activeToolExecutionIDs: activeToolExecutionIDs,
                protectedItemIDs: protectedItemIDs
            )
        }
    }

    private static func sanitizeColdRestoredSpan(
        _ span: inout AgentTranscriptProviderResponseSpan,
        terminalState: AgentSessionRunState?,
        activeToolExecutionIDs: Set<String>,
        protectedItemIDs: Set<UUID>
    ) {
        for activityIndex in span.activities.indices {
            sanitizeColdRestoredActivity(
                &span.activities[activityIndex],
                activeToolExecutionIDs: activeToolExecutionIDs,
                protectedItemIDs: protectedItemIDs
            )
        }
        if span.lifecycle == .open {
            span.lifecycle = closedSpanLifecycle(for: terminalState)
        }
        if span.completedAt == nil, span.lifecycle != .open {
            span.completedAt = span.lastActivityAt ?? span.activities.last?.timestamp ?? span.startedAt
        }
        span.collapsedSummary = span.collapsedSummary.map(sanitizedColdRestoredGroupedHistorySummary(_:))
        span.fullRenderGroupedHistoryCache = nil
    }

    private static func sanitizeColdRestoredActivity(
        _ activity: inout AgentTranscriptActivity,
        activeToolExecutionIDs: Set<String>,
        protectedItemIDs: Set<UUID>
    ) {
        activity.isStreaming = false
        // Step 4d5: a tool row associated to Claude's history (valid or cleared proof) keeps its
        // projected payload; the turn and its spans still close as interrupted, like any other.
        guard var execution = activity.toolExecution,
              activeToolExecutionIDs.contains(execution.stableExecutionID),
              !protectedItemIDs.contains(activity.id)
        else {
            return
        }
        execution.status = .cancelled
        execution.toolIsError = true
        if activity.itemKind == .toolResult {
            let resultJSON = coldRestoredCancelledToolResultJSON(
                toolName: execution.toolName,
                existingResultJSON: execution.resultJSON
            )
            execution.resultJSON = resultJSON
            activity.text = resultJSON
        }
        activity.toolExecution = execution
    }

    private static func activeToolExecutionIDsNeedingColdRestoreCancellation(in turn: AgentTranscriptTurn) -> Set<String> {
        var latestStatusByID: [String: AgentTranscriptToolStatus] = [:]
        for activity in turn.allActivities {
            guard let execution = activity.toolExecution else { continue }
            if let existing = latestStatusByID[execution.stableExecutionID],
               coldRestoredToolStatusRank(existing) > coldRestoredToolStatusRank(execution.status)
            {
                continue
            }
            latestStatusByID[execution.stableExecutionID] = execution.status
        }
        return Set(latestStatusByID.compactMap { executionID, status in
            switch status {
            case .pending, .running:
                executionID
            case .success, .warning, .failed, .cancelled, .unknown:
                nil
            }
        })
    }

    private static func closedSpanLifecycle(for terminalState: AgentSessionRunState?) -> AgentTranscriptSpanLifecycle {
        switch terminalState {
        case .cancelled:
            .cancelled
        case .failed:
            .failed
        default:
            .completed
        }
    }

    private static func coldRestoredToolStatusRank(_ status: AgentTranscriptToolStatus) -> Int {
        switch status {
        case .pending:
            0
        case .running:
            1
        case .unknown:
            2
        case .success:
            3
        case .warning:
            4
        case .failed:
            5
        case .cancelled:
            6
        }
    }

    private static func coldRestoredCancelledToolResultJSON(
        toolName: String?,
        existingResultJSON: String?
    ) -> String {
        var payload = coldRestoredToolResultObject(from: existingResultJSON) ?? [:]
        payload["status"] = "cancelled"
        payload["reason"] = "restored_without_live_run"
        payload["note"] = "This tool execution was restored from a previous app process and is no longer running."
        if let toolName,
           !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            payload["tool"] = toolName
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return #"{"status":"cancelled","reason":"restored_without_live_run"}"#
    }

    private static func coldRestoredToolResultObject(from raw: String?) -> [String: Any]? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func sanitizedColdRestoredGroupedHistorySummary(
        _ summary: AgentTranscriptGroupedHistorySummary
    ) -> AgentTranscriptGroupedHistorySummary {
        let sanitizedToolSummary = summary.toolSummary.map(sanitizedColdRestoredClusterSummary(_:))
        return AgentTranscriptGroupedHistorySummary(
            hiddenToolCardCount: summary.hiddenToolCardCount,
            hiddenAssistantCount: summary.hiddenAssistantCount,
            hiddenProgressCount: summary.hiddenProgressCount,
            hiddenNoteCount: summary.hiddenNoteCount,
            toolSummary: sanitizedToolSummary,
            collapsedDisplay: summary.collapsedDisplay.map(sanitizedColdRestoredCollapsedDisplay(_:))
        )
    }

    private static func sanitizedColdRestoredClusterSummary(
        _ summary: AgentTranscriptClusterSummary
    ) -> AgentTranscriptClusterSummary {
        let didCancelRunningWork = summary.containsRunningWork
        return AgentTranscriptClusterSummary(
            toolCount: summary.toolCount,
            toolNames: summary.toolNames,
            toolNameCounts: summary.toolNameCounts,
            toolGroups: summary.toolGroups,
            keyPaths: summary.keyPaths,
            containsRunningWork: false,
            containsFailure: summary.containsFailure || didCancelRunningWork,
            containsWarning: summary.containsWarning,
            shortNarration: summary.shortNarration,
            collapsedDisplay: summary.collapsedDisplay.map(sanitizedColdRestoredCollapsedDisplay(_:)),
            // Interrupted running work is not a failed execution; only retained failures count.
            failedToolCount: summary.failedToolCount
        )
    }

    private static func sanitizedColdRestoredCollapsedDisplay(
        _ display: AgentTranscriptCollapsedSummaryDisplay
    ) -> AgentTranscriptCollapsedSummaryDisplay {
        AgentTranscriptCollapsedSummaryDisplay(
            title: display.title,
            count: display.count,
            detailText: display.detailText,
            narrationText: display.narrationText,
            toolGroupText: display.toolGroupText,
            status: display.status == .running ? .failure : display.status
        )
    }

    static func computeLastUserMessageDate(in items: [AgentChatItem]) -> Date? {
        AgentTranscriptIO.lastUserInteractionDate(in: items)
    }

    static func hasUnknownConversationContent(in session: AgentSession) -> Bool {
        session.transcriptProjectionCounts == nil
            && session.lastUserMessageAt == nil
            && session.itemCount == 0
    }

    static func transcriptProjectionProtection(
        for transcript: AgentTranscript,
        viewportState: AgentTranscriptViewportState
    ) -> AgentTranscriptProjectionProtection {
        guard !transcript.turns.isEmpty else { return .none }
        return AgentTranscriptProjectionBuilder.projectionProtection(
            for: transcript,
            viewportState: viewportState
        )
    }

    static func buildTranscriptPresentation(
        from transcript: AgentTranscript,
        sourceItems: [AgentChatItem],
        selectedAgent: AgentProviderKind,
        previousPerformanceSnapshot: AgentTranscriptPerformanceSnapshot,
        projectionProtection: AgentTranscriptProjectionProtection,
        isCompressedHistoryRevealed: Bool,
        isColdLoad: Bool
    ) -> AgentBuiltTranscriptPresentation {
        AgentTranscriptPresentationBuilder.buildTranscriptPresentation(
            from: transcript,
            sourceItems: sourceItems,
            selectedAgent: selectedAgent,
            previousPerformanceSnapshot: previousPerformanceSnapshot,
            projectionProtection: projectionProtection,
            isCompressedHistoryRevealed: isCompressedHistoryRevealed,
            isColdLoad: isColdLoad
        )
    }

    static func buildSidebarIndexEntry(
        from session: AgentSession,
        tabID: UUID,
        name: String,
        lastUserMessageAt: Date? = nil,
        itemCount: Int? = nil,
        hasUnknownConversationContent: Bool = false
    ) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: session.id,
            tabID: tabID,
            name: normalizedSessionTitle(name),
            lastUserMessageAt: lastUserMessageAt ?? session.lastUserMessageAt,
            savedAt: session.savedAt,
            lastRunStateRaw: session.lastRunState,
            itemCount: itemCount ?? session.effectiveItemCount,
            agentKindRaw: session.agentKind,
            agentModelRaw: session.agentModel,
            agentReasoningEffortRaw: session.agentReasoningEffort,
            autoEditEnabled: session.autoEditEnabled,
            parentSessionID: session.parentSessionID,
            hasUnknownConversationContent: hasUnknownConversationContent,
            remoteHostID: session.remoteHost?.hostID,
            remoteHostName: session.remoteHost?.hostDisplayName,
            remoteSessionID: session.remoteHost?.normalizedRemoteSessionID,
            isMCPOriginated: session.isMCPOriginated,
            origin: session.origin,
            profile: session.profile,
            worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
            activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries,
            scheduledSendSummary: AgentSessionScheduledSendSummary.make(from: session.scheduledSend),
            lastScheduledDispatch: session.lastScheduledDispatch
        )
    }

    private static func shouldListBefore(
        lhsID: UUID,
        lhsDate: Date?,
        rhsID: UUID,
        rhsDate: Date?
    ) -> Bool {
        switch (lhsDate, rhsDate) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }
        return lhsID.uuidString < rhsID.uuidString
    }
}
