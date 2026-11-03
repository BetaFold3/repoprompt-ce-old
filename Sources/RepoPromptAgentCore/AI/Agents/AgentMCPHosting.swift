import Foundation
import MCP

/// The MCP server capabilities the agent runtime uses. The App's MCP server
/// actor implements it; runtime objects receive that instance through their initializers.
package protocol AgentMCPHosting: Sendable {
    func isRunning() async -> Bool

    /// Whether the run has a committed, live, admitted route for `expectedClientName`.
    /// A non-nil `requiredAgentPID` binds the evidence to that launch: the routed connection must
    /// be live and non-terminal, and its helper must descend from exactly the agent process
    /// instance registered for that PID (a route retained from an earlier launch of the same run
    /// proves nothing about a restarted launch). `nil` keeps the launch-independent check.
    func hasAuthoritativeLiveRunRoute(runID: UUID, expectedClientName: String, requiredAgentPID: pid_t?) async -> Bool

    /// Turn-start delivery of a newly installed run policy to the run's retained, ownership-proven
    /// helper connections (Claude native clients only; a no-op for every other client), one
    /// `tools/list_changed` per connection whose applied projection differs. Called by the
    /// bootstrap lease after it released the global gate and before the turn's message is sent.
    func refreshRetainedRunPolicyForTurnStart(for clientName: String, runID: UUID) async

    /// For a later turn whose launch keeps its helper: when the run already has a live route whose
    /// helper is proven (as `hasAuthoritativeLiveRunRoute` with `requiredAgentPID`) to belong to
    /// `agentPID`'s launch and no application of the run's policy is in flight, first clears the
    /// turn's unused pending policy (its queue entry, removed synchronously with those checks),
    /// then brings every proven connection of the run to the run's current policy projection,
    /// keeps routing state, and returns true. Returns false without changing anything when the
    /// checks fail before the clear; a false after the clear (the projection changed or the
    /// launch's route lost its proof during the refresh) means the entry is already gone, and the
    /// caller's routing wait and its revocation finish the turn (Claude native clients only).
    func releasePendingRunPolicyForProvenRoute(
        for clientName: String,
        windowID: Int,
        runID: UUID,
        agentPID: pid_t
    ) async -> Bool

    func waitForNewConnection(clientName: String?, timeout: TimeInterval) async -> UUID?

    func registerExpectedAgentPID(
        _ pid: pid_t,
        for clientName: String,
        runID: UUID?,
        expectedProcessExecutablePath: String?,
        expectedProcessExecutableIdentity: ExecutableFileIdentity?
    ) async

    func clearExpectedAgentPID(_ pid: pid_t, for clientName: String, runID: UUID?) async

    func requireExpectedAgentPIDForPendingPolicy(for clientName: String, runID: UUID, windowID: Int?) async -> Bool

    // swiftlint:disable:next function_parameter_count
    func installClientConnectionPolicy(
        for clientName: String,
        windowID: Int,
        restrictedTools: Set<String>,
        oneShot: Bool,
        reason: String?,
        ttl: TimeInterval,
        tabID: UUID?,
        runID: UUID?,
        additionalTools: Set<String>?,
        allowedToolsOverride: Set<String>?,
        sessionProfile: AgentSessionProfile,
        purpose: MCPRunPurpose,
        taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        allowsAgentExternalControlTools: Bool,
        requiresExpectedAgentPID: Bool
    ) async

    func clearClientConnectionPolicy(for clientName: String, windowID: Int?, runID: UUID?) async

    func revokeClientConnectionPolicy(for clientName: String, windowID: Int, runID: UUID) async

    /// The routing half of `revokeClientConnectionPolicy`, never touching a pending policy: clears
    /// the run's routing state when no live, ancestry-proven helper of the run remains, and
    /// otherwise prunes its unproven routes. Used for failure or cancellation cleanup after an
    /// early release (`releasePendingRunPolicyForProvenRoute`).
    func cleanupRunRoutingIfUnproven(for clientName: String, windowID: Int, runID: UUID) async

    func registerToolEventObserver(
        for runID: UUID,
        onCalled: @escaping @Sendable (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?) async -> Void,
        onCompleted: (@Sendable (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?, _ resultJSON: String, _ isError: Bool) async -> Void)?,
        observationPolicy: AgentToolTrackingObservationPolicy
    ) async -> UUID

    func unregisterToolEventObserver(for runID: UUID, token: UUID) async

    func unregisterToolObservers(for runID: UUID) async

    /// Registers or replaces the read-only companion grant for one run's current transport launch.
    /// Only the credential digest crosses this boundary. Replacing a grant revokes the previous
    /// launch's companion connection.
    func registerCompanionGrant(runID: UUID, credentialDigest: String) async

    /// Clears the run's companion grant when it still carries `credentialDigest` (nil clears any
    /// grant) and disconnects its companion connection.
    func clearCompanionGrant(runID: UUID, credentialDigest: String?) async

    /// Registers one provider launch's observer for loss of its run's RepoPrompt MCP tool path: the
    /// tool-execution watchdog force-disconnect, a helper process that exited after its connection
    /// closed, or a helper that stayed alive without restoring the run route. Watchdog events are
    /// captured when the connection's terminal state is committed, before any suspension; helper
    /// events are resolved later by the manager's helper-exit watch. Delivery is fire-and-forget
    /// and never delays or blocks containment. Each event is addressed to `launch` and states what
    /// the app could prove about that launch's ownership.
    func registerRunConnectionLossObserver(
        for runID: UUID,
        launch: AgentMCPRunLaunchIdentity,
        observer: @escaping @Sendable (AgentMCPRunConnectionLoss) async -> Void
    ) async -> UUID

    func unregisterRunConnectionLossObserver(for runID: UUID, token: UUID) async

    #if DEBUG
        func debugRecordRunRoutingEvent(runID: UUID, event: String, connectionID: UUID?, fields: [String: String]) async
    #endif
}

package extension AgentMCPHosting {
    /// Hosts without companion support never admit one: with no grant every companion fails closed.
    func registerCompanionGrant(runID _: UUID, credentialDigest _: String) async {}

    func clearCompanionGrant(runID _: UUID, credentialDigest _: String?) async {}
}

/// One provider launch (process) of a run, as registered for connection-loss delivery. Immutable:
/// a successor launch registers a new identity.
package struct AgentMCPRunLaunchIdentity: Equatable {
    /// Unique per spawned process; never reused by a successor launch.
    package let token: UUID
    /// The PID this launch registered as the run's expected agent process.
    package let agentProcessID: pid_t

    package init(token: UUID, agentProcessID: pid_t) {
        self.token = token
        self.agentProcessID = agentProcessID
    }
}

/// A loss of one run-routed RepoPrompt MCP connection's tool path, addressed to one registered
/// launch. Immutable and captured from the connection's run route before the connection is
/// removed, so the launch can tell its own connection from a stale one.
package struct AgentMCPRunConnectionLoss: Equatable {
    package enum Reason: String, Equatable {
        /// A tool exceeded its execution deadline and ignored cancellation grace; the app severed
        /// the connection, and the helper exits by design.
        case toolExecutionWatchdog = "tool_execution_watchdog"
        /// The connection closed and its `repoprompt-mcp` helper process then exited (gone,
        /// zombie, or its PID reused), so the agent's stdio MCP server is dead.
        case helperExited = "helper_exited"
        /// The connection closed and its helper stayed alive but never restored a run route for
        /// this run within the reconnect deadline.
        case routeNotRestored = "route_not_restored"
    }

    package let runID: UUID
    package let connectionID: UUID
    package let clientName: String?
    /// The token of the registered launch this event is addressed to.
    package let launchToken: UUID
    /// The addressed launch's agent PID when the app proved it is an ancestor of the helper peer
    /// (from the ancestry snapshot captured at admission, or a live query when no snapshot
    /// exists); `nil` when unproven. Helper-exit reasons are only ever emitted with a proven PID.
    package let agentProcessID: pid_t?
    /// The connection already existed when the addressed launch registered, so it cannot be that
    /// launch's own helper connection unless its agent PID is proven.
    package let connectionPredatesLaunch: Bool
    /// The tool whose execution triggered a watchdog loss; `nil` for helper-exit reasons.
    package let toolName: String?
    package let reason: Reason
    /// The app-side close reason of the triggering connection (for example `peer_eof` or
    /// `idle_timeout`); `tool_execution_watchdog` for watchdog losses.
    package let closeReason: String

    package init(
        runID: UUID,
        connectionID: UUID,
        clientName: String?,
        launchToken: UUID,
        agentProcessID: pid_t?,
        connectionPredatesLaunch: Bool,
        toolName: String?,
        reason: Reason,
        closeReason: String
    ) {
        self.runID = runID
        self.connectionID = connectionID
        self.clientName = clientName
        self.launchToken = launchToken
        self.agentProcessID = agentProcessID
        self.connectionPredatesLaunch = connectionPredatesLaunch
        self.toolName = toolName
        self.reason = reason
        self.closeReason = closeReason
    }

    /// Whether the event provably concerns the launch it is addressed to: a proven agent PID that
    /// is the launch's registered one, or (unproven) a connection admitted after the launch
    /// registered. A launch token alone is never proof of the connection's ownership.
    package func provesOwnership(by launch: AgentMCPRunLaunchIdentity) -> Bool {
        guard launchToken == launch.token else { return false }
        if let agentProcessID {
            return agentProcessID == launch.agentProcessID
        }
        return !connectionPredatesLaunch
    }
}
