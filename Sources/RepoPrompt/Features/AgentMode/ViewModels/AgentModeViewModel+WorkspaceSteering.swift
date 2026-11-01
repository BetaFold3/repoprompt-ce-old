import Foundation
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
}
