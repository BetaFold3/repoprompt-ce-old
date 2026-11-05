import Foundation
import OSLog

private func acpLeaseLog(_ message: @autoclosure () -> String) {
    guard AgentRuntimeProviderService.enableDebugLogging else { return }
    print(message())
}

/// Specification describing the MCP bootstrap requirements for a single run.
/// Used by both agent-mode and headless discovery paths.
package struct MCPBootstrapLeaseSpec {
    package let runID: UUID
    let gateID: UUID
    package let windowID: Int
    let tabID: UUID?
    package let clientName: String?

    let restrictedTools: Set<String>
    let additionalTools: Set<String>?
    /// Positive tool ceiling for this run. Nil preserves standard behavior.
    let allowedToolsOverride: Set<String>?
    /// Stable top-level Agent session profile used for model-visible projections.
    let sessionProfile: AgentSessionProfile
    let oneShot: Bool
    let reason: String?
    let ttl: TimeInterval
    let purpose: MCPRunPurpose
    /// The task label kind for role-aware tool advertisement filtering.
    /// `nil` for non-role connections (discover, delegate-edit, direct MCP).
    let taskLabelKind: AgentModelCatalog.TaskLabelKind?
    /// Whether this run may see external agent control tools even when role filtering would hide them.
    let allowsAgentExternalControlTools: Bool
    /// When true, the queued policy is reserved until the MCP peer PID is a descendant
    /// of an explicitly registered expected agent process.
    package let requiresExpectedAgentPID: Bool
    /// The admitted Agent Mode run attempt this lease's policy belongs to; `nil` for every
    /// non-Agent-Mode lease. Rich-presentation grants derive only from it, never from live Settings.
    package let runOwnership: AgentRunOwnership?

    init(
        runID: UUID,
        gateID: UUID,
        windowID: Int,
        tabID: UUID?,
        clientName: String?,
        restrictedTools: Set<String>,
        additionalTools: Set<String>?,
        allowedToolsOverride: Set<String>? = nil,
        sessionProfile: AgentSessionProfile = .standard,
        oneShot: Bool,
        reason: String?,
        ttl: TimeInterval,
        purpose: MCPRunPurpose,
        taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        allowsAgentExternalControlTools: Bool,
        requiresExpectedAgentPID: Bool,
        runOwnership: AgentRunOwnership? = nil
    ) {
        self.runID = runID
        self.gateID = gateID
        self.windowID = windowID
        self.tabID = tabID
        self.clientName = clientName
        self.restrictedTools = restrictedTools
        self.additionalTools = additionalTools
        self.allowedToolsOverride = allowedToolsOverride
        self.sessionProfile = sessionProfile
        self.oneShot = oneShot
        self.reason = reason
        self.ttl = ttl
        self.purpose = purpose
        self.taskLabelKind = taskLabelKind
        self.allowsAgentExternalControlTools = allowsAgentExternalControlTools
        self.requiresExpectedAgentPID = requiresExpectedAgentPID
        self.runOwnership = runOwnership
    }
}

/// Unified lease actor for the MCP bootstrap policy and routing lifecycle.
///
/// Policy installation remains serialized across shared MCP client types. PID-owned policies
/// release the process-global gate as soon as the unique run policy is confirmed armed, allowing
/// independent provider processes to initialize concurrently while their routing waits remain isolated.
/// Legacy policies without expected-PID ownership retain release-on-routed serialization.
///
/// ## Lifecycle
/// 1. `acquire()` — registers routing, acquires the gate, installs and arms the policy
/// 2. PID-owned policies release the gate immediately; routing state stays retained by the lease
/// 3. `releaseWhenRouted()` — waits for routing (or timeout) and cleans retained state.
///    A later turn whose launch's helper is already routed may instead finish with
///    `releaseWithProvenExistingRoute(agentPID:)`, which skips the wait and never revokes.
/// 4. `cancelAndCleanup()` — emergency cleanup on cancellation
///
/// ## Additional operations (agent-mode specific)
/// - `releaseWithoutRoutingWait()` — releases gate immediately (when no fresh connection is expected)
/// - `releaseGateForDeferredRouting()` — releases the gate while retaining pending routing/policy state
package actor MCPBootstrapLease {
    #if DEBUG
        struct CleanupSnapshot {
            let hasReleased: Bool
            let didRouteSuccessfully: Bool
            let didCleanupRouting: Bool
            /// Aggregate compatibility flag: either successful policy clear or terminal revocation ran.
            let didClearPolicy: Bool
            let didClearSuccessfulRoutingPolicy: Bool
            let didRevokePolicy: Bool
            let didReleaseWithProvenExistingRoute: Bool
            let didCleanUpRoutingAfterEarlyRelease: Bool
            let routingCleanupCount: Int
            let terminalCleanupRequestCount: Int
            let terminalCleanupRawRequestCount: Int
            let terminalCleanupRequestEntries: [String]
        }

        func debugCleanupSnapshot() -> CleanupSnapshot {
            CleanupSnapshot(
                hasReleased: hasReleased,
                didRouteSuccessfully: didRouteSuccessfully,
                didCleanupRouting: didCleanupRouting,
                didClearPolicy: didClearSuccessfulRoutingPolicy || didRevokePolicy,
                didClearSuccessfulRoutingPolicy: didClearSuccessfulRoutingPolicy,
                didRevokePolicy: didRevokePolicy,
                didReleaseWithProvenExistingRoute: didReleaseWithProvenExistingRoute,
                didCleanUpRoutingAfterEarlyRelease: didCleanUpRoutingAfterEarlyRelease,
                routingCleanupCount: routingCleanupCount,
                terminalCleanupRequestCount: terminalCleanupRequestCount,
                terminalCleanupRawRequestCount: terminalCleanupRequestEntries.count,
                terminalCleanupRequestEntries: terminalCleanupRequestEntries
            )
        }
    #endif

    private let log = Logger(subsystem: "com.repoprompt.mcp", category: "BootstrapLease")

    private var spec: MCPBootstrapLeaseSpec
    private let mcpHost: any AgentMCPHosting
    private let routingWaiter: MCPRoutingWaiter
    private let runCoordinator: AgentRunCoordinator
    private let mcpServerEnabler: (() async -> Void)?
    private let policyInstaller: (MCPBootstrapLeaseSpec) async -> Void
    private let expectedPIDPolicyArmer: (MCPBootstrapLeaseSpec) async -> Bool
    private let successfulRoutingPolicyClearer: (MCPBootstrapLeaseSpec) async -> Void
    private let policyClearer: (MCPBootstrapLeaseSpec) async -> Void
    private let provenRoutePolicyReleaser: (MCPBootstrapLeaseSpec, pid_t) async -> Bool
    private let retainedRunPolicyRefresher: (MCPBootstrapLeaseSpec) async -> Void

    private var hasAcquired = false
    private var hasReleased = false
    private var cleanupRequested = false
    private var ownsGate = false
    private var routingRegistered = false
    private var policyInstalled = false
    private var didRouteSuccessfully = false
    private var didSignalRoutingFailure = false
    private var didReleaseGate = false
    private var didCleanupRouting = false
    private var didClearSuccessfulRoutingPolicy = false
    private var didRevokePolicy = false
    /// The turn's pending policy was released because its launch's helper was already routed;
    /// later failure or cancellation cleanup never revokes it again.
    private var didReleaseWithProvenExistingRoute = false
    /// Failure or cancellation cleanup after an early release ran the host's routing-only cleanup
    /// (`cleanupRunRoutingIfUnproven`), at most once.
    private var didCleanUpRoutingAfterEarlyRelease = false
    #if DEBUG
        private var routingCleanupCount = 0
        private var terminalCleanupRequestCount = 0
        private var terminalCleanupRequestEntries: [String] = []
        private var didRecordTerminalCleanupRequest = false

        private func recordTerminalCleanupRequest(_ entry: String) {
            terminalCleanupRequestEntries.append(entry)
            guard !didRecordTerminalCleanupRequest else { return }
            didRecordTerminalCleanupRequest = true
            terminalCleanupRequestCount += 1
        }
    #endif

    /// Creates a unified bootstrap lease.
    ///
    /// - Parameters:
    ///   - spec: The run specification (run ID, gate ID, policy parameters, etc.)
    ///   - runCoordinator: The coordinator that releases the gate when routed and cleans up routing;
    ///     its MCP host and routing waiter are the ones this lease uses.
    ///   - mcpServerEnabler: Optional hook to ensure the MCP server is started before acquisition.
    ///     Agent-mode provides this; headless flows typically don't need it.
    ///   - policyInstaller: Installs the per-run connection policy. Defaults to calling
    ///     `mcpHost.installClientConnectionPolicy(...)`.
    ///   - expectedPIDPolicyArmer: Confirms the intended pending policy is uniquely PID-owned.
    ///   - successfulRoutingPolicyClearer: Clears only the pending per-run policy after successful routing.
    ///   - policyClearer: Revokes the per-run pending policy on failure/timeout. The default
    ///     (`revokeClientConnectionPolicy`) clears the run's routing state only when no live,
    ///     ancestry-proven helper connection of the run remains, so a helper a long-lived agent
    ///     kept from an earlier turn stays routed.
    ///   - provenRoutePolicyReleaser: Clears the turn's pending policy when the launch's helper is
    ///     already routed (see `releaseWithProvenExistingRoute`). Defaults to
    ///     `mcpHost.releasePendingRunPolicyForProvenRoute(...)`.
    ///   - retainedRunPolicyRefresher: Delivers the installed turn policy to the run's retained,
    ///     proven helper connections. Runs after the global gate is released (PID-owned policies
    ///     only) and before `acquire()` returns, so before the turn's message is sent. Defaults to
    ///     `mcpHost.refreshRetainedRunPolicyForTurnStart(...)`.
    init(
        spec: MCPBootstrapLeaseSpec,
        runCoordinator: AgentRunCoordinator,
        mcpServerEnabler: (() async -> Void)? = nil,
        policyInstaller: ((MCPBootstrapLeaseSpec) async -> Void)? = nil,
        expectedPIDPolicyArmer: ((MCPBootstrapLeaseSpec) async -> Bool)? = nil,
        successfulRoutingPolicyClearer: ((MCPBootstrapLeaseSpec) async -> Void)? = nil,
        policyClearer: ((MCPBootstrapLeaseSpec) async -> Void)? = nil,
        provenRoutePolicyReleaser: ((MCPBootstrapLeaseSpec, pid_t) async -> Bool)? = nil,
        retainedRunPolicyRefresher: ((MCPBootstrapLeaseSpec) async -> Void)? = nil
    ) {
        self.spec = spec
        let mcpHost = runCoordinator.mcpHost
        self.mcpHost = mcpHost
        routingWaiter = runCoordinator.routingWaiter
        self.runCoordinator = runCoordinator
        self.mcpServerEnabler = mcpServerEnabler
        self.policyInstaller = policyInstaller ?? Self.defaultPolicyInstaller(mcpHost)
        self.expectedPIDPolicyArmer = expectedPIDPolicyArmer ?? Self.defaultExpectedPIDPolicyArmer(mcpHost)
        self.successfulRoutingPolicyClearer =
            successfulRoutingPolicyClearer ?? Self.defaultSuccessfulRoutingPolicyClearer(mcpHost)
        self.policyClearer = policyClearer ?? Self.defaultPolicyClearer(mcpHost)
        self.provenRoutePolicyReleaser = provenRoutePolicyReleaser ?? Self.defaultProvenRoutePolicyReleaser(mcpHost)
        self.retainedRunPolicyRefresher = retainedRunPolicyRefresher ?? Self.defaultRetainedRunPolicyRefresher(mcpHost)
    }

    // MARK: - Core Lifecycle

    /// Atomically acquires the global gate, registers routing, and installs connection policy.
    /// PID-owned policies release the gate after their unique pending policy is confirmed armed.
    /// Returns `false` if cancelled, the gate could not be acquired, or PID ownership could not be armed.
    func acquire() async -> Bool {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) acquire() ignored because lease already released")
            return false
        }
        if hasAcquired {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) acquire() returning cached success")
            return true
        }

        let runID = spec.runID
        let gateID = spec.gateID
        acpLeaseLog("[ACP-Runner] lease run=\(runID) gate=\(gateID) acquire() begin client=\(spec.clientName ?? "<none>") window=\(spec.windowID) purpose=\(spec.purpose.rawValue)")

        // Ensure MCP server is started (agent-mode hook)
        if let enabler = mcpServerEnabler {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) enabling MCP server before gate acquire")
            await enabler()
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) MCP server enabler completed")
            if shouldAbortAcquire {
                await cancelAndCleanup()
                return false
            }
        }

        // Register routing state before gate acquisition
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) registering routing waiter")
        await routingWaiter.register(runID: spec.runID)
        routingRegistered = true
        if shouldAbortAcquire {
            await cancelAndCleanup()
            return false
        }
        #if DEBUG
            await mcpHost.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "routing_waiter_registered",
                connectionID: nil,
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "window_id": String(spec.windowID),
                    "tab_id": spec.tabID?.uuidString ?? "nil",
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) routing waiter registered")

        return await withTaskCancellationHandler {
            // Atomically wait + acquire the global gate.
            let gateSnapshot = await HeadlessAgentConnectionGate.snapshot()
            await recordDiagnosticEvent(
                "lease_gate_wait_started",
                fields: [
                    "active_gate_id": gateSnapshot.activeConnectionID?.uuidString ?? "nil",
                    "queue_depth": String(gateSnapshot.queueDepth)
                ]
            )
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) waiting to acquire global MCP gate")
            let gateAcquisition = await HeadlessAgentConnectionGate.acquireWithDiagnostics(spec.gateID)
            if gateAcquisition.acquired {
                ownsGate = true
            }
            await recordDiagnosticEvent(
                gateAcquisition.acquired ? "lease_gate_acquired" : "lease_gate_acquire_failed",
                fields: [
                    "active_gate_id_at_start": gateAcquisition.activeConnectionIDAtStart?.uuidString ?? "nil",
                    "queue_depth_at_start": String(gateAcquisition.queueDepthAtStart),
                    "queue_depth_at_acquire": String(gateAcquisition.queueDepthAtAcquire),
                    "wait_duration_ms": String(format: "%.3f", gateAcquisition.waitDurationMS)
                ]
            )
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) global MCP gate acquired=\(gateAcquisition.acquired)")
            if !gateAcquisition.acquired || shouldAbortAcquire {
                acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) acquire() failed, was released, or task cancelled")
                await cancelAndCleanup()
                return false
            }

            // Install per-run connection policy
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) installing connection policy for client=\(spec.clientName ?? "<none>")")
            await policyInstaller(spec)
            policyInstalled = true
            if shouldAbortAcquire {
                await cancelAndCleanup()
                return false
            }
            if spec.requiresExpectedAgentPID {
                let policyArmed = await expectedPIDPolicyArmer(spec)
                await recordDiagnosticEvent(
                    "lease_expected_pid_policy_armed",
                    fields: ["armed": String(policyArmed)]
                )
                guard policyArmed else {
                    acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) expected-PID policy could not be armed")
                    await cancelAndCleanup()
                    return false
                }
                if shouldAbortAcquire {
                    await cancelAndCleanup()
                    return false
                }
            }
            #if DEBUG
                await mcpHost.debugRecordRunRoutingEvent(
                    runID: spec.runID,
                    event: "lease_policy_ready",
                    connectionID: nil,
                    fields: [
                        "client_name": spec.clientName ?? "nil",
                        "requires_expected_pid": String(spec.requiresExpectedAgentPID),
                        "window_id": String(spec.windowID),
                        "tab_id": spec.tabID?.uuidString ?? "nil"
                    ]
                )
            #endif
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) connection policy installed")
            if shouldAbortAcquire {
                acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) task cancelled or lease released after policy install")
                await cancelAndCleanup()
                return false
            }

            hasAcquired = true
            if spec.requiresExpectedAgentPID {
                // The pending policy is now uniquely run-scoped and PID-owned. Release the
                // process-global gate before spawning so independent sessions may initialize
                // concurrently; the routing waiter and policy remain owned by this lease.
                await releaseOwnedGate(reason: "expected_pid_policy_armed")
                // Cancellation may have landed during the gate release or the refresh below: the
                // lease never reports success after it (cleanup is idempotent).
                if shouldAbortAcquire {
                    await cancelAndCleanup()
                    return false
                }
                // Turn-start delivery to a retained helper, outside the global gate: a slow
                // `tools/list_changed` write never holds up other sessions' bootstrap.
                await retainedRunPolicyRefresher(spec)
                if shouldAbortAcquire {
                    await cancelAndCleanup()
                    return false
                }
            }
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) acquire() completed")
            return true
        } onCancel: {
            acpLeaseLog("[ACP-Runner] lease run=\(runID) gate=\(gateID) acquire() cancellation handler invoked")
            Task { await self.cancelAndCleanup() }
        }
    }

    // MARK: - Release Strategies

    /// Waits for routing and releases legacy gate ownership once established or timed out.
    /// PID-owned policies have already released the gate but retain this routing/policy cleanup.
    /// If routing fails/times out, revokes the pending policy entry; the host clears the run's
    /// routing only when no live, ancestry-proven helper remains (a later turn of a long-lived
    /// agent keeps its existing helper, so no new connection arrives and the wait times out).
    @discardableResult
    package func releaseWhenRouted(timeoutMs: Int = 10000) async -> Bool {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseWhenRouted() ignored because lease already released")
            return false
        }
        hasReleased = true

        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseWhenRouted() waiting for routing client=\(spec.clientName ?? "<none>") timeoutMs=\(timeoutMs)")
        #if DEBUG
            await mcpHost.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "route_wait_started",
                connectionID: nil,
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "timeout_ms": String(timeoutMs),
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif
        let ownedGateBeforeWait = ownsGate
        let releaseResult = await runCoordinator.releaseGateWhenRouted(
            runID: spec.runID,
            gateID: spec.gateID,
            timeoutMs: timeoutMs
        )
        ownsGate = false
        let routed = releaseResult.routed
        if routed {
            didRouteSuccessfully = true
        }
        if ownedGateBeforeWait || releaseResult.gateRelease.released {
            await recordGateRelease(
                releaseResult.gateRelease,
                reason: routed ? "routing_completed" : (Task.isCancelled ? "routing_cancelled" : "routing_timeout_or_failure")
            )
        }
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseWhenRouted() completed routed=\(routed)")
        #if DEBUG
            await mcpHost.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "route_wait_completed",
                connectionID: nil,
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "routed": String(routed),
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif

        // Cancellation cleanup may have run while the wait was suspended; it already revoked the
        // policy and cleaned routing, and neither is repeated.
        if !routed, !didRevokePolicy, !didReleaseWithProvenExistingRoute {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) routing wait failed or timed out; clearing connection policy")
            didRevokePolicy = true
            await policyClearer(spec)
        }
        if !didCleanupRouting {
            didCleanupRouting = true
            await runCoordinator.cleanupRouting(runID: spec.runID)
            #if DEBUG
                routingCleanupCount += 1
            #endif
        }

        return routed
    }

    /// A later turn of a launch that kept its helper: no new connection will arrive, so instead of
    /// waiting out `releaseWhenRouted`'s timeout, the lease asks the host to release the turn's
    /// pending policy when the run already has a live route proven to belong to `agentPID`'s launch.
    /// On success it finishes like a routed release (the waiter is cleaned up, any owned gate is
    /// released, and later failure or cancellation cleanup never revokes) and returns true. Returns
    /// false, leaving the lease untouched for `releaseWhenRouted`, when the route is not proven (a
    /// first turn or a restarted launch, whose new helper must still be routed by the policy).
    package func releaseWithProvenExistingRoute(agentPID: pid_t) async -> Bool {
        guard hasAcquired, policyInstalled, !hasReleased, !cleanupRequested, !Task.isCancelled else { return false }
        let released = await provenRoutePolicyReleaser(spec, agentPID)
        // Cancellation cleanup that ran or was requested meanwhile owns the lease's cleanup.
        guard released, !hasReleased, !cleanupRequested else { return false }
        hasReleased = true
        didReleaseWithProvenExistingRoute = true
        didRouteSuccessfully = true
        // The host already cleared the policy; the successful-routing clear has nothing left to do.
        didClearSuccessfulRoutingPolicy = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) launch helper already routed; released without the routing wait")
        #if DEBUG
            await mcpHost.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "route_wait_skipped_proven_route",
                connectionID: nil,
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "agent_pid": String(agentPID),
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif
        await releaseOwnedGate(reason: "proven_existing_route")
        if routingRegistered, !didCleanupRouting {
            didCleanupRouting = true
            await runCoordinator.cleanupRouting(runID: spec.runID)
            #if DEBUG
                routingCleanupCount += 1
            #endif
        }
        return true
    }

    #if DEBUG
        /// Records that the runner did not attempt the proven-route early release, and why.
        package func debugRecordProvenRouteReleaseSkipped(reason: String) async {
            await mcpHost.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "proven_route_release_skipped",
                connectionID: nil,
                fields: [
                    "reason": reason,
                    "client_name": spec.clientName ?? "nil",
                    "gate_id": spec.gateID.uuidString
                ]
            )
        }
    #endif

    /// Clears only this run's installed policy after routing completed successfully.
    /// This preserves retained routing, affinity, mappings, gate state, and provider reuse.
    func clearPolicyAfterSuccessfulRouting() async {
        guard policyInstalled,
              didRouteSuccessfully,
              !didClearSuccessfulRoutingPolicy,
              !didRevokePolicy
        else { return }
        didClearSuccessfulRoutingPolicy = true
        await successfulRoutingPolicyClearer(spec)
    }

    /// Releases the global connection gate without waiting for a routing signal.
    /// Use this when no fresh connection is expected but we still need to free the gate.
    func releaseWithoutRoutingWait() async {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseWithoutRoutingWait() ignored because lease already released")
            return
        }
        hasReleased = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releasing gate without waiting for routing")
        await releaseOwnedGate(reason: "without_routing_wait")
        await runCoordinator.cleanupRouting(runID: spec.runID)
        didCleanupRouting = true
        #if DEBUG
            routingCleanupCount += 1
        #endif
    }

    /// Releases only the serialized bootstrap gate while retaining the pending run policy.
    /// Use this for ACP runtimes that do not open their MCP transport until the first prompt.
    func releaseGateForDeferredRouting() async {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseGateForDeferredRouting() ignored because lease already released")
            return
        }
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) deferring route wait until provider prompt")
        #if DEBUG
            await mcpHost.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "route_wait_deferred",
                connectionID: nil,
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif
        await releaseOwnedGate(reason: "deferred_routing")
    }

    /// Cleans up deferred routing state after a prompt-deferred provider reaches a terminal state
    /// without needing to report a bootstrap failure.
    func cleanupDeferredRouting() async {
        #if DEBUG
            recordTerminalCleanupRequest("cleanupDeferredRouting")
        #endif
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) cleanupDeferredRouting() ignored because lease already released")
            return
        }
        cleanupRequested = true
        hasReleased = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) cleaning up deferred routing state")
        await performDeferredRoutingCleanup(reason: "deferred_terminal")
    }

    // MARK: - Failure & Cancellation

    /// Hard failure path: signal routing failure and release gate immediately.
    func failAndRelease() async {
        #if DEBUG
            recordTerminalCleanupRequest("failAndRelease")
        #endif
        if hasReleased {
            cleanupRequested = true
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) failAndRelease() performing terminal cleanup after release")
            await performCancellationCleanup(reason: "failed")
            return
        }
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) failAndRelease() signaling routing failure")
        await routingWaiter.notifyFailed(runID: spec.runID)
        _ = await releaseWhenRouted()
    }

    /// Hard failure path variant used by headless flows.
    package func failAndCleanup() async {
        #if DEBUG
            recordTerminalCleanupRequest("failAndCleanup")
        #endif
        cleanupRequested = true
        hasReleased = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) failAndCleanup() signaling failure and clearing policy")
        await performCancellationCleanup(reason: "failed")
    }

    /// Cancellation path: signal failure, release any gate ownership that materializes,
    /// clear installed policy, and clean up routing. Cleanup remains retryable while a
    /// queued gate acquisition is still suspended.
    func cancelAndCleanup() async {
        #if DEBUG
            recordTerminalCleanupRequest("cancelAndCleanup")
        #endif
        cleanupRequested = true
        hasReleased = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) cancelAndCleanup() signaling failure and releasing gate")
        await performCancellationCleanup(reason: "cancelled")
    }

    private var shouldAbortAcquire: Bool {
        cleanupRequested || hasReleased || Task.isCancelled
    }

    func providerInitializationStarted(provider: String) async {
        await recordDiagnosticEvent(
            "provider_initialization_started",
            fields: ["provider": provider]
        )
    }

    func providerInitializationCompleted(provider: String, outcome: String) async {
        await recordDiagnosticEvent(
            "provider_initialization_completed",
            fields: [
                "provider": provider,
                "outcome": outcome
            ]
        )
    }

    private func releaseOwnedGate(reason: String) async {
        guard ownsGate else { return }
        let result = await HeadlessAgentConnectionGate.completeIfActiveWithDiagnostics(spec.gateID)
        ownsGate = false
        didReleaseGate = didReleaseGate || result.released
        await recordGateRelease(result, reason: reason)
    }

    private func recordGateRelease(
        _ result: HeadlessAgentConnectionGate.ReleaseResult,
        reason: String
    ) async {
        await recordDiagnosticEvent(
            "lease_gate_release",
            fields: [
                "reason": reason,
                "released": String(result.released),
                "active_gate_id_before_release": result.activeConnectionIDBeforeRelease?.uuidString ?? "nil",
                "queue_depth_before_release": String(result.queueDepthBeforeRelease),
                "resumed_waiter": String(result.resumedWaiter)
            ]
        )
    }

    private func recordDiagnosticEvent(
        _ event: String,
        fields: [String: String] = [:]
    ) async {
        #if DEBUG
            var diagnosticFields: [String: String] = [
                "client_name": spec.clientName ?? "nil",
                "connection_id": "nil",
                "gate_id": spec.gateID.uuidString,
                "window_id": String(spec.windowID),
                "tab_id": spec.tabID?.uuidString ?? "nil",
                "requires_expected_pid": String(spec.requiresExpectedAgentPID)
            ]
            for (key, value) in fields {
                diagnosticFields[key] = value
            }
            await mcpHost.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: event,
                connectionID: nil,
                fields: diagnosticFields
            )
            AgentModePerfDiagnostics.event(
                "mcp.routing.\(event)",
                tabID: spec.tabID,
                fields: diagnosticFields
            )
        #endif
    }

    private func performCancellationCleanup(reason: String) async {
        #if DEBUG
            await mcpHost.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "lease_cancelled",
                connectionID: nil,
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "gate_id": spec.gateID.uuidString,
                    "reason": reason
                ]
            )
        #endif
        // An early release finished the run's routing as routed: no failure is signalled for it.
        if routingRegistered, !didSignalRoutingFailure, !didReleaseWithProvenExistingRoute {
            didSignalRoutingFailure = true
            await routingWaiter.notifyFailed(runID: spec.runID)
        }
        await releaseOwnedGate(reason: reason)
        if policyInstalled, !didRevokePolicy, !didReleaseWithProvenExistingRoute {
            didRevokePolicy = true
            await policyClearer(spec)
        }
        await cleanUpRoutingAfterEarlyReleaseIfNeeded()
        if routingRegistered, !didCleanupRouting {
            didCleanupRouting = true
            await runCoordinator.cleanupRouting(runID: spec.runID)
            #if DEBUG
                routingCleanupCount += 1
            #endif
        }
        #if DEBUG
            await mcpHost.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "lease_cleanup_completed",
                connectionID: nil,
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "reason": reason,
                    "owns_gate": String(ownsGate),
                    "gate_released": String(didReleaseGate),
                    "routing_cleaned": String(didCleanupRouting),
                    "policy_installed": String(policyInstalled),
                    "policy_cleared": String(didClearSuccessfulRoutingPolicy || didRevokePolicy),
                    "successful_policy_cleared": String(didClearSuccessfulRoutingPolicy),
                    "policy_revoked": String(didRevokePolicy)
                ]
            )
        #endif
    }

    /// After an early release the turn's policy is gone and is never revoked, but a failed or
    /// cancelled turn still owes the run the revoke's routing half: the host clears the run's
    /// routing when its agent is no longer provable (and prunes unproven routes otherwise),
    /// without touching any pending policy. At most once per lease.
    private func cleanUpRoutingAfterEarlyReleaseIfNeeded() async {
        guard didReleaseWithProvenExistingRoute,
              !didCleanUpRoutingAfterEarlyRelease,
              let clientName = spec.clientName
        else { return }
        didCleanUpRoutingAfterEarlyRelease = true
        await mcpHost.cleanupRunRoutingIfUnproven(for: clientName, windowID: spec.windowID, runID: spec.runID)
    }

    private func performDeferredRoutingCleanup(reason: String) async {
        #if DEBUG
            await mcpHost.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "lease_deferred_cleanup",
                connectionID: nil,
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "gate_id": spec.gateID.uuidString,
                    "reason": reason
                ]
            )
        #endif
        await releaseOwnedGate(reason: reason)
        if policyInstalled, !didRevokePolicy, !didReleaseWithProvenExistingRoute {
            didRevokePolicy = true
            await policyClearer(spec)
        }
        await cleanUpRoutingAfterEarlyReleaseIfNeeded()
        if routingRegistered, !didCleanupRouting {
            didCleanupRouting = true
            await runCoordinator.cleanupRouting(runID: spec.runID)
            #if DEBUG
                routingCleanupCount += 1
            #endif
        }
        #if DEBUG
            await mcpHost.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "lease_cleanup_completed",
                connectionID: nil,
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "reason": reason,
                    "owns_gate": String(ownsGate),
                    "gate_released": String(didReleaseGate),
                    "routing_cleaned": String(didCleanupRouting),
                    "policy_installed": String(policyInstalled),
                    "policy_cleared": String(didClearSuccessfulRoutingPolicy || didRevokePolicy),
                    "successful_policy_cleared": String(didClearSuccessfulRoutingPolicy),
                    "policy_revoked": String(didRevokePolicy)
                ]
            )
        #endif
    }

    // MARK: - Default Policy Hooks

    private static func defaultExpectedPIDPolicyArmer(
        _ mcpHost: any AgentMCPHosting
    ) -> (MCPBootstrapLeaseSpec) async -> Bool {
        { spec in
            guard spec.requiresExpectedAgentPID, let clientName = spec.clientName else {
                return !spec.requiresExpectedAgentPID
            }
            return await mcpHost.requireExpectedAgentPIDForPendingPolicy(
                for: clientName,
                runID: spec.runID,
                windowID: spec.windowID
            )
        }
    }

    private static func defaultPolicyInstaller(
        _ mcpHost: any AgentMCPHosting
    ) -> (MCPBootstrapLeaseSpec) async -> Void {
        { spec in
            guard let clientName = spec.clientName else { return }
            await mcpHost.installClientConnectionPolicy(
                for: clientName,
                windowID: spec.windowID,
                restrictedTools: spec.restrictedTools,
                oneShot: spec.oneShot,
                reason: spec.reason,
                ttl: spec.ttl,
                tabID: spec.tabID,
                runID: spec.runID,
                additionalTools: spec.additionalTools,
                allowedToolsOverride: spec.allowedToolsOverride,
                sessionProfile: spec.sessionProfile,
                purpose: spec.purpose,
                taskLabelKind: spec.taskLabelKind,
                allowsAgentExternalControlTools: spec.allowsAgentExternalControlTools,
                requiresExpectedAgentPID: spec.requiresExpectedAgentPID,
                runOwnership: spec.runOwnership
            )
        }
    }

    private static func defaultSuccessfulRoutingPolicyClearer(
        _ mcpHost: any AgentMCPHosting
    ) -> (MCPBootstrapLeaseSpec) async -> Void {
        { spec in
            guard let clientName = spec.clientName else { return }
            await mcpHost.clearClientConnectionPolicy(
                for: clientName,
                windowID: spec.windowID,
                runID: spec.runID
            )
        }
    }

    private static func defaultProvenRoutePolicyReleaser(
        _ mcpHost: any AgentMCPHosting
    ) -> (MCPBootstrapLeaseSpec, pid_t) async -> Bool {
        { spec, agentPID in
            guard let clientName = spec.clientName else { return false }
            return await mcpHost.releasePendingRunPolicyForProvenRoute(
                for: clientName,
                windowID: spec.windowID,
                runID: spec.runID,
                agentPID: agentPID
            )
        }
    }

    private static func defaultRetainedRunPolicyRefresher(
        _ mcpHost: any AgentMCPHosting
    ) -> (MCPBootstrapLeaseSpec) async -> Void {
        { spec in
            guard let clientName = spec.clientName else { return }
            await mcpHost.refreshRetainedRunPolicyForTurnStart(for: clientName, runID: spec.runID)
            // Every provider's live routed connections of the run take this attempt's ownership
            // (and its rich-presentation grant) before the turn's message is sent.
            if spec.purpose == .agentModeRun, let runOwnership = spec.runOwnership {
                await mcpHost.refreshRunAttemptRichPresentation(
                    for: clientName,
                    runID: spec.runID,
                    runOwnership: runOwnership
                )
            }
        }
    }

    /// Revokes the run's pending policy. The host keeps the run's proven routes, run policy state
    /// and live affinity while a live, ancestry-proven helper connection of the run remains (and
    /// unroutes the run's unproven connections), and otherwise clears them
    /// (`cleanupRunRoutingState`).
    private static func defaultPolicyClearer(
        _ mcpHost: any AgentMCPHosting
    ) -> (MCPBootstrapLeaseSpec) async -> Void {
        { spec in
            guard let clientName = spec.clientName else { return }
            await mcpHost.revokeClientConnectionPolicy(
                for: clientName,
                windowID: spec.windowID,
                runID: spec.runID
            )
        }
    }
}
