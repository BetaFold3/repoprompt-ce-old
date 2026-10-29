import Foundation

/// Core Agent Mode contract for native CLI runtimes that keep an interactive
/// process/session alive across turns.
///
/// This is an app-internal contract, not the future external plugin API. It can
/// use core app models (`AIStreamResult`, `AgentApprovalRequest`, and
/// `AgentApprovalDecision`) because adapters/bridges are expected to translate
/// plugin-owned DTOs before events reach Agent Mode.
package protocol NativeAgentRuntimeControlling: Actor {
    var hasActiveSession: Bool { get async }
    var hasTurnInFlight: Bool { get async }
    var events: AsyncStream<NativeAgentRuntimeEvent> { get async }
    var requiresReplacementAfterTerminalStartupFailure: Bool { get async }
    /// Dedicated, ordered usage-accounting evidence stream (launch, dispatch, attributed results,
    /// blockage, launch end). Independent of transcript delivery and of run-attempt consumers.
    /// Runtimes without accounting evidence return an already-finished stream.
    var usageAccountingEvents: AsyncStream<NativeUsageAccountingEvent> { get async }

    func ensureEventsStreamReady() async
    func resetEventsStreamForNewRun() async
    /// Ensures the events stream is live and returns it with its generation, read atomically.
    /// The generation changes whenever the controller replaces its stream; `nil` means the
    /// runtime does not track generations.
    func eventsSubscription() async -> NativeAgentRuntimeEventsSubscription
    /// Yields `.marker(id)` on the current events stream, in order with provider output, and
    /// returns that stream's generation. Returns `nil` when no stream is live or the runtime does
    /// not support markers.
    func emitEventMarker(_ id: UUID) async -> UInt64?
    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef
    func currentSessionRef() async -> NativeAgentRuntimeSessionRef
    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws
    func sendUserMessage(_ text: String) async throws -> UUID
    /// Sends a reasoned interrupt request to the provider runtime.
    /// - Parameter reason: "interrupt" for steering (graceful), "cancel" for forceful stop.
    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome
    func shutdown() async
    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async
    /// Whether the runtime failed `turnID` because its provider process ended unexpectedly (not a
    /// shutdown it was asked for): the run's terminal cause is provider-process loss (review A F06).
    /// Answers once per turn. Runtimes without that evidence answer `false`.
    func turnEndedByProcessLoss(_ turnID: UUID) async -> Bool
    /// R6: whether this runtime's launches are registered. A registered start joins the tab's
    /// retained runtime retirements (any provider) before it reserves. Others never join.
    nonisolated var joinsRetirementBeforeSuccessor: Bool { get }
    /// O49: the written, not yet completed turn that provider output (model text, reasoning, or a
    /// tool call) has been attributed to, or `nil`. A queued turn the provider has not begun is
    /// never reported. Runtimes without per-turn output attribution report `nil`.
    nonisolated var startedTurnID: UUID? { get }
    /// RepoPrompt MCP health of the current launch. Runtimes without health tracking report
    /// `.unknown` and are never recovered for MCP health.
    var currentRepoPromptMCPHealth: NativeAgentRuntimeRepoPromptMCPHealth { get async }
    /// The PID of the current, healthy launch's spawned agent process, bound to that launch's
    /// RepoPrompt MCP launch token, or `nil` (no running launch, shutting down, or unhealthy). It
    /// may not be registered as the run's expected MCP agent yet; the host proves a route only
    /// against a registered instance, so an unregistered PID never skips the wait. A later turn may
    /// skip its routing wait only for a route proven to belong to this launch. Runtimes without
    /// it report `nil` and always wait.
    var repoPromptMCPLaunchAgentPID: pid_t? { get async }
    /// Bounded wait for fresh RepoPrompt MCP connected evidence on the current launch. Runtimes
    /// without such evidence never report `connected`.
    func awaitRepoPromptMCPConnectedEvidence(
        timeoutSeconds: TimeInterval,
        pollIntervalSeconds: TimeInterval
    ) async -> NativeAgentRuntimeRepoPromptMCPProbeOutcome
}

extension NativeAgentRuntimeControlling {
    var requiresReplacementAfterTerminalStartupFailure: Bool {
        false
    }

    var usageAccountingEvents: AsyncStream<NativeUsageAccountingEvent> {
        AsyncStream { $0.finish() }
    }

    func eventsSubscription() async -> NativeAgentRuntimeEventsSubscription {
        await ensureEventsStreamReady()
        return await NativeAgentRuntimeEventsSubscription(events: events, generation: nil)
    }

    func emitEventMarker(_: UUID) async -> UInt64? {
        nil
    }

    func turnEndedByProcessLoss(_: UUID) async -> Bool {
        false
    }

    nonisolated var joinsRetirementBeforeSuccessor: Bool {
        false
    }

    nonisolated var startedTurnID: UUID? {
        nil
    }

    var currentRepoPromptMCPHealth: NativeAgentRuntimeRepoPromptMCPHealth {
        get async { .unknown }
    }

    var repoPromptMCPLaunchAgentPID: pid_t? {
        get async { nil }
    }

    func awaitRepoPromptMCPConnectedEvidence(
        timeoutSeconds _: TimeInterval,
        pollIntervalSeconds _: TimeInterval
    ) async -> NativeAgentRuntimeRepoPromptMCPProbeOutcome {
        .notConnected("This runtime reports no RepoPrompt MCP connection evidence.")
    }
}

package struct NativeAgentRuntimeEventsSubscription {
    let events: AsyncStream<NativeAgentRuntimeEvent>
    let generation: UInt64?
}

// MARK: - Current Claude-compatible native runtime aliases

// Native process control is still core-owned in this wave. Typed executable-selection
// strictness is likewise core-owned today and is intentionally absent from the plugin DTO.
// These compatibility aliases let coordinators/runners depend on the provider-neutral contract
// while preserving the current Claude runtime DTO shapes. When a second native
// provider lands, the aliases become proper neutral DTOs and the Claude
// controller conforms via its own mapping.
// See docs/architecture/provider-plugins.md for the full bridge/adapter layout.
package typealias NativeAgentRuntimeEvent = ClaudeNativeProcessSessionController.Event
package typealias NativeAgentRuntimeSessionRef = ClaudeNativeProcessSessionController.SessionRef
typealias NativeAgentRuntimeTurnStatus = ClaudeNativeProcessSessionController.TurnStatus
typealias NativeAgentRuntimeRuntimeInitStatus = ClaudeNativeProcessSessionController.RuntimeInitStatus
package typealias NativeAgentRuntimeInterruptOutcome = ClaudeNativeProcessSessionController.InterruptOutcome
typealias NativeAgentRuntimeControllerError = ClaudeNativeProcessSessionController.ControllerError
package typealias NativeAgentRuntimeRepoPromptMCPHealth = ClaudeNativeProcessSessionController.RepoPromptMCPHealth
package typealias NativeAgentRuntimeRepoPromptMCPProbeOutcome = ClaudeNativeProcessSessionController.RepoPromptMCPConnectionProbeOutcome
package typealias NativeAgentRuntimeEffortLevel = ClaudeCodeEffortLevel
package typealias NativeUsageAccountingEvent = ClaudeNativeProcessSessionController.UsageAccountingEvent
typealias NativeProcessLaunchIdentity = ClaudeNativeProcessSessionController.ProcessLaunchIdentity
typealias NativeUsageResultAttribution = ClaudeNativeProcessSessionController.UsageResultAttribution

extension ClaudeNativeProcessSessionController: NativeAgentRuntimeControlling {}
