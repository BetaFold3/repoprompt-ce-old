import Foundation

/// Interactive native-runtime seam for the Claude-compatible plugin path.
///
/// Full native process control remains core-owned for this slice. The adapter is
/// nevertheless the object Agent Mode consumes: it carries the package-shaped
/// runtime DTO and delegates the `NativeAgentRuntimeControlling` contract to the
/// current core controller. This keeps run behavior unchanged while routing the
/// interactive path through the future plugin boundary.
actor ClaudeCompatibleNativeSessionAdapter: NativeAgentRuntimeControlling {
    typealias ControllerFactory = () -> any NativeAgentRuntimeControlling

    let runtimeConfig: ClaudeCompatiblePluginRuntimeConfig
    private let controller: any NativeAgentRuntimeControlling

    init(
        runtimeConfig: ClaudeCompatiblePluginRuntimeConfig,
        controllerFactory: @escaping ControllerFactory
    ) {
        self.runtimeConfig = runtimeConfig
        controller = controllerFactory()
    }

    var hasActiveSession: Bool {
        get async { await controller.hasActiveSession }
    }

    var hasTurnInFlight: Bool {
        get async { await controller.hasTurnInFlight }
    }

    nonisolated var startedTurnID: UUID? {
        controller.startedTurnID
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        get async { await controller.events }
    }

    var requiresReplacementAfterTerminalStartupFailure: Bool {
        get async { await controller.requiresReplacementAfterTerminalStartupFailure }
    }

    var usageAccountingEvents: AsyncStream<NativeUsageAccountingEvent> {
        get async { await controller.usageAccountingEvents }
    }

    func ensureEventsStreamReady() async {
        await controller.ensureEventsStreamReady()
    }

    func resetEventsStreamForNewRun() async {
        await controller.resetEventsStreamForNewRun()
    }

    func eventsSubscription() async -> NativeAgentRuntimeEventsSubscription {
        await controller.eventsSubscription()
    }

    func emitEventMarker(_ id: UUID) async -> UInt64? {
        await controller.emitEventMarker(id)
    }

    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        try await controller.startOrResume(
            existingSessionID: existingSessionID,
            model: model,
            effortLevel: effortLevel,
            systemPromptOverride: systemPromptOverride
        )
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        await controller.currentSessionRef()
    }

    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws {
        try await controller.applyModelAndEffort(model: model, effortLevel: effortLevel)
    }

    func sendUserMessage(_ text: String) async throws -> UUID {
        try await controller.sendUserMessage(text)
    }

    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome {
        await controller.interruptTurn(reason: reason)
    }

    func shutdown() async {
        await controller.shutdown()
    }

    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async {
        await controller.respondToPermissionRequest(id: id, decision: decision)
    }

    var currentRepoPromptMCPHealth: NativeAgentRuntimeRepoPromptMCPHealth {
        get async { await controller.currentRepoPromptMCPHealth }
    }

    /// Forwarded like the health: without it the protocol default (`nil`) would make every later
    /// Claude turn take the 10 s routing wait instead of the proven-route early release.
    var repoPromptMCPLaunchAgentPID: pid_t? {
        get async { await controller.repoPromptMCPLaunchAgentPID }
    }

    func awaitRepoPromptMCPConnectedEvidence(
        timeoutSeconds: TimeInterval,
        pollIntervalSeconds: TimeInterval
    ) async -> NativeAgentRuntimeRepoPromptMCPProbeOutcome {
        await controller.awaitRepoPromptMCPConnectedEvidence(
            timeoutSeconds: timeoutSeconds,
            pollIntervalSeconds: pollIntervalSeconds
        )
    }

    static func streamResult(from providerResult: ClaudeCompatiblePluginStreamResult) -> AIStreamResult {
        ClaudeCompatiblePluginBridge.streamResult(from: providerResult)
    }
}
