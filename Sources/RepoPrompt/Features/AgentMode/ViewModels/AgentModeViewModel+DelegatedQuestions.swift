import Foundation
import MCP
import RepoPromptAgentCore

// Delegated `ask_user` escalation (docs/context/plans/2026-10-02-oracle-errors-and-delegated-ask-user-plan.md §6;
// owning contract: docs/context/agent-mcp-delegation-depth.md "Delegated questions").
//
// A child's `pendingAskUser` plus its continuation stay the single authority for question
// content, drafts, the timeout, and resolution. This file only keeps a runtime-only notice
// registry keyed by (child session, interaction) that decides when the immediate parent
// agent learns about the question:
// - parent blocked in a covering `agent_run` wait → existing actionable snapshot, acknowledged at handoff;
// - parent blocked in another bounded wait → early wake (`delegatedQuestionPending`);
// - parent busy → next eligible RepoPrompt MCP tool result (`MCPServerViewModel.runTool`), bound to
//   the parent run attempt captured when that tool started and settled at the final handoff;
// - parent idle → banner/badge, then a labeled runtime block in the next turn's first input,
//   acknowledged only by that exact stage's provider submission outcome.
// Nothing here starts a turn, steers, interrupts a tool, or answers a question.

/// Runtime-only notice registry stored on `AgentModeViewModel` (never persisted).
struct AgentDelegatedQuestionNoticeRegistry {
    struct Record: Equatable {
        let key: AgentDelegatedQuestionNoticeKey
        let childTabID: UUID
        /// Immediate parent's durable session ID (resolved once through the reconciled lookup).
        let parentSessionID: UUID
        /// Parent tab observed at registration; only used to cheaply gate reconcile triggers.
        let parentTabID: UUID
        let askedAt: Date
        /// Parent run IDs each delivery was stamped with.
        var deliveredRunIDs: Set<UUID> = []
        /// Set once a delivery reached the parent model; an acknowledged notice is never re-delivered.
        var acknowledged = false
        /// Parent tab whose next-turn input carries this notice while the send outcome is pending.
        var stagedParentTabID: UUID?
        /// Parent run attempts already woken for this notice (wake de-duplication only; not a
        /// delivery). Keyed by attempt because a provider may keep its process run ID across turns.
        var wokenRunAttemptIDs: Set<UUID> = []
        /// Tool-result handoff holding this notice while its result travels to the transport.
        /// Reserved notices are neither deliverable elsewhere nor acknowledged until the
        /// reservation commits (result handed off) or releases (cancelled/failed before handoff).
        var reservationID: UUID?
    }

    struct StagedTurnNotice: Equatable {
        enum Phase: Equatable {
            /// `startAgentRun` is still assembling or starting the run; only its own settle step
            /// (or the provider send outcome) may resolve the stage.
            case startInFlight
            /// The run started; the provider send outcome is still pending. Held as
            /// `deliveryUnknown` if the parent run stops without reporting one.
            case awaitingSendOutcome
            /// The input carrying this stage may have reached the provider, but no outcome proves
            /// it either way. Neither acknowledged nor released: the notices stay undeliverable (no
            /// duplicate) and the child question stays answerable; only this stage's own late
            /// outcome (`sent` commits once, `notSent` releases) or the question's resolution ends it.
            case deliveryUnknown
        }

        let stageID: UUID
        let keys: Set<AgentDelegatedQuestionNoticeKey>
        let text: String
        var phase: Phase = .startInFlight
        /// Parent run whose first input carried this stage, captured while that run is provably the
        /// carrier (its own start in flight, or its start just returned). `nil` when unknown: a late
        /// commit then stamps no run rather than a successor run.
        var carryingRunID: UUID?
    }

    /// A stage no longer current for its parent tab (superseded by a newer first input, or its
    /// delivery is unknown) whose own outcome is still owed.
    struct HeldTurnNotice: Equatable {
        let parentTabID: UUID
        var notice: StagedTurnNotice
    }

    struct Reservation: Equatable {
        let target: AgentDelegatedQuestionDeliveryTarget
        let keys: Set<AgentDelegatedQuestionNoticeKey>
        /// Keys already visible in the result itself (an `agent_run` question snapshot), reserved
        /// without an attached payload. A commit records them as a persistence-only note.
        var coveredKeys: Set<AgentDelegatedQuestionNoticeKey> = []

        var parentRunID: UUID {
            target.parentRunID
        }
    }

    var records: [AgentDelegatedQuestionNoticeKey: Record] = [:]
    /// Next-turn notices staged into a parent's provider input, keyed by parent tab.
    var stagedTurnNoticesByParentTabID: [UUID: StagedTurnNotice] = [:]
    /// Unresolved earlier stages, keyed by stage ID. Their records keep `stagedParentTabID`, so a
    /// newer stage never re-carries them.
    var heldTurnNoticesByStageID: [UUID: HeldTurnNotice] = [:]
    /// Open tool-result handoffs, keyed by reservation ID.
    var reservations: [UUID: Reservation] = [:]
    var isReconciling = false

    var isEmpty: Bool {
        records.isEmpty && stagedTurnNoticesByParentTabID.isEmpty && heldTurnNoticesByStageID.isEmpty
            && reservations.isEmpty
    }

    /// The stage `stageID` of `parentTabID`, current or held.
    func turnStage(stageID: UUID, parentTabID: UUID) -> StagedTurnNotice? {
        if let current = stagedTurnNoticesByParentTabID[parentTabID], current.stageID == stageID {
            return current
        }
        guard let held = heldTurnNoticesByStageID[stageID], held.parentTabID == parentTabID else { return nil }
        return held.notice
    }

    /// Forgets stage `stageID` of `parentTabID` from both stores (never another stage).
    mutating func removeTurnStage(stageID: UUID, parentTabID: UUID) {
        if stagedTurnNoticesByParentTabID[parentTabID]?.stageID == stageID {
            stagedTurnNoticesByParentTabID.removeValue(forKey: parentTabID)
        }
        if heldTurnNoticesByStageID[stageID]?.parentTabID == parentTabID {
            heldTurnNoticesByStageID.removeValue(forKey: stageID)
        }
    }

    /// Moves stage `staged` of `parentTabID` to the held store with `phase`.
    mutating func holdTurnStage(_ staged: StagedTurnNotice, parentTabID: UUID, phase: StagedTurnNotice.Phase) {
        removeTurnStage(stageID: staged.stageID, parentTabID: parentTabID)
        var held = staged
        held.phase = phase
        heldTurnNoticesByStageID[staged.stageID] = HeldTurnNotice(parentTabID: parentTabID, notice: held)
    }

    /// Updates the phase (and, when given, the carrying run) of stage `stageID` in whichever store
    /// holds it.
    mutating func setTurnStagePhase(
        _ phase: StagedTurnNotice.Phase,
        stageID: UUID,
        parentTabID: UUID,
        carryingRunID: UUID? = nil
    ) {
        if var current = stagedTurnNoticesByParentTabID[parentTabID], current.stageID == stageID {
            current.phase = phase
            current.carryingRunID = current.carryingRunID ?? carryingRunID
            stagedTurnNoticesByParentTabID[parentTabID] = current
        } else if var held = heldTurnNoticesByStageID[stageID], held.parentTabID == parentTabID {
            held.notice.phase = phase
            held.notice.carryingRunID = held.notice.carryingRunID ?? carryingRunID
            heldTurnNoticesByStageID[stageID] = held
        }
    }

    func isDeliverable(_ record: Record, toRunID runID: UUID) -> Bool {
        !record.acknowledged
            && record.stagedParentTabID == nil
            && record.reservationID == nil
            && !record.deliveredRunIDs.contains(runID)
    }
}

/// Parent run attempt a tool result is returned to, captured when the tool starts executing
/// (plan §6.2). A result only delivers notices while this exact attempt is still the parent's
/// active one: a process run ID alone cannot tell an earlier turn's late completion (Claude keeps
/// its process run ID across turns) from the current turn.
struct AgentDelegatedQuestionDeliveryTarget: Equatable, Hashable {
    let parentRunID: UUID
    let runAttemptID: UUID
}

/// One tool-result handoff of delegated-question notices (plan §6.2). The payloads are attached
/// to exactly one result; the notices stay pending until the reservation settles at the final
/// handoff (`mcpSettleDelegatedQuestionNoticeReservation`: revalidate, then commit or strip and
/// release) or releases (the handler exited before handoff).
struct AgentDelegatedQuestionNoticeReservation: Equatable {
    let id: UUID
    let target: AgentDelegatedQuestionDeliveryTarget
    /// Notices to attach to the result (empty when only covered keys were reserved).
    let payloads: [AgentDelegatedQuestionNoticePayload]
    /// Notices already visible in the result itself (an `agent_run` question snapshot);
    /// acknowledged on commit without duplicating their text.
    let coveredKeys: Set<AgentDelegatedQuestionNoticeKey>

    var parentRunID: UUID {
        target.parentRunID
    }

    /// Keys whose payloads are attached to the result under `delegated_question_notices`.
    var attachedKeys: Set<AgentDelegatedQuestionNoticeKey> {
        Set(payloads.map(\.key))
    }
}

/// One parent-banner row per pending child question (plan §6.5). Never an answer surface.
struct AgentDelegatedQuestionBannerRow: Equatable, Identifiable {
    enum Status: Equatable {
        /// The parent model has seen the notice.
        case delivered
        /// The parent is running; the notice rides on its next eligible RepoPrompt tool result.
        case awaitingNextToolResult
        /// The parent is idle; the notice is included in its next turn.
        case waitingForNextTurn
    }

    let childTabID: UUID
    let key: AgentDelegatedQuestionNoticeKey
    let childTitle: String
    let status: Status

    var id: AgentDelegatedQuestionNoticeKey {
        key
    }

    var text: String {
        let base = "Child agent '\(childTitle)' asked a question"
        switch status {
        case .delivered:
            return base + " — delivered"
        case .awaitingNextToolResult:
            return base + " — delivering with this agent's next tool result"
        case .waitingForNextTurn:
            return base + " — waiting for this agent's next turn"
        }
    }
}

struct AgentDelegatedQuestionBannerActions {
    /// Selects the child tab after verifying the question is still pending; returns an error
    /// message otherwise. Never answers anything.
    let openChild: (_ row: AgentDelegatedQuestionBannerRow) async -> String?
}

/// Sidebar legibility for delegated questions, resolved by durable session ID (plan §6.5).
struct AgentDelegatedQuestionSidebarAttention: Equatable {
    enum OwnQuestion: Equatable {
        case waitingOnParentAgent
        case needsUserAnswer
    }

    /// Pending child questions addressed to this session as the parent agent.
    var pendingChildQuestionCount = 0
    /// Of those, how many the parent model has not seen yet.
    var undeliveredChildQuestionCount = 0
    /// This session's own pending question routing, when delegated.
    var ownQuestion: OwnQuestion?

    var isEmpty: Bool {
        pendingChildQuestionCount == 0 && ownQuestion == nil
    }

    var tooltipText: String {
        var parts: [String] = []
        switch ownQuestion {
        case .waitingOnParentAgent:
            parts.append("Waiting on parent agent")
        case .needsUserAnswer:
            parts.append("Needs your answer")
        case nil:
            break
        }
        if pendingChildQuestionCount > 0 {
            let noun = pendingChildQuestionCount == 1 ? "child question" : "child questions"
            var text = "\(pendingChildQuestionCount) pending \(noun)"
            if undeliveredChildQuestionCount > 0 {
                text += " (\(undeliveredChildQuestionCount) not yet delivered)"
            }
            parts.append(text)
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
extension AgentModeViewModel {
    static let delegatedQuestionWakeSource = "delegated-question"

    // MARK: - Audience

    /// Reconciled audience for `session`'s `ask_user` (plan §6.1). Reuses the delegation lineage
    /// lookups; never guesses a parent. Remote-host projections are out of scope (unchanged).
    func delegatedQuestionAudience(
        for session: AgentTabSession,
        provenance: AgentDelegatedQuestionControllerProvenance
    ) -> AgentDelegatedQuestionAudience {
        let isControlled = isMCPControlled(tabID: session.tabID)
        guard session.remoteHost == nil else { return .user }
        guard let sessionID = session.activeAgentSessionID else {
            return isControlled ? .userFallback : .user
        }
        let parentLookup = mcpDelegationParentLookup(sessionID: sessionID)
        let parentIsLive: Bool = if case let .parent(parentSessionID) = parentLookup {
            liveDelegatedQuestionParent(parentSessionID: parentSessionID) != nil
        } else {
            false
        }
        return AgentDelegatedQuestionAudience.resolve(.init(
            isMCPControlled: isControlled,
            parentLookup: parentLookup,
            lineage: mcpDelegationLineage(for: session),
            parentIsLive: parentIsLive,
            controllerVerifiedNonAgentMode: provenance.verifies(
                currentControllerConnectionID: session.mcpControlContext?.originatingConnectionID
            )
        ))
    }

    /// The single live local record bound to `parentSessionID`; ambiguous bindings are not live.
    func liveDelegatedQuestionParent(parentSessionID: UUID) -> AgentTabSession? {
        let matches = sessions.values.filter {
            $0.activeAgentSessionID == parentSessionID && $0.remoteHost == nil
        }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    /// Controlling connection of an MCP-controlled tab, used to verify an external controller.
    func mcpControllerConnectionID(tabID: UUID) -> UUID? {
        sessions[tabID]?.mcpControlContext?.originatingConnectionID
    }

    // MARK: - Install and reconcile

    /// Called synchronously once `pendingAskUser` and the continuation exist. Returns the audience;
    /// the caller starts the normal timeout unless the audience pauses it.
    @discardableResult
    func installDelegatedQuestionRouting(
        for session: AgentTabSession,
        interactionID: UUID,
        provenance: AgentDelegatedQuestionControllerProvenance
    ) -> AgentDelegatedQuestionAudience {
        guard var pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              session.askUserContinuation != nil
        else {
            return .user
        }
        let audience = delegatedQuestionAudience(for: session, provenance: provenance)
        switch audience {
        case .user, .externalController:
            return audience
        case .userFallback:
            pending.delegatedRouting = .userFallback
            session.pendingAskUser = pending
        case let .parentAgent(parentSessionID):
            guard let childSessionID = session.activeAgentSessionID,
                  let parent = liveDelegatedQuestionParent(parentSessionID: parentSessionID)
            else {
                pending.delegatedRouting = .userFallback
                session.pendingAskUser = pending
                publishDelegatedQuestionChange(childTabIDs: [session.tabID])
                return .userFallback
            }
            pending.delegatedRouting = .awaitingParentAgent
            session.pendingAskUser = pending
            // No timeout runs while the parent chain owns the question (§6.4).
            invalidatePendingAskUserTimeout(for: session)
            let key = AgentDelegatedQuestionNoticeKey(childSessionID: childSessionID, interactionID: interactionID)
            delegatedQuestionNotices.records[key] = AgentDelegatedQuestionNoticeRegistry.Record(
                key: key,
                childTabID: session.tabID,
                parentSessionID: parentSessionID,
                parentTabID: parent.tabID,
                askedAt: pending.interaction.askedAt
            )
        }
        publishDelegatedQuestionChange(childTabIDs: [session.tabID])
        wakeParentsForDelegatedQuestionsIfNeeded()
        return audience
    }

    /// Synchronous lifecycle reconcile (§6.2): drops records whose question resolved or whose
    /// child went away, falls back to the user with a fresh timeout when the parent route is no
    /// longer valid, and wakes parents with deliverable notices. Idempotent and cheap when empty.
    func reconcileDelegatedQuestionNotices(trigger: String) {
        guard !delegatedQuestionNotices.isEmpty, !delegatedQuestionNotices.isReconciling else { return }
        delegatedQuestionNotices.isReconciling = true
        defer { delegatedQuestionNotices.isReconciling = false }

        var changedChildTabIDs = Set<UUID>()
        var changed = false
        for (key, record) in delegatedQuestionNotices.records {
            guard let child = delegatedQuestionPendingChild(for: record),
                  var pending = child.pendingAskUser
            else {
                delegatedQuestionNotices.records.removeValue(forKey: key)
                changed = true
                continue
            }
            let audience = delegatedQuestionAudience(for: child, provenance: .unverified)
            if case let .parentAgent(parentSessionID) = audience, parentSessionID == record.parentSessionID {
                continue
            }
            // The parent route is gone: the user answers in the child tab, with a fresh timeout
            // from now (§6.4). The route never re-pauses afterwards.
            delegatedQuestionNotices.records.removeValue(forKey: key)
            pending.delegatedRouting = .userFallback
            child.pendingAskUser = pending
            schedulePendingAskUserTimeout(
                for: child,
                interactionID: key.interactionID,
                timeoutSeconds: pending.interaction.timeoutSeconds,
                startedAt: Date()
            )
            Self.steeringDebugLog("[DelegatedQuestion] fallback to user trigger=\(trigger) child=\(key.childSessionID) interaction=\(key.interactionID)")
            changedChildTabIDs.insert(child.tabID)
            changed = true
        }
        for (parentTabID, staged) in delegatedQuestionNotices.stagedTurnNoticesByParentTabID {
            // A stage whose parent tab is gone never reaches the model: release it so the notice
            // stays deliverable elsewhere. A started run that stopped without reporting a send
            // outcome is not proof of non-delivery: hold the stage as unknown (no re-delivery,
            // no acknowledgement) until its own late outcome or the question's resolution.
            let parent = sessions[parentTabID]
            if parent == nil {
                rollBackStagedDelegatedQuestionNotices(staged, parentTabID: parentTabID)
                changed = true
            } else if staged.phase == .awaitingSendOutcome, parent?.runState.isActive != true {
                delegatedQuestionNotices.holdTurnStage(staged, parentTabID: parentTabID, phase: .deliveryUnknown)
                Self.steeringDebugLog("[DelegatedQuestion] next-turn stage delivery unknown tab=\(parentTabID) stage=\(staged.stageID)")
                changed = true
            }
        }
        for (stageID, held) in delegatedQuestionNotices.heldTurnNoticesByStageID {
            let parentTabID = held.parentTabID
            let holdsLiveRecord = held.notice.keys.contains {
                delegatedQuestionNotices.records[$0]?.stagedParentTabID == parentTabID
            }
            if !holdsLiveRecord {
                // Every question it carried resolved (or fell back): nothing left to settle.
                delegatedQuestionNotices.heldTurnNoticesByStageID.removeValue(forKey: stageID)
                changed = true
            } else if sessions[parentTabID] == nil {
                rollBackStagedDelegatedQuestionNotices(held.notice, parentTabID: parentTabID)
                changed = true
            } else if held.notice.phase == .awaitingSendOutcome, sessions[parentTabID]?.runState.isActive != true {
                delegatedQuestionNotices.setTurnStagePhase(.deliveryUnknown, stageID: stageID, parentTabID: parentTabID)
                changed = true
            }
        }
        for (reservationID, reservation) in delegatedQuestionNotices.reservations {
            // A tool-result handoff that can no longer reach its run attempt (the run ended, or a
            // new turn replaced the attempt, or every reserved question resolved) is released
            // rather than left pending forever. Its final settlement then strips the notices.
            let holdsLiveRecord = reservation.keys.contains {
                delegatedQuestionNotices.records[$0]?.reservationID == reservationID
            }
            let attemptIsCurrent = delegatedQuestionParentSession(for: reservation.target) != nil
            guard !holdsLiveRecord || !attemptIsCurrent else { continue }
            delegatedQuestionNotices.reservations.removeValue(forKey: reservationID)
            releaseDelegatedQuestionReservationKeys(reservation, reservationID: reservationID)
            changed = true
        }
        if changed {
            publishDelegatedQuestionChange(childTabIDs: changedChildTabIDs)
        }
        wakeParentsForDelegatedQuestionsIfNeeded()
    }

    /// Cheap relevance gate for high-frequency binding updates.
    func reconcileDelegatedQuestionNoticesIfRelevant(to session: AgentTabSession) {
        guard !delegatedQuestionNotices.isEmpty, !delegatedQuestionNotices.isReconciling else { return }
        let tabID = session.tabID
        let sessionID = session.activeAgentSessionID
        let isRelevant = delegatedQuestionNotices.records.values.contains { record in
            record.childTabID == tabID || record.parentTabID == tabID || record.parentSessionID == sessionID
        } || delegatedQuestionNotices.stagedTurnNoticesByParentTabID[tabID] != nil
            || delegatedQuestionNotices.heldTurnNoticesByStageID.values.contains { $0.parentTabID == tabID }
        guard isRelevant else { return }
        reconcileDelegatedQuestionNotices(trigger: "bindings")
    }

    private func delegatedQuestionPendingChild(
        for record: AgentDelegatedQuestionNoticeRegistry.Record
    ) -> AgentTabSession? {
        guard let child = sessions[record.childTabID],
              child.activeAgentSessionID == record.key.childSessionID,
              child.remoteHost == nil,
              let pending = child.pendingAskUser,
              pending.interaction.id == record.key.interactionID,
              child.askUserContinuation != nil
        else {
            return nil
        }
        return child
    }

    private func delegatedQuestionChildName(_ child: AgentTabSession, childSessionID: UUID) -> String {
        if let name = workspaceManager?.composeTabName(with: child.tabID) {
            return name
        }
        if let name = ownerValidatedSessionIndex[childSessionID]?.name {
            return name
        }
        return "Agent Session"
    }

    private func delegatedQuestionPayload(
        for record: AgentDelegatedQuestionNoticeRegistry.Record
    ) -> AgentDelegatedQuestionNoticePayload? {
        guard let child = delegatedQuestionPendingChild(for: record),
              let pending = child.pendingAskUser
        else {
            return nil
        }
        return AgentDelegatedQuestionNoticePayload(
            childSessionID: record.key.childSessionID,
            childSessionName: delegatedQuestionChildName(child, childSessionID: record.key.childSessionID),
            interaction: pending.interaction
        )
    }

    private func delegatedQuestionRecordsSorted(
        parentSessionID: UUID
    ) -> [AgentDelegatedQuestionNoticeRegistry.Record] {
        delegatedQuestionNotices.records.values
            .filter { $0.parentSessionID == parentSessionID }
            .sorted { lhs, rhs in
                if lhs.askedAt != rhs.askedAt { return lhs.askedAt < rhs.askedAt }
                return lhs.key.interactionID.uuidString < rhs.key.interactionID.uuidString
            }
    }

    /// The live parent record whose *active* run is `runID` and whose identity is a notice parent.
    /// An idle parent that merely retains its process run ID (Claude) is never a destination.
    private func delegatedQuestionParentSession(forRunID runID: UUID) -> AgentTabSession? {
        let matches = sessions.values.filter { $0.runID == runID && $0.remoteHost == nil }
        guard matches.count == 1, let parent = matches.first,
              parent.runState.isActive,
              parent.activeRunAttemptID != nil,
              let parentSessionID = parent.activeAgentSessionID,
              liveDelegatedQuestionParent(parentSessionID: parentSessionID) === parent
        else {
            return nil
        }
        return parent
    }

    /// The live parent whose active run and run attempt still match `target`.
    private func delegatedQuestionParentSession(for target: AgentDelegatedQuestionDeliveryTarget) -> AgentTabSession? {
        guard let parent = delegatedQuestionParentSession(forRunID: target.parentRunID),
              parent.activeRunAttemptID == target.runAttemptID
        else {
            return nil
        }
        return parent
    }

    // MARK: - Wake (§6.2 "Wake early")

    /// Wakes every bounded wait owned by a parent's active run once per (notice, run attempt).
    private func wakeParentsForDelegatedQuestionsIfNeeded() {
        var runIDsToWake = Set<UUID>()
        for (key, record) in delegatedQuestionNotices.records {
            guard let parent = liveDelegatedQuestionParent(parentSessionID: record.parentSessionID),
                  parent.runState.isActive,
                  let runID = parent.runID,
                  let runAttemptID = parent.activeRunAttemptID,
                  delegatedQuestionNotices.isDeliverable(record, toRunID: runID),
                  !record.wokenRunAttemptIDs.contains(runAttemptID)
            else {
                continue
            }
            delegatedQuestionNotices.records[key]?.wokenRunAttemptIDs.insert(runAttemptID)
            runIDsToWake.insert(runID)
        }
        for runID in runIDsToWake {
            Self.steeringDebugLog("[DelegatedQuestion] wake parent run runID=\(runID)")
            Task { @MainActor [weak self] in
                await self?.wakeMCPWaitersForDelegatedQuestion(parentRunID: runID)
            }
        }
    }

    // MARK: - MCP handoff API (called by MCPServerViewModel / AgentRunMCPToolService)

    /// Captures the parent run attempt that a tool executing for `parentRunID` returns its result
    /// to (plan §6.2). Nil unless `parentRunID` is the active run of a live notice parent. Callers
    /// capture this when the tool starts, so a result completing after its turn ended (or after a
    /// new turn began under a reused process run ID) can never deliver a notice.
    func mcpDelegatedQuestionDeliveryTarget(parentRunID: UUID) -> AgentDelegatedQuestionDeliveryTarget? {
        guard let parent = delegatedQuestionParentSession(forRunID: parentRunID),
              let runAttemptID = parent.activeRunAttemptID
        else {
            return nil
        }
        return AgentDelegatedQuestionDeliveryTarget(parentRunID: parentRunID, runAttemptID: runAttemptID)
    }

    /// True when a pending child question addressed to the parent whose active run is
    /// `parentRunID` has not been delivered to (or acknowledged by) that run. Children in
    /// `excludingChildSessionIDs` (already covered by the caller's wait) are ignored.
    func mcpHasDeliverableDelegatedQuestionNotices(
        parentRunID: UUID,
        excludingChildSessionIDs: Set<UUID>
    ) -> Bool {
        guard !delegatedQuestionNotices.records.isEmpty,
              let parent = delegatedQuestionParentSession(forRunID: parentRunID),
              let parentSessionID = parent.activeAgentSessionID
        else {
            return false
        }
        return delegatedQuestionNotices.records.values.contains { record in
            record.parentSessionID == parentSessionID
                && !excludingChildSessionIDs.contains(record.key.childSessionID)
                && delegatedQuestionNotices.isDeliverable(record, toRunID: parentRunID)
                && delegatedQuestionPendingChild(for: record) != nil
        }
    }

    /// Reserves the notices for one tool result being returned to `target` (plan §6.2). Requires
    /// the captured parent run attempt to still be the active one and revalidates each pending
    /// interaction. `coveredKeys` (questions already visible in the result) are reserved without a
    /// payload; every other deliverable notice is reserved and its payload returned for attachment.
    /// Nothing is acknowledged here: the connection handler settles the reservation at its final
    /// handoff (`mcpSettleDelegatedQuestionNoticeReservation`) and releases it on any other exit,
    /// so cancellation never consumes a notice.
    func mcpReserveDelegatedQuestionNotices(
        target: AgentDelegatedQuestionDeliveryTarget,
        coveredKeys: Set<AgentDelegatedQuestionNoticeKey>
    ) -> AgentDelegatedQuestionNoticeReservation? {
        guard !delegatedQuestionNotices.records.isEmpty,
              let parent = delegatedQuestionParentSession(for: target),
              let parentSessionID = parent.activeAgentSessionID
        else {
            return nil
        }
        let parentRunID = target.parentRunID
        var payloads: [AgentDelegatedQuestionNoticePayload] = []
        var reservedCoveredKeys = Set<AgentDelegatedQuestionNoticeKey>()
        var keys = Set<AgentDelegatedQuestionNoticeKey>()
        for record in delegatedQuestionRecordsSorted(parentSessionID: parentSessionID) {
            let key = record.key
            if coveredKeys.contains(key) {
                guard record.stagedParentTabID == nil,
                      record.reservationID == nil,
                      !record.acknowledged || !record.deliveredRunIDs.contains(parentRunID),
                      delegatedQuestionPendingChild(for: record) != nil
                else {
                    continue
                }
                reservedCoveredKeys.insert(key)
                keys.insert(key)
                continue
            }
            guard delegatedQuestionNotices.isDeliverable(record, toRunID: parentRunID),
                  let payload = delegatedQuestionPayload(for: record)
            else {
                continue
            }
            payloads.append(payload)
            keys.insert(key)
        }
        guard !keys.isEmpty else { return nil }
        let reservationID = UUID()
        for key in keys {
            delegatedQuestionNotices.records[key]?.reservationID = reservationID
        }
        delegatedQuestionNotices.reservations[reservationID] = .init(
            target: target,
            keys: keys,
            coveredKeys: reservedCoveredKeys
        )
        Self.steeringDebugLog("[DelegatedQuestion] reserve id=\(reservationID) parentRunID=\(parentRunID) attempt=\(target.runAttemptID) attached=\(payloads.count) covered=\(reservedCoveredKeys.count)")
        return AgentDelegatedQuestionNoticeReservation(
            id: reservationID,
            target: target,
            payloads: payloads,
            coveredKeys: reservedCoveredKeys
        )
    }

    /// Final handoff boundary of one tool-result reservation (plan §6.2). The connection handler
    /// calls it after the last suspending completion processing (completion observers recorded
    /// the unannotated result) and formats and returns the settled value without suspending
    /// again, so the returned response and the parent transcript carry exactly the notices
    /// committed here.
    /// - `handOff == false` (the handler was cancelled before settling), a calling task that is
    ///   cancelled by the time this main-actor step runs, an unknown or already-released
    ///   reservation, or a captured parent attempt that is no longer active: every attached
    ///   notice is removed from `value` and every held notice is released, so a cancelled result
    ///   never both carries a notice and leaves it pending.
    /// - Otherwise each notice is revalidated (still held by this reservation, question still
    ///   pending): valid notices are stamped and acknowledged, and the attached ones are recorded
    ///   synchronously as a labeled note in the parent transcript; notices that resolved or lost
    ///   the reservation meanwhile are removed from `value` and never recorded. Committed covered
    ///   questions (already visible in the result) are recorded as a separate persistence-only
    ///   note with their complete content; `value` is never changed for them.
    /// Returns the value to hand off.
    func mcpSettleDelegatedQuestionNoticeReservation(
        _ reservationID: UUID,
        attachedKeys: Set<AgentDelegatedQuestionNoticeKey>,
        value: Value,
        handOff: Bool
    ) -> Value {
        // The handler sampled `handOff` before suspending into this main-actor step. A
        // cancellation that landed during that hop must still strip and release, so the calling
        // (handler) task is rechecked here, at the commit point, with the reservation and attempt.
        let handOff = handOff && !Task.isCancelled
        guard let reservation = delegatedQuestionNotices.reservations.removeValue(forKey: reservationID) else {
            Self.steeringDebugLog("[DelegatedQuestion] settle id=\(reservationID) reservation gone; stripped=\(attachedKeys.count)")
            return AgentDelegatedQuestionNoticeWire.removing(attachedKeys, from: value)
        }
        let attemptIsCurrent = delegatedQuestionParentSession(for: reservation.target) != nil
        var committedKeys = Set<AgentDelegatedQuestionNoticeKey>()
        var releasedKeys = Set<AgentDelegatedQuestionNoticeKey>()
        for key in reservation.keys {
            guard let record = delegatedQuestionNotices.records[key],
                  record.reservationID == reservationID
            else {
                continue
            }
            if handOff, attemptIsCurrent, delegatedQuestionPendingChild(for: record) != nil {
                committedKeys.insert(key)
            } else {
                releasedKeys.insert(key)
            }
        }
        for key in committedKeys {
            delegatedQuestionNotices.records[key]?.reservationID = nil
            delegatedQuestionNotices.records[key]?.deliveredRunIDs.insert(reservation.parentRunID)
            delegatedQuestionNotices.records[key]?.acknowledged = true
        }
        if !releasedKeys.isEmpty {
            releaseDelegatedQuestionReservationKeys(
                .init(target: reservation.target, keys: releasedKeys),
                reservationID: reservationID
            )
        }
        let strippedKeys = attachedKeys.subtracting(committedKeys)
        let settled = AgentDelegatedQuestionNoticeWire.removing(strippedKeys, from: value)
        // Completion observers recorded the unannotated result, so the committed notices reach
        // the parent transcript only here, in the same main-actor step that commits them.
        if let parent = delegatedQuestionParentSession(for: reservation.target) {
            if let noticeText = AgentDelegatedQuestionNoticeWire.renderedText(
                for: attachedKeys.intersection(committedKeys),
                in: settled
            ) {
                appendDelegatedQuestionNoticeNote(noticeText, session: parent)
            }
            appendDelegatedQuestionCoveredRecordNote(
                for: committedKeys.intersection(reservation.coveredKeys),
                parent: parent
            )
        }
        Self.steeringDebugLog("[DelegatedQuestion] settle id=\(reservationID) handOff=\(handOff) attemptCurrent=\(attemptIsCurrent) committed=\(committedKeys.count) released=\(releasedKeys.count) stripped=\(strippedKeys.count)")
        publishDelegatedQuestionChange(childTabIDs: [])
        if !releasedKeys.isEmpty {
            wakeParentsForDelegatedQuestionsIfNeeded()
        }
        return settled
    }

    /// Commits a reservation for a caller without a connection-handler handoff boundary (the
    /// result is returned synchronously after reservation). Stamps the parent run and
    /// acknowledges. Unknown or already-released reservations are a no-op.
    func mcpCommitDelegatedQuestionNoticeReservation(_ reservationID: UUID) {
        guard let reservation = delegatedQuestionNotices.reservations.removeValue(forKey: reservationID) else { return }
        var committedCoveredKeys = Set<AgentDelegatedQuestionNoticeKey>()
        for key in reservation.keys where delegatedQuestionNotices.records[key]?.reservationID == reservationID {
            delegatedQuestionNotices.records[key]?.reservationID = nil
            delegatedQuestionNotices.records[key]?.deliveredRunIDs.insert(reservation.parentRunID)
            delegatedQuestionNotices.records[key]?.acknowledged = true
            if reservation.coveredKeys.contains(key) {
                committedCoveredKeys.insert(key)
            }
        }
        if let parent = delegatedQuestionParentSession(for: reservation.target) {
            appendDelegatedQuestionCoveredRecordNote(for: committedCoveredKeys, parent: parent)
        }
        Self.steeringDebugLog("[DelegatedQuestion] commit id=\(reservationID) parentRunID=\(reservation.parentRunID) notices=\(reservation.keys.count)")
        publishDelegatedQuestionChange(childTabIDs: [])
    }

    /// The reserved result was cancelled or failed before handoff: the notices become deliverable
    /// again (to the same run) and a still-waiting parent may be woken again.
    func mcpReleaseDelegatedQuestionNoticeReservation(_ reservationID: UUID) {
        guard let reservation = delegatedQuestionNotices.reservations.removeValue(forKey: reservationID) else { return }
        releaseDelegatedQuestionReservationKeys(reservation, reservationID: reservationID)
        Self.steeringDebugLog("[DelegatedQuestion] release id=\(reservationID) parentRunID=\(reservation.parentRunID) notices=\(reservation.keys.count)")
        publishDelegatedQuestionChange(childTabIDs: [])
        wakeParentsForDelegatedQuestionsIfNeeded()
    }

    private func releaseDelegatedQuestionReservationKeys(
        _ reservation: AgentDelegatedQuestionNoticeRegistry.Reservation,
        reservationID: UUID
    ) {
        for key in reservation.keys where delegatedQuestionNotices.records[key]?.reservationID == reservationID {
            delegatedQuestionNotices.records[key]?.reservationID = nil
            delegatedQuestionNotices.records[key]?.wokenRunAttemptIDs.remove(reservation.target.runAttemptID)
        }
    }

    /// Reserve and immediately commit for the parent's current attempt, for callers without a
    /// transport handoff boundary. Callers must attach every returned payload to the result.
    func mcpHandOffDelegatedQuestionNotices(
        parentRunID: UUID,
        coveredKeys: Set<AgentDelegatedQuestionNoticeKey>
    ) -> [AgentDelegatedQuestionNoticePayload] {
        guard let target = mcpDelegatedQuestionDeliveryTarget(parentRunID: parentRunID),
              let reservation = mcpReserveDelegatedQuestionNotices(target: target, coveredKeys: coveredKeys)
        else {
            return []
        }
        mcpCommitDelegatedQuestionNoticeReservation(reservation.id)
        return reservation.payloads
    }

    // MARK: - Idle parent: next turn's first input (§6.2, owner decision 2)

    /// Prepends a labeled runtime notice block to the provider-facing first input of a parent's
    /// next turn. The user's message text and transcript item are never modified. The notices
    /// stay unacknowledged until `recordDelegatedQuestionNoticeSendOutcome` confirms the send of
    /// this exact stage. Notices reserved by an open tool-result handoff are never staged.
    func stageDelegatedQuestionNoticesForTurnInput(_ text: String, session: AgentTabSession) -> String {
        guard !delegatedQuestionNotices.records.isEmpty || delegatedQuestionNotices.stagedTurnNoticesByParentTabID[session.tabID] != nil else {
            return text
        }
        // A new first-input assembly supersedes an unresolved earlier stage for this tab. Its input
        // may still reach the provider, so it is held (never rolled back and re-carried) until its
        // own outcome settles it.
        if let earlier = delegatedQuestionNotices.stagedTurnNoticesByParentTabID[session.tabID] {
            delegatedQuestionNotices.holdTurnStage(earlier, parentTabID: session.tabID, phase: earlier.phase)
        }
        guard session.remoteHost == nil,
              let parentSessionID = session.activeAgentSessionID,
              liveDelegatedQuestionParent(parentSessionID: parentSessionID) === session
        else {
            return text
        }
        let runID = session.runID
        var keys = Set<AgentDelegatedQuestionNoticeKey>()
        var payloads: [AgentDelegatedQuestionNoticePayload] = []
        for record in delegatedQuestionRecordsSorted(parentSessionID: parentSessionID) {
            guard !record.acknowledged,
                  record.stagedParentTabID == nil,
                  record.reservationID == nil,
                  runID.map({ !record.deliveredRunIDs.contains($0) }) ?? true,
                  let payload = delegatedQuestionPayload(for: record)
            else {
                continue
            }
            keys.insert(record.key)
            payloads.append(payload)
        }
        guard let noticeText = AgentDelegatedQuestionNoticeWire.renderedText(for: payloads) else {
            return text
        }
        for key in keys {
            delegatedQuestionNotices.records[key]?.stagedParentTabID = session.tabID
        }
        delegatedQuestionNotices.stagedTurnNoticesByParentTabID[session.tabID] = .init(
            stageID: UUID(),
            keys: keys,
            text: noticeText
        )
        publishDelegatedQuestionChange(childTabIDs: [])
        return Self.delegatedQuestionTurnInput(noticeText: noticeText, providerText: text)
    }

    /// Identity of the stage currently held for `tabID`, captured by `startAgentRun` right after
    /// staging so its settle step only ever resolves its own stage.
    func delegatedQuestionTurnStageID(forTabID tabID: UUID) -> UUID? {
        delegatedQuestionNotices.stagedTurnNoticesByParentTabID[tabID]?.stageID
    }

    /// Settles a next-turn stage once `runService.startRun` has returned. A stage the provider send
    /// outcome already committed or rolled back is gone. `startDisposition` is the start's own
    /// verified result (`AgentModeViewModel.stagedInputStartDisposition`): `notSent` (failed,
    /// cancelled, stale) releases the stage so the notice stays deliverable; `deliveryUnknown`
    /// holds it; `nil` means the runner owns the outcome, so the stage awaits it while the run is
    /// active and is held as unknown otherwise (an inactive run alone is not proof of non-delivery).
    func settleDelegatedQuestionTurnStageAfterRunStart(
        _ stageID: UUID?,
        session: AgentTabSession,
        startDisposition: AgentStagedInputDisposition?
    ) {
        guard let stageID,
              let staged = delegatedQuestionNotices.turnStage(stageID: stageID, parentTabID: session.tabID),
              staged.phase == .startInFlight
        else {
            return
        }
        if let startDisposition {
            recordDelegatedQuestionNoticeSendOutcome(for: session, stageID: stageID, disposition: startDisposition)
            if startDisposition == .notSent {
                Self.steeringDebugLog("[DelegatedQuestion] next-turn stage released after start without send tab=\(session.tabID)")
                wakeParentsForDelegatedQuestionsIfNeeded()
            }
        } else if session.runState.isActive {
            // The start just returned: its run is the carrier.
            delegatedQuestionNotices.setTurnStagePhase(
                .awaitingSendOutcome,
                stageID: stageID,
                parentTabID: session.tabID,
                carryingRunID: delegatedQuestionCarryingRunID(staged, session: session)
            )
        } else {
            recordDelegatedQuestionNoticeSendOutcome(for: session, stageID: stageID, disposition: .deliveryUnknown)
        }
    }

    /// Run whose input carried `staged`: the captured carrying run, else the session's run while the
    /// stage is still the tab's current in-flight start (that start's run is the carrier). `nil`
    /// otherwise, so a late outcome never stamps a successor run.
    private func delegatedQuestionCarryingRunID(
        _ staged: AgentDelegatedQuestionNoticeRegistry.StagedTurnNotice,
        session: AgentTabSession
    ) -> UUID? {
        if let carryingRunID = staged.carryingRunID { return carryingRunID }
        guard staged.phase == .startInFlight,
              delegatedQuestionNotices.stagedTurnNoticesByParentTabID[session.tabID]?.stageID == staged.stageID
        else { return nil }
        return session.runID
    }

    /// Wraps already-neutralized notice text (`AgentDelegatedQuestionNoticePayload.renderedText`)
    /// ahead of the provider text; child-controlled text cannot close this wrapper.
    static func delegatedQuestionTurnInput(noticeText: String, providerText: String) -> String {
        delegatedQuestionTurnInputBlock(noticeText: noticeText) + providerText
    }

    /// The exact runtime block (with its trailing separator) that `delegatedQuestionTurnInput`
    /// prepends for `noticeText`. A released stage removes exactly this block from queued copies.
    static func delegatedQuestionTurnInputBlock(noticeText: String) -> String {
        let tag = AgentDelegatedQuestionNoticeWire.runtimeNoticeTagName
        let body = AgentDelegatedQuestionNoticeWire.neutralizingRuntimeNoticeDelimiters(noticeText)
        return "<\(tag) kind=\"delegated_child_questions\">\n\(body)\n</\(tag)>\n\n"
    }

    /// Verified two-state outcome (`didSend` true → `sent`, false → `notSent`).
    func recordDelegatedQuestionNoticeSendOutcome(for session: AgentTabSession, stageID: UUID?, didSend: Bool) {
        recordDelegatedQuestionNoticeSendOutcome(for: session, stageID: stageID, disposition: didSend ? .sent : .notSent)
    }

    /// Settles exactly the stage `stageID` (current or held) once the stage-delivery outcome of
    /// the input that carried it is known: `sent` commits once (stamp with the parent's run,
    /// acknowledge, persist a labeled note); `notSent` releases it (and strips it from queued Codex
    /// copies); `deliveryUnknown` holds it, neither acknowledged nor released. A late outcome of an
    /// earlier stage never commits or releases a newer stage. A nil `stageID` (the input carried
    /// no notices) is a no-op.
    func recordDelegatedQuestionNoticeSendOutcome(
        for session: AgentTabSession,
        stageID: UUID?,
        disposition: AgentStagedInputDisposition
    ) {
        guard let stageID,
              let staged = delegatedQuestionNotices.turnStage(stageID: stageID, parentTabID: session.tabID)
        else {
            return
        }
        switch disposition {
        case .notSent:
            rollBackStagedDelegatedQuestionNotices(staged, parentTabID: session.tabID)
            publishDelegatedQuestionChange(childTabIDs: [])
            return
        case .deliveryUnknown:
            guard staged.phase != .deliveryUnknown else { return }
            var held = staged
            held.carryingRunID = delegatedQuestionCarryingRunID(staged, session: session)
            delegatedQuestionNotices.holdTurnStage(held, parentTabID: session.tabID, phase: .deliveryUnknown)
            Self.steeringDebugLog("[DelegatedQuestion] next-turn stage delivery unknown tab=\(session.tabID) stage=\(stageID)")
            publishDelegatedQuestionChange(childTabIDs: [])
            return
        case .sent:
            break
        }
        // The carrying run, never a successor that is current when a late outcome arrives.
        let runID = delegatedQuestionCarryingRunID(staged, session: session)
        delegatedQuestionNotices.removeTurnStage(stageID: stageID, parentTabID: session.tabID)
        for key in staged.keys {
            guard var record = delegatedQuestionNotices.records[key],
                  record.stagedParentTabID == session.tabID
            else {
                continue
            }
            record.stagedParentTabID = nil
            if let runID {
                record.deliveredRunIDs.insert(runID)
            }
            record.acknowledged = true
            delegatedQuestionNotices.records[key] = record
        }
        appendDelegatedQuestionNoticeNote(staged.text, session: session)
        Self.steeringDebugLog("[DelegatedQuestion] next-turn input delivered tab=\(session.tabID) stage=\(stageID) notices=\(staged.keys.count) runID=\(runID?.uuidString ?? "nil")")
        publishDelegatedQuestionChange(childTabIDs: [])
    }

    /// Persists delivered notice text (what the model saw) as a labeled, ID-bearing runtime note
    /// in the parent transcript. Live state stays in the child's pendingAskUser, so this note is
    /// never read back as current state.
    private func appendDelegatedQuestionNoticeNote(_ text: String, session: AgentTabSession) {
        session.appendItem(.system(text, sequenceIndex: session.nextSequenceIndex))
        session.isDirty = true
        scheduleSave(for: session.tabID)
        requestUIRefresh(tabID: session.tabID)
    }

    /// Records committed covered questions (already visible in an `agent_run` result snapshot)
    /// as one labeled, persistence-only note with their complete content, resolved from the
    /// still-pending interactions. The storage summary of the `agent_run` result keeps only the
    /// interaction identity, so without this note the persisted parent history would lose the
    /// question the parent was handed. The returned result is never changed.
    private func appendDelegatedQuestionCoveredRecordNote(
        for keys: Set<AgentDelegatedQuestionNoticeKey>,
        parent: AgentTabSession
    ) {
        guard !keys.isEmpty, let parentSessionID = parent.activeAgentSessionID else { return }
        let payloads = delegatedQuestionRecordsSorted(parentSessionID: parentSessionID)
            .filter { keys.contains($0.key) }
            .compactMap { delegatedQuestionPayload(for: $0) }
        guard let recordText = AgentDelegatedQuestionNoticeWire.coveredRecordText(for: payloads) else { return }
        appendDelegatedQuestionNoticeNote(recordText, session: parent)
    }

    /// Stage and commit in one step for inputs delivered synchronously to a waiting provider
    /// (instruction-continuation resume and queued instructions): returning the text is the
    /// handoff, so the stage created here commits immediately.
    func deliverDelegatedQuestionNoticesWithImmediateInput(_ text: String, session: AgentTabSession) -> String {
        let staged = stageDelegatedQuestionNoticesForTurnInput(text, session: session)
        guard staged != text else { return staged }
        recordDelegatedQuestionNoticeSendOutcome(
            for: session,
            stageID: delegatedQuestionTurnStageID(forTabID: session.tabID),
            disposition: .sent
        )
        return staged
    }

    private func rollBackStagedDelegatedQuestionNotices(
        _ staged: AgentDelegatedQuestionNoticeRegistry.StagedTurnNotice,
        parentTabID: UUID
    ) {
        delegatedQuestionNotices.removeTurnStage(stageID: staged.stageID, parentTabID: parentTabID)
        for key in staged.keys where delegatedQuestionNotices.records[key]?.stagedParentTabID == parentTabID {
            delegatedQuestionNotices.records[key]?.stagedParentTabID = nil
        }
        removeReleasedStageBlockFromQueuedCodexFallbacks(staged, parentTabID: parentTabID)
    }

    /// A released stage's notices are deliverable again, so no queued copy of the input that
    /// carried them may still deliver them. A Codex `.queuedFallback` keeps the already assembled
    /// provider text, so this removes exactly the released stage's runtime block from every queued
    /// (not yet claimed) fallback entry of the parent tab. The user's text, context, and
    /// attachments stay unchanged, and the notices reach the parent only through a later delivery
    /// that acknowledges them.
    private func removeReleasedStageBlockFromQueuedCodexFallbacks(
        _ staged: AgentDelegatedQuestionNoticeRegistry.StagedTurnNotice,
        parentTabID: UUID
    ) {
        guard let session = sessions[parentTabID], !session.codexFallbackQueue.isEmpty else { return }
        let block = Self.delegatedQuestionTurnInputBlock(noticeText: staged.text)
        var strippedQueueIDs: [UUID] = []
        for index in session.codexFallbackQueue.indices {
            guard let range = session.codexFallbackQueue[index].providerText.range(of: block) else { continue }
            session.codexFallbackQueue[index].providerText.removeSubrange(range)
            // A fallback queued without a composer context restores its provider text as the draft.
            if let draftRange = session.codexFallbackQueue[index].draftText.range(of: block) {
                session.codexFallbackQueue[index].draftText.removeSubrange(draftRange)
            }
            strippedQueueIDs.append(session.codexFallbackQueue[index].id)
        }
        guard !strippedQueueIDs.isEmpty else { return }
        Self.steeringDebugLog("[DelegatedQuestion] released stage=\(staged.stageID) removed from queued Codex fallback tab=\(parentTabID) queueIDs=\(strippedQueueIDs.map(\.uuidString))")
    }

    // MARK: - Presentation (§6.5)

    func delegatedQuestionBannerRows(forParentTabID tabID: UUID?) -> [AgentDelegatedQuestionBannerRow] {
        guard let tabID,
              !delegatedQuestionNotices.records.isEmpty,
              let parent = sessions[tabID],
              let parentSessionID = parent.activeAgentSessionID
        else {
            return []
        }
        let isParentRunning = parent.runState.isActive && parent.runState != .waitingForUser
        return delegatedQuestionRecordsSorted(parentSessionID: parentSessionID).compactMap { record in
            guard let child = delegatedQuestionPendingChild(for: record) else { return nil }
            let status: AgentDelegatedQuestionBannerRow.Status = if record.acknowledged {
                .delivered
            } else if isParentRunning {
                .awaitingNextToolResult
            } else {
                .waitingForNextTurn
            }
            return AgentDelegatedQuestionBannerRow(
                childTabID: record.childTabID,
                key: record.key,
                childTitle: delegatedQuestionChildName(child, childSessionID: record.key.childSessionID),
                status: status
            )
        }
    }

    func delegatedQuestionSidebarAttentionBySessionID() -> [UUID: AgentDelegatedQuestionSidebarAttention] {
        var result: [UUID: AgentDelegatedQuestionSidebarAttention] = [:]
        for record in delegatedQuestionNotices.records.values where delegatedQuestionPendingChild(for: record) != nil {
            var attention = result[record.parentSessionID] ?? AgentDelegatedQuestionSidebarAttention()
            attention.pendingChildQuestionCount += 1
            if !record.acknowledged {
                attention.undeliveredChildQuestionCount += 1
            }
            result[record.parentSessionID] = attention
        }
        for session in sessions.values {
            guard let sessionID = session.activeAgentSessionID,
                  let pending = session.pendingAskUser
            else {
                continue
            }
            let ownQuestion: AgentDelegatedQuestionSidebarAttention.OwnQuestion? = switch pending.delegatedRouting {
            case .direct:
                nil
            case .awaitingParentAgent:
                .waitingOnParentAgent
            case .userFallback:
                .needsUserAnswer
            }
            guard let ownQuestion else { continue }
            var attention = result[sessionID] ?? AgentDelegatedQuestionSidebarAttention()
            attention.ownQuestion = ownQuestion
            result[sessionID] = attention
        }
        return result
    }

    /// Banner **Open** action: selects the child tab only while its question is still pending.
    func openDelegatedQuestionChild(_ row: AgentDelegatedQuestionBannerRow) async -> String? {
        guard let child = sessions[row.childTabID],
              child.activeAgentSessionID == row.key.childSessionID,
              child.pendingAskUser?.interaction.id == row.key.interactionID
        else {
            return "That child question is no longer pending."
        }
        await promptManager?.switchComposeTab(row.childTabID)
        return nil
    }

    private func publishDelegatedQuestionChange(childTabIDs: Set<UUID>) {
        for tabID in childTabIDs {
            guard let child = sessions[tabID] else { continue }
            updateBindingsFromSession(child)
            requestUIRefresh(tabID: tabID)
        }
        syncSidebarUIState(refresh: true, reason: .delegatedQuestion)
        syncComposerUIState()
    }
}
