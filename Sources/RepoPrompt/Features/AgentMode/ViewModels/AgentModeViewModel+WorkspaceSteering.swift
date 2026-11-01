import Foundation
import MCP
import RepoPromptAgentCore

// Cross-workspace steering targets
// (docs/context/specs/2026-11-01-assistant-workspace-steering-spec.md).
//
// A steering target is a paired-phone attention root (`remoteAttentionRootSession`) that is also
// a verified standard session. The Knowledge exclusion lives here only, so phone eligibility is
// unchanged.

@MainActor
extension AgentModeViewModel {
    /// How one durable session ID resolves as a workspace-steering target in this window.
    enum WorkspaceSteeringTargetResolution {
        /// No live record binds the ID here.
        case unbound
        /// The ID is bound to more than one tab here.
        case ambiguous
        /// A live record binds the ID, but it is not a steerable root (MCP-controlled, a child,
        /// unknown lineage, a remote-host projection, a Knowledge or unverified profile, or a tab
        /// outside the target workspace).
        case ineligible
        case eligible(AgentTabSession)
    }

    /// Resolves `sessionID` as a target in `workspaceID`. The live record's tab must be a compose
    /// tab of that workspace, so a background session of another workspace in this window never
    /// counts.
    func workspaceSteeringTargetResolution(
        sessionID: UUID,
        workspaceID: UUID
    ) -> WorkspaceSteeringTargetResolution {
        let bound: AgentTabSession?
        do {
            bound = try authoritativeLiveSession(for: sessionID)
        } catch {
            return .ambiguous
        }
        guard bound != nil else { return .unbound }
        guard let session = remoteAttentionRootSession(sessionID: sessionID),
              workspaceSteeringTabIDs(workspaceID: workspaceID).contains(session.tabID),
              mcpDelegationCallerProfile(for: session) == .standard
        else { return .ineligible }
        return .eligible(session)
    }

    /// The tabs claiming each durable session ID in `workspaceID` in this window: live records on
    /// its compose tabs, plus the stored claims of its compose and stashed tabs. The stored
    /// workspace model is the membership authority (`PromptViewModel` publishes its compose tabs
    /// from it). Callers merge these maps across windows by tab ID, so a claim mirrored for the
    /// same tab counts once and claims on two different tabs make the session ambiguous.
    func workspaceSteeringClaims(workspaceID: UUID) -> [UUID: Set<UUID>] {
        guard let workspace = workspaceManager?.workspace(withID: workspaceID) else { return [:] }
        var claims: [UUID: Set<UUID>] = [:]
        for tab in workspace.composeTabs {
            if let sessionID = tab.activeAgentSessionID {
                claims[sessionID, default: []].insert(tab.id)
            }
            if let sessionID = sessions[tab.id]?.activeAgentSessionID {
                claims[sessionID, default: []].insert(tab.id)
            }
        }
        for stashed in workspace.stashedTabs {
            if let sessionID = stashed.tab.activeAgentSessionID {
                claims[sessionID, default: []].insert(stashed.tab.id)
            }
        }
        return claims
    }

    private func workspaceSteeringTabIDs(workspaceID: UUID) -> Set<UUID> {
        Set((workspaceManager?.workspace(withID: workspaceID)?.composeTabs ?? []).map(\.id))
    }

    // MARK: - send

    /// Grants checked by the final fence of a steering send.
    var workspaceSteeringGrantStore: WorkspaceSteeringGrantStore {
        #if DEBUG
            if let test_workspaceSteeringGrantStoreOverride {
                return test_workspaceSteeringGrantStoreOverride
            }
        #endif
        return .shared
    }

    /// The `.workspaceGrant` target authority: the live session `sessionID` resolves to as an
    /// eligible steering target in this window's current workspace, provided that workspace is
    /// still granted to `sourceWorkspaceID` (read from the settings file). Nil otherwise. Every
    /// post-await fence of a steering send re-resolves through this and requires the same object,
    /// so a revoked grant, a window that switched workspaces, or a replaced session sends nothing.
    func workspaceSteeringGrantedTarget(sessionID: UUID, sourceWorkspaceID: UUID) -> AgentTabSession? {
        guard let workspaceID = workspaceManager?.activeWorkspace?.id,
              case let .eligible(session) = workspaceSteeringTargetResolution(
                  sessionID: sessionID,
                  workspaceID: workspaceID
              ),
              workspaceSteeringGrantStore.isGranted(source: sourceWorkspaceID, target: workspaceID)
        else { return nil }
        return session
    }

    /// Why a steering send to `session` cannot proceed now, judged on the original (unattributed)
    /// message; nil when it may. A pending question or approval stays with the owner; the paired-
    /// phone readiness rules (`remoteRootDispatchRefusal`: loaded state, no `/compact`- or
    /// `/goal`-style command) apply unchanged.
    func workspaceSteeringDispatchRefusal(session: AgentTabSession, message: String) -> String? {
        if let interaction = mcpPendingInteraction(for: session), interaction.kind != .instruction {
            return Self.workspaceSteeringPendingInteractionMessage(kind: interaction.kind.rawValue)
        }
        let refusal = remoteRootDispatchRefusal(session: session, text: message)
        if refusal == Self.remoteRootControlCommandMessage {
            return Self.workspaceSteeringControlCommandMessage
        }
        return refusal
    }

    /// Steer a running target, or send a follow-up that starts a new turn in an idle one, through
    /// the normal session-targeted send path on this (pinned) view model. `message` is checked
    /// before `attribution` is added; the submitted text is the attribution line, a blank line and
    /// the message. The final submission predicate re-resolves `.workspaceGrant` and re-checks
    /// `workspaceSteeringDispatchRefusal` (pending question or approval, loaded state, session
    /// commands) on `message`. Nothing installs MCP control or changes lineage, and there is no
    /// fallback to MCP control. Admitted input is delivered and reported even if the caller stops.
    func workspaceSteeringDispatchInstruction(
        session: AgentTabSession,
        sessionID: UUID,
        sourceWorkspaceID: UUID,
        message: String,
        attribution: String
    ) async throws -> MCPInstructionDispatch {
        let target = SessionInstructionTarget.workspaceGrant(sourceWorkspaceID: sourceWorkspaceID)
        guard instructionTargetSession(sessionID: sessionID, target: target) === session else {
            throw MCPError.invalidParams(Self.workspaceSteeringTargetChangedMessage)
        }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw MCPError.invalidParams(Self.workspaceSteeringEmptyMessageMessage)
        }
        if let refusal = workspaceSteeringDispatchRefusal(session: session, message: message) {
            throw MCPError.invalidParams(refusal)
        }
        do {
            return try await dispatchSessionInstruction(
                session: session,
                sessionID: sessionID,
                text: "\(attribution)\n\n\(message)",
                allowStartingRun: true,
                workflow: nil,
                nativePreparedTurn: nil,
                target: target,
                readinessText: message
            )
        } catch let MCPError.invalidParams(refused) where refused == Self.staleInstructionTargetMessage {
            // The final predicate refused before anything was handed off: name the readiness
            // reason when that is what changed.
            if let refusal = workspaceSteeringDispatchRefusal(session: session, message: message) {
                throw MCPError.invalidParams(refusal)
            }
            throw MCPError.invalidParams(Self.workspaceSteeringTargetChangedMessage)
        }
    }

    static let workspaceSteeringTargetChangedMessage =
        "The target session, its workspace, or the steering grant changed before the message could be sent. Nothing was sent."

    static let workspaceSteeringEmptyMessageMessage =
        "workspace_steer send requires a nonempty message. Nothing was sent."

    static let workspaceSteeringControlCommandMessage =
        "Session commands such as /compact and /goal cannot be sent with workspace_steer. Nothing was sent."

    static func workspaceSteeringPendingInteractionMessage(kind: String) -> String {
        "The target session is waiting for the owner's \(kind), and workspace_steer cannot answer it. Nothing was sent."
    }
}
