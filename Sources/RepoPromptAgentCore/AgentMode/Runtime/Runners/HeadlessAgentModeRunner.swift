import Foundation

/// The run's input could not be associated with its run attempt before the provider handoff; the
/// provider was not invoked and the input's intent is back in `queued`.
private enum HeadlessHandoffError: LocalizedError {
    case deliveryNotRecorded
    /// The dispatching lane retired or froze for reset after the dispatch commit (R06).
    case sessionChangedBeforeHandoff
    /// The deferred dispatch commit (adopted plan §5) could not be completed; nothing was sent.
    case dispatchNotCommitted(AgentProviderHandoff.CommitFailure)

    var errorDescription: String? {
        switch self {
        case .deliveryNotRecorded:
            AgentRecoveryAdmissionFailure.deliveryNotRecordedText()
        case .sessionChangedBeforeHandoff:
            AgentProviderHandoff.sessionChangedBeforeHandoffMessage
        case let .dispatchNotCommitted(failure):
            failure.userText
        }
    }
}

@MainActor
final class HeadlessAgentModeRunner {
    private let headlessProviderFactory: AgentHeadlessProviderFactory
    private let hooks: AgentModeRunService.Hooks
    private let terminalCommitBarrier: AgentRunTerminalCommitBarrier

    init(
        headlessProviderFactory: @escaping AgentHeadlessProviderFactory,
        hooks: AgentModeRunService.Hooks,
        terminalCommitBarrier: AgentRunTerminalCommitBarrier
    ) {
        self.headlessProviderFactory = headlessProviderFactory
        self.hooks = hooks
        self.terminalCommitBarrier = terminalCommitBarrier
    }

    func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        handoff: AgentProviderHandoff,
        makeLease: (_ runID: UUID) -> MCPBootstrapLease
    ) async {
        // The run task owns the handoff once created; every earlier exit never reached the provider.
        var runTaskOwnsHandoff = false
        defer {
            if !runTaskOwnsHandoff {
                handoff.settleRunInputScope()
            }
        }
        let attachmentReservationID = hooks.reserveAttachmentsForTurn(attachments, session)

        if initialMessageForRun != initialUserMessage,
           !session.pendingNonCodexUserInputTokenQueue.isEmpty
        {
            session.pendingNonCodexUserInputTokenQueue[0] = hooks.estimateRuntimeTokens(initialMessageForRun)
        }
        hooks.startNonCodexTurnAccountingIfNeeded(session, initialMessageForRun)

        let runID = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        let lease = makeLease(runID)

        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()

        let ownership = session.beginRunAttempt(source: "headless", inputUserItemID: handoff.attributedUserItemID)
        let runAttemptID = ownership.attemptID
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        session.runningStatusText = nil
        session.runningStatusSource = nil
        session.runState = .running
        hooks.setAgentRunActive(tabID, true)
        hooks.updateBindings(session)

        guard session.selectedAgent != .codexExec else {
            await terminalCommitBarrier.commit(.init(
                session: session,
                ownership: ownership,
                expectedRunID: runID,
                terminalState: .failed,
                source: "headless.invalidRoute",
                cause: .ordinary,
                errorText: "Internal routing error: Codex native run attempted to use headless provider path.",
                attachmentReservationID: attachmentReservationID,
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: true,
                supportsFollowUp: false,
                notifyTurnComplete: false,
                prepareProviderState: {
                    session.provider = nil
                    session.runID = nil
                    return nil
                }
            ))
            return
        }

        let provider: HeadlessAgentProvider
        do {
            provider = try headlessProviderFactory(
                session.selectedAgent,
                session.selectedModelRaw == AgentModel.defaultModel.rawValue
                    ? nil
                    : session.selectedModelRaw
            )
        } catch {
            await terminalCommitBarrier.commit(.init(
                session: session,
                ownership: ownership,
                expectedRunID: runID,
                terminalState: .failed,
                source: "headless.providerFactory",
                cause: .ordinary,
                errorText: error.localizedDescription,
                attachmentReservationID: attachmentReservationID,
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: true,
                supportsFollowUp: false,
                notifyTurnComplete: false,
                prepareProviderState: {
                    session.provider = nil
                    session.runID = nil
                    return nil
                }
            ))
            return
        }
        session.provider = provider
        session.installRunAttemptTerminalResources(ownership: ownership) { terminalState in
            session.provider = nil
            if session.runID == runID {
                session.runID = nil
            }
            return {
                switch terminalState {
                case .failed:
                    await lease.failAndRelease()
                case .cancelled:
                    await lease.cancelAndCleanup()
                default:
                    break
                }
                await provider.dispose()
            }
        }

        runTaskOwnsHandoff = true
        session.agentTask = Task { [weak self, weak session] in
            defer { handoff.settleRunInputScope() }
            guard let self, let session else { return }
            await withTaskCancellationHandler {
                let acquired = await lease.acquire()
                guard acquired else {
                    await self.handleAcquireFailure(
                        session: session,
                        runID: runID,
                        ownership: ownership,
                        handoff: handoff,
                        attachmentReservationID: attachmentReservationID
                    )
                    return
                }

                let agentMessage = self.hooks.buildHeadlessAgentMessage(
                    session,
                    initialMessageForRun,
                    runID,
                    attachments
                )
                await self.executeHeadlessRun(
                    session: session,
                    provider: provider,
                    initialMessage: agentMessage,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    ownership: ownership,
                    handoff: handoff,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    lease: lease
                )
            } onCancel: {}
        }
    }

    private func handleAcquireFailure(
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
            source: "headless.acquireFailure",
            cause: .ordinary,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            prepareProviderState: {
                session.provider = nil
                session.runID = nil
                return nil
            }
        ))
    }

    private func executeHeadlessRun(
        session: AgentTabSession,
        provider: HeadlessAgentProvider,
        initialMessage: AgentMessage,
        runID: UUID,
        runAttemptID: UUID,
        ownership: AgentRunOwnership,
        handoff: AgentProviderHandoff,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        lease: MCPBootstrapLease
    ) async {
        var providerInitializationCompleted = false
        do {
            await lease.providerInitializationStarted(provider: session.selectedAgent.rawValue)
            // The input's delivery attempts are attached to this run attempt before the provider
            // is invoked; then the exact attempt must still own the session.
            if case let .failure(failure) = await handoff.attachRunAttempt(
                ownership: ownership,
                processRunID: runID,
                session: session
            ) {
                AgentDeliveryRecordDiagnostics.runAttemptNotRecorded(route: .headless, runAttemptID: runAttemptID, failure: failure)
                handoff.noteNoHandoff(message: AgentProviderHandoff.deliveryNotRecordedText(failure))
                throw HeadlessHandoffError.deliveryNotRecorded
            }
            // Deferred dispatch commit (no bootstrap on this route creates a pending-handoff prefix;
            // a payload created after the commit still blocks the send).
            var commitFailure: AgentProviderHandoff.CommitFailure?
            if case let .failure(failure) = await handoff.commitDispatch(session: session) {
                commitFailure = failure
            } else if handoff.pendingHandoffCreatedAfterCommit(in: session) {
                commitFailure = .pendingHandoffAfterCommit
            }
            if let commitFailure {
                handoff.blockBeforeHandoff(commitFailure)
                throw HeadlessHandoffError.dispatchNotCommitted(commitFailure)
            }
            guard !Task.isCancelled, session.isCurrentRunAttempt(ownership, expectedRunID: runID) else {
                handoff.noteNoHandoff()
                throw CancellationError()
            }
            // Stream creation is the handoff boundary, not acceptance. Final ownership check with no
            // suspension before the provider call.
            guard handoff.enterProviderBoundary(in: session) else {
                throw HeadlessHandoffError.sessionChangedBeforeHandoff
            }
            let stream = try await provider.streamAgentMessage(initialMessage, runID: runID)
            providerInitializationCompleted = true
            await lease.providerInitializationCompleted(provider: session.selectedAgent.rawValue, outcome: "ready")
            // Stream creation is the headless stage-delivery boundary (not acceptance).
            hooks.recordStagedInputSendOutcome(handoff: handoff, sent: true)
            hooks.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
            hooks.markAttachmentsConsumed(session, attachmentReservationID)
            _ = await lease.releaseWhenRouted()
            if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
            }

            for try await result in stream {
                // Model output is the provider's affirmative evidence; record it before anything
                // that could end this loop.
                if handoff.observation != .accepted,
                   AgentProviderHandoff.streamResultProvesProviderAcceptance(result)
                {
                    handoff.noteAccepted()
                }
                guard !Task.isCancelled else { break }
                guard session.isCurrentRunAttempt(ownership, expectedRunID: runID) else { return }
                session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
                await hooks.handleHeadlessStreamResult(result, session, runID, runAttemptID)
            }

            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID
            else {
                return
            }

            await terminalCommitBarrier.commit(.init(
                session: session,
                ownership: ownership,
                expectedRunID: runID,
                terminalState: .completed,
                source: "headless.completed",
                cause: .ordinary,
                attachmentReservationID: attachmentReservationID,
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: true,
                supportsFollowUp: false,
                notifyTurnComplete: true,
                prepareProviderState: {
                    session.provider = nil
                    session.runID = nil
                    return nil
                }
            ))
        } catch is CancellationError {
            if !providerInitializationCompleted {
                await lease.providerInitializationCompleted(provider: session.selectedAgent.rawValue, outcome: "cancelled")
            }
            // No-op once the stream started (that stage already committed). Stream creation that
            // failed after the boundary was entered leaves durable input uncertain: held.
            hooks.recordStagedInputSendOutcome(handoff: handoff, sent: false)
            await terminalCommitBarrier.commit(.init(
                session: session,
                ownership: ownership,
                expectedRunID: runID,
                terminalState: .cancelled,
                source: "headless.cancelled",
                cause: .ordinary,
                attachmentReservationID: attachmentReservationID,
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: true,
                supportsFollowUp: false,
                notifyTurnComplete: false,
                prepareProviderState: {
                    session.provider = nil
                    session.runID = nil
                    return nil
                }
            ))
        } catch {
            if !providerInitializationCompleted {
                await lease.providerInitializationCompleted(provider: session.selectedAgent.rawValue, outcome: "failed")
            }
            hooks.recordStagedInputSendOutcome(handoff: handoff, sent: false)
            await terminalCommitBarrier.commit(.init(
                session: session,
                ownership: ownership,
                expectedRunID: runID,
                terminalState: .failed,
                source: "headless.failed",
                // Review A F06: only a provider's typed process loss; every other error is ordinary.
                cause: error is HeadlessProviderProcessLostError ? .providerProcessLost : .ordinary,
                errorText: "Agent failed: \(error.localizedDescription)",
                attachmentReservationID: attachmentReservationID,
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: true,
                supportsFollowUp: false,
                notifyTurnComplete: false,
                prepareProviderState: {
                    session.provider = nil
                    session.runID = nil
                    return nil
                }
            ))
        }
    }
}
