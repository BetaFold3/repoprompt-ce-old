import Foundation
import MCP
import RepoPromptAgentCore

extension ServerNetworkManager: AgentMCPHosting {
    /// Builds the server-owned observer inside the actor so registration stays a single
    /// synchronous actor-isolated step.
    func registerToolEventObserver(
        for runID: UUID,
        onCalled: @escaping @Sendable (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?) async -> Void,
        onCompleted: (@Sendable (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?, _ resultJSON: String, _ isError: Bool) async -> Void)?,
        observationPolicy: AgentToolTrackingObservationPolicy
    ) -> UUID {
        registerToolEventObserver(
            for: runID,
            observer: ToolEventObserver(
                onCalled: onCalled,
                onCompleted: onCompleted,
                observationPolicy: observationPolicy
            )
        )
    }
}

extension MCPRoutingWaiter {
    static let shared = MCPRoutingWaiter(mcpHost: ServerNetworkManager.shared)
}

// MARK: - Static Async Methods (for async callers)

extension MCPRoutingWaiter {
    /// Register a runID before any routing signals are expected.
    static func register(runID: UUID) async {
        await shared.register(runID: runID)
    }

    /// Wait until the runID is routed or timeout/failure.
    /// - Parameters:
    ///   - runID: The run identifier to watch for routing.
    ///   - timeoutSeconds: Maximum time to wait. If <= 0, waits indefinitely.
    static func waitUntilRouted(runID: UUID, timeoutSeconds: TimeInterval) async -> Bool {
        await shared.waitUntilRouted(runID: runID, timeoutSeconds: timeoutSeconds)
    }

    static func waitUntilRoutedOutcome(runID: UUID, timeoutSeconds: TimeInterval) async -> WaitOutcome {
        await shared.waitUntilRoutedOutcome(runID: runID, timeoutSeconds: timeoutSeconds)
    }

    /// Notify that a runID was successfully routed (async version).
    static func notifyRouted(runID: UUID) async {
        await shared.notifyRouted(runID: runID)
    }

    /// Notify that a runID failed to route (async version).
    static func notifyFailed(runID: UUID) async {
        await shared.notifyFailed(runID: runID)
    }

    /// Clean up state for a completed runID.
    static func cleanup(runID: UUID) async {
        await shared.cleanup(runID: runID)
    }

    #if DEBUG
        static func debugContinuationCount(runID: UUID) async -> Int {
            await shared.debugContinuationCount(runID: runID)
        }
    #endif
}

// MARK: - Fire-and-Forget Signal Methods (for sync callers)

extension MCPRoutingWaiter {
    /// Fire-and-forget routed signal to the process-wide waiter.
    nonisolated static func signalRouted(_ runID: UUID) {
        shared.signalRouted(runID)
    }

    /// Fire-and-forget failure signal to the process-wide waiter.
    nonisolated static func signalFailed(_ runID: UUID) {
        shared.signalFailed(runID)
    }
}

extension AgentRunCoordinator {
    static let shared = AgentRunCoordinator(mcpHost: ServerNetworkManager.shared, routingWaiter: .shared)
}

extension AgentRuntimeProviderService {
    static let shared = AgentRuntimeProviderService(mcpHost: ServerNetworkManager.shared, routingWaiter: .shared)
}

extension OhMyPiACPModelPollingService {
    static let shared = OhMyPiACPModelPollingService(
        client: OhMyPiACPControllerModelDiscoveryClient(mcpHost: ServerNetworkManager.shared)
    )
}

extension OpenCodeACPModelPollingService {
    static let shared = OpenCodeACPModelPollingService(
        client: OpenCodeACPControllerModelDiscoveryClient(mcpHost: ServerNetworkManager.shared)
    )
}

extension CursorACPModelPollingService {
    static let shared = CursorACPModelPollingService(
        client: CursorACPControllerModelDiscoveryClient(mcpHost: ServerNetworkManager.shared)
    )
}

extension OhMyPiThinkingCapabilityResolver {
    static let shared = OhMyPiThinkingCapabilityResolver(
        client: OhMyPiThinkingCapabilityControllerSweepClient(
            sessionFactory: OhMyPiThinkingCapabilityControllerSessionFactory(mcpHost: ServerNetworkManager.shared),
            isAvailable: { OhMyPiConnectionAvailability.isEffectivelyConnected() }
        ),
        isAvailable: { OhMyPiConnectionAvailability.isEffectivelyConnected() }
    )
}

extension CodexModelPollingService {
    static let shared = CodexModelPollingService(
        client: CodexProviderHelpers.makeOwnedNonAgentAppServerClient(mcpHost: ServerNetworkManager.shared),
        stopClientOnShutdown: true,
        stopClientWhenIdle: true
    )
}

extension CodexManagedAuthRecoveryService {
    static let shared = CodexManagedAuthRecoveryService {
        CodexProviderHelpers.makeOwnedNonAgentAppServerClient(mcpHost: ServerNetworkManager.shared)
    }
}

extension OhMyPiConnectionAvailability {
    /// App-composed availability that includes the DEBUG qualification-lease override.
    static func isEffectivelyConnected(userDefaults: UserDefaults = .standard) -> Bool {
        isEffectivelyConnected(userDefaults: userDefaults, debugOverride: currentDebugOverride)
    }

    private static var currentDebugOverride: Bool {
        #if DEBUG
            OhMyPiAgentModeSmokeGate.shared.isEnabled
        #else
            false
        #endif
    }
}

#if DEBUG
    extension OhMyPiAgentModeSmokeGate {
        static let shared = OhMyPiAgentModeSmokeGate()

        /// App composition: cancels the bound run through the window registry when a
        /// qualification lease ends.
        convenience init(
            notificationCenter: NotificationCenter = .default,
            wallClock: @escaping @Sendable () -> Date = Date.init,
            monotonicNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
        ) {
            self.init(
                notificationCenter: notificationCenter,
                cancellationHandler: { snapshot, reason in
                    guard let sessionID = snapshot.sessionID else { return }
                    Task { @MainActor in
                        for window in WindowStatesManager.shared.allWindows {
                            guard let runID = snapshot.runID,
                                  let session = window.agentModeViewModel.mcpControlledSession(sessionID: sessionID),
                                  session.runID == runID,
                                  session.runState.isActive
                            else { continue }
                            window.mcpServer.cancelActiveToolsForRun(runID: runID, reason: reason)
                            let target = window.agentModeViewModel.makeRunCancelTarget(
                                tabID: session.tabID,
                                session: session
                            )
                            // The controlling MCP client's explicit cancellation.
                            _ = await window.agentModeViewModel.cancelAgentRun(
                                target: target,
                                cause: .userCancel,
                                completion: .terminalPublished
                            )
                            break
                        }
                    }
                },
                wallClock: wallClock,
                monotonicNowNanoseconds: monotonicNowNanoseconds
            )
        }
    }
#endif
