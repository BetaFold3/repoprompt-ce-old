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
    /// Per-run `code_mode` exposure (plan §6 D3). Always `.native` for Knowledge and
    /// non-Agent Mode runs; not persisted and not consumed by policy installation yet.
    package let codeModeEligibility: MCPCodeModeEligibility

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
        codeModeEligibility: MCPCodeModeEligibility = .native
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
        self.codeModeEligibility = MCPCodeModeEligibility.normalized(
            codeModeEligibility,
            purpose: purpose,
            sessionProfile: sessionProfile
        )
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
/// 3. `releaseWhenRouted()` — waits for routing (or timeout) and cleans retained state
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
    ///   - policyClearer: Revokes the per-run policy and routing state on failure/timeout.
    init(
        spec: MCPBootstrapLeaseSpec,
        runCoordinator: AgentRunCoordinator,
        mcpServerEnabler: (() async -> Void)? = nil,
        policyInstaller: ((MCPBootstrapLeaseSpec) async -> Void)? = nil,
        expectedPIDPolicyArmer: ((MCPBootstrapLeaseSpec) async -> Bool)? = nil,
        successfulRoutingPolicyClearer: ((MCPBootstrapLeaseSpec) async -> Void)? = nil,
        policyClearer: ((MCPBootstrapLeaseSpec) async -> Void)? = nil
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
    /// If routing fails/times out, clears the pending policy entry.
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

        if !routed {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) routing wait failed or timed out; clearing connection policy")
            didRevokePolicy = true
            await policyClearer(spec)
        }
        await runCoordinator.cleanupRouting(runID: spec.runID)
        didCleanupRouting = true
        #if DEBUG
            routingCleanupCount += 1
        #endif

        return routed
    }

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
        if routingRegistered, !didSignalRoutingFailure {
            didSignalRoutingFailure = true
            await routingWaiter.notifyFailed(runID: spec.runID)
        }
        await releaseOwnedGate(reason: reason)
        if policyInstalled, !didRevokePolicy {
            didRevokePolicy = true
            await policyClearer(spec)
        }
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
        if policyInstalled, !didRevokePolicy {
            didRevokePolicy = true
            await policyClearer(spec)
        }
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
                requiresExpectedAgentPID: spec.requiresExpectedAgentPID
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
