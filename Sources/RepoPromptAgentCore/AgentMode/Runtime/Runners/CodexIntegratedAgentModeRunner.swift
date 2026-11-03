import Foundation
import RepoPromptWorkspace

@MainActor
final class CodexIntegratedAgentModeRunner {
    private let mcpServerEnabler: AgentMCPServerEnabler
    private let codexCoordinator: CodexAgentModeCoordinator
    private let hooks: AgentModeRunService.Hooks

    init(
        mcpServerEnabler: @escaping AgentMCPServerEnabler,
        codexCoordinator: CodexAgentModeCoordinator,
        hooks: AgentModeRunService.Hooks
    ) {
        self.mcpServerEnabler = mcpServerEnabler
        self.codexCoordinator = codexCoordinator
        self.hooks = hooks
    }

    func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        fallbackContext: AgentTabSession.CodexFallbackSubmissionContext?,
        stagedInput: AgentCarriedStagedInput = AgentCarriedStagedInput()
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome {
        let ownership: AgentRunOwnership
        let createdOwnership: Bool
        if let activeOwnership = session.activeRunOwnership {
            ownership = activeOwnership
            createdOwnership = false
        } else {
            ownership = session.beginRunAttempt(source: "codex")
            createdOwnership = true
            session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        }
        let attemptGeneration = session.runAttemptGeneration
        let attachmentReservationID = hooks.reserveAttachmentsForTurn(attachments, session)

        let sendTask = Task<CodexAgentModeCoordinator.NativeSendOutcome, Never> { [weak self, weak session] in
            guard let self, let session else {
                return .cancelled
            }
            defer {
                // A send outliving Stop must not clear a successor run's task handle.
                if !Self.isSupersededBySuccessor(ownership, attemptGeneration: attemptGeneration, session: session) {
                    session.agentTask = nil
                }
            }
            #if DEBUG || EDIT_FLOW_PERF
                let codexTurnMCPServerEnableState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable)
            #endif
            await mcpServerEnabler()
            #if DEBUG || EDIT_FLOW_PERF
                EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable, codexTurnMCPServerEnableState)
            #endif

            let outcome = await codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: initialMessageForRun,
                attachments: attachments,
                fallbackContext: fallbackContext,
                attachmentReservationID: attachmentReservationID,
                terminalizeRejectedSend: createdOwnership
            )
            // Exact-stage settlement. Uncertainty is neither consumption nor permission to replay:
            // both stages stay held. A superseded send leaves the successor's staging alone.
            if !Self.isSupersededBySuccessor(ownership, attemptGeneration: attemptGeneration, session: session) {
                hooks.recordPendingHandoffSendOutcome(
                    session,
                    stagedInput.pendingHandoffStage,
                    Self.pendingHandoffDisposition(for: outcome)
                )
            }
            if stagedInput.delegatedQuestionStageID != nil {
                hooks.recordDelegatedQuestionNoticeSendOutcome(
                    session,
                    stagedInput.delegatedQuestionStageID,
                    Self.delegatedQuestionNoticeDisposition(for: outcome)
                )
            }
            switch outcome {
            case .sent:
                session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
            case .cancelled, .failed, .stale, .deliveryUnknown:
                // `.deliveryUnknown`: the durable intent stays uncertain (or in flight through
                // another send); it is never retried from here.
                if createdOwnership {
                    session.endRunAttempt(ifCurrent: ownership, source: "codex.sendRejected")
                }
            case .queuedFallback:
                break
            }
            return outcome
        }
        session.agentTask = Task {
            await withTaskCancellationHandler {
                _ = await sendTask.value
            } onCancel: {
                sendTask.cancel()
            }
        }
        return await sendTask.value
    }

    /// True once a later run attempt took the tab (Stop, then a new send, while this send was still
    /// starting), whether that attempt still owns the tab or has already ended and released it.
    private static func isSupersededBySuccessor(
        _ ownership: AgentRunOwnership,
        attemptGeneration: UInt64,
        session: AgentTabSession
    ) -> Bool {
        if session.runAttemptGeneration != attemptGeneration {
            return true
        }
        guard let currentOwnership = session.activeRunOwnership else { return false }
        return currentOwnership != ownership
    }

    /// Codex stage-delivery boundary for the staged pending-handoff payload. `turn/start` is the send
    /// boundary; a queued fallback carries the payload inside its durably queued provider text, so
    /// the session's copy is consumed. Uncertainty holds the payload; every other refusal proves
    /// nothing was handed off.
    static func pendingHandoffDisposition(
        for outcome: CodexAgentModeCoordinator.NativeSendOutcome
    ) -> AgentStagedInputDisposition {
        switch outcome {
        case .sent, .queuedFallback:
            .sent
        case .deliveryUnknown:
            .deliveryUnknown
        case .stale, .cancelled, .failed:
            .notSent
        }
    }

    /// Delegated child-question notices acknowledge only at an actual send: a queued fallback has not
    /// reached the model, so its stage is released (and its block stripped from the queued copy).
    static func delegatedQuestionNoticeDisposition(
        for outcome: CodexAgentModeCoordinator.NativeSendOutcome
    ) -> AgentStagedInputDisposition {
        switch outcome {
        case .sent:
            .sent
        case .deliveryUnknown:
            .deliveryUnknown
        case .queuedFallback, .stale, .cancelled, .failed:
            .notSent
        }
    }
}
