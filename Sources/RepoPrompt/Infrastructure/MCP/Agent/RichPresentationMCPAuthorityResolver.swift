import Foundation
import RepoPromptAgentCore

/// Exact rich-presentation creation authority for one MCP request
/// (docs/context/specs/2026-11-04-rich-presentation-spec.md, A3).
///
/// The Step 1 admission seam for the future `present_rich` tool; no tool uses it yet. Authority
/// comes only from trusted request metadata captured in one actor read: the connection's run
/// route (`actorRoutedRunTab`) and the attempt ownership applied to that connection with its run
/// policy (`appliedRunOwnership`). Tool arguments, `_windowID`, `context_id`, selected tabs, client
/// names, working directories and the run's latest policy state never establish it. Every local
/// Agent Mode session qualifies (roots, workers, Explore and Knowledge); gateway, Oracle, Context
/// Builder, external and unbound callers are refused.
///
/// It is not a publisher: tombstone and storage-identity checks remain the publication step's.
@MainActor
struct RichPresentationMCPAuthorityResolver {
    typealias RequestMetadata = MCPServerViewModel.RequestMetadata

    /// Immutable authority for one admitted request.
    struct Authority: Equatable {
        let runID: UUID
        let windowID: Int
        let tabID: UUID
        let workspaceID: UUID
        let sessionID: UUID
        /// The exact attempt the request was admitted under, with its captured policy.
        let ownership: AgentRunOwnership
        /// The server-generated invocation UUID of the `tools/call`, when inside one.
        let toolInvocationID: UUID?

        var policy: AgentRichPresentationAttemptPolicy? {
            ownership.richPresentationPolicy
        }
    }

    /// Typed refusal: `denied` (valid context, creation not permitted) or `invalidContext` (no
    /// provable local attempt authority; the caller must start a new run).
    enum Denial: Error, Equatable {
        case denied(String)
        case invalidContext(String)

        var message: String {
            switch self {
            case let .denied(message), let .invalidContext(message):
                message
            }
        }
    }

    let isGatewayPrincipalConnection: @Sendable (UUID) async -> Bool
    let windows: @MainActor () -> [WindowState]

    static var live: RichPresentationMCPAuthorityResolver {
        RichPresentationMCPAuthorityResolver(
            isGatewayPrincipalConnection: { connectionID in
                await ServerNetworkManager.shared.isGatewayPrincipalConnection(connectionID)
            },
            windows: { WindowStatesManager.shared.allWindows }
        )
    }

    /// Resolves authority for request metadata captured at admission. The only suspension (the
    /// gateway-principal check) precedes every session check, which then runs synchronously.
    func resolve(metadata: RequestMetadata) async -> Result<Authority, Denial> {
        if metadata.gatewayRemoteDeviceID != nil {
            return .failure(.invalidContext(Self.gatewayRefusalMessage))
        }
        if let connectionID = metadata.connectionID, await isGatewayPrincipalConnection(connectionID) {
            return .failure(.invalidContext(Self.gatewayRefusalMessage))
        }
        guard metadata.runPurpose == .agentModeRun,
              let route = metadata.actorRoutedRunTab,
              let applied = metadata.appliedRunOwnership,
              applied.runID == route.runID
        else {
            return .failure(.invalidContext(Self.noAttemptAuthorityMessage))
        }
        return validate(
            runID: route.runID,
            windowID: route.windowID,
            tabID: route.tabID,
            routeWorkspaceID: route.workspaceID,
            ownership: applied.ownership,
            toolInvocationID: metadata.toolInvocationID
        )
    }

    /// Re-checks a previously resolved authority after a suspension (for example before a final
    /// install): the same window, workspace, exact session binding and current attempt.
    func revalidate(_ authority: Authority) -> Result<Authority, Denial> {
        validate(
            runID: authority.runID,
            windowID: authority.windowID,
            tabID: authority.tabID,
            routeWorkspaceID: authority.workspaceID,
            ownership: authority.ownership,
            toolInvocationID: authority.toolInvocationID
        )
    }

    private func validate(
        runID: UUID,
        windowID: Int,
        tabID: UUID,
        routeWorkspaceID: UUID?,
        ownership: AgentRunOwnership,
        toolInvocationID: UUID?
    ) -> Result<Authority, Denial> {
        guard let policy = ownership.richPresentationPolicy,
              let routeWorkspaceID,
              policy.workspaceID == routeWorkspaceID,
              ownership.binding.tabID == tabID
        else {
            return .failure(.invalidContext(Self.noAttemptAuthorityMessage))
        }
        guard let window = windows().first(where: { $0.windowID == windowID }),
              !window.isClosing,
              window.workspaceManager.activeWorkspace?.id == routeWorkspaceID
        else {
            return .failure(.invalidContext(Self.noAttemptAuthorityMessage))
        }
        let viewModel = window.agentModeViewModel
        guard let session = viewModel.sessions[tabID],
              session.remoteHost == nil,
              let sessionID = session.activeAgentSessionID,
              ownership.binding.persistentSessionID == sessionID,
              ((try? viewModel.authoritativeLiveSession(for: sessionID)) ?? nil) === session,
              session.runID == runID,
              session.isCurrentRunAttemptForCurrentBinding(ownership, expectedRunID: runID)
        else {
            return .failure(.invalidContext(Self.noAttemptAuthorityMessage))
        }
        guard policy.grantsCreation else {
            return .failure(.denied(Self.disabledMessage))
        }
        return .success(Authority(
            runID: runID,
            windowID: windowID,
            tabID: tabID,
            workspaceID: routeWorkspaceID,
            sessionID: sessionID,
            ownership: ownership,
            toolInvocationID: toolInvocationID
        ))
    }

    static let noAttemptAuthorityMessage =
        "Rich presentation needs the current local Agent Mode run of this session, and this request's run could not be proven current. Nothing was created. Start a new agent run."
    static let gatewayRefusalMessage =
        "Rich presentation is available only to local Agent Mode runs, not paired devices or external clients. Nothing was created."
    static let disabledMessage =
        "Rich presentation is turned off for this workspace in Settings. Nothing was created. A change in Settings applies from the next agent run."
}
