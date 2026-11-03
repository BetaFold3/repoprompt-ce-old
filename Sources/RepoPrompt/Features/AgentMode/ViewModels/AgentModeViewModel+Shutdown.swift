import Foundation
import RepoPromptAgentCore

// Two-stage quit / window-close preservation for one window's Agent Mode sessions (spec R4).
//
// The app-scoped `AgentLifecycleShutdownCoordinator` drives these entry points:
// - `beginShutdownFreeze` (synchronous, before any await): refuses new input, dispatch commits,
//   handoff, question answers, and binding changes for this window's sessions only.
// - `prepareSessionsForShutdown` (Stage A, reversible): joins composer work, preserves composers,
//   writes pending-question snapshots and run shutdown reasons, and flushes fully hydrated dirty
//   transcripts. Nothing irreversible happens; a failure leaves every session usable.
// - `endShutdownFreeze` (Stage A cancelled or failed): reopens admission.
// - `prepareForWindowClose(reason:)` (Stage B, irreversible, joinable, runs once).
// - `finalizeTranscriptsAfterShutdown` (Stage B, after the actual stop and terminal commit).

/// Stage A freeze of one window's sessions.
struct AgentModeShutdownFreezeState: Equatable {
    let requestID: UUID
    /// Window-scoped recovery freeze owned by this view model; `nil` when the app quit owns an
    /// application-wide freeze instead.
    let recoveryToken: UUID?
}

/// The exact pending-question snapshots one tab's Stage A wrote, on the lane they were written to.
/// Snapshots another owner preserved (a closed window of this or an earlier launch) are never
/// tracked here, so neither live resolution nor Cancel removes them.
struct AgentModeShutdownQuestionSnapshots: Equatable {
    let lane: ObjectIdentifier
    /// Questions live in this window when they were written; resolving one live removes that ID.
    var live: Set<UUID>
    /// The subset this window added (not already stored by another owner); Cancel removes these.
    var introduced: Set<UUID>
}

/// Question-snapshot removals on one lane whose write failed. Kept with their lane (never dropped
/// before a receipt) and retried before this window's next Stage A writes; a retry that still fails
/// is reported as a Stage A blocker.
struct AgentModeShutdownFailedQuestionRemoval {
    weak var lane: AgentRecoverySessionLane?
    let tabID: UUID
    var interactionIDs: Set<UUID>
}

/// An answer (ask_user, user input, MCP elicitation) submitted while a shutdown freeze covers its
/// window. Refused before any mutation: drafts, the pending request, and its continuation are kept.
struct AgentModeShutdownAnswerRefused: LocalizedError, Equatable {
    var errorDescription: String? {
        "This session is being saved for quit or window close, so the question was not answered. Answer it after the shutdown is cancelled."
    }
}

/// Stage A (or Stage B final-flush) result for one window: user-facing reasons it cannot proceed.
struct AgentModeShutdownReport: Equatable {
    var blockers: [String] = []

    var isReady: Bool {
        blockers.isEmpty
    }
}

@MainActor
extension AgentModeViewModel {
    // MARK: Freeze

    /// Any shutdown request covers this window (Stage A freeze, or teardown already began).
    var isShutdownFrozen: Bool {
        shutdownFreezeState != nil || hasPreparedForWindowClose
    }

    /// Whether producers for `session` must refuse: this window is frozen, or an app-wide freeze
    /// covers its owner.
    func isRecoveryShutdownFrozen(_ session: AgentTabSession) -> Bool {
        isShutdownFrozen || recoveryCoordinator?.isShutdownFrozen(owner: session) == true
    }

    /// Synchronous freeze for `requestID`. With `ownsRecoveryFreeze` (window close) this view
    /// model also freezes its sessions' recovery lanes; app quit freezes every lane itself.
    func beginShutdownFreeze(requestID: UUID, ownsRecoveryFreeze: Bool) {
        if let current = shutdownFreezeState {
            guard current.requestID != requestID else { return }
            if let token = current.recoveryToken {
                recoveryCoordinator?.endShutdownFreeze(token)
            }
        }
        let token = ownsRecoveryFreeze
            ? recoveryCoordinator?.beginShutdownFreeze(scope: .owners(Set(sessions.values.map { ObjectIdentifier($0) })))
            : nil
        shutdownFreezeState = AgentModeShutdownFreezeState(requestID: requestID, recoveryToken: token)
        publishShutdownFreezeToObservedUI()
        notifyScheduledSendBusyStateMayHaveChanged(tabIDs: Set(sessions.keys))
    }

    /// The views that present the composer and answer cards observe narrow stores, not this view
    /// model: the freeze reaches them through those stores' snapshots. Skipped once this window's
    /// teardown began: its stores already show it frozen, and a closing window is not republished.
    private func publishShutdownFreezeToObservedUI() {
        guard !hasPreparedForWindowClose else { return }
        syncComposerUIState()
        syncRunInteractionUIState()
    }

    /// Reopens a cancelled or failed Stage A. Ignored for any other request (stale fence). The
    /// question snapshots this window introduced are removed by ID: only a Stage A that proceeds to
    /// teardown needs them, and a reopened question may end through a path that never refreshes
    /// them. Snapshots another owner preserved are kept.
    func endShutdownFreeze(requestID: UUID) {
        guard let state = shutdownFreezeState, state.requestID == requestID else { return }
        shutdownFreezeState = nil
        if let token = state.recoveryToken {
            recoveryCoordinator?.endShutdownFreeze(token)
        }
        clearShutdownQuestionSnapshotsAfterCancel()
        publishShutdownFreezeToObservedUI()
        notifyScheduledSendBusyStateMayHaveChanged(tabIDs: Set(sessions.keys))
    }

    /// Removes, by ID, the snapshots this window introduced on the lane they were written to.
    /// A torn-down window's snapshots are its preservation and are never removed.
    private func clearShutdownQuestionSnapshotsAfterCancel() {
        let tracked = shutdownQuestionSnapshots
        shutdownQuestionSnapshots.removeAll()
        guard !hasPreparedForWindowClose else { return }
        for session in sessions.values {
            guard let lane = session.recoveryLane, !lane.isRetired,
                  let snapshots = tracked[session.tabID], snapshots.lane == ObjectIdentifier(lane),
                  !snapshots.introduced.isEmpty
            else { continue }
            enqueueQuestionSnapshotRemoval(snapshots.introduced, on: lane, tabID: session.tabID)
        }
    }

    /// Serialized behind every earlier removal; a later Stage A joins the chain before writing. A
    /// failed removal keeps its IDs and lane (`shutdownFailedQuestionSnapshotRemovals`).
    private func enqueueQuestionSnapshotRemoval(
        _ interactionIDs: Set<UUID>,
        on lane: AgentRecoverySessionLane,
        tabID: UUID
    ) {
        let previous = shutdownQuestionSnapshotWriteTask
        shutdownQuestionSnapshotWriteTask = Task { @MainActor [weak self] in
            await previous?.value
            let result = await lane.updateQuestionSnapshots(.init(removing: interactionIDs))
            let succeeded = if case .success = result { true } else { false }
            self?.noteQuestionSnapshotRemoval(interactionIDs, on: lane, tabID: tabID, succeeded: succeeded)
        }
    }

    private func noteQuestionSnapshotRemoval(
        _ interactionIDs: Set<UUID>,
        on lane: AgentRecoverySessionLane,
        tabID: UUID,
        succeeded: Bool
    ) {
        let key = ObjectIdentifier(lane)
        var failed = shutdownFailedQuestionSnapshotRemovals[key].flatMap { $0.lane === lane ? $0 : nil }
            ?? AgentModeShutdownFailedQuestionRemoval(lane: lane, tabID: tabID, interactionIDs: [])
        if succeeded {
            failed.interactionIDs.subtract(interactionIDs)
        } else {
            failed.interactionIDs.formUnion(interactionIDs)
        }
        shutdownFailedQuestionSnapshotRemovals[key] = failed.interactionIDs.isEmpty ? nil : failed
    }

    /// Retries every retained failed removal on its own (live, unretired) lane. Each one that still
    /// fails is a blocker: the saved recovery state would otherwise keep a question that is no longer
    /// pending. A retired lane's entry is kept (not retried here); a deallocated lane's is dropped.
    private func retryFailedQuestionSnapshotRemovals() async -> [String] {
        var blockers: [String] = []
        shutdownFailedQuestionSnapshotRemovals = shutdownFailedQuestionSnapshotRemovals.filter { $0.value.lane != nil }
        for failed in shutdownFailedQuestionSnapshotRemovals.values {
            guard let lane = failed.lane, !lane.isRetired else { continue }
            let result = await lane.updateQuestionSnapshots(.init(removing: failed.interactionIDs))
            if case .success = result {
                noteQuestionSnapshotRemoval(failed.interactionIDs, on: lane, tabID: failed.tabID, succeeded: true)
            } else {
                let label = sessions[failed.tabID].map { shutdownSessionLabel($0) } ?? "A session"
                blockers.append("\(label): a question that is no longer pending could not be removed from its saved recovery state.")
            }
        }
        return blockers
    }

    // MARK: Native user-input drafts (session-owned)

    func userInputDrafts(tabID: UUID, requestID: UUID) -> [String: AgentRequestUserInputQuestionDraft] {
        guard let state = sessions[tabID]?.pendingUserInputDrafts, state.requestID == requestID else { return [:] }
        return state.draftsByQuestionID
    }

    func updateUserInputDraft(
        tabID: UUID,
        requestID: UUID,
        questionID: String,
        draft: AgentRequestUserInputQuestionDraft
    ) {
        guard !isShutdownFrozen,
              let session = sessions[tabID],
              let request = session.pendingUserInputRequest,
              request.id == requestID,
              request.questions.contains(where: { $0.id == questionID }),
              !isRecoveryQuestionResolutionReserved(session, interactionID: requestID)
        else { return }
        var state = session.pendingUserInputDrafts?.requestID == requestID
            ? session.pendingUserInputDrafts ?? AgentRequestUserInputDraftState(requestID: requestID)
            : AgentRequestUserInputDraftState(requestID: requestID)
        guard state.draftsByQuestionID[questionID] != draft else { return }
        state.draftsByQuestionID[questionID] = draft
        session.pendingUserInputDrafts = state
        // A secret answer never reaches the snapshot, so it never schedules a changed write.
        noteRecoveryQuestionDraftChanged(for: session, interactionID: requestID)
    }

    // MARK: Stage A

    /// Stage A for this window. Every blocker leaves the session usable (caller ends the freeze
    /// on cancel). Order: secret-answer veto (before any write), composer obligations without a
    /// lane, lane preservation (composer, question snapshots, run shutdown reason), transcripts.
    ///
    /// Serialized per view model across requests: a preparation runs only after the previous one
    /// (a Retry, a cancelled request's, or a superseded window close's) finished, and after the
    /// snapshot removals it enqueued landed. A stale preparation's late removal therefore always
    /// lands before this one captures and upserts, never after.
    func prepareSessionsForShutdown(reason: AgentRecoveryShutdownReason) async -> AgentModeShutdownReport {
        // The request this preparation serves is the freeze in force when it was asked for.
        let freezeRequestID = shutdownFreezeState?.requestID
        let predecessor = shutdownPreparationTask
        let preparation = Task { @MainActor [weak self] () -> AgentModeShutdownReport in
            _ = await predecessor?.value
            guard let self else { return AgentModeShutdownReport() }
            return await performShutdownPreparation(reason: reason, freezeRequestID: freezeRequestID)
        }
        shutdownPreparationTask = preparation
        return await preparation.value
    }

    private func performShutdownPreparation(
        reason: AgentRecoveryShutdownReason,
        freezeRequestID: UUID?
    ) async -> AgentModeShutdownReport {
        var report = AgentModeShutdownReport()
        // Already torn down (its own window close finished): it was preserved then, and its live
        // questions were cancelled by teardown, so re-preparing would erase its snapshots.
        guard !hasPreparedForWindowClose else { return report }
        let ordered = sessions.values.sorted { $0.tabID.uuidString < $1.tabID.uuidString }
        let appInstanceID = recoveryCoordinator?.store.appInstanceID ?? UUID()
        for session in ordered {
            let capture = AgentRecoveryQuestionSnapshotBuilder.capture(
                session: session,
                appInstanceID: appInstanceID,
                transcriptResetGeneration: session.recoveryLane?.binding.transcriptResetGeneration ?? 0
            )
            if capture.hasUnsavableSecretAnswer {
                report.blockers.append(
                    "\(shutdownSessionLabel(session)) has a secret answer typed into a pending question. Submit or clear it first: secret answers are never saved."
                )
            }
        }
        guard report.isReady else { return report }

        /// A cancelled (or superseded) request ends this freeze: no later session is prepared or
        /// flushed for it. A step already in flight completes (its writes are conservative).
        func isStillFrozenForThisRequest() -> Bool {
            freezeRequestID == nil || shutdownFreezeState?.requestID == freezeRequestID
        }
        // Every earlier removal (Cancel, live resolution, a predecessor's stale cleanup) lands
        // before this attempt's snapshots; failed ones are retried first.
        await shutdownQuestionSnapshotWriteTask?.value
        guard isStillFrozenForThisRequest() else { return report }
        // A removal that still fails blocks before any new write (nothing is upserted over it).
        report.blockers += await retryFailedQuestionSnapshotRemovals()
        guard report.isReady else { return report }
        if let coordinator = recoveryCoordinator {
            for session in ordered {
                guard isStillFrozenForThisRequest() else { return report }
                if let blocker = await prepareRecoveryForShutdown(
                    session,
                    coordinator: coordinator,
                    reason: reason,
                    isStillFrozenForThisRequest: isStillFrozenForThisRequest
                ) {
                    report.blockers.append(blocker)
                }
            }
        }
        for session in ordered {
            guard isStillFrozenForThisRequest() else { return report }
            if case let .failed(message) = await flushTranscriptForShutdown(session, final: false) {
                report.blockers.append(message)
            }
        }
        return report
    }

    private func prepareRecoveryForShutdown(
        _ session: AgentTabSession,
        coordinator: AgentRecoveryCoordinator,
        reason: AgentRecoveryShutdownReason,
        isStillFrozenForThisRequest: () -> Bool
    ) async -> String? {
        let label = shutdownSessionLabel(session)
        // Composer input that has no lane yet (first draft of a new tab, images awaiting promotion):
        // its single preparation is joined, and any obligation left is not durable.
        // F5 observability: this join is unbounded (only the coordinator's deadline ends Stage A),
        // so a persisted line brackets it.
        let requestID = shutdownFreezeState?.requestID
        if let preparation = coordinator.composerPreparation(for: session) {
            AgentLifecycleShutdownDiagnostics.composerPreparationWait(request: requestID, tabID: session.tabID, finished: false)
            await preparation.preparationTask?.value
            let stillPending = coordinator.composerPreparation(for: session) != nil
            AgentLifecycleShutdownDiagnostics.composerPreparationWait(
                request: requestID,
                tabID: session.tabID,
                finished: true,
                stillPending: stillPending
            )
            if stillPending {
                return "\(label) has a draft that could not be saved yet."
            }
        }
        guard let lane = session.recoveryLane, !lane.isRetired else {
            // No lane: no composer, question, or run-shutdown evidence is written for this session.
            AgentLifecycleShutdownDiagnostics.sessionSkippedWithoutLane(
                request: requestID,
                tabID: session.tabID,
                hasActiveRun: session.activeRunOwnership != nil
            )
            return nil
        }
        let capture = AgentRecoveryQuestionSnapshotBuilder.capture(
            session: session,
            appInstanceID: coordinator.store.appInstanceID,
            transcriptResetGeneration: lane.binding.transcriptResetGeneration
        )
        // Secret content typed meanwhile is impossible (answers are frozen); checked again anyway.
        if capture.hasUnsavableSecretAnswer {
            return "\(label) has a secret answer typed into a pending question. Submit or clear it first: secret answers are never saved."
        }
        let run = session.activeRunOwnership.map {
            AgentRecoverySessionLane.ShutdownRunEvidence(
                ownership: $0,
                processRunID: session.runID,
                reason: reason,
                lastConfirmedActivityAt: session.lastActivityAt
            )
        }
        // Upsert the live questions; remove only what an earlier attempt of this window introduced
        // and is no longer live. Nothing another owner preserved is named.
        let liveIDs = Set(capture.snapshots.map(\.interactionID))
        let laneID = ObjectIdentifier(lane)
        let earlier = shutdownQuestionSnapshots[session.tabID].flatMap { $0.lane == laneID ? $0 : nil }
        let update = AgentRecoveryStore.QuestionSnapshotUpdate(
            upserting: capture.snapshots,
            removing: (earlier?.introduced ?? []).subtracting(liveIDs)
        )
        switch await lane.prepareForShutdown(questions: update, run: run) {
        case let .success(alreadyStored):
            let preservedByOthers = alreadyStored.subtracting(earlier?.introduced ?? [])
            var tracked = AgentModeShutdownQuestionSnapshots(
                lane: laneID,
                live: liveIDs,
                introduced: liveIDs.subtracting(preservedByOthers)
            )
            // A question resolved while this write was in flight was not yet tracked for refresh.
            let stillLive = Set(AgentRecoveryQuestionSnapshotBuilder.capture(
                session: session,
                appInstanceID: coordinator.store.appInstanceID,
                transcriptResetGeneration: lane.binding.transcriptResetGeneration
            ).snapshots.map(\.interactionID))
            var stale = tracked.introduced.subtracting(stillLive)
            tracked.live.formIntersection(stillLive)
            tracked.introduced.formIntersection(stillLive)
            if isStillFrozenForThisRequest() {
                shutdownQuestionSnapshots[session.tabID] = tracked.live.isEmpty ? nil : tracked
            } else {
                // Cancelled or superseded while this write was in flight: its Cancel removal ran
                // without these. The removal lands before any successor preparation captures (it
                // joins this preparation and the removal chain), which then re-preserves and owns
                // any question still live.
                stale.formUnion(tracked.introduced)
                shutdownQuestionSnapshots[session.tabID] = nil
            }
            if !stale.isEmpty {
                enqueueQuestionSnapshotRemoval(stale, on: lane, tabID: session.tabID)
            }
            return nil
        case let .failure(failure):
            AgentRecoveryFailureDiagnostics.shutdownBlocked(
                reason: Self.shutdownPreparationDiagnosticReason(failure),
                tabID: session.tabID,
                failure: Self.shutdownPreparationControllerFailure(failure)
            )
            return "\(label): \(Self.shutdownPreparationFailureText(failure))"
        }
    }

    /// F6: plain, actionable wording only. The raw controller failure (store errors, `Domain=`
    /// text, paths) is logged privately by `AgentRecoveryFailureDiagnostics.shutdownBlocked`.
    static func shutdownPreparationFailureText(_ failure: AgentRecoveryShutdownPreparationFailure) -> String {
        switch failure {
        case .composer(.unsavedPredecessorInput):
            "earlier unsaved input needs to be restored or discarded first (recovery banner)."
        case .composer(.unrepresentableComposerInput):
            "the message box holds an attachment that is not saved yet."
        case .composer(.composerChangedDuringPreparation):
            "the message box kept changing while it was being saved."
        case .composer(.laneRetired), .composer(.alreadyPreparing):
            "the session changed while it was being saved."
        case let .composer(.composerNotPersisted(failure)):
            "the message box could not be saved\(failure.map { " (\($0.userFacingDescription))" } ?? "")."
        case let .evidenceNotPersisted(failure):
            "its recovery state could not be saved (\(failure.userFacingDescription))."
        }
    }

    private static func shutdownPreparationDiagnosticReason(_ failure: AgentRecoveryShutdownPreparationFailure) -> String {
        switch failure {
        case .composer(.unsavedPredecessorInput): "unsaved_predecessor_input"
        case .composer(.unrepresentableComposerInput): "unrepresentable_composer_input"
        case .composer(.composerChangedDuringPreparation): "composer_changed_during_preparation"
        case .composer(.laneRetired): "lane_retired"
        case .composer(.alreadyPreparing): "already_preparing"
        case .composer(.composerNotPersisted): "composer_not_persisted"
        case .evidenceNotPersisted: "evidence_not_persisted"
        }
    }

    private static func shutdownPreparationControllerFailure(
        _ failure: AgentRecoveryShutdownPreparationFailure
    ) -> AgentRecoveryControllerFailure? {
        switch failure {
        case let .composer(.composerNotPersisted(failure)): failure
        case let .evidenceNotPersisted(failure): failure
        case .composer: nil
        }
    }

    private func shutdownSessionLabel(_ session: AgentTabSession) -> String {
        let title = (sidebarContentFingerprintTabs.first { $0.id == session.tabID }?.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "A session" : "“\(title)”"
    }

    // MARK: Transcripts

    enum ShutdownTranscriptFlush: Equatable {
        /// Not eligible (partially hydrated, rebinding, stale-reset retained, or gone): skipped
        /// without writing, never treated as saved.
        case skipped
        case clean
        case failed(String)
    }

    /// Whether a shutdown flush may write this session: unbound with content, or a bound session
    /// whose persisted state finished loading (the VM's hydration gate; `authoritativeHydratedBinding`
    /// is presentation-only and absent for background or newly bound tabs), with no load, rebinding,
    /// or stale-reset recovery in progress. A partially hydrated session is never written.
    func isShutdownTranscriptFlushEligible(_ session: AgentTabSession) -> Bool {
        guard session.staleResetRecovery == nil,
              !session.bindingTransitionInProgress,
              session.persistedLoadTask == nil
        else { return false }
        guard session.activeAgentSessionID != nil || session.persistentSessionBindingIdentity != nil else { return true }
        return session.hasLoadedPersistedState
    }

    /// Drains buffered assistant text, joins an in-flight save, and writes the session until a
    /// receipt proves the latest projection durable. Stage A accepts a write that a still-running
    /// turn dirtied again; the final (Stage B) flush requires a clean projection.
    func flushTranscriptForShutdown(_ session: AgentTabSession, final: Bool) async -> ShutdownTranscriptFlush {
        guard !AppLaunchConfiguration.current.suppressesAgentSessionPersistence else { return .clean }
        let label = shutdownSessionLabel(session)
        for _ in 0 ..< 4 {
            guard sessions[session.tabID] === session, isShutdownTranscriptFlushEligible(session) else {
                return .skipped
            }
            session.drainPendingAssistantDelta()
            if let sessionID = session.activeAgentSessionID {
                await awaitInFlightSave(sessionID: sessionID)
            }
            guard sessions[session.tabID] === session, isShutdownTranscriptFlushEligible(session) else {
                return .skipped
            }
            let needsWrite = session.isDirty
                || !session.pendingAssistantDelta.isEmpty
                || (session.activeAgentSessionID == nil && hasPersistableConversationContent(session))
            guard needsWrite else { return .clean }
            switch await flushSaveDetailed(for: session.tabID) {
            case .suppressed:
                return .clean
            case .written:
                if !session.isDirty || (!final && session.runState.isActive) {
                    return .clean
                }
            case .resetAcknowledged, .deferredBehindInFlightSave:
                continue
            case .notWritten:
                if let admission = session.staleResetRemovalAdmission,
                   admission.isFinalSaveCompleted || admission.isCommitted
                {
                    // A removal operation's final save owns this owner's durability.
                    return .clean
                }
                return .failed("\(label) could not be saved.")
            }
        }
        return .failed("\(label) kept changing while it was being saved.")
    }

    // MARK: Stage B final flush

    /// After the irreversible teardown awaited the actual stop and terminal commit: settles each
    /// lane's evidence writes, re-flushes its composer, and flushes every eligible transcript to a
    /// clean projection. Returns blockers; an empty report is the precondition for a clean mark.
    func finalizeTranscriptsAfterShutdown() async -> AgentModeShutdownReport {
        var report = AgentModeShutdownReport()
        let ordered = sessions.values.sorted { $0.tabID.uuidString < $1.tabID.uuidString }
        for session in ordered {
            let label = shutdownSessionLabel(session)
            if let lane = session.recoveryLane, !lane.isRetired {
                await lane.settleEvidenceWrites()
                // The provider already stopped: no later terminal event repairs a failed write, so
                // only the storage write is retried (nothing is torn down again).
                await lane.retryFailedTerminalEvidence()
                if !lane.terminalEvidenceFailures.isEmpty {
                    report.blockers.append("\(label): how its last run ended could not be saved.")
                }
                if case let .failed(failure) = await lane.flushComposer() {
                    AgentRecoveryFailureDiagnostics.shutdownBlocked(
                        reason: "final_composer_not_persisted",
                        tabID: session.tabID,
                        failure: failure
                    )
                    report.blockers.append("\(label): the message box could not be saved (\(failure.userFacingDescription)).")
                }
            }
            if case let .failed(message) = await flushTranscriptForShutdown(session, final: true) {
                report.blockers.append(message)
            }
        }
        return report
    }

    // MARK: Question snapshots after live resolution

    /// A question this window snapshotted was resolved live (answered, skipped, timed out): exactly
    /// that interaction's durable snapshot is removed from the lane it was written to. Not during
    /// teardown, whose cancellations must not erase the preserved questions.
    func refreshRecoveryQuestionSnapshotsAfterLiveResolution(for session: AgentTabSession, interactionID: UUID) {
        guard !hasPreparedForWindowClose,
              let lane = session.recoveryLane, !lane.isRetired,
              var tracked = shutdownQuestionSnapshots[session.tabID],
              tracked.lane == ObjectIdentifier(lane),
              tracked.live.contains(interactionID)
        else { return }
        tracked.live.remove(interactionID)
        tracked.introduced.remove(interactionID)
        shutdownQuestionSnapshots[session.tabID] = tracked.live.isEmpty ? nil : tracked
        enqueueQuestionSnapshotRemoval([interactionID], on: lane, tabID: session.tabID)
    }
}
