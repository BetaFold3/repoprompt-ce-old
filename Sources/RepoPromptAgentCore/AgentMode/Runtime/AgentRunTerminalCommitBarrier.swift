import Foundation
import RepoPromptWorkspace

package extension AgentSessionRunState {
    var isTerminalForCommit: Bool {
        self == .completed || self == .cancelled || self == .failed
    }
}

package struct AgentRunTerminalCommitRevision: Equatable {
    package let commitID: UUID
    package let ownership: AgentRunOwnership
    package let terminalState: AgentSessionRunState
    package let expectedRunID: UUID?
    /// The effective terminal cause (`AgentRunTerminalCause.effective`), recorded with recovery
    /// terminal evidence.
    package let cause: AgentRunTerminalCause
    let sourceItemsRevision: Int
    let assistantDeltaFlushGeneration: UInt64
    let providerDrainGeneration: UInt64
    package let mcpPublicationEnvelope: AgentRunTerminalPublicationEnvelope?
    package let successorKind: AgentRunEpochTransitionKind?
    package let providerSuccessorID: UUID?
}

@MainActor
package final class AgentRunTerminalCommitBarrier {
    struct ProviderSuccessor {
        let id: UUID
        let transitionKind: AgentRunEpochTransitionKind
        let consumeAfterPublication: (
            AgentRunTerminalCommitRevision,
            AgentRunTerminalPublicationResult
        ) -> Bool
    }

    struct Request {
        let session: AgentTabSession
        let ownership: AgentRunOwnership
        let expectedRunID: UUID?
        let terminalState: AgentSessionRunState
        let source: String
        /// The runner's requested cause; the commit records the effective one.
        let cause: AgentRunTerminalCause
        let completion: AgentModeRunService.CancellationCompletion
        let errorText: String?
        let attachmentReservationID: UUID?
        let capturedAttachments: [AgentImageAttachment]
        let attachmentDisposition: AgentAttachmentTurnDisposition
        let finalizeNonCodexUsage: Bool
        let supportsFollowUp: Bool
        let providerSuccessor: ProviderSuccessor?
        let notifyTurnComplete: Bool
        let providerDrainGeneration: UInt64
        let providerBuffersAreDrained: () -> Bool
        let prepareProviderState: () -> (@MainActor () async -> Void)?
        /// Tells the provider the run will not consume again, right after its completion was
        /// captured for attention notifications, so output it still owns can be shown at once.
        let releaseProviderOutput: (@MainActor () -> Void)?
        /// Delivers provider output that arrived before a queued follow-up starts, so it is shown
        /// before the follow-up's user row. Runs after the attention capture, while the commit is
        /// still in progress, and only when a queued follow-up instruction exists.
        let deliverProviderOutputBeforeFollowUp: (@MainActor () async -> Void)?
        let postCommit: () -> Void

        @MainActor
        init(
            session: AgentTabSession,
            ownership: AgentRunOwnership,
            expectedRunID: UUID?,
            terminalState: AgentSessionRunState,
            source: String,
            cause: AgentRunTerminalCause,
            completion: AgentModeRunService.CancellationCompletion = .terminalPublished,
            errorText: String? = nil,
            attachmentReservationID: UUID? = nil,
            capturedAttachments: [AgentImageAttachment]? = nil,
            attachmentDisposition: AgentAttachmentTurnDisposition,
            finalizeNonCodexUsage: Bool,
            supportsFollowUp: Bool,
            providerSuccessor: ProviderSuccessor? = nil,
            notifyTurnComplete: Bool,
            providerDrainGeneration: UInt64 = 0,
            providerBuffersAreDrained: @escaping () -> Bool = { true },
            prepareProviderState: @escaping () -> (@MainActor () async -> Void)? = { nil },
            releaseProviderOutput: (@MainActor () -> Void)? = nil,
            deliverProviderOutputBeforeFollowUp: (@MainActor () async -> Void)? = nil,
            postCommit: @escaping () -> Void = {}
        ) {
            self.session = session
            self.ownership = ownership
            self.expectedRunID = expectedRunID
            self.terminalState = terminalState
            self.source = source
            self.cause = cause
            self.completion = completion
            self.errorText = errorText
            self.attachmentReservationID = attachmentReservationID
            if let capturedAttachments {
                self.capturedAttachments = capturedAttachments
            } else if let attachmentReservationID {
                self.capturedAttachments = switch session.attachmentTurnState {
                case .idle:
                    []
                case let .reserved(storedID, attachments),
                     let .consumed(storedID, attachments):
                    attachmentReservationID == storedID ? attachments : []
                }
            } else {
                self.capturedAttachments = []
            }
            self.attachmentDisposition = attachmentDisposition
            self.finalizeNonCodexUsage = finalizeNonCodexUsage
            self.supportsFollowUp = supportsFollowUp
            self.providerSuccessor = providerSuccessor
            self.notifyTurnComplete = notifyTurnComplete
            self.providerDrainGeneration = providerDrainGeneration
            self.providerBuffersAreDrained = providerBuffersAreDrained
            self.prepareProviderState = prepareProviderState
            self.releaseProviderOutput = releaseProviderOutput
            self.deliverProviderOutputBeforeFollowUp = deliverProviderOutputBeforeFollowUp
            self.postCommit = postCommit
        }
    }

    private func recordTerminalBarrierState(_ active: Bool, request: Request) {
        #if DEBUG
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.MCPToolCall.publicationOwnershipState,
                EditFlowPerf.Dimensions(
                    status: "terminal_barrier",
                    outcome: request.terminalState.rawValue,
                    runID: request.expectedRunID?.uuidString,
                    providerActive: false,
                    networkScopeActive: false,
                    permitActive: false,
                    publicationPending: active,
                    terminalBarrier: active
                )
            )
        #endif
    }

    private let hooks: AgentModeRunService.Hooks
    private var terminalTeardownTasks: [AgentRunOwnership: Task<Void, Never>] = [:]
    private var consumedProviderSuccessorIDs: Set<UUID> = []
    private var consumedProviderSuccessorOrder: [UUID] = []
    private let maxConsumedProviderSuccessorTombstones = 512

    init(hooks: AgentModeRunService.Hooks) {
        self.hooks = hooks
    }

    @discardableResult
    func commit(_ request: Request) async -> AgentRunTerminalCommitRevision? {
        let session = request.session
        guard request.terminalState == .completed
            || request.terminalState == .cancelled
            || request.terminalState == .failed
        else {
            assertionFailure("Terminal commit requires a terminal run state")
            return nil
        }
        guard !session.terminalCommitInProgress else {
            recordRejection("commit_in_progress", request: request)
            return nil
        }
        if let existingRevision = session.lastTerminalCommitRevision,
           existingRevision.ownership == request.ownership
        {
            recordRejection("duplicate_commit", request: request)
            var retryPublicationResult = session.lastTerminalPublicationResult
            if retryPublicationResult?.isResolved != true {
                let publicationResult = await hooks.publishTerminalCommit(
                    session,
                    existingRevision,
                    existingRevision.successorKind
                )
                // Overlapping retries publish concurrently: a result is recorded only for the
                // still-current commit, and never over a resolved one (a later rejection must not
                // undo the acceptance the barrier owner's follow-up depends on).
                let isCurrent = session.lastTerminalCommitRevision?.commitID == existingRevision.commitID
                if isCurrent, session.lastTerminalPublicationResult?.isResolved != true {
                    session.lastTerminalPublicationResult = publicationResult
                }
                retryPublicationResult = isCurrent ? session.lastTerminalPublicationResult : publicationResult
            }
            // Publication may have suspended. A retry acts only while this commit is still current
            // and no other commit or retry holds the barrier (that one consumes the follow-up
            // after its own delivery). Only `commit` (blocked while the flag is held) and
            // `beginRunAttempt` (which resets the flag) replace the revision.
            let ownsRetry = !session.terminalCommitInProgress
                && session.lastTerminalCommitRevision?.commitID == existingRevision.commitID
            if ownsRetry,
               existingRevision.successorKind != nil,
               existingRevision.providerSuccessorID == nil,
               session.terminalFollowUpTakenCommitID != existingRevision.commitID,
               !session.pendingInstructions.isEmpty,
               let deliverProviderOutput = request.deliverProviderOutputBeforeFollowUp
            {
                // Same boundary as the first commit: provider output received since then is shown
                // before the follow-up's user row. Concurrent commits are rejected meanwhile.
                session.terminalCommitInProgress = true
                recordTerminalBarrierState(true, request: request)
                await deliverProviderOutput()
                if session.lastTerminalCommitRevision?.commitID == existingRevision.commitID {
                    session.terminalCommitInProgress = false
                    recordTerminalBarrierState(false, request: request)
                }
            }
            if ownsRetry,
               !session.terminalCommitInProgress,
               session.lastTerminalCommitRevision?.commitID == existingRevision.commitID,
               let followUpInstruction = takeQueuedFollowUpIfReady(
                   session: session,
                   revision: existingRevision,
                   publicationResult: session.lastTerminalPublicationResult
               )
            {
                hooks.startFollowUpRun(session.tabID, followUpInstruction, nil)
            }
            if let providerSuccessor = request.providerSuccessor,
               providerSuccessor.id == existingRevision.providerSuccessorID,
               let publicationResult = retryPublicationResult
            {
                notifyProviderSuccessor(
                    providerSuccessor,
                    revision: existingRevision,
                    publicationResult: publicationResult
                )
            }
            return existingRevision
        }
        guard validatesOwnership(request) else {
            recordRejection("stale_ownership", request: request)
            return nil
        }
        guard session.providerTerminalDrainGeneration == request.providerDrainGeneration else {
            recordRejection("stale_provider_drain_generation", request: request)
            return nil
        }
        guard request.providerBuffersAreDrained() else {
            assertionFailure("Provider-local terminal buffers must be drained before terminal commit")
            recordRejection("provider_buffers_pending", request: request)
            return nil
        }
        // The terminal user item's execution turn: its own ID, or the distinct destination turn a
        // relocated saved input runs in (O11), never the historical envelope sharing that ID.
        let terminalTurnID = Self.terminalUserItemID(for: request.ownership, in: session).map {
            session.transcript.executionTurnID(forUserItemID: $0)
        }

        session.terminalCommitInProgress = true
        recordTerminalBarrierState(true, request: request)
        hooks.flushPendingAssistantDelta(session)
        guard validatesOwnership(request) else {
            session.terminalCommitInProgress = false
            recordTerminalBarrierState(false, request: request)
            recordRejection("ownership_changed_during_drain", request: request)
            return nil
        }

        hooks.finalizeStreamingItems(session)
        hooks.finalizePendingToolCalls(session, request.terminalState)
        if request.finalizeNonCodexUsage {
            hooks.finalizeNonCodexTurnUsage(session, nil, nil, nil)
        }

        let queuedInstruction = request.terminalState == .completed && request.supportsFollowUp
            ? session.pendingInstructions.first
            : nil
        let providerSuccessor = request.terminalState == .completed
            ? request.providerSuccessor
            : nil
        assert(
            queuedInstruction == nil || providerSuccessor == nil,
            "Generic and provider-specific successors must not drain from the same terminal commit"
        )
        if queuedInstruction != nil || providerSuccessor != nil {
            session.mcpFollowUpRunPending = true
        }

        hooks.cancelPendingQuestion(session)
        hooks.cancelPendingApproval(session)
        let reviewCancellationReason = switch request.terminalState {
        case .completed:
            "Run completed before review decision"
        case .cancelled:
            "Run cancelled"
        case .failed:
            "Run failed"
        default:
            "Run finished"
        }
        hooks.cancelPendingApplyEditsReview(session, reviewCancellationReason)
        hooks.cancelPendingWorktreeMergeReview(session, reviewCancellationReason)
        hooks.finalizeAttachmentsForTurn(
            session,
            request.attachmentReservationID,
            request.capturedAttachments,
            request.attachmentDisposition
        )

        if let errorText = request.errorText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !errorText.isEmpty
        {
            session.appendItem(AgentChatItem.error(errorText, sequenceIndex: session.nextSequenceIndex))
        }

        guard validatesOwnership(request),
              session.providerTerminalDrainGeneration == request.providerDrainGeneration,
              request.providerBuffersAreDrained()
        else {
            session.terminalCommitInProgress = false
            recordTerminalBarrierState(false, request: request)
            recordRejection("ownership_or_drain_changed_before_commit", request: request)
            return nil
        }

        let attemptTeardown = session.claimRunAttemptTerminalTeardown(
            ownership: request.ownership,
            terminalState: request.terminalState
        )
        let providerTeardown = request.prepareProviderState()
        let teardown: AgentRunAttemptTerminalResources.Teardown? = if attemptTeardown != nil || providerTeardown != nil {
            {
                await attemptTeardown?()
                await providerTeardown?()
            }
        } else {
            nil
        }
        session.agentTask = nil
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus(nil, source: nil)
        session.waitingPrompt = nil
        session.runState = request.terminalState
        _ = session.endRunAttempt(ifCurrent: request.ownership, source: request.source)
        hooks.setAgentRunActive(session.tabID, false)
        hooks.prepareTerminalPublication(session)
        if let runID = request.expectedRunID, let terminalTurnID {
            AgentModeProcessRunIdentity.retainProcessRunID(
                runID,
                inTranscriptTurnID: terminalTurnID,
                for: session
            )
        }
        let cause = AgentRunTerminalCause.effective(
            requested: request.cause,
            terminalState: request.terminalState,
            lifecycleTeardown: session.lifecycleTeardownCause
        )
        if let terminalTurnID {
            Self.stampLiveInterruption(
                cause: cause,
                terminalState: request.terminalState,
                turnID: terminalTurnID,
                runAttemptID: request.ownership.attemptID,
                session: session
            )
        }

        let successorKind: AgentRunEpochTransitionKind? = if queuedInstruction != nil {
            .relatedFollowUp
        } else {
            providerSuccessor?.transitionKind
        }
        let revision = AgentRunTerminalCommitRevision(
            commitID: UUID(),
            ownership: request.ownership,
            terminalState: request.terminalState,
            expectedRunID: request.expectedRunID,
            cause: cause,
            sourceItemsRevision: session.sourceItemsRevision,
            assistantDeltaFlushGeneration: session.assistantDeltaFlushGeneration,
            providerDrainGeneration: request.providerDrainGeneration,
            mcpPublicationEnvelope: hooks.makeTerminalPublicationEnvelope(
                session,
                request.ownership,
                request.terminalState,
                request.expectedRunID
            ),
            successorKind: successorKind,
            providerSuccessorID: providerSuccessor?.id
        )
        session.lastTerminalCommitRevision = revision
        session.lastTerminalPublicationResult = nil
        // Recovery terminal evidence does not depend on MCP publication (local runs have no
        // envelope). Recorded only for the lane bound to this run's persistent session. The turn
        // the process run was retained in completes a missing turn join (R08).
        if let lane = session.recoveryLane,
           request.ownership.binding.persistentSessionID == lane.sessionID
        {
            lane.recordTerminalEvidence(revision, transcriptTurnID: terminalTurnID)
        }

        hooks.updateBindings(session)
        var attentionCapture: AttentionNotificationCapture?
        if request.notifyTurnComplete {
            hooks.notifyAgentTurnComplete(session)
            if request.terminalState == .completed {
                attentionCapture = hooks.captureAttentionTurnCompletion(session, revision)
            }
        }
        request.releaseProviderOutput?()
        hooks.scheduleSave(session.tabID)
        let publicationResult = await hooks.publishTerminalCommit(
            session,
            revision,
            successorKind
        )
        // A newer run attempt can begin while this commit publishes or delivers provider output
        // (`beginRunAttempt` resets the revision and the flag); this commit then owns neither the
        // result slot, the follow-up, nor the flag.
        var superseded = session.lastTerminalCommitRevision?.commitID != revision.commitID
        if !superseded {
            session.lastTerminalPublicationResult = publicationResult
        }
        if !superseded, queuedInstruction != nil,
           let deliverProviderOutput = request.deliverProviderOutputBeforeFollowUp
        {
            await deliverProviderOutput()
            superseded = session.lastTerminalCommitRevision?.commitID != revision.commitID
        }
        let followUpInstruction = superseded ? nil : takeQueuedFollowUpIfReady(
            session: session,
            revision: revision,
            publicationResult: session.lastTerminalPublicationResult
        )
        var providerSuccessorDeclined = false
        if let providerSuccessor {
            providerSuccessorDeclined = notifyProviderSuccessor(
                providerSuccessor,
                revision: revision,
                publicationResult: publicationResult
            )
        }
        let teardownTask = registerTerminalTeardown(
            teardown,
            ownership: request.ownership,
            tabID: session.tabID
        )
        if !superseded {
            session.terminalCommitInProgress = false
            recordTerminalBarrierState(false, request: request)
        }
        request.postCommit()
        var followUpStartObservation: AgentModeRunService.Hooks.FollowUpStartObservation?
        if let attentionCapture {
            followUpStartObservation = hooks.settleAttentionTurnCompletion(
                session,
                revision,
                attentionCapture,
                providerSuccessorDeclined,
                followUpInstruction != nil
            )
        }

        if let followUpInstruction {
            hooks.startFollowUpRun(session.tabID, followUpInstruction, followUpStartObservation)
        }
        if request.completion == .terminalTeardownCompleted {
            await teardownTask?.value
        }

        #if DEBUG
            AgentModePerfDiagnostics.increment("run.terminal.commit.accepted", tabID: session.tabID)
            AgentModePerfDiagnostics.increment(
                "run.terminal.commit.accepted.\(request.terminalState.rawValue)",
                tabID: session.tabID
            )
        #endif
        return revision
    }

    /// The user item a terminal commit is attributed to (F1). A run attempt whose runner named its
    /// own input is bound to that item: a later queued user item never takes its outcome, and when
    /// the item is gone (a withdrawn scheduled bubble) nothing is attributed, never an earlier turn.
    /// Attempts without a named input (Codex, pre-runner startup failures) keep the last user item.
    static func terminalUserItemID(for ownership: AgentRunOwnership, in session: AgentTabSession) -> UUID? {
        if let attribution = session.runAttemptInputAttribution, attribution.attemptID == ownership.attemptID {
            return session.items.contains { $0.id == attribution.userItemID && $0.kind == .user }
                ? attribution.userItemID
                : nil
        }
        return session.items.last(where: { $0.kind == .user })?.id
    }

    /// Live R5 stamp: a non-completed terminal whose effective cause is an interruption (quit,
    /// window close, provider process loss) records it on the terminal turn once, so a warm
    /// session presents the same state cold restore would. A user cancel or an ordinary terminal
    /// is never stamped, and an existing interruption (cold restore, an earlier commit) is kept.
    static func stampLiveInterruption(
        cause: AgentRunTerminalCause,
        terminalState: AgentSessionRunState,
        turnID: UUID,
        runAttemptID: UUID,
        session: AgentTabSession,
        now: Date = Date()
    ) {
        guard terminalState != .completed,
              let reason = cause.interruptionReason,
              // Review B R1-F1: the turn containing the terminal user item (its own turn, its
              // request, or a mid-turn user activity), not only a turn with that exact ID.
              let turnIndex = session.transcript.turns.lastIndex(where: { $0.containsUserItem(turnID) }),
              session.transcript.turns[turnIndex].interruption == nil
        else { return }
        let turn = session.transcript.turns[turnIndex]
        let lastActivity = turn.lastActivityAt
            ?? turn.responseSpans.compactMap(\.lastActivityAt).max()
        session.transcript.turns[turnIndex].interruption = AgentTranscriptTurnInterruption(
            reason: reason,
            observedAt: now,
            lastConfirmedActivityAt: lastActivity,
            runAttemptID: runAttemptID,
            providerConversationID: session.providerSessionID
        )
        session.isDirty = true
    }

    /// Returns true only when the provider explicitly declined its successor after an accepted
    /// publication (an observation for attention notifications; consumption is unchanged).
    @discardableResult
    private func notifyProviderSuccessor(
        _ providerSuccessor: ProviderSuccessor,
        revision: AgentRunTerminalCommitRevision,
        publicationResult: AgentRunTerminalPublicationResult
    ) -> Bool {
        if case .accepted = publicationResult {
            guard !consumedProviderSuccessorIDs.contains(providerSuccessor.id) else {
                return false
            }
            guard providerSuccessor.consumeAfterPublication(revision, publicationResult) else {
                return true
            }
            consumedProviderSuccessorIDs.insert(providerSuccessor.id)
            consumedProviderSuccessorOrder.append(providerSuccessor.id)
            while consumedProviderSuccessorOrder.count > maxConsumedProviderSuccessorTombstones {
                let expiredID = consumedProviderSuccessorOrder.removeFirst()
                consumedProviderSuccessorIDs.remove(expiredID)
            }
            return false
        }
        _ = providerSuccessor.consumeAfterPublication(revision, publicationResult)
        return false
    }

    private func takeQueuedFollowUpIfReady(
        session: AgentTabSession,
        revision: AgentRunTerminalCommitRevision,
        publicationResult: AgentRunTerminalPublicationResult?
    ) -> AgentPendingInstruction? {
        guard revision.successorKind != nil,
              revision.providerSuccessorID == nil,
              let publicationResult
        else { return nil }
        // One commit consumes at most one queued instruction. The follow-up's attempt begins
        // asynchronously, so the commit stays current after the take and a later retry must not
        // consume another.
        guard session.terminalFollowUpTakenCommitID != revision.commitID else { return nil }
        switch publicationResult {
        case let .accepted(successorEpoch):
            if revision.mcpPublicationEnvelope != nil, successorEpoch == nil {
                return nil
            }
        case .rejected:
            return nil
        case .stale:
            session.terminalFollowUpTakenCommitID = revision.commitID
            // Untracked input keeps the legacy drop. A durable input is never silently discarded:
            // it stays queued for a later boundary or explicit user action.
            if let head = session.pendingInstructions.first, !head.isDurable {
                session.pendingInstructions.removeFirst()
            }
            session.mcpFollowUpRunPending = false
            return nil
        }
        guard !session.pendingInstructions.isEmpty else {
            session.mcpFollowUpRunPending = false
            return nil
        }
        session.terminalFollowUpTakenCommitID = revision.commitID
        return session.pendingInstructions.removeFirst()
    }

    func awaitTerminalPublication(
        for ownership: AgentRunOwnership,
        session: AgentTabSession
    ) async {
        while session.terminalCommitInProgress {
            if let revision = session.lastTerminalCommitRevision,
               revision.ownership != ownership
            {
                return
            }
            await Task.yield()
        }
    }

    func awaitTerminalTeardown(
        for ownership: AgentRunOwnership,
        session: AgentTabSession
    ) async {
        await awaitTerminalPublication(for: ownership, session: session)
        guard session.lastTerminalCommitRevision?.ownership == ownership else { return }
        await terminalTeardownTasks[ownership]?.value
    }

    private func registerTerminalTeardown(
        _ teardown: AgentRunAttemptTerminalResources.Teardown?,
        ownership: AgentRunOwnership,
        tabID: UUID
    ) -> Task<Void, Never>? {
        guard let teardown else { return nil }
        let task = Task { @MainActor [weak self] in
            #if DEBUG
                AgentModePerfDiagnostics.increment("run.terminal.teardown.started", tabID: tabID)
            #endif
            await teardown()
            #if DEBUG
                AgentModePerfDiagnostics.increment("run.terminal.teardown.completed", tabID: tabID)
            #endif
            self?.terminalTeardownTasks[ownership] = nil
        }
        terminalTeardownTasks[ownership] = task
        return task
    }

    private func validatesOwnership(_ request: Request) -> Bool {
        request.session.isCurrentRunAttemptForCurrentBinding(
            request.ownership,
            expectedRunID: request.expectedRunID
        )
    }

    private func recordRejection(_ reason: String, request: Request) {
        #if DEBUG
            AgentModePerfDiagnostics.increment("run.terminal.commit.rejected.\(reason)", tabID: request.session.tabID)
            AgentModePerfDiagnostics.event(
                "run.terminal.commitRejected",
                tabID: request.session.tabID,
                fields: [
                    "reason": reason,
                    "source": request.source,
                    "state": request.terminalState.rawValue
                ]
            )
        #endif
    }
}
