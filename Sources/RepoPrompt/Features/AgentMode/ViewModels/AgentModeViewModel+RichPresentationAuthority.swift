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

    static let richPublicationUnsavedSessionMessage =
        "Rich presentation needs this session saved first, and it could not be saved now. Nothing was created. Retry after the session has been saved."
    static let richPublicationPersistenceOffMessage =
        "Rich presentation is unavailable because session saving is turned off for this launch. Nothing was created."

    /// The exact owner's persistence authority for a rich publication admitted under `authority`
    /// (Step 4, Part A). The owner is the authority's exact tab, session binding and workspace,
    /// never the selected tab. An already persisted owner (its captured state enters only through
    /// its paired hydration load or its own durable exclusive creation) is returned without
    /// saving. A not-yet-persisted owner is saved through the existing save path; only the owner
    /// state that save establishes for this exact session and workspace authorizes creation (a
    /// suppressed, coalesced or failed save without it refuses). Attempt authority is re-checked
    /// after every suspension. Publication still re-validates the returned state.
    func ensureRichPublicationPersistence(
        authority: RichPresentationMCPAuthorityResolver.Authority,
        resolver: RichPresentationMCPAuthorityResolver
    ) async throws -> AgentSessionPersistenceState {
        func exactOwner() throws -> (session: AgentTabSession, workspace: WorkspaceModel) {
            _ = try resolver.revalidate(authority).get()
            guard let session = sessions[authority.tabID],
                  session.activeAgentSessionID == authority.sessionID,
                  let workspace = workspaceManager?.workspaces.first(where: { $0.id == authority.workspaceID })
            else {
                throw RichPresentationMCPAuthorityResolver.Denial.invalidContext(
                    RichPresentationMCPAuthorityResolver.noAttemptAuthorityMessage
                )
            }
            return (session, workspace)
        }
        let owner = try exactOwner()
        if let state = owner.session.persistenceState(for: authority.sessionID),
           state.stamp.workspaceID == owner.workspace.id
        {
            return state
        }
        guard !AppLaunchConfiguration.current.suppressesAgentSessionPersistence else {
            throw RichPresentationMCPAuthorityResolver.Denial.denied(Self.richPublicationPersistenceOffMessage)
        }
        _ = await saveSessionDetailed(for: authority.tabID)
        let current = try exactOwner()
        guard current.session === owner.session,
              let state = current.session.persistenceState(for: authority.sessionID),
              state.stamp.workspaceID == current.workspace.id
        else {
            throw RichPresentationMCPAuthorityResolver.Denial.invalidContext(Self.richPublicationUnsavedSessionMessage)
        }
        return state
    }

    /// The exact hydrated owner of the transcript shown for `tabID`, for rich-presentation history
    /// reads: that tab's local session, its bound session ID and the persistence state captured
    /// for it, and the stamp's own workspace in this window. `nil` (labeled fallback only) for a
    /// remote or never-persisted session. Creation permission and the D2 agreement are not
    /// consulted: history renders where creation is refused.
    func richHistoryOwner(forTabID tabID: UUID) -> RichPresentationHistoryLoader.Owner? {
        guard let session = sessions[tabID],
              session.remoteHost == nil,
              let sessionID = session.activeAgentSessionID,
              let state = session.persistenceState(for: sessionID),
              let workspaceManager,
              workspaceManager.workspaces.contains(where: { $0.id == state.stamp.workspaceID })
        else { return nil }
        return RichPresentationHistoryLoader.Owner(
            viewModel: self,
            session: session,
            tabID: tabID,
            sessionID: sessionID,
            state: state,
            workspaceID: state.stamp.workspaceID,
            workspaceManager: workspaceManager,
            dataService: dataService
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
