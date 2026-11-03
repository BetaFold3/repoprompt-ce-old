import Foundation
import RepoPromptAgentCore

@MainActor
extension AgentModeViewModel {
    func submitApprovalDecision(tabID: UUID, decision: AgentApprovalDecision) {
        guard let session = sessions[tabID],
              let request = session.pendingApproval
        else {
            return
        }
        let interactionID = request.id
        switch request.requestID {
        case .codex:
            codexCoordinator.submitApprovalDecision(session: session, decision: decision)
        case .claudeControl:
            claudeCoordinator.submitApprovalDecision(session: session, decision: decision)
        case let .remoteGateway(remoteInteractionID):
            remoteCoordinator.submitApprovalDecision(
                session: session,
                interactionID: remoteInteractionID,
                decision: decision
            )
        case let .acp(requestID):
            session.pendingApproval = nil
            if session.runState == .waitingForApproval {
                session.runState = .running
            }
            requestUIRefresh(tabID: tabID, urgent: true)
            Task { [controller = session.acpController] in
                await controller?.respondToPermissionRequest(id: requestID, decision: decision)
            }
        }
        // The provider coordinators clear `pendingApproval` synchronously only when
        // their guards pass; emit the resolution event only for an actual resolution.
        if session.pendingApproval?.id != interactionID {
            recordMCPInteractionResolution(for: session, interactionID: interactionID)
        }
    }

    func submitMCPElicitationResponse(
        tabID: UUID,
        requestID: UUID,
        response: AgentMCPElicitationResponse
    ) {
        // Answers are frozen while a shutdown preserves this window (same boundary as ask_user).
        guard !isShutdownFrozen else { return }
        guard let session = sessions[tabID],
              let request = session.pendingMCPElicitationRequest,
              request.id == requestID
        else {
            return
        }
        if session.remoteHost != nil {
            remoteCoordinator.submitMCPElicitationResponse(session: session, request: request, response: response)
            recordMCPInteractionResolution(for: session, interactionID: request.id)
            return
        }
        codexCoordinator.submitMCPElicitationResponse(session: session, request: request, response: response)
    }

    func submitApplyEditsReviewDecision(
        tabID: UUID,
        reviewID: UUID,
        decision: ApplyEditsReviewDecision
    ) {
        let scope = applyEditsScope(for: tabID)
        Task { [applyEditsApprovalStore] in
            await applyEditsApprovalStore.resolveReview(
                scope: scope,
                reviewID: reviewID,
                decision: decision
            )
        }
    }
}
