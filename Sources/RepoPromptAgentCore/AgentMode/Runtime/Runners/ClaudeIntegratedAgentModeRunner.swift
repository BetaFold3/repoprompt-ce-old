import Foundation

@MainActor
final class ClaudeIntegratedAgentModeRunner {
    private struct ConsumeEventsOutcome {
        let terminalState: AgentSessionRunState
        let errorText: String?
        let shouldShutdownSession: Bool
        /// `.providerProcessLost` only when the provider's process or event transport ended under a
        /// still-active run (review A F06); provider-reported failures stay ordinary.
        var cause: AgentRunTerminalCause = .ordinary
        /// The run's turn the provider reported failed; its runtime says whether process loss failed it.
        var failedTurnID: UUID?
    }

    /// Carries a run handler's terminal outcome out of the router callback.
    private final class ConsumeOutcomeBox {
        var value: ConsumeEventsOutcome?
    }

    private let claudeCoordinator: ClaudeAgentModeCoordinator
    private let hooks: AgentModeRunService.Hooks
    private let terminalCommitBarrier: AgentRunTerminalCommitBarrier
    /// One router per tab, bound to the controller stream that tab currently consumes.
    private var eventRoutersByTabID: [UUID: ClaudeNativeEventRouter] = [:]
    /// Routers of the tab's controller whose stream was replaced; each delivers its remaining
    /// events and then removes itself.
    private var drainingEventRoutersByTabID: [UUID: [ClaudeNativeEventRouter]] = [:]
    /// Run attempts whose runner task is alive. Events owned by a live run wait for that run
    /// instead of being delivered as between-run output.
    private var idleDeliveryHoldsByTabID: [UUID: Set<UUID>] = [:]

    #if DEBUG
        private func reasoningDebug(_ message: @autoclosure () -> String) {
            guard ClaudeReasoningExtractionFeature.isEnabled else { return }
            let line = "[ClaudeReasoningDebug][Runner] \(message())"
            print(line)
            ClaudeReasoningDebugLog.append(line)
        }
    #else
        private func reasoningDebug(_ message: @autoclosure () -> String) {}
    #endif

    private func reasoningDebugSnippet(_ text: String, limit: Int = 160) -> String {
        text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(limit)
            .description
    }

    init(
        claudeCoordinator: ClaudeAgentModeCoordinator,
        hooks: AgentModeRunService.Hooks,
        terminalCommitBarrier: AgentRunTerminalCommitBarrier
    ) {
        self.claudeCoordinator = claudeCoordinator
        self.hooks = hooks
        self.terminalCommitBarrier = terminalCommitBarrier
        claudeCoordinator.installIdleRuntimeReleaseRunnerFence { [weak self] tabID in
            self?.idleRuntimeReleaseBlocker(tabID: tabID)
        }
        claudeCoordinator.installIdleRuntimeReleaseRunTaskProbe { [weak self] tabID, attemptID in
            self?.idleDeliveryHoldsByTabID[tabID]?.contains(attemptID) == true
        }
    }

    /// Live-run fence for the coordinator's delegated idle release: a run task still alive, or
    /// provider output not yet delivered or still draining, keeps the runtime retained.
    private func idleRuntimeReleaseBlocker(tabID: UUID) -> String? {
        if idleDeliveryHoldsByTabID[tabID]?.isEmpty == false {
            return "run-task-alive"
        }
        if drainingEventRoutersByTabID[tabID]?.contains(where: { !$0.isFinished }) == true {
            return "draining-output"
        }
        if eventRoutersByTabID[tabID]?.hasUndeliveredEvents == true {
            return "undelivered-output"
        }
        return nil
    }

    func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        handoff: AgentProviderHandoff,
        makeLease: (_ runID: UUID, _ ownership: AgentRunOwnership) -> MCPBootstrapLease
    ) async {
        // A new turn ends any armed idle interval; this run's own end arms a fresh one.
        claudeCoordinator.cancelArmedIdleRuntimeRelease(for: tabID, reason: "new-turn")
        let attachmentReservationID = hooks.reserveAttachmentsForTurn(attachments, session)

        if initialMessageForRun != initialUserMessage,
           !session.pendingNonCodexUserInputTokenQueue.isEmpty
        {
            session.pendingNonCodexUserInputTokenQueue[0] = hooks.estimateRuntimeTokens(initialMessageForRun)
        }
        hooks.startNonCodexTurnAccountingIfNeeded(session, initialMessageForRun)
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()

        let runID = session.claudeController.flatMap { _ in
            AgentModeProcessRunIdentity.existingProcessRunID(for: session)
        } ?? AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        // Admit first: a Claude follow-up reuses its process run ID, so the attempt (not the run
        // ID) owns this turn's policy; the lease is built from that exact ownership.
        let ownership = session.beginRunAttempt(source: "claudeNative", inputUserItemID: handoff.attributedUserItemID)
        let lease = makeLease(runID, ownership)
        session.installRunAttemptTerminalResources(ownership: ownership) { terminalState in
            {
                switch terminalState {
                case .failed:
                    await lease.failAndRelease()
                case .cancelled:
                    await lease.cancelAndCleanup()
                default:
                    break
                }
            }
        }
        let runAttemptID = ownership.attemptID
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus("Thinking…", source: .transport)
        session.runState = .running
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        session.claudeExpectedTurnIDs.removeAll()
        hooks.setAgentRunActive(tabID, true)
        hooks.updateBindings(session)
        acquireIdleDeliveryHold(tabID: tabID, attemptID: runAttemptID)

        session.agentTask = Task { [weak self, weak session] in
            // Never reached the controller write → no handoff; written without its turn's
            // completion → delivery unknown.
            defer { handoff.settleRunInputScope() }
            guard let self else { return }
            defer {
                self.releaseIdleDeliveryHold(tabID: tabID, attemptID: runAttemptID)
                // A delegated tab's idle interval starts only from this attempt's own terminal
                // commit, and only when that commit is still current and its publication was
                // accepted (the barrier can reject or be superseded). Expiry also waits for the
                // save receipt and re-checks every fence.
                if let session {
                    self.claudeCoordinator.scheduleIdleRuntimeReleaseIfEligible(
                        for: session,
                        reason: "run-ended",
                        committedAttemptID: runAttemptID
                    )
                }
            }
            guard let session else { return }
            await withTaskCancellationHandler {
                let acquired = await lease.acquire()
                guard acquired else {
                    await self.handleAcquireFailure(
                        tabID: tabID,
                        session: session,
                        runID: runID,
                        ownership: ownership,
                        handoff: handoff,
                        attachmentReservationID: attachmentReservationID
                    )
                    return
                }

                await self.claudeCoordinator.ensureClaudeToolTrackingIfNeeded(
                    for: session,
                    runID: runID
                )

                // Attach the input's delivery attempts to this run attempt before the provider
                // is invoked; the send seam then only sends under this exact attempt.
                if case let .failure(failure) = await handoff.attachRunAttempt(
                    ownership: ownership,
                    processRunID: runID,
                    session: session
                ) {
                    AgentDeliveryRecordDiagnostics.runAttemptNotRecorded(route: .claude, runAttemptID: runAttemptID, failure: failure)
                    handoff.noteNoHandoff(message: AgentProviderHandoff.deliveryNotRecordedText(failure))
                    self.hooks.recordStagedInputSendOutcome(handoff: handoff, sent: false)
                    await self.finalize(
                        session: session,
                        runID: runID,
                        ownership: ownership,
                        attachmentReservationID: attachmentReservationID,
                        terminalState: .failed,
                        errorText: AgentRecoveryAdmissionFailure.deliveryNotRecordedText(),
                        notifyTurnComplete: false
                    )
                    return
                }
                guard !Task.isCancelled,
                      session.runID == runID,
                      session.activeRunAttemptID == runAttemptID
                else {
                    handoff.noteNoHandoff()
                    self.hooks.recordStagedInputSendOutcome(handoff: handoff, sent: false)
                    await self.finalize(
                        session: session,
                        runID: runID,
                        ownership: ownership,
                        attachmentReservationID: attachmentReservationID,
                        terminalState: .cancelled,
                        errorText: nil,
                        notifyTurnComplete: false
                    )
                    return
                }

                let providerName = session.selectedAgent.rawValue
                await lease.providerInitializationStarted(provider: providerName)
                // Everything the provider emits before this marker predates the run's message.
                let runMarker = await self.emitRunStartMarker(session: session, attemptID: runAttemptID)
                let sent = await self.claudeCoordinator.sendClaudeNativeMessage(
                    session: session,
                    text: initialMessageForRun,
                    attachments: attachments,
                    handoff: handoff
                )
                await lease.providerInitializationCompleted(
                    provider: providerName,
                    outcome: sent ? "ready" : (Task.isCancelled ? "cancelled" : "failed")
                )
                // Stage-scoped: a late outcome from this (possibly superseded) turn never settles
                // a newer turn's staged input, even though Claude reuses its process run ID. The
                // controller write is the stage-delivery boundary; an uncertain durable write
                // neither replays nor consumes the staged input, and the turn's later completion
                // (acceptance) settles it as sent.
                self.hooks.recordStagedInputSendOutcome(handoff: handoff, sent: sent)
                guard sent else {
                    await self.finalize(
                        session: session,
                        runID: runID,
                        ownership: ownership,
                        attachmentReservationID: attachmentReservationID,
                        terminalState: .failed,
                        errorText: nil,
                        notifyTurnComplete: false
                    )
                    return
                }

                self.hooks.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
                self.hooks.markAttachmentsConsumed(session, attachmentReservationID)
                // This run's events are held by the tab's router until `consumeEvents` below. A
                // later turn on a launch that kept its helper gets no new connection, so when the
                // run's route is proven to belong to this launch the routing wait is skipped; a
                // first or restarted launch still waits for its new helper to be routed.
                let launchAgentPID = await self.claudeCoordinator.repoPromptMCPLaunchAgentPID(for: session)
                var releasedForProvenRoute = false
                if let launchAgentPID {
                    releasedForProvenRoute = await lease.releaseWithProvenExistingRoute(agentPID: launchAgentPID)
                } else {
                    #if DEBUG
                        await lease.debugRecordProvenRouteReleaseSkipped(reason: "launch_agent_pid_unavailable")
                    #endif
                }
                if !releasedForProvenRoute {
                    _ = await lease.releaseWhenRouted()
                }

                guard let subscribed = await self.claudeCoordinator.eventSubscription(for: session) else {
                    await self.finalize(
                        session: session,
                        runID: runID,
                        ownership: ownership,
                        attachmentReservationID: attachmentReservationID,
                        terminalState: .failed,
                        errorText: "Claude native events stream not available.",
                        notifyTurnComplete: false
                    )
                    return
                }
                // A cancelled or superseded attempt must not select (and so replace) the tab's router.
                guard let router = await self.eventRouter(
                    for: session,
                    controller: subscribed.controller,
                    subscription: subscribed.subscription,
                    attemptID: runAttemptID,
                    runMarker: runMarker
                ) else {
                    await self.finalize(
                        session: session,
                        runID: runID,
                        ownership: ownership,
                        attachmentReservationID: attachmentReservationID,
                        terminalState: .cancelled,
                        errorText: nil,
                        notifyTurnComplete: false
                    )
                    return
                }
                session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
                let outcome = await self.consumeEvents(
                    router: router,
                    controller: subscribed.controller,
                    subscription: subscribed.subscription,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID
                )
                await self.finalize(
                    session: session,
                    runID: runID,
                    ownership: ownership,
                    attachmentReservationID: attachmentReservationID,
                    terminalState: outcome.terminalState,
                    errorText: outcome.errorText,
                    notifyTurnComplete: outcome.terminalState == .completed,
                    shouldShutdownSession: outcome.shouldShutdownSession,
                    cause: outcome.cause
                )
            } onCancel: {}
        }
    }

    private func consumeEvents(
        router initialRouter: ClaudeNativeEventRouter,
        controller: any NativeAgentRuntimeControlling,
        subscription: NativeAgentRuntimeEventsSubscription,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async -> ConsumeEventsOutcome {
        let box = ConsumeOutcomeBox()
        var router = initialRouter
        var resolution = await consumeRun(router: router, box: box, session: session, runID: runID, runAttemptID: runAttemptID)
        // A reused router of an older stream is only a prefix: if it ends without this run's
        // terminal event, the run continues on the stream it subscribed to.
        while box.value == nil, resolution == .streamEnded, !Task.isCancelled,
              session.activeRunAttemptID == runAttemptID,
              let ended = router.streamGeneration,
              let subscribed = subscription.generation,
              ended != subscribed
        {
            guard let next = await eventRouter(
                for: session,
                controller: controller,
                subscription: subscription,
                attemptID: runAttemptID,
                runMarker: nil
            ) else { break }
            router = next
            resolution = await consumeRun(router: router, box: box, session: session, runID: runID, runAttemptID: runAttemptID)
        }
        if var outcome = box.value {
            if outcome.terminalState == .failed, let turnID = outcome.failedTurnID,
               await controller.turnEndedByProcessLoss(turnID)
            {
                outcome.cause = .providerProcessLost
            }
            return outcome
        }
        switch resolution {
        case .finished, .cancelled:
            return ConsumeEventsOutcome(terminalState: .cancelled, errorText: nil, shouldShutdownSession: false)
        case .streamEnded:
            // A cancelled or superseded attempt is expected to stop consuming; that is not a
            // stream failure.
            if Task.isCancelled || session.activeRunAttemptID != runAttemptID {
                return ConsumeEventsOutcome(terminalState: .cancelled, errorText: nil, shouldShutdownSession: false)
            }
            // The events stream ended without a terminal turnCompleted event while this
            // attempt was still active.  This means the stream was finished or the Claude
            // process exited unexpectedly.
            return ConsumeEventsOutcome(
                terminalState: .failed,
                errorText: "Claude events stream ended unexpectedly. The run may need to be restarted.",
                shouldShutdownSession: false,
                cause: .providerProcessLost
            )
        }
    }

    private func consumeRun(
        router: ClaudeNativeEventRouter,
        box: ConsumeOutcomeBox,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async -> ClaudeNativeEventRouter.RunResolution {
        await router.consumeRun(attemptID: runAttemptID) { [weak self] event in
            guard let self else {
                box.value = ConsumeEventsOutcome(terminalState: .cancelled, errorText: nil, shouldShutdownSession: false)
                return .finish
            }
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID
            else {
                // This attempt no longer owns the session: it ends as cancelled without taking
                // the event, which the router then routes by ownership.
                box.value = ConsumeEventsOutcome(terminalState: .cancelled, errorText: nil, shouldShutdownSession: false)
                return .detach
            }
            switch event {
            case .approvalRequest, .approvalCancelled:
                // Approval requests from before the run's marker (and cancellations following
                // their recipient) are handed to the run without the stream being its own yet:
                // between-run output may still follow them. A run's own approval always follows
                // its own `tool_call` (a non-approval event), which marks the takeover first.
                break
            default:
                // Every other event dispatched here is the run's own, so the run took over this
                // stream: a background message it interrupted continues as this run's output, and
                // the stream's later between-run output starts a new message.
                hooks.endBackgroundNativeMessage(router.backgroundSourceID, session)
            }
            guard let outcome = await handleRunEvent(
                event,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                isEmittedBy: { router.isBound(to: $0) }
            ) else {
                return .continue
            }
            box.value = outcome
            return .finish
        }
    }

    /// Handles one event for the consuming run, which still owns the session. Returns the run's
    /// terminal outcome, or `nil` to keep consuming.
    private func handleRunEvent(
        _ event: NativeAgentRuntimeEvent,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        isEmittedBy: (AnyObject) -> Bool
    ) async -> ConsumeEventsOutcome? {
        if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
            session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
        }

        switch event {
        case let .stream(result):
            #if DEBUG
                if ClaudeReasoningExtractionFeature.isEnabled, result.type == "reasoning" {
                    let text = result.reasoning ?? result.text ?? ""
                    reasoningDebug("stream reasoning run=\(runID.uuidString) attempt=\(runAttemptID.uuidString) tab=\(session.tabID.uuidString) len=\(text.count) snippet=\(reasoningDebugSnippet(text))")
                }
            #endif
            // Accounting (plan §3.2) is not ingested from the transcript stream: attributed
            // results arrive on the controller's dedicated usage-evidence stream through the
            // session-owned forwarder (`TabSession.ingestNativeUsageAccountingEvent`), so a
            // transcript result here never carries accounting authority.
            await hooks.handleHeadlessStreamResult(result, session, runID, runAttemptID)
        case let .runtimeInit(status):
            persistRuntimeInitSessionID(status, session: session)
            if status.isRepoPromptServerFailed {
                return ConsumeEventsOutcome(
                    terminalState: .failed,
                    errorText: "RepoPrompt MCP failed to initialize for Claude (session \(status.sessionID ?? "unknown")).",
                    shouldShutdownSession: true
                )
            }
        case let .approvalRequest(request):
            if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: ownership, kind: .interaction, stage: .waitingForInteraction)
            }
            session.pendingApproval = request
            session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
            session.setRunningStatus(nil, source: nil)
            session.runState = .waitingForApproval
            hooks.updateBindings(session)
        case let .approvalCancelled(requestID):
            if session.pendingApproval?.requestID == .claudeControl(requestID) {
                session.pendingApproval = nil
                if session.runState == .waitingForApproval {
                    session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
                    session.setRunningStatus("Thinking…", source: .transport)
                    session.runState = .running
                }
                hooks.updateBindings(session)
            }
        case let .turnCompleted(turnID, turnStatus, origin):
            // Provider evidence first, before any reconciliation below.
            claudeCoordinator.noteClaudeTurnCompleted(
                turnID: turnID,
                status: turnStatus,
                origin: origin,
                isEmittedBy: isEmittedBy
            )
            guard session.claudeExpectedTurnIDs.contains(turnID) else {
                // Stale completion from a previous cancelled run attempt; ignore.
                return nil
            }
            session.claudeExpectedTurnIDs.remove(turnID)
            // Accounting closure travels on the controller's ordered usage stream
            // (`.turnClosed`, after any attribution for the turn); the transcript stream owns
            // no accounting mutation, so completion here can never race an attributed result.

            let wasProtectedClaudeTurn = session.claudeSupersedingProtectedTurnIDs.remove(turnID) != nil
            let hasLegacyUnscopedProtection = session.claudeSupersedingProtectedTurnIDs.isEmpty
                && session.pendingSupersedingTurnCompletions > 0
            if wasProtectedClaudeTurn || hasLegacyUnscopedProtection {
                session.pendingSupersedingTurnCompletions = max(0, session.pendingSupersedingTurnCompletions - 1)
                // Keep run alive for the next (superseding) turn regardless of the
                // stale turn's reported terminal status. Old interrupted turns can land
                // as .cancelled, .failed, or even .completed after the superseding send
                // is already in flight.
                if !session.runState.isActive {
                    session.runState = .running
                }
                hooks.setAgentRunActive(session.tabID, true)
                hooks.updateBindings(session)
                return nil
            }
            // No superseding turn expected — terminal for this run.
            session.pendingSupersedingTurnCompletions = 0
            session.claudeSupersedingProtectedTurnIDs.removeAll()
            switch turnStatus {
            case .completed:
                return ConsumeEventsOutcome(terminalState: .completed, errorText: nil, shouldShutdownSession: false)
            case .cancelled:
                return ConsumeEventsOutcome(terminalState: .cancelled, errorText: nil, shouldShutdownSession: false)
            case .failed:
                return ConsumeEventsOutcome(terminalState: .failed, errorText: nil, shouldShutdownSession: false, failedTurnID: turnID)
            }
        case let .error(message):
            session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
            session.setRunningStatus(nil, source: nil)
            appendRuntimeError(message, session: session)
        case .marker:
            // Markers are consumed by the router and never dispatched.
            break
        }
        return nil
    }

    // MARK: - Between-run delivery

    /// Where a run's start marker was emitted: the controller and its stream generation.
    private struct RunStartMarker {
        weak var controller: AnyObject?
        let generation: UInt64
    }

    /// Asks the controller to emit the run's start marker in order with provider output. When no
    /// marker can be emitted (no live stream, or a runtime without markers), the run's start is
    /// resolved now on the tab's router instead, before its message is sent.
    private func emitRunStartMarker(
        session: AgentTabSession,
        attemptID: UUID
    ) async -> RunStartMarker? {
        if let controller = session.claudeController,
           let generation = await controller.emitEventMarker(attemptID)
        {
            return RunStartMarker(controller: controller as AnyObject, generation: generation)
        }
        // A runtime that tracks stream generations only fails to emit when it has no live
        // stream; the tab's router then reads an ended stream whose remaining events predate
        // this run, and the run starts on the router of its subscribed stream instead.
        if let router = eventRoutersByTabID[session.tabID],
           router.streamGeneration == nil,
           !router.hasStreamEnded
        {
            router.resolveRunStart(attemptID: attemptID)
        }
        return nil
    }

    /// Returns the router for the subscribed stream.
    ///
    /// The tab's router is reused while it reads the subscribed stream. It is also reused when
    /// its stream ended but it still holds events of this run: if the process exits after the
    /// run's message was sent, the controller emits the run's failure on the old stream before
    /// finishing it, and `eventsSubscription` then returns a new, empty stream. Such a router is
    /// only a prefix (`consumeEvents` continues on the subscribed stream if it ends without the
    /// run's terminal event). Otherwise a router of the tab is kept draining what its stream
    /// carries, and a draining router that reads the subscribed stream is revived rather than
    /// given a second reader. Returns `nil`, touching no router, when the attempt was cancelled or
    /// superseded (also while waiting for the older stream to end).
    private func eventRouter(
        for session: AgentTabSession,
        controller: any NativeAgentRuntimeControlling,
        subscription: NativeAgentRuntimeEventsSubscription,
        attemptID: UUID,
        runMarker: RunStartMarker?
    ) async -> ClaudeNativeEventRouter? {
        let controllerObject = controller as AnyObject
        if let existing = eventRoutersByTabID[session.tabID],
           existing.isBound(to: controllerObject),
           let generation = existing.streamGeneration,
           let subscribed = subscription.generation,
           generation < subscribed
        {
            // The controller replaces its stream only after finishing it, so this only waits for
            // the reader to take in what the older, finished stream still buffers. Deciding
            // before that could miss this run's failure and leave it waiting on the empty new
            // stream. A router of a newer stream is never waited on (it may stay live).
            await existing.waitUntilStreamEnded()
        }
        guard !Task.isCancelled, session.activeRunAttemptID == attemptID else { return nil }
        return selectEventRouter(
            for: session,
            controllerObject: controllerObject,
            subscription: subscription,
            attemptID: attemptID,
            runMarker: runMarker
        )
    }

    private func selectEventRouter(
        for session: AgentTabSession,
        controllerObject: AnyObject,
        subscription: NativeAgentRuntimeEventsSubscription,
        attemptID: UUID,
        runMarker: RunStartMarker?
    ) -> ClaudeNativeEventRouter {
        let tabID = session.tabID
        func readsSubscribedStream(_ router: ClaudeNativeEventRouter) -> Bool {
            guard router.isBound(to: controllerObject), !router.isFinished else { return false }
            if let generation = router.streamGeneration, let subscribed = subscription.generation {
                return generation == subscribed
            }
            return !router.hasStreamEnded
        }
        let markerIsOnSubscribedStream = runMarker.map { marker in
            marker.controller === controllerObject && marker.generation == subscription.generation
        } ?? false

        if let existing = eventRoutersByTabID[tabID] {
            if readsSubscribedStream(existing) {
                return existing
            }
            if existing.isBound(to: controllerObject), existing.holdsUndeliveredEvents(ownedBy: attemptID) {
                return existing
            }
            eventRoutersByTabID.removeValue(forKey: tabID)
            if !existing.isFinished {
                drainingEventRoutersByTabID[tabID, default: []].append(existing)
            }
        }
        if let revived = drainingEventRoutersByTabID[tabID]?.first(where: readsSubscribedStream) {
            drainingEventRoutersByTabID[tabID]?.removeAll { $0 === revived }
            if markerIsOnSubscribedStream {
                revived.noteRunStarted(attemptID: attemptID)
            }
            eventRoutersByTabID[tabID] = revived
            session.claudeAuthoritativeEventSourceID = revived.backgroundSourceID
            return revived
        }

        // Identifies this stream's between-run output: a background message never continues
        // across streams (provider launches).
        let backgroundSourceID = UUID()
        let router = ClaudeNativeEventRouter(
            controller: controllerObject,
            streamGeneration: subscription.generation,
            backgroundSourceID: backgroundSourceID,
            events: subscription.events,
            // With the run's marker on this stream, events before it predate the run.
            initialOwner: markerIsOnSubscribedStream ? nil : attemptID,
            idleHandler: { [weak self, weak session, weak controllerObject] event in
                guard let self, let session, let controllerObject else { return }
                await handleBetweenRunEvent(
                    event,
                    session: session,
                    controller: controllerObject,
                    sourceID: backgroundSourceID
                )
            },
            isRunTaskAlive: { [weak self] attemptID in
                self?.idleDeliveryHoldsByTabID[tabID]?.contains(attemptID) == true
            },
            onFinished: { [weak self] router in
                guard let self else { return }
                if eventRoutersByTabID[tabID] === router {
                    eventRoutersByTabID.removeValue(forKey: tabID)
                }
                drainingEventRoutersByTabID[tabID]?.removeAll { $0 === router }
                if drainingEventRoutersByTabID[tabID]?.isEmpty == true {
                    drainingEventRoutersByTabID.removeValue(forKey: tabID)
                }
                // A written message's late completion can only arrive through a live router of
                // its writing controller; once none remains, its delivery stays unknown.
                let liveRouters: [ClaudeNativeEventRouter] = (eventRoutersByTabID[tabID].map { [$0] } ?? [])
                    + (drainingEventRoutersByTabID[tabID] ?? [])
                claudeCoordinator.releaseWrittenDispatchHandoffs(tabID: tabID) { controller in
                    liveRouters.contains { !$0.isFinished && $0.isBound(to: controller) }
                }
            },
            onInboxChanged: { [weak self, weak session] router in
                // A held approval request (waiting for the next run) or one dropped with its
                // cancellation is activity for the delegated idle interval of the runtime this
                // router reads; another runtime's router is not. Ordinary stream output re-arms
                // through the between-run handler instead.
                guard let self, let session,
                      let controller = session.claudeController,
                      router.isBound(to: controller as AnyObject)
                else { return }
                claudeCoordinator.noteIdleRuntimeActivity(for: session)
            }
        )
        if markerIsOnSubscribedStream {
            router.noteRunStarted(attemptID: attemptID)
        }
        eventRoutersByTabID[tabID] = router
        // Only the tab's current stream updates session metadata between runs: a replaced stream
        // still draining is shown but never overwrites the newer launch's provider session ID.
        session.claudeAuthoritativeEventSourceID = backgroundSourceID
        router.start()
        return router
    }

    /// Releases the finishing run right after its completion was captured for attention
    /// notifications: it will not consume again, so output it still owns is between-run output
    /// and is not held until its task returns.
    private func releaseFinishingRun(tabID: UUID, attemptID: UUID) {
        eventRoutersByTabID[tabID]?.release(attemptID: attemptID)
        for router in drainingEventRoutersByTabID[tabID] ?? [] {
            router.release(attemptID: attemptID)
        }
    }

    /// Delivers provider output that arrived before a queued follow-up starts, so it is shown
    /// before the follow-up's user row. The finishing run is released first: it will not consume
    /// again, so output it still owns is between-run output.
    private func deliverBetweenRunOutput(
        session: AgentTabSession,
        releasing attemptID: UUID
    ) async {
        // Routers whose stream was replaced deliver what they have read; their streams ended or
        // carry nothing newer than the current stream.
        for draining in drainingEventRoutersByTabID[session.tabID] ?? [] {
            await draining.drain(releasing: attemptID, throughMarker: nil)
        }
        if let router = eventRoutersByTabID[session.tabID] {
            var markerID: UUID?
            if let controller = session.claudeController, router.isBound(to: controller as AnyObject) {
                let id = UUID()
                if let generation = await controller.emitEventMarker(id), generation == router.streamGeneration {
                    markerID = id
                }
            }
            await router.drain(releasing: attemptID, throughMarker: markerID)
        }
        // Background text is applied to the transcript directly; this only materializes run text
        // still buffered (normally none after the terminal commit's own flush), so nothing
        // buffered can follow the follow-up's user row.
        hooks.flushPendingAssistantDelta(session)
    }

    /// Marks the run task alive and registers its start on the tab's router. Called synchronously
    /// in `startRun`, after the caller appended the run's user row.
    private func acquireIdleDeliveryHold(tabID: UUID, attemptID: UUID) {
        idleDeliveryHoldsByTabID[tabID, default: []].insert(attemptID)
        eventRoutersByTabID[tabID]?.noteRunStarted(attemptID: attemptID)
    }

    private func releaseIdleDeliveryHold(tabID: UUID, attemptID: UUID) {
        if var holds = idleDeliveryHoldsByTabID[tabID] {
            holds.remove(attemptID)
            if holds.isEmpty {
                idleDeliveryHoldsByTabID.removeValue(forKey: tabID)
            } else {
                idleDeliveryHoldsByTabID[tabID] = holds
            }
        }
        eventRoutersByTabID[tabID]?.noteRunEnded(attemptID: attemptID)
        for router in drainingEventRoutersByTabID[tabID] ?? [] {
            router.noteRunEnded(attemptID: attemptID)
        }
    }

    /// Output the provider produced while no run is consuming, typically an autonomous
    /// continuation after a background task finished. It is shown as soon as it arrives.
    /// Approval requests reach this handler only when their stream ended (the process is gone),
    /// and are discarded.
    private func handleBetweenRunEvent(
        _ event: NativeAgentRuntimeEvent,
        session: AgentTabSession,
        controller: AnyObject,
        sourceID: UUID
    ) async {
        if case let .turnCompleted(turnID, turnStatus, origin) = event {
            // Provider evidence for a written message is honored even after its run attempt
            // ended or the tab moved to another controller: it applies only to the turn this
            // same controller wrote (never a successor's).
            claudeCoordinator.noteClaudeTurnCompleted(
                turnID: turnID,
                status: turnStatus,
                origin: origin,
                isEmittedBy: { $0 === controller }
            )
        }
        guard session.selectedAgent.usesClaudeNativeRuntime,
              let current = session.claudeController,
              (current as AnyObject) === controller
        else {
            // Output from a controller the tab no longer owns is dropped, as it was when no
            // consumer existed for a detached controller's stream.
            return
        }
        switch event {
        case let .stream(result):
            await hooks.handleBackgroundNativeStreamResult(result, sourceID, session)
            // Between-run provider activity restarts a full idle interval.
            claudeCoordinator.scheduleIdleRuntimeReleaseIfEligible(for: session, reason: "background-output")
        case let .runtimeInit(status):
            guard session.claudeAuthoritativeEventSourceID == sourceID else { return }
            persistRuntimeInitSessionID(status, session: session)
            // A between-run conversation identity change ends the armed interval as stale; the
            // same runtime is re-armed for its new identity.
            claudeCoordinator.scheduleIdleRuntimeReleaseIfEligible(for: session, reason: "runtime-init")
        case let .error(message):
            // Through the background stream path, which records the row as between-run output so
            // neither a run's continuation nor its notification text treats it as the run's.
            guard let text = Self.displayableRuntimeErrorText(message) else { return }
            await hooks.handleBackgroundNativeStreamResult(AIStreamResult(type: "error", text: text), sourceID, session)
            claudeCoordinator.scheduleIdleRuntimeReleaseIfEligible(for: session, reason: "background-output")
        case .turnCompleted:
            // Delivery evidence was recorded above; a between-run completion belongs to no
            // expected turn.
            break
        case .approvalRequest, .approvalCancelled, .marker:
            // A pending approval cannot exist without a run.
            break
        }
    }

    /// Persist provider session ID as soon as it becomes available from runtime init events
    /// (initialize response or system/init stream).
    private func persistRuntimeInitSessionID(
        _ status: NativeAgentRuntimeRuntimeInitStatus,
        session: AgentTabSession
    ) {
        guard let newSessionID = status.sessionID,
              !newSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              newSessionID != session.providerSessionID
        else {
            return
        }
        session.providerSessionID = newSessionID
        session.isDirty = true
        hooks.scheduleSave(session.tabID)
    }

    /// The runtime error text shown in the transcript, or nil when it is empty or suppressed.
    private static func displayableRuntimeErrorText(_ message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        #if !DEBUG
            // Suppress known non-actionable abort side-effect errors (e.g. JSON parse
            // errors from killed tool processes) in release builds.
            if isKnownNonActionableStreamError(trimmed) { return nil }
        #endif
        return trimmed
    }

    private func appendRuntimeError(_ message: String, session: AgentTabSession) {
        guard let trimmed = Self.displayableRuntimeErrorText(message) else { return }
        // Text the run received before the error is shown above it.
        hooks.flushPendingAssistantDelta(session)
        let errorItem = AgentChatItem.error(trimmed, sequenceIndex: session.nextSequenceIndex)
        session.appendItem(errorItem)
        hooks.updateBindings(session)
        hooks.scheduleSave(session.tabID)
    }

    private func handleAcquireFailure(
        tabID _: UUID,
        session: AgentTabSession,
        runID: UUID,
        ownership: AgentRunOwnership,
        handoff: AgentProviderHandoff,
        attachmentReservationID: UUID?
    ) async {
        // Never reached the provider: release the staged input before the terminal commit.
        handoff.noteNoHandoff()
        hooks.recordStagedInputSendOutcome(handoff: handoff, sent: false)
        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: runID,
            terminalState: .cancelled,
            source: "claudeNative.acquireFailure",
            cause: .ordinary,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: true,
            notifyTurnComplete: false
        ))
    }

    private func finalize(
        session: AgentTabSession,
        runID: UUID,
        ownership: AgentRunOwnership,
        attachmentReservationID: UUID?,
        terminalState: AgentSessionRunState,
        errorText: String?,
        notifyTurnComplete: Bool,
        shouldShutdownSession: Bool = false,
        cause: AgentRunTerminalCause = .ordinary
    ) async {
        // Messages this attempt wrote whose turn never completed stay delivery-unknown.
        claudeCoordinator.settleWrittenDispatchHandoffs(tabID: session.tabID, runAttemptID: ownership.attemptID)
        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: runID,
            terminalState: terminalState,
            source: "claudeNative.finalize",
            cause: cause,
            errorText: errorText,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: true,
            notifyTurnComplete: notifyTurnComplete,
            prepareProviderState: { [claudeCoordinator] in
                session.pendingSupersedingTurnCompletions = 0
                session.claudeSupersedingProtectedTurnIDs.removeAll()
                session.claudeExpectedTurnIDs.removeAll()
                guard shouldShutdownSession else { return nil }
                let oldController = claudeCoordinator.prepareClaudeCancelSync(session)
                return {
                    claudeCoordinator.beginClaudeResumeTransferIfNeeded(
                        for: session,
                        oldController: oldController
                    )
                    await claudeCoordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)
                }
            },
            releaseProviderOutput: { [weak self] in
                self?.releaseFinishingRun(tabID: session.tabID, attemptID: ownership.attemptID)
            },
            deliverProviderOutputBeforeFollowUp: { [weak self] in
                await self?.deliverBetweenRunOutput(session: session, releasing: ownership.attemptID)
            }
        ))
    }

    // MARK: - Error Filtering

    /// Returns `true` when the error message is a known non-actionable abort side
    /// effect (e.g. JSON parse errors from killed tool processes, MCP AbortErrors).
    /// These are suppressed in release builds to avoid alarming users.
    private static func isKnownNonActionableStreamError(_ message: String) -> Bool {
        ClaudeAbortArtifactFilter.shouldSuppressUserFacingError(message)
    }
}
