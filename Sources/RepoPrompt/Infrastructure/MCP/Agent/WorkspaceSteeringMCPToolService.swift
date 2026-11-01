import Foundation
import MCP
import RepoPromptAgentCore

/// `workspace_steer`: list and (later) steer top-level sessions in workspaces the owner granted to
/// the caller's workspace (docs/context/specs/2026-11-01-assistant-workspace-steering-spec.md).
///
/// The source workspace comes only from the request's actor-owned run route
/// (`RequestMetadata.actorRoutedRunTab`), and that run's window must still show it. Tool
/// arguments, `_windowID`, `context_id`, selected tabs and client names never establish it.
/// Calls without a local Agent Mode run route, and gateway (paired-device) callers, are refused.
@MainActor
struct WorkspaceSteeringMCPToolService {
    typealias RequestMetadata = MCPServerViewModel.RequestMetadata

    /// The calling Agent Mode run, derived from its run route.
    struct Caller: Equatable {
        let runID: UUID
        let windowID: Int
        let tabID: UUID
        let sourceWorkspaceID: UUID
        let sourceWorkspaceName: String
        /// Durable session bound in the route-owned run tab (for message attribution); nil when that
        /// tab holds no bound session.
        let sourceSessionID: UUID?
    }

    /// One eligible target, pinned to the window, view model and live session that resolved it.
    struct TargetMatch {
        let window: WindowState
        let viewModel: AgentModeViewModel
        let session: AgentTabSession
    }

    /// A target workspace across every open window that shows it.
    struct TargetScan {
        let openWindows: [WindowState]
        /// Session IDs that resolve to exactly one eligible root across all those windows.
        let eligible: [UUID: TargetMatch]
        /// Session IDs bound more than once (within one window or across windows).
        let ambiguous: Set<UUID>

        var isOpen: Bool {
            !openWindows.isEmpty
        }
    }

    let captureRequestMetadata: @MainActor () async -> RequestMetadata
    let isGatewayPrincipalConnection: @Sendable (UUID) async -> Bool
    let windows: @MainActor () -> [WindowState]
    let grantStore: @MainActor () -> WorkspaceSteeringGrantStore

    func execute(args: [String: Value]) async throws -> Value {
        let metadata = await captureRequestMetadata()
        let caller = try await resolveCaller(metadata: metadata)
        let op = args["op"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch op {
        case "list":
            return try list(args: args, caller: caller)
        case "send", "request_grant":
            throw MCPError.invalidParams(Self.notImplementedMessage(op: op))
        default:
            throw MCPError.invalidParams(
                "workspace_steer requires op: list, send, or request_grant."
            )
        }
    }

    // MARK: - Caller

    /// The caller from its actor-owned run route only. The gateway checks run first, so a paired
    /// device is refused even if its metadata somehow carried a route.
    func resolveCaller(metadata: RequestMetadata) async throws -> Caller {
        if metadata.gatewayRemoteDeviceID != nil {
            throw MCPError.invalidParams(Self.gatewayRefusalMessage)
        }
        if let connectionID = metadata.connectionID, await isGatewayPrincipalConnection(connectionID) {
            throw MCPError.invalidParams(Self.gatewayRefusalMessage)
        }
        guard metadata.runPurpose == .agentModeRun, let route = metadata.actorRoutedRunTab else {
            throw MCPError.invalidParams(Self.noRunRouteMessage)
        }
        guard let workspaceID = route.workspaceID else {
            throw MCPError.invalidParams(Self.missingSourceWorkspaceMessage)
        }
        guard let window = windows().first(where: { $0.windowID == route.windowID }),
              !window.isClosing,
              let workspace = window.workspaceManager.activeWorkspace,
              workspace.id == workspaceID
        else {
            throw MCPError.invalidParams(Self.sourceWindowChangedMessage)
        }
        return Caller(
            runID: route.runID,
            windowID: route.windowID,
            tabID: route.tabID,
            sourceWorkspaceID: workspaceID,
            sourceWorkspaceName: workspace.name,
            sourceSessionID: window.agentModeViewModel.sessions[route.tabID]?.activeAgentSessionID
        )
    }

    // MARK: - Target resolution

    /// Every non-closing window whose active workspace is `workspaceID`, and the session IDs on that
    /// workspace's tabs that resolve there as steering targets. Ambiguous IDs are never eligible.
    /// An ID is ambiguous when its claims across those windows name more than one distinct tab
    /// (a claim mirrored for the same tab counts once), when one window cannot resolve it to a
    /// single tab, or when more than one window holds a live binding for it (eligible or not).
    func scanTarget(workspaceID: UUID) -> TargetScan {
        let openWindows = windows().filter {
            !$0.isClosing && $0.workspaceManager.activeWorkspace?.id == workspaceID
        }
        let claimsByWindow = openWindows.map {
            $0.agentModeViewModel.workspaceSteeringClaims(workspaceID: workspaceID)
        }
        var claimedTabs: [UUID: Set<UUID>] = [:]
        for claims in claimsByWindow {
            claimedTabs.merge(claims) { $0.union($1) }
        }
        var bindingCounts: [UUID: Int] = [:]
        var matches: [UUID: TargetMatch] = [:]
        var ambiguous = Set(claimedTabs.filter { $0.value.count > 1 }.keys)
        for (window, claims) in zip(openWindows, claimsByWindow) {
            let viewModel = window.agentModeViewModel
            for sessionID in claims.keys {
                switch viewModel.workspaceSteeringTargetResolution(sessionID: sessionID, workspaceID: workspaceID) {
                case .unbound:
                    continue
                case .ambiguous:
                    ambiguous.insert(sessionID)
                case .ineligible:
                    bindingCounts[sessionID, default: 0] += 1
                case let .eligible(session):
                    bindingCounts[sessionID, default: 0] += 1
                    matches[sessionID] = TargetMatch(window: window, viewModel: viewModel, session: session)
                }
            }
        }
        for (sessionID, count) in bindingCounts where count > 1 {
            ambiguous.insert(sessionID)
        }
        return TargetScan(
            openWindows: openWindows,
            eligible: matches.filter { !ambiguous.contains($0.key) },
            ambiguous: ambiguous
        )
    }

    // MARK: - list

    private func list(args: [String: Value], caller: Caller) throws -> Value {
        // Validate the argument before reading grants: a malformed or empty ID is refused either way.
        var explicitTarget: UUID?
        if let rawTarget = args["target_workspace_id"], rawTarget != .null {
            guard let text = rawTarget.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let targetID = UUID(uuidString: text)
            else {
                throw MCPError.invalidParams("workspace_steer target_workspace_id must be a workspace UUID.")
            }
            explicitTarget = targetID
        }
        // One fresh read of the grants file serves both the explicit and the implicit target.
        guard let granted = grantStore().grantedTargets(source: caller.sourceWorkspaceID) else {
            throw MCPError.invalidParams(Self.grantsUnreadableMessage)
        }
        let targets: [UUID]
        if let explicitTarget {
            guard granted.contains(explicitTarget) else {
                throw MCPError.invalidParams(
                    Self.notGrantedMessage(
                        target: workspaceName(explicitTarget, caller: caller) ?? explicitTarget.uuidString,
                        source: caller.sourceWorkspaceName
                    )
                )
            }
            targets = [explicitTarget]
        } else {
            targets = granted
        }

        let workspaces = targets.map { describe(targetID: $0, caller: caller) }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return order == .orderedSame ? lhs.workspaceID < rhs.workspaceID : order == .orderedAscending
            }
        return try Value(ListReply(workspaces: workspaces))
    }

    private func describe(targetID: UUID, caller: Caller) -> ListReply.Workspace {
        let scan = scanTarget(workspaceID: targetID)
        let knownName = workspaceName(targetID, caller: caller)
            ?? scan.openWindows.first?.workspaceManager.activeWorkspace?.name
        let name = knownName ?? Self.unknownWorkspaceName
        guard scan.isOpen else {
            // No window's workspace list knows the ID: the grant names a deleted workspace.
            let warning = knownName == nil && !isKnownWorkspace(targetID)
                ? Self.deletedWorkspaceMessage(workspaceID: targetID.uuidString)
                : Self.notOpenMessage(workspaceName: name)
            return ListReply.Workspace(
                workspaceID: targetID.uuidString,
                name: name,
                isOpen: false,
                sessions: [],
                warnings: [warning]
            )
        }
        let sessions = scan.eligible.map { sessionID, match in
            ListReply.Session(
                sessionID: sessionID.uuidString,
                name: match.viewModel.resolvedSessionDisplayName(for: match.session.tabID),
                runState: Self.runStateName(match.session.runState)
            )
        }
        .sorted { lhs, rhs in
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return order == .orderedSame ? lhs.sessionID < rhs.sessionID : order == .orderedAscending
        }
        let warnings = scan.ambiguous
            .map(\.uuidString)
            .sorted()
            .map(Self.ambiguousSessionMessage(sessionID:))
        return ListReply.Workspace(
            workspaceID: targetID.uuidString,
            name: name,
            isOpen: true,
            sessions: sessions,
            warnings: warnings
        )
    }

    /// Name from the caller window's workspace list, disambiguated like Settings.
    private func workspaceName(_ workspaceID: UUID, caller: Caller) -> String? {
        let known = windows().first { $0.windowID == caller.windowID }?.workspaceManager.workspaces ?? []
        return WorkspaceSteeringGrantStore.displayNames(for: known)[workspaceID]
    }

    /// Whether any open window's workspace list still contains `workspaceID`.
    private func isKnownWorkspace(_ workspaceID: UUID) -> Bool {
        windows().contains { window in
            window.workspaceManager.workspaces.contains { $0.id == workspaceID }
        }
    }

    static func runStateName(_ state: AgentSessionRunState) -> String {
        switch state {
        case .idle: "idle"
        case .running: "running"
        case .waitingForUser: "waiting_for_user"
        case .waitingForQuestion: "waiting_for_question"
        case .waitingForApproval: "waiting_for_approval"
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }

    // MARK: - Reply

    struct ListReply: Codable, Equatable {
        struct Session: Codable, Equatable {
            let sessionID: String
            let name: String
            let runState: String

            enum CodingKeys: String, CodingKey {
                case sessionID = "session_id"
                case name
                case runState = "run_state"
            }
        }

        struct Workspace: Codable, Equatable {
            let workspaceID: String
            let name: String
            let isOpen: Bool
            let sessions: [Session]
            let warnings: [String]

            enum CodingKeys: String, CodingKey {
                case workspaceID = "workspace_id"
                case name
                case isOpen = "is_open"
                case sessions
                case warnings
            }
        }

        let workspaces: [Workspace]
    }

    // MARK: - Messages

    static let unknownWorkspaceName = "unknown workspace"

    static let gatewayRefusalMessage =
        "workspace_steer is not available to paired remote devices. It runs only from Agent Mode sessions on this Mac."

    static let noRunRouteMessage =
        "workspace_steer is available only to Agent Mode sessions running on this Mac. This call has no Agent Mode run route, so it was refused."

    static let missingSourceWorkspaceMessage =
        "This Agent Mode run has no recorded workspace, so workspace_steer cannot identify the source workspace. Nothing was listed or sent."

    static let sourceWindowChangedMessage =
        "The window running this Agent Mode session no longer shows its workspace, so workspace_steer refused the call. Nothing was listed or sent."

    static let grantsUnreadableMessage =
        "Workspace steering grants could not be read from settings, so nothing was listed."

    static func notGrantedMessage(target: String, source: String) -> String {
        "Workspace '\(target)' is not granted to '\(source)'. The owner can add a grant in Settings → Manage Workspaces → Workspace Steering."
    }

    static func notOpenMessage(workspaceName: String) -> String {
        "Workspace '\(workspaceName)' is not open on this Mac. Open it, then retry."
    }

    static func deletedWorkspaceMessage(workspaceID: String) -> String {
        "Workspace \(workspaceID) no longer exists on this Mac. The owner can remove this grant in Settings → Manage Workspaces → Workspace Steering."
    }

    static func ambiguousSessionMessage(sessionID: String) -> String {
        "Session \(sessionID) is bound to more than one tab or window on this Mac and was omitted."
    }

    static func notImplementedMessage(op: String) -> String {
        "workspace_steer op '\(op)' is not available yet. Nothing was sent and no grant was requested."
    }
}
