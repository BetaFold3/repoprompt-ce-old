import Foundation
import MCP
import RepoPromptAgentCore

// Paired-browser (gateway) control of UI-driven root sessions
// (docs/context/plans/2026-10-30-telegram-remote-link-specs.md, Step 1).
//
// A verified per-device gateway caller acts on exactly the sessions that alert: the authoritative
// live session for a durable session ID that passes `isAttentionNotificationRoot` (no MCP control,
// depth-0 lineage) and runs on this Mac. It reuses the session-targeted send and resolution cores
// and the desktop Stop path. Nothing here installs MCP control, so a remote action never removes
// the session from later alerts. Only `ask_user` questions can be answered; approvals, MCP
// elicitations, and Codex `requestUserInput` stay on the Mac.

@MainActor
extension AgentModeViewModel {
    /// The authority that resolved a session-targeted send or resolution. Post-await fences
    /// re-resolve through the same authority and require the same live session object.
    enum SessionInstructionTarget: Equatable {
        /// The session's MCP control context (`mcpControlledSession(sessionID:)`).
        case mcpControlled
        /// A remote-controllable attention root (`remoteAttentionRootSession(sessionID:)`).
        case remoteAttentionRoot
    }

    func instructionTargetSession(sessionID: UUID, target: SessionInstructionTarget) -> AgentTabSession? {
        switch target {
        case .mcpControlled:
            mcpControlledSession(sessionID: sessionID)
        case .remoteAttentionRoot:
            remoteAttentionRootSession(sessionID: sessionID)
        }
    }

    /// The live session a paired device may act on: the authoritative live binding for `sessionID`
    /// (unique, and `authoritativeLiveSession` already requires the same durable identity), executed
    /// on this Mac (not a projected remote-host session), and an attention-notification root. Nil
    /// otherwise, including ambiguous bindings.
    func remoteAttentionRootSession(sessionID: UUID) -> AgentTabSession? {
        guard let session = (try? authoritativeLiveSession(for: sessionID)) ?? nil,
              session.remoteHost == nil,
              isAttentionNotificationRoot(session)
        else { return nil }
        return session
    }

    /// Dispatch readiness of a remote send, kept separate from root identity
    /// (`remoteAttentionRootSession`) so an ineligible send still fails inside the remote path and
    /// never falls through to ordinary MCP control. Nil when the send may proceed; otherwise the
    /// refusal shown to the device. Evaluated at entry and again in the final submission predicate.
    /// - A session whose persisted state is not loaded would defer its send into a hydration task
    ///   that outlives the final check, so it is refused instead.
    /// - Native control-plane commands (`/compact`, `/goal`) project optimistic progress and run in
    ///   a deferred task, and are outside the phone's answer/steer/follow-up/Stop scope.
    func remoteRootDispatchRefusal(session: AgentTabSession, text: String) -> String? {
        guard session.hasLoadedPersistedState else {
            return Self.remoteRootNotLoadedMessage
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedNativeSlashCommand(in: trimmedText, session: session)?.command.behavior == .controlPlane {
            return Self.remoteRootControlCommandMessage
        }
        return nil
    }

    /// The final submission predicate of a session-targeted send: the same live object still
    /// resolves through `target`, and a remote root send is still dispatch-ready for `text`.
    func sessionInstructionTargetIsReady(
        session: AgentTabSession,
        sessionID: UUID,
        target: SessionInstructionTarget,
        text: String
    ) -> Bool {
        guard instructionTargetSession(sessionID: sessionID, target: target) === session else { return false }
        switch target {
        case .mcpControlled:
            return true
        case .remoteAttentionRoot:
            return remoteRootDispatchRefusal(session: session, text: text) == nil
        }
    }

    /// Steer a running root, or send a follow-up to an idle one, through the normal send path.
    func remoteRootDispatchInstruction(
        sessionID: UUID,
        text: String,
        workflow: AgentWorkflowDefinition? = nil
    ) async throws -> MCPInstructionDispatch {
        guard let session = remoteAttentionRootSession(sessionID: sessionID) else {
            throw MCPError.invalidParams(Self.remoteRootUnavailableMessage)
        }
        if let refusal = remoteRootDispatchRefusal(session: session, text: text) {
            throw MCPError.invalidParams(refusal)
        }
        do {
            return try await dispatchSessionInstruction(
                session: session,
                sessionID: sessionID,
                text: text,
                allowStartingRun: true,
                workflow: workflow,
                nativePreparedTurn: nil,
                target: .remoteAttentionRoot
            )
        } catch let MCPError.invalidParams(message) where message == Self.staleInstructionTargetMessage {
            // The final predicate refused before anything was handed off: name the readiness
            // reason when that is what changed.
            if let refusal = remoteRootDispatchRefusal(session: session, text: text) {
                throw MCPError.invalidParams(refusal)
            }
            throw MCPError.invalidParams(message)
        }
    }

    /// Answer (or skip) the exact pending `ask_user` question of a root. `resolvedBy` is the
    /// verified device attribution (`remote:<device8>`); the core stages it for this resolution only
    /// and clears it on every exit.
    func remoteRootResolvePendingQuestion(
        sessionID: UUID,
        interactionID: UUID,
        payload: MCPInteractionResponsePayload,
        resolvedBy: String
    ) async throws -> MCPInstructionDispatch? {
        guard let session = remoteAttentionRootSession(sessionID: sessionID) else {
            throw MCPError.invalidParams(Self.remoteRootUnavailableMessage)
        }
        return try await resolveSessionPendingInteraction(
            session: session,
            sessionID: sessionID,
            interactionID: interactionID,
            payload: payload,
            workflow: nil,
            resolvedBy: resolvedBy,
            target: .remoteAttentionRoot,
            allowedKinds: [.question]
        )
    }

    /// Stop the root's current run through the desktop's guarded cancel target (same eligibility
    /// as the composer's Stop: an active run with a run ID). `expectedRunID`, when given, must be
    /// the current run.
    func remoteRootCancelRun(sessionID: UUID, expectedRunID: UUID?) async throws {
        guard let session = remoteAttentionRootSession(sessionID: sessionID) else {
            throw MCPError.invalidParams(Self.remoteRootUnavailableMessage)
        }
        guard session.runState.isActive, session.runID != nil else {
            throw MCPError.invalidParams("The run is not currently active and cannot be cancelled.")
        }
        let cancelTarget = makeRunCancelTarget(tabID: session.tabID, session: session)
        if let expectedRunID, cancelTarget.expectedRunID != expectedRunID {
            throw MCPError.invalidParams(
                "The requested run_id is not the current run for this session; refusing to cancel a different run."
            )
        }
        guard await cancelAgentRun(target: cancelTarget, cause: .userCancel, completion: .terminalPublished) else {
            throw MCPError.invalidParams("The requested run is no longer current; refusing to cancel a different run.")
        }
    }

    static let remoteRootUnavailableMessage =
        "The requested session is not available for remote control (it is not a desktop root session on this Mac, or it changed)."

    static let remoteRootNotLoadedMessage =
        "This session is not loaded on the Mac yet. Open it on the Mac, then try again. Nothing was sent."

    static let remoteRootControlCommandMessage =
        "Session commands such as /compact and /goal are not available from remote control. Nothing was sent."
}
