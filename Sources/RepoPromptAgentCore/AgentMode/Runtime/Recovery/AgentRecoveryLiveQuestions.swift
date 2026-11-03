import Foundation

/// Producer-side entry points for live pending-question persistence (plan §E), shared by the view
/// model's `ask_user` path and the native provider coordinators. Each call resolves the session's
/// own recovery lane; a session without a usable lane (not persisted yet, retired, or a remote
/// mirror whose host owns its questions) keeps the existing behavior and is covered only by
/// shutdown preparation.
@MainActor
package enum AgentRecoveryLiveQuestions {
    /// The lane that persists `session`'s live questions, if any.
    package static func lane(for session: AgentTabSession) -> AgentRecoverySessionLane? {
        guard session.remoteHost == nil, let lane = session.recoveryLane, !lane.isRetired else { return nil }
        return lane
    }

    package static func context(
        for session: AgentTabSession,
        lane: AgentRecoverySessionLane
    ) -> AgentRecoveryQuestionSnapshotBuilder.Context {
        AgentRecoveryQuestionSnapshotBuilder.Context(
            session: session,
            appInstanceID: lane.store.appInstanceID,
            transcriptResetGeneration: lane.binding.transcriptResetGeneration
        )
    }

    /// Commits a new interaction's snapshot before it is published (no debounce). `nil` when the
    /// session has no lane (nothing was written).
    package static func commitCreation(
        session: AgentTabSession,
        snapshot: (AgentRecoveryQuestionSnapshotBuilder.Context) -> AgentRecoveryQuestionSnapshot
    ) async -> (lane: AgentRecoverySessionLane, result: Result<Void, AgentRecoveryControllerFailure>)? {
        guard let lane = lane(for: session) else { return nil }
        let built = snapshot(context(for: session, lane: lane))
        return await (lane, lane.questionPersistence.commitCreation(built))
    }

    /// After a validated edit of a live interaction: schedules the bounded write of its latest
    /// sanitized snapshot (secret answers are never captured).
    package static func draftDidChange(session: AgentTabSession, interactionID: UUID) {
        guard let lane = lane(for: session),
              let snapshot = AgentRecoveryQuestionSnapshotBuilder.snapshot(
                  interactionID: interactionID,
                  session: session,
                  appInstanceID: lane.store.appInstanceID,
                  transcriptResetGeneration: lane.binding.transcriptResetGeneration
              )
        else { return }
        lane.questionPersistence.draftDidChange(snapshot)
    }

    /// Whether `interactionID` has an unsaved snapshot that resolution must flush first.
    package static func hasUnsavedSnapshot(session: AgentTabSession, interactionID: UUID) -> Bool {
        lane(for: session)?.questionPersistence.hasUnsavedSnapshot(interactionID) == true
    }

    /// Ends interactions that left the live surface. Lifecycle teardown (window close, app quit)
    /// preserves them; every other ending (answer, decline, cancel, timeout, expiry) removes exactly
    /// those IDs without waiting for storage.
    package static func end(session: AgentTabSession, interactionIDs: Set<UUID>, preserving: Bool) {
        guard !interactionIDs.isEmpty, let lane = session.recoveryLane else { return }
        lane.questionPersistence.end(interactionIDs, preserving: preserving || session.lifecycleTeardownCause != nil)
    }

    /// Every live question interaction of `session` (active and queued).
    package static func liveInteractionIDs(of session: AgentTabSession) -> Set<UUID> {
        var ids = Set<UUID>()
        if let pending = session.pendingAskUser { ids.insert(pending.interaction.id) }
        if let request = session.pendingUserInputRequest { ids.insert(request.id) }
        ids.formUnion(session.queuedUserInputRequests.map(\.id))
        if let request = session.pendingMCPElicitationRequest { ids.insert(request.id) }
        ids.formUnion(session.queuedMCPElicitationRequests.map(\.id))
        return ids
    }
}
