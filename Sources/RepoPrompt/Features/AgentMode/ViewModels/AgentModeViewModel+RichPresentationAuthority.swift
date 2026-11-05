import Foundation
import RepoPromptAgentCore

extension AgentModeViewModel {
    /// The rich-presentation policy captured for a newly admitted run attempt of `session`
    /// (`AgentTabSession.beginRunAttempt`). Synchronous: the exact workspace that owns this view
    /// model's session index must be the window's active workspace, and its Settings entry
    /// committed on disk is read once. `nil` (no workspace authority, creation fails closed) when
    /// the session is not owned by this view model, the session index has no owner, that owner is
    /// not the active workspace, or the settings file can't be read (unreadable, or a preserved
    /// future/foreign schema). A malformed stored entry captures as disabled. Attempts already
    /// admitted keep their snapshot whatever the file says later.
    func richPresentationAttemptPolicy(for session: AgentTabSession) -> AgentRichPresentationAttemptPolicy? {
        guard sessions[session.tabID] === session,
              session.remoteHost == nil,
              let workspaceID = sessionIndexOwner?.workspaceID,
              workspaceID == richPresentationActiveWorkspaceID
        else {
            return nil
        }
        guard let settings = richPresentationSettingsRead(workspaceID) else { return nil }
        guard !settings.storedEntryWasInvalid else {
            return .disabled(workspaceID: workspaceID)
        }
        return .captured(
            workspaceID: workspaceID,
            enabled: settings.enabled,
            approvedImageHosts: settings.approvedImageHosts
        )
    }

    /// The window's active workspace. Only DEBUG fixtures without a workspace manager fall back to
    /// the session-index active-workspace override they set; production requires the manager.
    private var richPresentationActiveWorkspaceID: UUID? {
        if let workspaceManager {
            return workspaceManager.activeWorkspaceID
        }
        #if DEBUG
            if enforcesActiveWorkspaceIDForSessionIndexOwnership {
                return activeWorkspaceIDForSessionIndexOwnership
            }
        #endif
        return nil
    }
}
