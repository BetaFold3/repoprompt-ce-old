import Foundation
import MCP
import RepoPromptAgentCore

// Live pending-question persistence for this window's sessions (lossless-restart plan §E). The
// session's recovery lane owns the writes (`AgentRecoveryQuestionPersistenceController`); these
// helpers order them around the existing question producers and resolution paths.

@MainActor
extension AgentModeViewModel {
    /// Commits a new `ask_user` before it is published. Reserves the interaction first, so a
    /// concurrent request is refused, then revalidates ownership after the write. No lane: no-op
    /// (shutdown preparation still covers the question). A failed write refuses the question with
    /// the existing MCP error path; it is never shown as durably available.
    func commitAskUserForRecovery(_ pending: AgentAskUserPendingState, session: AgentTabSession, tabID: UUID) async throws {
        guard AgentRecoveryLiveQuestions.lane(for: session) != nil else { return }
        let interactionID = pending.interaction.id
        session.recoveryQuestionCreationReservation = interactionID
        let committed = await AgentRecoveryLiveQuestions.commitCreation(session: session) {
            AgentRecoveryQuestionSnapshotBuilder.snapshot(askUser: pending, context: $0)
        }
        let stillReserved = session.recoveryQuestionCreationReservation == interactionID
        if stillReserved {
            session.recoveryQuestionCreationReservation = nil
        }
        guard let (lane, result) = committed else { return }
        if case .failure = result {
            // Generic wording: storage failures can describe local paths. The lane keeps the typed
            // failure as its visible save error.
            lane.questionPersistence.forget(interactionID)
            throw MCPError.internalError("ask_user could not be saved for crash recovery, so it was not shown. Try again.")
        }
        guard stillReserved else {
            // The pending question was cancelled while its snapshot was written.
            endRecoveryQuestions(for: session, [interactionID])
            throw CancellationError()
        }
        guard sessions[tabID] === session, session.recoveryLane === lane, !lane.isRetired else {
            // Ownership expired after the commit: no continuation is installed on a new owner, and
            // the committed snapshot stays as historical data.
            throw MCPError.internalError("The session changed while ask_user was being saved.")
        }
        do {
            try rejectAskUserIfBlockingInteractionExists(in: session)
        } catch {
            endRecoveryQuestions(for: session, [interactionID])
            throw error
        }
    }

    /// Ends live questions that left the session. This window's teardown (and any lifecycle
    /// teardown cause on the session) preserves them; every other ending removes exactly them.
    func endRecoveryQuestions(for session: AgentTabSession, _ interactionIDs: Set<UUID>) {
        AgentRecoveryLiveQuestions.end(
            session: session,
            interactionIDs: interactionIDs,
            preserving: hasPreparedForWindowClose
        )
    }

    /// A validated edit of a live question's answers: its latest sanitized snapshot is written
    /// within the bounded delay.
    func noteRecoveryQuestionDraftChanged(for session: AgentTabSession, interactionID: UUID) {
        AgentRecoveryLiveQuestions.draftDidChange(session: session, interactionID: interactionID)
    }

    func isRecoveryQuestionResolutionReserved(_ session: AgentTabSession, interactionID: UUID) -> Bool {
        session.recoveryQuestionResolutionReservations.contains(interactionID)
    }

    /// Answer ordering (plan §E): flush → reply → exact-ID removal. The latest non-secret snapshot
    /// must be preserved before the existing reply runs once. Returns `false` when it is already
    /// durable (the caller replies now). Otherwise the interaction is reserved (edits, answers, and
    /// the timeout are refused) while the flush runs, bounded by the maximum draft delay, and then:
    /// - preserved: `resolve` revalidates and replies;
    /// - failed or timed out: nothing is sent. The answer, its request, and its live continuation
    ///   stay pending, the reservation is released, and the lane shows a retryable save error
    ///   (`notSent`; submitting again retries);
    /// - shutdown froze answers meanwhile: `notSent` too, with the saved snapshot kept.
    /// Timeout, decline, and cancel endings never come through here: they remove without waiting.
    func resolveAfterRecoveryQuestionFlush(
        for session: AgentTabSession,
        interactionID: UUID,
        resolve: @escaping @MainActor (AgentTabSession) -> Void,
        notSent: @escaping @MainActor (AgentTabSession) -> Void = { _ in }
    ) -> Bool {
        noteRecoveryQuestionDraftChanged(for: session, interactionID: interactionID)
        guard let lane = AgentRecoveryLiveQuestions.lane(for: session),
              lane.questionPersistence.needsPreservation(interactionID)
        else { return false }
        session.recoveryQuestionResolutionReservations.insert(interactionID)
        Task { @MainActor [weak self, weak session] in
            let preservation = await lane.questionPersistence.preserveBeforeReply(
                interactionID,
                within: AgentRecoveryQuestionPersistenceController.maximumDelay
            )
            guard let session else { return }
            session.recoveryQuestionResolutionReservations.remove(interactionID)
            guard let self, sessions[session.tabID] === session else { return }
            guard !isShutdownFrozen, preservation == .preserved,
                  AgentRecoveryLiveQuestions.lane(for: session) === lane
            else {
                notSent(session)
                requestUIRefresh(tabID: session.tabID, urgent: true)
                return
            }
            resolve(session)
        }
        return true
    }

    /// A deferred answer that was not sent (not preserved, or abandoned by a shutdown freeze): its
    /// timeout (which yielded to the answer) is armed again unless the parent agent owns the question.
    func rearmAskUserTimeoutAfterAbandonedAnswer(_ session: AgentTabSession, interactionID: UUID) {
        guard let pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              session.askUserContinuation != nil,
              !pending.isAwaitingParentAgent
        else { return }
        schedulePendingAskUserTimeout(
            for: session,
            interactionID: interactionID,
            timeoutSeconds: pending.interaction.timeoutSeconds,
            startedAt: Date()
        )
    }
}
