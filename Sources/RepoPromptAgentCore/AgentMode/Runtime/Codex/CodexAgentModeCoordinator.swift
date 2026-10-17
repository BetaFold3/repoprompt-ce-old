import Foundation
import MCP
import RepoPromptPlatform
#if canImport(Darwin)
    import Darwin
#endif

@MainActor
package final class CodexAgentModeCoordinator: AgentModeRunInteractionStateObserving {
    package typealias CodexControllerFactory = (
        _ runID: UUID,
        _ tabID: UUID,
        _ windowID: Int,
        _ workspacePath: String?,
        _ permissionProfile: AgentProviderPermissionProfile,
        _ sessionProfile: AgentSessionProfile,
        _ taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        _ computerUseEnabled: Bool
    ) -> any CodexSessionControlling

    package typealias ConnectionPolicyInstaller = (
        _ clientName: String,
        _ windowID: Int,
        _ restrictedTools: Set<String>,
        _ oneShot: Bool,
        _ reason: String?,
        _ ttl: TimeInterval,
        _ tabID: UUID?,
        _ runID: UUID?,
        _ additionalTools: Set<String>?,
        _ allowedToolsOverride: Set<String>?,
        _ sessionProfile: AgentSessionProfile,
        _ purpose: MCPRunPurpose,
        _ taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        _ allowsAgentExternalControlTools: Bool,
        _ requiresExpectedAgentPID: Bool
    ) async -> Void
    package typealias ActiveToolQuery = AgentCodexActiveToolQuery
    package typealias ActiveAgentRunWaitQuery = AgentCodexAgentRunWaitQuery
    package typealias ActiveAgentRunWaitDrain = AgentCodexAgentRunWaitDrain
    typealias NativeToolLivenessState = AgentCodexNativeToolLivenessState

    package enum NativeSlashCommand: String, CaseIterable {
        case compact
        case goal
        case computerUse = "computer-use"

        package var subtitle: String {
            switch self {
            case .compact:
                "Compact the active Codex thread context"
            case .goal:
                "Set or view the goal for a long-running Codex task"
            case .computerUse:
                "Guide Codex through a computer-use workflow"
            }
        }

        package var behavior: NativeSlashCommandBehavior {
            switch self {
            case .compact, .goal:
                .controlPlane
            case .computerUse:
                .userTurnWrapper
            }
        }
    }

    package enum NativeSlashCommandBehavior: Equatable {
        case controlPlane
        case userTurnWrapper
    }

    package enum NativeSlashCommandExecutionResult: Equatable {
        case succeeded(String)
        case failed(String)
    }

    package enum GoalSlashAction: Equatable {
        case show
        case clear
        case pause
        case resume
        case setObjective(String)
    }

    static let maxThreadGoalObjectiveCharacters = 4000

    package static func goalSlashAction(from argumentsText: String) -> GoalSlashAction {
        let trimmed = argumentsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .show }
        switch trimmed.lowercased() {
        case "clear":
            return .clear
        case "pause":
            return .pause
        case "resume":
            return .resume
        default:
            return .setObjective(trimmed)
        }
    }

    package static func goalObjectiveValidationMessage(_ objective: String) -> String? {
        let actual = objective.count
        guard actual > maxThreadGoalObjectiveCharacters else { return nil }
        return "Goal objective is too long: \(formattedCharacterCount(actual)) characters. Limit: \(formattedCharacterCount(maxThreadGoalObjectiveCharacters)) characters. Put longer instructions in a file and refer to that file in the goal, for example: /goal follow the instructions in docs/goal.md."
    }

    package struct GoalObjectiveComposition: Equatable {
        let objective: String
    }

    package enum GoalObjectiveCompositionResult: Equatable {
        case success(GoalObjectiveComposition)
        case failure(String)
    }

    package static func composeGoalObjective(
        rawObjective: String,
        selectedWorkflow: AgentWorkflowDefinition?,
        includeBuiltInSessionCleanupGuidance: Bool
    ) -> GoalObjectiveCompositionResult {
        let rawObjective = rawObjective.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = goalObjectiveValidationMessage(rawObjective) {
            return .failure(message)
        }
        guard let selectedWorkflow else {
            return .success(GoalObjectiveComposition(objective: rawObjective))
        }

        let description = selectedWorkflow.descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tooltip = selectedWorkflow.tooltipText?.trimmingCharacters(in: .whitespacesAndNewlines)
        var contextLines = [
            "User goal:",
            rawObjective,
            "",
            "RepoPrompt workflow context:",
            "Workflow: \(selectedWorkflow.displayName)"
        ]
        if let description, !description.isEmpty {
            contextLines.append("Description: \(description)")
        } else if let tooltip, !tooltip.isEmpty {
            contextLines.append("Description: \(tooltip)")
        }
        contextLines.append("Apply this workflow's intent while pursuing the Codex goal. This is goal context, not a separate user turn.")
        let contextBlock = contextLines.joined(separator: "\n")

        let instructionSourceCandidates = [
            selectedWorkflow.wrapUserText(
                rawObjective,
                includeBuiltInSessionCleanupGuidance: includeBuiltInSessionCleanupGuidance
            ),
            description,
            tooltip,
            selectedWorkflow.displayName
        ]
        let instructionSource = instructionSourceCandidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? selectedWorkflow.displayName
        let instructionsPrefix = "\n\nWorkflow instructions:\n"
        let fixedCount = contextBlock.count + instructionsPrefix.count
        guard fixedCount < maxThreadGoalObjectiveCharacters else {
            return .failure("Goal objective is too long to include the selected workflow context. Shorten the objective or clear the selected workflow before using /goal.")
        }
        let budget = maxThreadGoalObjectiveCharacters - fixedCount
        let instructionExcerpt: String
        if instructionSource.count <= budget {
            instructionExcerpt = instructionSource
        } else {
            let prefixLength = max(0, budget - 1)
            let prefix = instructionSource.prefix(prefixLength)
            instructionExcerpt = "\(prefix)…"
        }
        return .success(GoalObjectiveComposition(
            objective: contextBlock + instructionsPrefix + instructionExcerpt
        ))
    }

    private static func formattedCharacterCount(_ value: Int) -> String {
        let raw = String(value)
        var output = ""
        for (offset, character) in raw.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 {
                output.append(",")
            }
            output.append(character)
        }
        return String(output.reversed())
    }

    package typealias CodexTurnFallbackDecision = AgentTabSession.CodexFallbackReason

    package enum NativeSendOutcome: Equatable {
        case sent
        case queuedFallback(queueID: UUID, reason: CodexTurnFallbackDecision)
        case stale(reason: String)
        case cancelled
        case failed(message: String)

        package var didSend: Bool {
            switch self {
            case .sent, .queuedFallback:
                true
            case .stale, .cancelled, .failed:
                false
            }
        }
    }

    private enum CodexTurnStartFailureDisposition {
        case provenNotSubmitted
        case deliveryUnknown
    }

    /// Only the controller's local preflight error proves `turn/start` never reached its transport.
    /// `requestFailed` is not definitive: the client uses it for both JSON-RPC error envelopes and
    /// locally synthesized timeouts, and neither proves that provider work did not start.
    private nonisolated static func codexTurnStartFailureDisposition(
        _ error: Error
    ) -> CodexTurnStartFailureDisposition {
        if error is CodexTurnStartPreflightError {
            return .provenNotSubmitted
        }
        return .deliveryUnknown
    }

    private func settleCodexUsageDispatchAfterStartFailure(
        _ ticket: CodexDispatchTicket?,
        error: Error,
        session: AgentTabSession
    ) {
        guard let ticket else { return }
        switch Self.codexTurnStartFailureDisposition(error) {
        case .provenNotSubmitted:
            session.withdrawCodexUsageDispatch(ticket)
        case .deliveryUnknown:
            logCodex("[AgentModeVM][CodexUsage] retaining dispatch ticket after delivery-unknown turn/start failure")
        }
    }

    package func isCodexCompactionInFlight(session: AgentTabSession) -> Bool {
        session.codexPendingTurnKind == .compact
            || session.codexAuthoritativeActiveTurn?.turnKind == .compact
            || session.codexAnonymousActiveTurn?.turnKind == .compact
    }

    private weak var viewModel: (any CodexAgentModeCoordinatorHost)?
    private var terminalCommitBarrier: AgentRunTerminalCommitBarrier?
    private var toolTrackingByTabID: [UUID: AgentToolTrackingController] = [:]
    #if DEBUG
        /// Ready-session tool-tracking requests per tab, counted before the tooling guards so tests
        /// can prove a discarded start never reached tracking.
        private var testReadySessionToolTrackingRequestsByTabID: [UUID: Int] = [:]
    #endif
    private let windowID: Int
    private let workspacePathProvider: (AgentTabSession) throws -> String?
    private let codexControllerFactory: CodexControllerFactory
    private let connectionPolicyInstaller: ConnectionPolicyInstaller
    private let shouldManageCodexTooling: Bool
    private let runCoordinator: AgentRunCoordinator
    /// The host the run coordinator registers policies on, so observers and policies share one server.
    private var mcpHost: any AgentMCPHosting {
        runCoordinator.mcpHost
    }

    private let activeToolQuery: ActiveToolQuery
    private let activeAgentRunWaitQuery: ActiveAgentRunWaitQuery
    private var activeAgentRunWaitDrain: ActiveAgentRunWaitDrain
    private let authRecovery: any CodexManagedAuthRecovering
    private var codexModelsSubscriptionTask: Task<Void, Never>?
    private let commandRunningStatusCoalesceDelayNanos: UInt64 = 75_000_000
    private let commandRunningLiveOutputCoalesceDelayNanos: UInt64 = 225_000_000
    private let assistantDeltaFlushDelayNanos: UInt64 = 75_000_000
    private let codexTerminalAssistantSettleDelayNanos: UInt64 = 1_750_000_000
    private let bashLivenessPollIntervalNanos: UInt64 = 350_000_000
    private let bashUnobservedProcessFinalizeGraceInterval: TimeInterval = 1.2
    private let bashSignalQuietPollGraceInterval: TimeInterval = 1.0
    private let codexLeaseRoutingTimeoutMs: Int
    private let codexIdleShutdownDelayNanos: UInt64
    private let codexStallWatchdogPollIntervalNanos: UInt64
    private let codexStallWatchdogProbeThreshold: TimeInterval
    private let codexStallWatchdogRecoveryThreshold: TimeInterval
    private let codexTransportClosedRecoveryGraceInterval: TimeInterval
    private static let maxMergedCommandRunningOutputCharacters: Int = 24000
    private let bashLivenessTasksByTabID = PerKeyTaskStore<UUID>()
    private var bashObservedAliveProcessIDsByTabID: [UUID: Set<String>] = [:]
    private var bashRunningProcessFirstSeenByTabID: [UUID: [String: Date]] = [:]
    private let codexIdleShutdownTasksByTabID = PerKeyTaskStore<UUID>()
    private let codexStallWatchdogTasksByTabID = PerKeyTaskStore<UUID>()
    private let codexTransportClosedFallbackTasksByTabID = PerKeyTaskStore<UUID>()
    private let codexRecoveryProbeTimeout: TimeInterval
    private var codexRecoveryAttemptedRunIDs: Set<UUID> = []
    private var codexAuthRecoveryAttemptedRunIDs: Set<UUID> = []
    private var pendingCodexThreadNameSyncByTabID: [UUID: PendingCodexThreadNameSync] = [:]
    private var codexThreadNameSyncTaskByTabID: [UUID: (generation: UUID, task: Task<Void, Never>)] = [:]
    private var observedCodexAssistantCompletionScopesByTabID: [UUID: Set<CodexNativeSessionController.ItemScope>] = [:]
    private var pendingCodexTerminalSettleByTabID: [UUID: PendingCodexTerminalSettle] = [:]

    private enum CodexRecoveryTrigger: Equatable {
        case unexpectedStreamEnd
        case stallWatchdog

        var reconnectSource: String {
            switch self {
            case .unexpectedStreamEnd:
                "unexpected-stream-end-recovery"
            case .stallWatchdog:
                "stall-watchdog-recovery"
            }
        }
    }

    private enum CodexRecoveryOutcome {
        case recovered
        case skipped
        case unrecoverable(String?)
    }

    private enum CodexNativeSessionFallbackReason {
        case missingRollout
    }

    private enum LiveBashRunningApplyResult {
        case noChange
        case liveStateOnly
        case materializedTranscript

        var didChange: Bool {
            switch self {
            case .noChange:
                false
            case .liveStateOnly, .materializedTranscript:
                true
            }
        }

        mutating func merge(_ other: LiveBashRunningApplyResult) {
            switch (self, other) {
            case (.materializedTranscript, _), (_, .materializedTranscript):
                self = .materializedTranscript
            case (.liveStateOnly, _), (_, .liveStateOnly):
                self = .liveStateOnly
            case (.noChange, .noChange):
                self = .noChange
            }
        }
    }

    private struct CodexNativeSessionStartResult {
        let sessionRef: CodexNativeSessionController.SessionRef?
        let fallbackReason: CodexNativeSessionFallbackReason?
    }

    private struct PendingCodexThreadNameSync {
        let tabID: UUID
        let name: String
        let explicitThreadID: String?
        let source: String
        let controller: any CodexSessionControlling
    }

    private struct PendingCodexTerminalSettle {
        let generation: UUID
        let expectedRunID: UUID?
        let turnID: String?
        let turnStatus: CodexNativeSessionController.TurnStatus
        let reason: String
        let errorMessage: String?
        let providerSuccessor: AgentRunTerminalCommitBarrier.ProviderSuccessor?
        let assistantScope: CodexNativeSessionController.ItemScope
        let assistantRowID: UUID?
        let task: Task<Void, Never>
    }

    private struct CodexAssistantSettleCandidate {
        let scope: CodexNativeSessionController.ItemScope
        let rowID: UUID?
        let reason: String
    }

    private struct RunningBashProcessScanEntry {
        let index: Int
        let processID: String
    }

    private struct RunningBashProcessScan {
        let entries: [RunningBashProcessScanEntry]
        let processIDs: Set<String>
    }

    private let preferenceDefaults: UserDefaults
    private let computerUseEnabled: @MainActor () -> Bool
    private let goalSupportEnabled: @MainActor () -> Bool
    private let reasoningSummariesEnabled: @MainActor () -> Bool
    private let showBuiltInWorkflowCleanupGuidance: @MainActor () -> Bool
    private let globalCodeMapsDisabled: @MainActor () -> Bool
    private let codexModelPollingService: @MainActor () -> CodexModelPollingService

    package init(
        windowID: Int,
        workspacePathProvider: @escaping (AgentTabSession) throws -> String?,
        codexControllerFactory: @escaping CodexControllerFactory,
        connectionPolicyInstaller: @escaping ConnectionPolicyInstaller,
        shouldManageCodexTooling: Bool,
        runCoordinator: AgentRunCoordinator,
        authRecovery: any CodexManagedAuthRecovering,
        computerUseEnabled: @escaping @MainActor () -> Bool,
        goalSupportEnabled: @escaping @MainActor () -> Bool,
        reasoningSummariesEnabled: @escaping @MainActor () -> Bool,
        showBuiltInWorkflowCleanupGuidance: @escaping @MainActor () -> Bool,
        globalCodeMapsDisabled: @escaping @MainActor () -> Bool,
        codexModelPollingService: @escaping @MainActor () -> CodexModelPollingService,
        activeToolQuery: @escaping ActiveToolQuery = { _ in false },
        activeAgentRunWaitQuery: @escaping ActiveAgentRunWaitQuery = { _ in false },
        activeAgentRunWaitDrain: @escaping ActiveAgentRunWaitDrain = { _, _ in .drained },
        leaseRoutingTimeoutMs: Int = 2000,
        idleShutdownDelayNanos: UInt64 = 300_000_000_000,
        stallWatchdogPollIntervalNanos: UInt64 = 5_000_000_000,
        stallWatchdogProbeThreshold: TimeInterval = 0,
        stallWatchdogRecoveryThreshold: TimeInterval = 0,
        transportClosedRecoveryGraceInterval: TimeInterval = 1.5,
        recoveryProbeTimeout: TimeInterval = 2.0,
        preferenceDefaults: UserDefaults = .standard,
        initialLastUsedReasoningEffort: CodexReasoningEffort? = nil,
        initialLastUsedReasoningEffortsByModelSlug: [String: CodexReasoningEffort] = [:]
    ) {
        self.windowID = windowID
        self.workspacePathProvider = workspacePathProvider
        self.codexControllerFactory = codexControllerFactory
        self.connectionPolicyInstaller = connectionPolicyInstaller
        self.shouldManageCodexTooling = shouldManageCodexTooling
        self.runCoordinator = runCoordinator
        self.authRecovery = authRecovery
        self.computerUseEnabled = computerUseEnabled
        self.goalSupportEnabled = goalSupportEnabled
        self.reasoningSummariesEnabled = reasoningSummariesEnabled
        self.showBuiltInWorkflowCleanupGuidance = showBuiltInWorkflowCleanupGuidance
        self.globalCodeMapsDisabled = globalCodeMapsDisabled
        self.codexModelPollingService = codexModelPollingService
        self.activeToolQuery = activeToolQuery
        self.activeAgentRunWaitQuery = activeAgentRunWaitQuery
        self.activeAgentRunWaitDrain = activeAgentRunWaitDrain
        codexLeaseRoutingTimeoutMs = max(500, leaseRoutingTimeoutMs)
        codexIdleShutdownDelayNanos = max(1_000_000, idleShutdownDelayNanos)
        codexStallWatchdogPollIntervalNanos = max(10_000_000, stallWatchdogPollIntervalNanos)
        let normalizedProbeThreshold = max(0, stallWatchdogProbeThreshold)
        let normalizedRecoveryThreshold = max(0, stallWatchdogRecoveryThreshold)
        if normalizedProbeThreshold == 0 || normalizedRecoveryThreshold == 0 {
            codexStallWatchdogProbeThreshold = 0
            codexStallWatchdogRecoveryThreshold = 0
        } else {
            codexStallWatchdogProbeThreshold = normalizedProbeThreshold
            codexStallWatchdogRecoveryThreshold = max(normalizedProbeThreshold, normalizedRecoveryThreshold)
        }
        codexTransportClosedRecoveryGraceInterval = max(0.1, transportClosedRecoveryGraceInterval)
        codexRecoveryProbeTimeout = max(0.1, recoveryProbeTimeout)
        self.preferenceDefaults = preferenceDefaults
        lastUsedReasoningEffort = initialLastUsedReasoningEffort
        lastUsedReasoningEffortByModelSlug = initialLastUsedReasoningEffortsByModelSlug.reduce(into: [:]) { result, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return }
            result[key] = entry.value
        }
    }

    package func attach(viewModel: any CodexAgentModeCoordinatorHost) {
        self.viewModel = viewModel
    }

    func installTerminalCommitBarrier(_ barrier: AgentRunTerminalCommitBarrier) {
        terminalCommitBarrier = barrier
    }

    package func setActiveAgentRunWaitDrain(_ drain: @escaping ActiveAgentRunWaitDrain) {
        activeAgentRunWaitDrain = drain
    }

    private func logCodex(_ message: @autoclosure () -> String) {
        CodexDebugLog.log(message())
    }

    private func logCodexTranscriptOrdering(
        _ label: String,
        session: AgentTabSession,
        extra: String = ""
    ) {
        let lastDescription = session.items.last.map(Self.codexTranscriptItemDebugSummary) ?? "none"
        let extraSuffix = extra.isEmpty ? "" : " \(extra)"
        logCodex(
            "[AgentModeVM][CodexOrder] \(label) tab=\(session.tabID) nextSeq=\(session.nextSequenceIndex) items=\(session.items.count) pendingAssistantChars=\(session.pendingAssistantDelta.count) last=\(lastDescription)\(extraSuffix)"
        )
    }

    private static func codexTranscriptItemDebugSummary(_ item: AgentChatItem) -> String {
        let name = item.toolName ?? item.kind.rawValue
        let invocation = item.toolInvocationID?.uuidString ?? "nil"
        return "seq=\(item.sequenceIndex):\(item.kind.rawValue):\(name):inv=\(invocation):stream=\(item.isStreaming)"
    }

    private func resetCodexWatchdogState(_ session: AgentTabSession) {
        session.codexWatchdogState = .init()
    }

    private func recordCodexWatchdogProgress(
        for session: AgentTabSession,
        at timestamp: Date = Date()
    ) {
        session.codexWatchdogState.lastProgressAt = timestamp
        session.codexWatchdogState.suppressUntil = nil
        session.codexWatchdogState.ambiguousActiveProbeCount = 0
        guard session.runState.isActive else {
            return
        }
        session.codexWatchdogState.isPausedAfterWarning = false
        session.codexWatchdogState.warnedSinceLastProgress = false
        session.codexWatchdogState.requiresColdTeardownOnCancel = false
    }

    private func codexWatchdogReferenceDate(for session: AgentTabSession) -> Date {
        session.codexWatchdogState.lastProgressAt
            ?? session.codexLastEventAt
            ?? session.lastUserMessageAt
            ?? session.lastActivityAt
    }

    private func shouldSuppressCodexWatchdog(
        for session: AgentTabSession,
        now: Date = Date()
    ) -> Bool {
        guard let suppressUntil = session.codexWatchdogState.suppressUntil else {
            return false
        }
        if now < suppressUntil {
            return true
        }
        session.codexWatchdogState.suppressUntil = nil
        return false
    }

    private func hasActiveRepoPromptTools(for session: AgentTabSession) -> Bool {
        guard let runID = session.runID else {
            return false
        }
        return activeToolQuery(runID)
    }

    private func hasActiveAgentRunWaits(for session: AgentTabSession) -> Bool {
        guard let runID = session.runID else {
            return false
        }
        return activeAgentRunWaitQuery(runID)
    }

    private func hasPendingCodexInteraction(for session: AgentTabSession) -> Bool {
        session.pendingApproval != nil
            || session.pendingPermissionsRequest != nil
            || session.pendingMCPElicitationRequest != nil
            || !session.queuedMCPElicitationRequests.isEmpty
            || session.pendingUserInputRequest != nil
            || !session.queuedUserInputRequests.isEmpty
            || session.runState == .waitingForApproval
    }

    @discardableResult
    private func clearCodexPendingInteractions(in session: AgentTabSession) -> Bool {
        let didClear = session.pendingApproval != nil
            || session.pendingPermissionsRequest != nil
            || session.pendingMCPElicitationRequest != nil
            || !session.queuedMCPElicitationRequests.isEmpty
            || session.pendingUserInputRequest != nil
            || !session.queuedUserInputRequests.isEmpty
        session.pendingApproval = nil
        session.pendingPermissionsRequest = nil
        session.pendingMCPElicitationRequest = nil
        session.queuedMCPElicitationRequests.removeAll()
        session.pendingUserInputRequest = nil
        session.queuedUserInputRequests.removeAll()
        return didClear
    }

    private func pendingCodexInteractionMatches(turnID: String, session: AgentTabSession) -> Bool {
        session.pendingApproval?.turnID == turnID
            || session.pendingPermissionsRequest?.turnID == turnID
            || session.pendingMCPElicitationRequest?.turnID == turnID
            || session.queuedMCPElicitationRequests.contains { $0.turnID == turnID }
            || session.pendingUserInputRequest?.turnID == turnID
            || session.queuedUserInputRequests.contains { $0.turnID == turnID }
    }

    private func clearStaleCodexPendingInteractionsForNewTurn(
        _ turnID: String?,
        session: AgentTabSession
    ) {
        guard let turnID,
              hasPendingCodexInteraction(for: session),
              !pendingCodexInteractionMatches(turnID: turnID, session: session)
        else {
            return
        }
        guard clearCodexPendingInteractions(in: session) else { return }
        viewModel?.reconcileInteractiveRunState(session)
        viewModel?.publishMCPStateChange(for: session)
        handleRunInteractionStateChange(for: session, reason: .pendingQuestionCancelled)
        logCodex("[AgentModeVM][CodexUI] cleared stale pending Codex interactions for tab \(session.tabID) before new turn \(turnID)")
    }

    private static func isCodexWaitingOnUserInputFlag(_ flag: String) -> Bool {
        let normalized = normalizedCodexActiveFlag(flag)
        return normalized.contains("waiting")
            && normalized.contains("user")
            && normalized.contains("input")
    }

    private static func isCodexWaitingOnApprovalFlag(_ flag: String) -> Bool {
        let normalized = normalizedCodexActiveFlag(flag)
        return normalized.contains("waiting")
            && normalized.contains("approval")
    }

    private static func normalizedCodexActiveFlag(_ flag: String) -> String {
        flag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
    }

    private func reconcileCodexReportedWaitingFlags(
        _ activeFlags: [String],
        session: AgentTabSession
    ) {
        guard session.runState.isActive else { return }
        if activeFlags.contains(where: Self.isCodexWaitingOnUserInputFlag),
           session.pendingUserInputRequest == nil,
           session.queuedUserInputRequests.isEmpty
        {
            setRunningStatus("Codex reports it is waiting for user input…", source: .transport, session: session, urgent: true)
            return
        }
        if activeFlags.contains(where: Self.isCodexWaitingOnApprovalFlag),
           session.pendingApproval == nil,
           session.pendingPermissionsRequest == nil,
           session.pendingMCPElicitationRequest == nil,
           session.queuedMCPElicitationRequests.isEmpty,
           session.runState != .waitingForApproval
        {
            setRunningStatus("Codex reports it is waiting for approval…", source: .transport, session: session, urgent: true)
        }
    }

    private func isRepoPromptTrackerToolName(_ toolName: String) -> Bool {
        if AgentToolTrackingSupport.isRepoPromptTool(toolName) {
            return true
        }
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let server = MCPIntegrationHelper.repoPromptMCPServerName.lowercased()
        return normalized.hasPrefix("mcp__\(server)__")
            || normalized.hasPrefix("mcp_\(server)__")
            || normalized.hasPrefix("\(server)__")
            || normalized.hasPrefix("\(server)_")
    }

    private static func canonicalNativeToolFallbackSignature(
        toolName: String,
        argsJSON: String?
    ) -> String {
        let normalizedToolName = normalizedExternalToolName(toolName) ?? toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let canonicalArgs: String = {
            guard let trimmedArgs = argsJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmedArgs.isEmpty
            else {
                return ""
            }
            guard let data = trimmedArgs.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let pretty = JSONDictionaryHelpers.prettyJSONString(from: object, sortedKeys: true)
            else {
                return trimmedArgs
            }
            return pretty.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        return normalizedToolName + "\n" + canonicalArgs
    }

    private static func matchingNativeToolLivenessKey(
        in state: NativeToolLivenessState,
        toolName: String,
        invocationID: UUID?,
        argsJSON: String?
    ) -> NativeToolLivenessState.Key? {
        if let invocationID,
           let exact = state.inFlight.first(where: { $0.key.invocationID == invocationID })?.key
        {
            return exact
        }
        let fallbackSignature = canonicalNativeToolFallbackSignature(toolName: toolName, argsJSON: argsJSON)
        let candidate = state.inFlight
            .filter { $0.key.fallbackSignature == fallbackSignature }
            .max { lhs, rhs in lhs.value.lastSignalAt < rhs.value.lastSignalAt }
        return candidate?.key
    }

    private static func matchingNativeToolLivenessKeyForRunningSignal(
        in state: NativeToolLivenessState,
        invocationID: UUID?,
        processID: String?
    ) -> NativeToolLivenessState.Key? {
        if let invocationID,
           let exact = state.inFlight.first(where: { $0.key.invocationID == invocationID })?.key
        {
            return exact
        }
        if let processID,
           let exact = state.inFlight.first(where: { $0.value.processID == processID })?.key
        {
            return exact
        }
        let bashCandidates = state.inFlight.filter {
            normalizedExternalToolName($0.value.toolName) == "bash"
        }
        guard !bashCandidates.isEmpty else {
            return nil
        }
        if bashCandidates.count == 1 {
            return bashCandidates.first?.key
        }
        let candidate = bashCandidates.max { lhs, rhs in
            lhs.value.lastSignalAt < rhs.value.lastSignalAt
        }
        return candidate?.key
    }

    private func clearCodexNativeToolLiveness(_ session: AgentTabSession) {
        session.codexNativeToolLiveness = .init()
    }

    private func noteCodexNativeToolCall(
        toolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        session: AgentTabSession,
        at timestamp: Date
    ) {
        guard !AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return }
        let key = Self.matchingNativeToolLivenessKey(
            in: session.codexNativeToolLiveness,
            toolName: toolName,
            invocationID: invocationID,
            argsJSON: argsJSON
        ) ?? NativeToolLivenessState.Key(
            invocationID: invocationID,
            fallbackSignature: Self.canonicalNativeToolFallbackSignature(toolName: toolName, argsJSON: argsJSON)
        )
        let existing = session.codexNativeToolLiveness.inFlight[key]
        session.codexNativeToolLiveness.inFlight[key] = .init(
            toolName: toolName,
            startedAt: existing?.startedAt ?? timestamp,
            lastSignalAt: timestamp,
            processID: existing?.processID,
            sawRunningUpdate: existing?.sawRunningUpdate ?? false
        )
    }

    private func noteCodexNativeToolRunningSignal(
        invocationID: UUID?,
        processID: String?,
        session: AgentTabSession,
        at timestamp: Date
    ) {
        let key = Self.matchingNativeToolLivenessKeyForRunningSignal(
            in: session.codexNativeToolLiveness,
            invocationID: invocationID,
            processID: processID
        ) ?? {
            guard invocationID != nil else { return nil }
            return NativeToolLivenessState.Key(
                invocationID: invocationID,
                fallbackSignature: "bash\ninvocation:\(invocationID?.uuidString ?? "nil")"
            )
        }()
        guard let key else { return }
        let existing = session.codexNativeToolLiveness.inFlight[key]
        let normalizedProcessID = processID?.trimmingCharacters(in: .whitespacesAndNewlines)
        session.codexNativeToolLiveness.inFlight[key] = .init(
            toolName: existing?.toolName ?? "bash",
            startedAt: existing?.startedAt ?? timestamp,
            lastSignalAt: timestamp,
            processID: (normalizedProcessID?.isEmpty == false ? normalizedProcessID : nil) ?? existing?.processID,
            sawRunningUpdate: true
        )
    }

    private func completeCodexNativeTool(
        toolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        session: AgentTabSession
    ) {
        guard !AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return }
        guard let key = Self.matchingNativeToolLivenessKey(
            in: session.codexNativeToolLiveness,
            toolName: toolName,
            invocationID: invocationID,
            argsJSON: argsJSON
        ) else {
            return
        }
        session.codexNativeToolLiveness.inFlight.removeValue(forKey: key)
    }

    private func hasObservedAliveBashProcess(for session: AgentTabSession) -> Bool {
        for execution in session.bashLiveExecutionByKey.values {
            guard execution.isRunning,
                  let processID = execution.processID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !processID.isEmpty,
                  Self.isCandidatePOSIXProcessID(processID)
            else {
                continue
            }
            if Self.processIsAlive(processID) {
                return true
            }
        }
        let observedAliveProcessIDs = bashObservedAliveProcessIDsByTabID[session.tabID] ?? []
        guard !observedAliveProcessIDs.isEmpty else {
            return false
        }
        for execution in session.codexNativeToolLiveness.inFlight.values {
            guard Self.normalizedExternalToolName(execution.toolName) == "bash",
                  let processID = execution.processID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !processID.isEmpty,
                  Self.isCandidatePOSIXProcessID(processID),
                  observedAliveProcessIDs.contains(processID)
            else {
                continue
            }
            if Self.processIsAlive(processID) {
                return true
            }
        }
        return false
    }

    private func hardLocalToolLivenessReasons(for session: AgentTabSession) -> [String] {
        var reasons: [String] = []
        if hasActiveRepoPromptTools(for: session) {
            reasons.append("repoprompt-mcp")
        }
        if hasActiveAgentRunWaits(for: session) {
            reasons.append("agent-run-wait")
        }
        if hasObservedAliveBashProcess(for: session) {
            reasons.append("bash-pid")
        }
        return reasons
    }

    private func hasSoftLocalToolLiveness(for session: AgentTabSession) -> Bool {
        !session.codexNativeToolLiveness.inFlight.isEmpty
    }

    private func hasRecentSoftLocalToolSignal(
        for session: AgentTabSession,
        now: Date = Date()
    ) -> Bool {
        guard codexStallWatchdogProbeThreshold > 0 else {
            return false
        }
        let cutoff = now.addingTimeInterval(-codexStallWatchdogProbeThreshold)
        return session.codexNativeToolLiveness.inFlight.values.contains { $0.lastSignalAt >= cutoff }
    }

    private static func isToolRelatedActiveFlag(_ flag: String) -> Bool {
        let normalized = flag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.contains("tool")
            || normalized.contains("command")
            || normalized.contains("bash")
            || normalized.contains("exec")
            || normalized.contains("mcp")
            || normalized.contains("shell")
    }

    private func probeCorroboratesSoftLocalToolLiveness(
        _ snapshot: CodexNativeSessionController.ThreadSnapshot,
        session: AgentTabSession,
        now: Date = Date()
    ) -> Bool {
        guard hasSoftLocalToolLiveness(for: session), snapshot.hasActiveTurn else {
            return false
        }
        if snapshot.activeFlags.contains(where: Self.isToolRelatedActiveFlag) {
            return true
        }
        return hasRecentSoftLocalToolSignal(for: session, now: now)
    }

    private func deferCodexWatchdogUntilNextProbeWindow(
        for session: AgentTabSession,
        reason: String,
        now: Date = Date()
    ) -> Bool {
        guard codexStallWatchdogProbeThreshold > 0 else {
            return false
        }
        let nextProbeDate = now.addingTimeInterval(codexStallWatchdogProbeThreshold)
        if let existingSuppressUntil = session.codexWatchdogState.suppressUntil,
           existingSuppressUntil > nextProbeDate
        {
            logCodex(
                "[AgentModeVM][CodexWatchdog] preserving watchdog suppression for tab \(session.tabID) reason=\(reason) until=\(existingSuppressUntil.timeIntervalSince1970)"
            )
            return true
        }
        session.codexWatchdogState.suppressUntil = nextProbeDate
        logCodex(
            "[AgentModeVM][CodexWatchdog] deferring watchdog until next probe window for tab \(session.tabID) reason=\(reason) until=\(nextProbeDate.timeIntervalSince1970)"
        )
        return true
    }

    private func deferCodexWatchdogAfterAmbiguousActiveProbe(
        for session: AgentTabSession,
        activeFlags: [String],
        referenceDate: Date,
        now: Date = Date()
    ) -> Bool {
        let recoveryDeadline = referenceDate.addingTimeInterval(codexStallWatchdogRecoveryThreshold)
        guard recoveryDeadline > now else {
            return false
        }
        session.codexWatchdogState.ambiguousActiveProbeCount += 1
        session.codexWatchdogState.suppressUntil = recoveryDeadline
        logCodex(
            "[AgentModeVM][CodexWatchdog] deferring watchdog recovery for tab \(session.tabID) activeFlags=\(activeFlags.joined(separator: ",")) count=\(session.codexWatchdogState.ambiguousActiveProbeCount) until=\(recoveryDeadline.timeIntervalSince1970)"
        )
        return true
    }

    package func stop() {
        stopCodexModelsSubscription()
        stopAllBashLivenessTasks()
        stopAllCodexIdleShutdownTasks()
        stopAllCodexStallWatchdogTasks()
        stopAllCodexTransportClosedFallbackTasks()
        stopAllCodexThreadNameSyncTasks()
        codexRecoveryAttemptedRunIDs.removeAll()
    }

    package func updateCodexModelPolling() {
        guard let viewModel else { return }
        if viewModel.selectedAgent == .codexExec {
            startCodexModelsSubscriptionIfNeeded()
        } else {
            stopCodexModelsSubscription()
        }
    }

    private func startCodexModelsSubscriptionIfNeeded() {
        guard codexModelsSubscriptionTask == nil else { return }
        codexModelsSubscriptionTask = Task { [weak self] in
            guard let self else { return }
            let stream = await codexModelPollingService().subscribe()
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, let viewModel else { return }
                    // Update UI state — registry updates are owned by the polling service
                    viewModel.updateCodexDynamicModels(snapshot.models)
                    if let session = viewModel.activeSession, session.selectedAgent == .codexExec {
                        normalizeCodexSelectionForSession(session, preservingExplicitEffort: true)
                    }
                }
            }
        }
    }

    static func shouldPreserveWithdrawnExplicitSelection(
        rawModel: String,
        refreshedModels: [CodexAppServerClient.RemoteModel]
    ) -> Bool {
        let normalized = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else { return false }
        return matchingLiveModel(
            rawModel: normalized,
            refreshedModels: refreshedModels,
            capabilities: .shared
        ) == nil
    }

    private static func matchingLiveModel(
        rawModel: String,
        refreshedModels: [CodexAppServerClient.RemoteModel],
        capabilities: CodexModelCapabilitySnapshot
    ) -> CodexAppServerClient.RemoteModel? {
        var identityCapabilities = Array(capabilities.capabilitiesByBase.values)
        identityCapabilities.append(contentsOf: refreshedModels.map {
            CodexModelCapabilitySnapshot.Capability(
                base: $0.id,
                efforts: Set(CodexReasoningEffort.allCases),
                speedTiers: [CodexServiceTierVariantCatalog.fastServiceTier]
            )
        })
        let identitySnapshot = CodexModelCapabilitySnapshot(capabilities: identityCapabilities)
        guard let selectedBase = CodexModelSpecifier(
            raw: rawModel,
            capabilities: identitySnapshot
        ).baseModel else { return nil }
        return refreshedModels.first {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(selectedBase) == .orderedSame
        }
    }

    private func stopCodexModelsSubscription() {
        codexModelsSubscriptionTask?.cancel()
        codexModelsSubscriptionTask = nil
    }

    package func modelOptions(
        for agentKind: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]? = nil,
        includeClaudeEffortVariants: Bool = true
    ) -> [AgentModelOption] {
        let options = AgentModelCatalog.options(
            for: agentKind,
            availability: availability,
            codexDynamicModels: codexDynamicModels,
            includeClaudeEffortVariants: includeClaudeEffortVariants
        )
        guard agentKind == .codexExec else { return options }
        return Self.collapseCodexModelOptions(options)
    }

    package func selectedModelDisplayName(
        rawModel: String,
        agentKind: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]? = nil
    ) -> String {
        if agentKind == .codexExec,
           let option = modelOptions(
               for: .codexExec,
               availability: availability,
               codexDynamicModels: codexDynamicModels
           ).first(where: {
               $0.rawValue.caseInsensitiveCompare(rawModel) == .orderedSame
           })
        {
            return option.displayName
        }
        return AgentModelCatalog.displayName(
            for: rawModel,
            agentKind: agentKind,
            availability: availability,
            codexDynamicModels: codexDynamicModels
        )
    }

    /// Tracks the last reasoning effort the user explicitly selected, so older
    /// persisted/global fallback paths still behave sensibly.
    private(set) var lastUsedReasoningEffort: CodexReasoningEffort?
    private(set) var lastUsedReasoningEffortByModelSlug: [String: CodexReasoningEffort] = [:]

    func recordLastUsedReasoningEffort(_ effort: CodexReasoningEffort?) {
        guard let effort else { return }
        lastUsedReasoningEffort = effort
    }

    package func recordLastUsedReasoningEffort(
        _ effort: CodexReasoningEffort?,
        forModelRaw modelRaw: String?
    ) {
        let slug = CodexAgentToolPreferences.reasoningEffortPreferenceSlug(forModelRaw: modelRaw)
        guard let effort else {
            lastUsedReasoningEffortByModelSlug.removeValue(forKey: slug)
            return
        }
        lastUsedReasoningEffort = effort
        lastUsedReasoningEffortByModelSlug[slug] = effort
    }

    package func selectedReasoningEffortDisplayName(raw: String?) -> String {
        guard let effort = CodexReasoningEffort.parse(raw) else {
            return CodexReasoningEffort.medium.displayName
        }
        return effort.displayName
    }

    package func reasoningEffortOptions(forModelRaw rawModel: String, agentKind: AgentProviderKind) -> [CodexReasoningEffort] {
        guard agentKind == .codexExec else { return [] }
        let options = modelOptions(for: .codexExec)
        let normalizedRaw = Self.normalizedCodexSelectionModelRaw(from: rawModel)
        let exactOption = options.first {
            $0.rawValue.caseInsensitiveCompare(normalizedRaw) == .orderedSame
        }
        let option = if normalizedRaw.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame {
            exactOption ?? defaultCodexModelOption(from: options)
        } else {
            exactOption
        }
        guard let option else {
            return []
        }
        return option.supportedReasoningEfforts
    }

    func defaultReasoningEffort(forModelRaw rawModel: String, agentKind: AgentProviderKind) -> CodexReasoningEffort? {
        guard agentKind == .codexExec else { return nil }
        let options = modelOptions(for: .codexExec)
        let normalizedRaw = Self.normalizedCodexSelectionModelRaw(from: rawModel)
        let exactOption = options.first {
            $0.rawValue.caseInsensitiveCompare(normalizedRaw) == .orderedSame
        }
        let option = if normalizedRaw.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame {
            exactOption ?? defaultCodexModelOption(from: options)
        } else {
            exactOption
        }
        guard let option else {
            return nil
        }
        if let explicit = option.defaultReasoningEffort {
            return explicit
        }
        return option.supportedReasoningEfforts.first
    }

    private func defaultCodexModelOption(
        from options: [AgentModelOption]
    ) -> AgentModelOption? {
        options.first(where: {
            $0.rawValue.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame &&
                $0.isProviderDefault
        }) ?? options.first(where: {
            $0.rawValue.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        })
    }

    private func lastUsedReasoningEffort(
        forModelRaw modelRaw: String?,
        validOptions: [CodexReasoningEffort],
        includeGlobalFallback: Bool
    ) -> CodexReasoningEffort? {
        let slug = CodexAgentToolPreferences.reasoningEffortPreferenceSlug(forModelRaw: modelRaw)
        var candidates: [CodexReasoningEffort?] = [
            lastUsedReasoningEffortByModelSlug[slug],
            CodexAgentToolPreferences.lastUsedReasoningEffortsByModelSlug(defaults: preferenceDefaults)[slug]
        ]
        if includeGlobalFallback {
            candidates.append(lastUsedReasoningEffort)
            candidates.append(CodexAgentToolPreferences.lastUsedReasoningEffort(defaults: preferenceDefaults))
        }
        return candidates.lazy.compactMap(\.self).first { validOptions.contains($0) }
    }

    private static func collapseCodexModelOptions(
        _ options: [AgentModelOption],
        capabilities: CodexModelCapabilitySnapshot = .shared
    ) -> [AgentModelOption] {
        struct Collapsed {
            var rawValue: String
            var displayName: String
            var description: String?
            var isPlaceholderDefault: Bool
            var isProviderDefault: Bool
            var supported: Set<CodexReasoningEffort>
            var defaultEffort: CodexReasoningEffort?
        }

        var byRaw: [String: Collapsed] = [:]
        var order: [String] = []

        for option in options {
            let specifier = CodexModelSpecifier(raw: option.rawValue, capabilities: capabilities)
            let normalizedRaw = option.isPlaceholderDefault
                ? AgentModel.defaultModel.rawValue
                : CodexServiceTierVariantCatalog.serviceTierAwareBaseID(
                    for: option.rawValue,
                    capabilities: capabilities
                )
            let key = normalizedRaw.lowercased()
            if byRaw[key] == nil {
                let isDefaultPlaceholder =
                    normalizedRaw.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame
                order.append(key)
                byRaw[key] = Collapsed(
                    rawValue: normalizedRaw,
                    displayName: isDefaultPlaceholder
                        ? AgentModel.defaultModel.displayName
                        : Self.codexDisplayName(forBaseModel: normalizedRaw),
                    description: option.description,
                    isPlaceholderDefault: option.isPlaceholderDefault,
                    isProviderDefault: option.isProviderDefault,
                    supported: [],
                    defaultEffort: option.defaultReasoningEffort
                )
            }
            if option.isPlaceholderDefault {
                byRaw[key]?.isPlaceholderDefault = true
            }
            if option.isProviderDefault {
                byRaw[key]?.isProviderDefault = true
            }
            if byRaw[key]?.description?.isEmpty ?? true {
                byRaw[key]?.description = option.description
            }
            if let explicitDefault = option.defaultReasoningEffort {
                byRaw[key]?.defaultEffort = explicitDefault
            }
            if let parsedEffort = specifier.reasoningEffort {
                byRaw[key]?.supported.insert(parsedEffort)
                if option.isProviderDefault {
                    byRaw[key]?.defaultEffort = parsedEffort
                }
            }
            for supported in option.supportedReasoningEfforts {
                byRaw[key]?.supported.insert(supported)
            }
        }

        var collapsed: [AgentModelOption] = []
        for key in order {
            guard let record = byRaw[key] else { continue }
            let orderedEfforts = CodexReasoningEffort.displayOrder.filter { record.supported.contains($0) }
            collapsed.append(
                AgentModelOption(
                    rawValue: record.rawValue,
                    displayName: record.displayName,
                    description: record.description,
                    isPlaceholderDefault: record.isPlaceholderDefault,
                    isProviderDefault: record.isProviderDefault,
                    supportedReasoningEfforts: orderedEfforts,
                    defaultReasoningEffort: record.defaultEffort
                )
            )
        }
        // `collapsed` should already be deduplicated by raw value, but use a
        // duplicate-tolerant init (keep-first) so we never trap on a stray
        // collision — insertion order is the meaningful signal here.
        let insertionOrderByRaw = Dictionary(
            collapsed.enumerated().map { index, option in
                (option.rawValue.lowercased(), index)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        return collapsed.sorted { lhs, rhs in
            if lhs.isPlaceholderDefault != rhs.isPlaceholderDefault {
                return lhs.isPlaceholderDefault && !rhs.isPlaceholderDefault
            }

            if AIModel.codexBaseModelPrecedes(lhs.rawValue, rhs.rawValue) { return true }
            if AIModel.codexBaseModelPrecedes(rhs.rawValue, lhs.rawValue) { return false }

            let leftInsertionOrder = insertionOrderByRaw[lhs.rawValue.lowercased()] ?? Int.max
            let rightInsertionOrder = insertionOrderByRaw[rhs.rawValue.lowercased()] ?? Int.max
            if leftInsertionOrder != rightInsertionOrder {
                return leftInsertionOrder < rightInsertionOrder
            }

            return ModelPickerStringOrdering.precedes(lhs.displayName, rhs.displayName)
        }
    }

    private static func codexDisplayName(forBaseModel rawModel: String) -> String {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawModel }
        let normalized = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let tokens = normalized.split(separator: " ").map { token -> String in
            let value = String(token)
            let lower = value.lowercased()
            switch lower {
            case "gpt": return "GPT"
            case "codex": return "Codex"
            case "openai": return "OpenAI"
            case "max": return "Max"
            default:
                if lower.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil {
                    return value
                }
                return lower.capitalized
            }
        }
        var output = tokens.joined(separator: " ")
        output = output.replacingOccurrences(
            of: "(?i)\\bGPT ([0-9]+(?:\\.[0-9]+)*)\\b",
            with: "GPT-$1",
            options: .regularExpression
        )
        return output
    }

    private struct ResolvedCodexSelection {
        let storedModelRaw: String
        let modelParam: String?
        let reasoningEffort: CodexReasoningEffort?
        let serviceTier: String?
    }

    private func resolveCodexSelection(
        rawModel: String,
        selectedEffortRaw: String?,
        preservingExplicitEffort: Bool
    ) -> ResolvedCodexSelection {
        let capabilities = CodexModelCapabilitySnapshot.shared
        let parsed = CodexModelSpecifier(raw: rawModel, capabilities: capabilities)
        let normalizedModel = Self.normalizedCodexSelectionModelRaw(
            from: rawModel,
            capabilities: capabilities
        )
        let normalizedSpecifier = CodexModelSpecifier(
            raw: normalizedModel,
            capabilities: capabilities
        )
        let liveModels = viewModel?.codexDynamicModels ?? []
        let matchingLiveModel = Self.matchingLiveModel(
            rawModel: rawModel,
            refreshedModels: liveModels,
            capabilities: capabilities
        )
        let isPlaceholderDefault =
            normalizedModel.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame
        let isWithdrawn = !liveModels.isEmpty && !isPlaceholderDefault && matchingLiveModel == nil
        let explicitEffort = preservingExplicitEffort
            ? CodexReasoningEffort.parse(selectedEffortRaw)
            : nil

        let options: [CodexReasoningEffort]
        let defaultEffort: CodexReasoningEffort?
        let preservesEffortWhenOptionsAreEmpty: Bool
        if let matchingLiveModel {
            if matchingLiveModel.hasSupportedReasoningEffortsEvidence {
                var liveEfforts = Set(matchingLiveModel.supportedReasoningEfforts.compactMap {
                    CodexReasoningEffort.parse($0.reasoningEffort)
                })
                defaultEffort = CodexReasoningEffort.parse(
                    matchingLiveModel.defaultReasoningEffort
                )
                if let defaultEffort {
                    liveEfforts.insert(defaultEffort)
                }
                options = CodexReasoningEffort.displayOrder.filter(liveEfforts.contains)
                preservesEffortWhenOptionsAreEmpty = false
            } else {
                options = []
                defaultEffort = nil
                preservesEffortWhenOptionsAreEmpty = true
            }
        } else if isWithdrawn {
            options = []
            defaultEffort = nil
            preservesEffortWhenOptionsAreEmpty = true
        } else {
            options = reasoningEffortOptions(
                forModelRaw: normalizedModel,
                agentKind: .codexExec
            )
            defaultEffort = defaultReasoningEffort(
                forModelRaw: normalizedModel,
                agentKind: .codexExec
            )
            preservesEffortWhenOptionsAreEmpty = !isPlaceholderDefault
        }

        let lastUsed = lastUsedReasoningEffort(
            forModelRaw: normalizedModel,
            validOptions: options,
            includeGlobalFallback: preservingExplicitEffort
        )
        let chosenEffort: CodexReasoningEffort? = {
            guard !options.isEmpty else {
                guard preservesEffortWhenOptionsAreEmpty else { return nil }
                return explicitEffort ?? parsed.reasoningEffort
            }
            if let explicitEffort, options.contains(explicitEffort) {
                return explicitEffort
            }
            if let parsedEffort = parsed.reasoningEffort, options.contains(parsedEffort) {
                return parsedEffort
            }
            if let lastUsed, options.contains(lastUsed) {
                return lastUsed
            }
            if let defaultEffort, options.contains(defaultEffort) {
                return defaultEffort
            }
            if options.contains(.medium) {
                return .medium
            }
            return options.first
        }()

        return ResolvedCodexSelection(
            storedModelRaw: isWithdrawn ? rawModel : normalizedModel,
            modelParam: normalizedSpecifier.appServerModelParam,
            reasoningEffort: chosenEffort,
            serviceTier: normalizedSpecifier.appServerServiceTierParam
        )
    }

    package func normalizeCodexSelectionForSession(
        _ session: AgentTabSession,
        preservingExplicitEffort: Bool
    ) {
        guard session.selectedAgent == .codexExec else {
            session.selectedReasoningEffortRaw = nil
            if session.tabID == viewModel?.currentTabID {
                viewModel?.applyCodexSelectionToBindings(
                    modelRaw: session.selectedModelRaw,
                    reasoningEffortRaw: nil
                )
            }
            return
        }

        let resolution = resolveCodexSelection(
            rawModel: session.selectedModelRaw,
            selectedEffortRaw: session.selectedReasoningEffortRaw,
            preservingExplicitEffort: preservingExplicitEffort
        )
        session.selectedModelRaw = resolution.storedModelRaw
        session.selectedReasoningEffortRaw = resolution.reasoningEffort?.rawValue

        if session.tabID == viewModel?.currentTabID {
            viewModel?.applyCodexSelectionToBindings(
                modelRaw: resolution.storedModelRaw,
                reasoningEffortRaw: resolution.reasoningEffort?.rawValue
            )
        }
    }

    package func restoreCodexSelection(
        from agentSession: AgentSession,
        session: AgentTabSession
    ) {
        guard session.selectedAgent == .codexExec else { return }
        guard let modelRaw = agentSession.agentModel,
              !modelRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }
        let parsed = CodexModelSpecifier(raw: modelRaw)
        let normalizedModel = Self.normalizedCodexSelectionModelRaw(from: modelRaw)
        session.selectedModelRaw = normalizedModel
        session.selectedReasoningEffortRaw =
            CodexReasoningEffort.parse(agentSession.agentReasoningEffort)?.rawValue
                ?? parsed.reasoningEffort?.rawValue
    }

    package func restoreCodexMetadata(
        from agentSession: AgentSession,
        session: AgentTabSession
    ) {
        session.codexConversationID = agentSession.codexConversationID
        session.codexRolloutPath = agentSession.codexRolloutPath
        session.codexModel = agentSession.codexModel
        session.codexReasoningEffort = agentSession.codexReasoningEffort
        session.codexContextUsage = AgentContextUsage(
            modelContextWindow: agentSession.codexContextWindow,
            lastTotalTokens: agentSession.codexLastTotalTokens,
            totalTotalTokens: agentSession.codexTotalTotalTokens
        )
        viewModel?.refreshCodexContextUsageSnapshot(for: session)
        if session.selectedAgent == .codexExec {
            session.codexNeedsReconnect = agentSession.codexConversationID != nil || agentSession.codexRolloutPath != nil
            reconcilePersistedCodexCommandStatusIfNeeded(session: session)
        }
    }

    package func applyCodexPersistence(
        from session: AgentTabSession,
        to agentSession: inout AgentSession
    ) {
        agentSession.codexConversationID = session.codexConversationID
        agentSession.codexRolloutPath = session.codexRolloutPath
        agentSession.codexModel = session.codexModel
        agentSession.codexReasoningEffort = session.codexReasoningEffort
        agentSession.codexContextWindow = session.codexContextUsage?.modelContextWindow
        agentSession.codexLastTotalTokens = session.codexContextUsage?.lastTotalTokens
        agentSession.codexTotalTotalTokens = session.codexContextUsage?.totalTotalTokens
    }

    package func nativeSlashCommand(named name: String, session: AgentTabSession) -> NativeSlashCommand? {
        guard session.selectedAgent == .codexExec else { return nil }
        return NativeSlashCommand(rawValue: name.lowercased())
    }

    func nativeSlashCommandAvailabilityMessage(
        _ command: NativeSlashCommand,
        session: AgentTabSession
    ) -> String? {
        nativeSlashCommandAvailabilityMessage(command, argumentsText: "", session: session)
    }

    package func nativeSlashCommandAvailabilityMessage(
        _ command: NativeSlashCommand,
        argumentsText: String,
        session: AgentTabSession,
        effectiveRunState: AgentSessionRunState? = nil
    ) -> String? {
        let runState = effectiveRunState ?? session.runState
        guard session.selectedAgent == .codexExec else {
            return "Native Codex slash commands are only available in Codex agent sessions."
        }
        if session.profile == .knowledge, command != .compact {
            return "Only /compact is available in a Knowledge session. Open a standard Agent Mode session for /\(command.rawValue)."
        }
        switch command {
        case .compact:
            guard !runState.isActive else {
                return "Wait for the current Codex turn to finish before using /compact."
            }
            guard hasKnownCodexThread(session) else {
                return "Start a Codex conversation before using /compact."
            }
            return nil
        case .computerUse:
            if session.permissionProfile == .mcpSafeDefaults {
                return CodexComputerUseWorkflow.safeManagedDisabledMessage
            }
            guard computerUseEnabled() else {
                return CodexComputerUseWorkflow.disabledMessage
            }
            guard !runState.isActive || runState == .waitingForUser else {
                return "Wait for the current Codex turn to finish before starting a /computer-use workflow."
            }
            return nil
        case .goal:
            guard goalSupportEnabled() else {
                return CodexGoalSupport.disabledMessage
            }
            if runState.isActive,
               session.codexController != nil,
               session.codexControllerFeatureState?.goalSupportEnabled == false
            {
                return "Codex goal support will be available after the current Codex turn finishes and reconnects."
            }
            switch Self.goalSlashAction(from: argumentsText) {
            case .setObjective:
                return nil
            case .show:
                return hasKnownCodexThread(session) ? nil : "Start a Codex conversation before using /goal."
            case .clear:
                return hasKnownCodexThread(session) ? nil : "Start a Codex conversation before clearing a goal."
            case .pause:
                return hasKnownCodexThread(session) ? nil : "Start a Codex conversation before pausing a goal."
            case .resume:
                return hasKnownCodexThread(session) ? nil : "Start a Codex conversation before resuming a goal."
            }
        }
    }

    package func executeNativeSlashCommand(
        _ command: NativeSlashCommand,
        argumentsText: String,
        session: AgentTabSession,
        selectedWorkflowForGoal: AgentWorkflowDefinition? = nil,
        semanticRunStateForControlCommand: AgentSessionRunState? = nil
    ) async -> NativeSlashCommandExecutionResult {
        switch command {
        case .compact:
            await executeCompactSlashCommand(session: session)
        case .goal:
            await executeGoalSlashCommand(
                argumentsText: argumentsText,
                session: session,
                selectedWorkflow: selectedWorkflowForGoal,
                semanticRunState: semanticRunStateForControlCommand
            )
        case .computerUse:
            .failed("/computer-use starts a guided Codex turn and cannot be executed as a control-plane command.")
        }
    }

    private func executeCompactSlashCommand(
        session: AgentTabSession
    ) async -> NativeSlashCommandExecutionResult {
        if let message = nativeSlashCommandAvailabilityMessage(.compact, session: session) {
            return .failed(message)
        }
        if session.codexController == nil, hasPersistedCodexThreadMetadata(session) {
            session.codexNeedsReconnect = true
        }
        await ensureCodexNativeSession(session: session)
        guard let controller = session.codexController,
              controller.hasActiveThread
        else {
            return .failed("Start a Codex conversation before using /compact.")
        }
        beginCodexCompaction(session)
        do {
            try await controller.compactThread()
            return .succeeded("Requested Codex context compaction.")
        } catch {
            resetTrackedCodexTurns(session)
            if !session.codexFallbackQueue.isEmpty || session.codexFallbackDispatchInFlight != nil {
                abandonCodexFallbackQueue(
                    session: session,
                    reason: "Codex queued follow-ups were cancelled because context compaction failed to start."
                )
            }
            if let ownership = session.activeRunOwnership {
                _ = session.endRunAttempt(ifCurrent: ownership, source: "codex.compaction.startFailed")
            }
            viewModel?.setAgentRunActive(session.tabID, isActive: false)
            session.runState = .idle
            setRunningStatus(nil, source: nil, session: session)
            viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
            viewModel?.scheduleSave(for: session.tabID)
            return .failed("Codex context compaction failed: \(error.localizedDescription)")
        }
    }

    private func executeGoalSlashCommand(
        argumentsText: String,
        session: AgentTabSession,
        selectedWorkflow: AgentWorkflowDefinition?,
        semanticRunState: AgentSessionRunState?
    ) async -> NativeSlashCommandExecutionResult {
        let effectiveRunState = semanticRunState ?? session.runState
        if let message = nativeSlashCommandAvailabilityMessage(
            .goal,
            argumentsText: argumentsText,
            session: session,
            effectiveRunState: effectiveRunState
        ) {
            return .failed(message)
        }
        if session.codexController == nil, hasPersistedCodexThreadMetadata(session) {
            session.codexNeedsReconnect = true
        }
        await ensureCodexNativeSession(
            session: session,
            deferReconnectForCurrentActiveTurn: effectiveRunState.isActive,
            semanticRunState: effectiveRunState
        )
        defer {
            scheduleCodexIdleShutdownIfNeeded(
                for: session,
                reason: "native-goal-command",
                effectiveRunState: effectiveRunState
            )
        }
        guard let controller = session.codexController,
              controller.hasActiveThread
        else {
            return .failed("Codex goal command failed: session not ready.")
        }

        let action = Self.goalSlashAction(from: argumentsText)
        do {
            switch action {
            case .show:
                if let goal = try await controller.getThreadGoal() {
                    return .succeeded(Self.formatThreadGoal(goal))
                }
                return .succeeded("No Codex goal is set. Use /goal <objective> to set one.")
            case .clear:
                let cleared = try await controller.clearThreadGoal()
                return .succeeded(cleared ? "Cleared Codex goal." : "No Codex goal was set.")
            case .pause:
                let goal = try await controller.setThreadGoalStatus(.paused)
                return .succeeded("Paused Codex goal: \(Self.shortObjective(goal.objective))")
            case .resume:
                let goal = try await controller.setThreadGoalStatus(.active)
                return .succeeded("Resumed Codex goal: \(Self.shortObjective(goal.objective))")
            case let .setObjective(objective):
                let includeBuiltInCleanupGuidance = showBuiltInWorkflowCleanupGuidance()
                let composition: GoalObjectiveComposition
                switch Self.composeGoalObjective(
                    rawObjective: objective,
                    selectedWorkflow: selectedWorkflow,
                    includeBuiltInSessionCleanupGuidance: includeBuiltInCleanupGuidance
                ) {
                case let .success(value):
                    composition = value
                case let .failure(message):
                    return .failed(message)
                }
                _ = try await controller.setThreadGoalObjective(composition.objective)
                return .succeeded("Set Codex goal: \(Self.shortObjective(objective))")
            }
        } catch {
            return .failed("Codex goal command failed: \(error.localizedDescription)")
        }
    }

    private static func shortObjective(_ objective: String, limit: Int = 240) -> String {
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let prefix = trimmed.prefix(max(0, limit - 1))
        return "\(prefix)…"
    }

    private static func formatThreadGoal(_ goal: CodexNativeSessionController.ThreadGoal) -> String {
        var lines = [
            "Current Codex goal:",
            goal.objective,
            "",
            "Status: \(displayName(for: goal.status))"
        ]
        if let tokenBudget = goal.tokenBudget {
            lines.append("Tokens: \(goal.tokensUsed)/\(tokenBudget)")
        } else {
            lines.append("Tokens used: \(goal.tokensUsed)")
        }
        return lines.joined(separator: "\n")
    }

    private static func displayName(for status: CodexNativeSessionController.ThreadGoalStatus) -> String {
        switch status {
        case .active:
            "Active"
        case .paused:
            "Paused"
        case .budgetLimited:
            "Budget limited"
        case .complete:
            "Complete"
        }
    }

    func effectiveCodexSelection(
        for session: AgentTabSession
    ) -> (model: String?, reasoningEffort: String?, serviceTier: String?) {
        let resolution = resolveCodexSelection(
            rawModel: session.selectedModelRaw,
            selectedEffortRaw: session.selectedReasoningEffortRaw,
            preservingExplicitEffort: true
        )
        return (
            resolution.modelParam,
            resolution.reasoningEffort?.rawValue,
            resolution.serviceTier
        )
    }

    private func beginCodexCompaction(_ session: AgentTabSession) {
        if session.activeRunOwnership == nil {
            _ = session.beginRunAttempt(source: "codex.compaction")
        }
        session.codexPendingTurnKind = .compact
        session.runState = .running
        setRunningStatus("Compacting context…", source: .transport, session: session, urgent: true)
        viewModel?.setAgentRunActive(session.tabID, isActive: true)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        viewModel?.scheduleSave(for: session.tabID)
    }

    private func beginTrackedCodexUserTurn(_ session: AgentTabSession) {
        session.codexPendingTurnKind = .user
    }

    private func installAuthoritativeCodexTurnForStart(
        turnID: String?,
        session: AgentTabSession,
        sourceController: (any CodexSessionControlling)?
    ) -> AgentTabSession.CodexTurnKind? {
        guard let controller = sourceController ?? session.codexController,
              let activeController = session.codexController,
              Self.sameCodexControllerInstance(activeController, controller),
              let threadID = session.codexConversationID,
              let runID = session.runID,
              let runAttemptID = session.activeRunAttemptID
        else {
            recordRejectedCodexTurnStart(
                reason: "missing_scope",
                eventTurnID: turnID,
                session: session
            )
            return nil
        }
        let kind = session.codexPendingTurnKind ?? .unknown
        let controllerInstanceID = ObjectIdentifier(controller)
        if let turnID = turnID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !turnID.isEmpty
        {
            if let current = session.codexAuthoritativeActiveTurn,
               current.turnID == turnID,
               authoritativeCodexTurnIsCurrent(current, session: session)
            {
                session.codexPendingTurnKind = nil
                session.codexRoutingObservedTurnID = turnID
                return current.turnKind
            }
            let candidate = AgentTabSession.CodexAuthoritativeTurnIdentity(
                threadID: threadID,
                turnID: turnID,
                turnKind: kind,
                controllerInstanceID: controllerInstanceID,
                controllerGeneration: session.codexControllerGeneration,
                runID: runID,
                runAttemptID: runAttemptID
            )
            if let current = session.codexAuthoritativeActiveTurn {
                if let reconciliation = session.codexPendingSteerLifecycleReconciliation,
                   reconciliation.priorIdentity == current,
                   reconciliation.acceptedDispatchTurnID == turnID,
                   authoritativeCodexTurnIsCurrent(current, session: session)
                {
                    let reconciled = AgentTabSession.CodexAuthoritativeTurnIdentity(
                        threadID: current.threadID,
                        turnID: turnID,
                        turnKind: current.turnKind,
                        controllerInstanceID: current.controllerInstanceID,
                        controllerGeneration: current.controllerGeneration,
                        runID: current.runID,
                        runAttemptID: current.runAttemptID
                    )
                    rebindCodexFallbackBlockers(
                        from: codexFallbackBlockingTurn(for: current),
                        to: codexFallbackBlockingTurn(for: reconciled),
                        session: session
                    )
                    session.codexAuthoritativeActiveTurn = reconciled
                    session.codexPendingSteerLifecycleReconciliation = nil
                    session.codexPendingTurnKind = nil
                    session.codexRoutingObservedTurnID = turnID
                    return reconciled.turnKind
                }
                recordRejectedCodexTurnStart(
                    reason: "authoritative_identity_mismatch",
                    eventTurnID: turnID,
                    session: session
                )
                return nil
            }
            session.codexAnonymousActiveTurn = nil
            session.codexAuthoritativeActiveTurn = candidate
            session.codexPendingTurnKind = nil
            session.codexRoutingObservedTurnID = turnID
            bindResumedThreadFallbacks(to: candidate, session: session)
            return kind
        }

        let candidate = AgentTabSession.CodexAnonymousTurnLiveness(
            threadID: threadID,
            turnKind: kind,
            controllerInstanceID: controllerInstanceID,
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: runAttemptID
        )
        guard session.codexAuthoritativeActiveTurn == nil else {
            recordRejectedCodexTurnStart(
                reason: "nil_id_with_authoritative_turn",
                eventTurnID: nil,
                session: session
            )
            return nil
        }
        if let current = session.codexAnonymousActiveTurn,
           current != candidate
        {
            recordRejectedCodexTurnStart(
                reason: "anonymous_identity_mismatch",
                eventTurnID: nil,
                session: session
            )
            return nil
        }
        session.codexAnonymousActiveTurn = candidate
        session.codexPendingTurnKind = nil
        return kind
    }

    private struct CorrelatedCodexTurnCompletion {
        let turnKind: AgentTabSession.CodexTurnKind
        let authoritativeIdentity: AgentTabSession.CodexAuthoritativeTurnIdentity?
    }

    private func correlatedCodexTurnKindForCompletion(
        turnID: String?,
        session: AgentTabSession
    ) -> CorrelatedCodexTurnCompletion? {
        if let turnID = turnID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !turnID.isEmpty
        {
            guard let identity = session.codexAuthoritativeActiveTurn else {
                recordRejectedCodexTurnCompletion(
                    reason: "missing_authoritative_identity",
                    eventTurnID: turnID,
                    session: session
                )
                return nil
            }
            guard authoritativeCodexTurnIsCurrent(identity, session: session) else {
                recordRejectedCodexTurnCompletion(
                    reason: "stale_authoritative_identity",
                    eventTurnID: turnID,
                    session: session
                )
                return nil
            }
            let completedIdentity: AgentTabSession.CodexAuthoritativeTurnIdentity
            if identity.turnID == turnID {
                completedIdentity = identity
            } else if let reconciliation = session.codexPendingSteerLifecycleReconciliation,
                      reconciliation.priorIdentity == identity,
                      reconciliation.acceptedDispatchTurnID == turnID
            {
                completedIdentity = .init(
                    threadID: identity.threadID,
                    turnID: turnID,
                    turnKind: identity.turnKind,
                    controllerInstanceID: identity.controllerInstanceID,
                    controllerGeneration: identity.controllerGeneration,
                    runID: identity.runID,
                    runAttemptID: identity.runAttemptID
                )
                rebindCodexFallbackBlockers(
                    from: codexFallbackBlockingTurn(for: identity),
                    to: codexFallbackBlockingTurn(for: completedIdentity),
                    session: session
                )
            } else {
                recordRejectedCodexTurnCompletion(
                    reason: "turn_id_mismatch",
                    eventTurnID: turnID,
                    session: session
                )
                return nil
            }
            session.codexAuthoritativeActiveTurn = nil
            session.codexPendingSteerLifecycleReconciliation = nil
            if session.codexRoutingObservedTurnID == identity.turnID
                || session.codexRoutingObservedTurnID == turnID
            {
                session.codexRoutingObservedTurnID = nil
            }
            return .init(
                turnKind: completedIdentity.turnKind,
                authoritativeIdentity: completedIdentity
            )
        }

        if let identity = session.codexAuthoritativeActiveTurn,
           session.codexAnonymousActiveTurn == nil,
           authoritativeCodexTurnIsCurrent(identity, session: session)
        {
            let blocker = codexFallbackBlockingTurn(for: identity)
            let queueDependsOnExactIdentity = session.codexFallbackQueue.contains {
                $0.blockingTurn == blocker
            } || session.codexFallbackDispatchInFlight?.blockingTurn == blocker
            guard !queueDependsOnExactIdentity else {
                recordRejectedCodexTurnCompletion(
                    reason: "nil_id_would_destroy_fifo_recovery",
                    eventTurnID: nil,
                    session: session
                )
                return nil
            }
            session.codexAuthoritativeActiveTurn = nil
            session.codexPendingSteerLifecycleReconciliation = nil
            if session.codexRoutingObservedTurnID == identity.turnID {
                session.codexRoutingObservedTurnID = nil
            }
            return .init(
                turnKind: identity.turnKind,
                authoritativeIdentity: identity
            )
        }
        if let anonymous = session.codexAnonymousActiveTurn,
           session.codexAuthoritativeActiveTurn == nil,
           anonymousCodexTurnIsCurrent(anonymous, session: session)
        {
            session.codexAnonymousActiveTurn = nil
            return .init(
                turnKind: anonymous.turnKind,
                authoritativeIdentity: nil
            )
        }
        recordRejectedCodexTurnCompletion(
            reason: "no_single_active_turn",
            eventTurnID: nil,
            session: session
        )
        return nil
    }

    private func authoritativeCodexTurnIsCurrent(
        _ identity: AgentTabSession.CodexAuthoritativeTurnIdentity,
        session: AgentTabSession
    ) -> Bool {
        guard let controller = session.codexController else { return false }
        return identity.threadID == session.codexConversationID
            && identity.controllerInstanceID == ObjectIdentifier(controller)
            && identity.controllerGeneration == session.codexControllerGeneration
            && identity.runID == session.runID
            && identity.runAttemptID == session.activeRunAttemptID
    }

    private func anonymousCodexTurnIsCurrent(
        _ identity: AgentTabSession.CodexAnonymousTurnLiveness,
        session: AgentTabSession
    ) -> Bool {
        guard let controller = session.codexController else { return false }
        return identity.threadID == session.codexConversationID
            && identity.controllerInstanceID == ObjectIdentifier(controller)
            && identity.controllerGeneration == session.codexControllerGeneration
            && identity.runID == session.runID
            && identity.runAttemptID == session.activeRunAttemptID
    }

    private func recordRejectedCodexTurnStart(
        reason: String,
        eventTurnID: String?,
        session: AgentTabSession
    ) {
        #if DEBUG
            AgentModePerfDiagnostics.increment(
                "codex.turn_start.rejected.\(reason)",
                tabID: session.tabID
            )
            AgentModePerfDiagnostics.event(
                "codex.turnStartRejected",
                tabID: session.tabID,
                fields: [
                    "reason": reason,
                    "eventTurnID": eventTurnID ?? "nil",
                    "authoritativeTurnID": session.codexAuthoritativeActiveTurn?.turnID ?? "nil"
                ]
            )
        #endif
    }

    private func recordRejectedCodexTurnCompletion(
        reason: String,
        eventTurnID: String?,
        session: AgentTabSession
    ) {
        #if DEBUG
            AgentModePerfDiagnostics.increment(
                "codex.turn_completion.rejected.\(reason)",
                tabID: session.tabID
            )
            AgentModePerfDiagnostics.event(
                "codex.turnCompletionRejected",
                tabID: session.tabID,
                fields: [
                    "reason": reason,
                    "eventTurnID": eventTurnID ?? "nil",
                    "currentTurnID": session.codexAuthoritativeActiveTurn?.turnID ?? "nil"
                ]
            )
        #endif
    }

    private func markCodexContextCompacted(_ session: AgentTabSession) {
        session.contextCompactedAt = Date()
        viewModel?.refreshCodexContextUsageSnapshot(for: session)
        session.isDirty = true
        viewModel?.requestUIRefresh(tabID: session.tabID)
        viewModel?.scheduleSave(for: session.tabID)
    }

    private func resetTrackedCodexTurns(_ session: AgentTabSession) {
        session.codexPendingTurnKind = nil
        session.codexAuthoritativeActiveTurn = nil
        session.codexAnonymousActiveTurn = nil
        session.codexRoutingObservedTurnID = nil
        session.codexPendingSteerLifecycleReconciliation = nil
    }

    /// A steer the server accepted into a different turn already delivered the
    /// user's input, so this rebinds lifecycle identity without resending.
    private func reconcileAcceptedCodexSteerMismatch(
        from identity: AgentTabSession.CodexAuthoritativeTurnIdentity,
        acceptedTurnID: String,
        controller: any CodexSessionControlling,
        session: AgentTabSession
    ) async {
        guard session.codexAuthoritativeActiveTurn == identity,
              authoritativeCodexTurnIsCurrent(identity, session: session),
              session.codexController.map(ObjectIdentifier.init) == ObjectIdentifier(controller)
        else { return }
        logCodex(
            "[AgentModeVM] sendCodexNativeMessage: steer accepted into different turn expected=\(identity.turnID) actual=\(acceptedTurnID); reconciling without resend"
        )
        let reconciliation = AgentTabSession.CodexPendingSteerLifecycleReconciliation(
            priorIdentity: identity,
            acceptedDispatchTurnID: acceptedTurnID
        )
        session.codexPendingSteerLifecycleReconciliation = reconciliation
        let prepared = await controller.prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
            expectedCurrentTurnID: identity.turnID,
            acceptedDispatchTurnID: acceptedTurnID
        )
        if !prepared {
            logCodex(
                "[AgentModeVM] sendCodexNativeMessage: controller lifecycle authority unavailable for accepted steer turn=\(acceptedTurnID); relying on session-level reconciliation"
            )
        }
        if session.codexPendingSteerLifecycleReconciliation == reconciliation,
           session.codexAuthoritativeActiveTurn != identity
        {
            session.codexPendingSteerLifecycleReconciliation = nil
        }
    }

    private func codexFallbackBlockingTurn(
        for identity: AgentTabSession.CodexAuthoritativeTurnIdentity
    ) -> AgentTabSession.CodexFallbackBlockingTurn {
        .init(
            threadID: identity.threadID,
            turnID: identity.turnID,
            controllerInstanceID: identity.controllerInstanceID,
            controllerGeneration: identity.controllerGeneration,
            runID: identity.runID,
            runAttemptID: identity.runAttemptID
        )
    }

    private func recoverableCodexFallbackBlockingTurn(
        session: AgentTabSession
    ) -> AgentTabSession.CodexFallbackBlockingTurn? {
        if let identity = session.codexAuthoritativeActiveTurn {
            return codexFallbackBlockingTurn(for: identity)
        }
        guard let inFlight = session.codexFallbackDispatchInFlight else {
            return nil
        }
        switch inFlight.state {
        case .dispatching, .awaitingLifecycleStart, .lifecycleStarted:
            return inFlight.blockingTurn
        case .queued, .eligibleForSuccessor:
            return nil
        }
    }

    private func fallbackSubmissionContext(
        _ context: AgentTabSession.CodexFallbackSubmissionContext?,
        text: String,
        images: [AgentImageAttachment]
    ) -> AgentTabSession.CodexFallbackSubmissionContext {
        context ?? .init(
            queueID: UUID(),
            providerText: text,
            images: images,
            taggedFileAttachments: [],
            draftText: text,
            optimisticUserItemID: nil,
            origin: .manual,
            dispatchTicket: nil
        )
    }

    private func detachCodexFallbackAttachmentReservation(
        _ reservationID: UUID?,
        session: AgentTabSession
    ) {
        guard let reservationID else { return }
        switch session.attachmentTurnState {
        case .idle:
            return
        case let .reserved(storedID, _), let .consumed(storedID, _):
            guard storedID == reservationID else { return }
            session.attachmentTurnState = .idle
        }
    }

    private static let maxDeliveredMCPFallbackAttemptIDs = 32

    private func recordDeliveredMCPFallbackAttempt(
        _ attemptID: UUID,
        session: AgentTabSession
    ) {
        guard session.codexDeliveredMCPFallbackAttemptIDs.insert(attemptID).inserted else { return }
        session.codexDeliveredMCPFallbackAttemptOrder.append(attemptID)
        while session.codexDeliveredMCPFallbackAttemptOrder.count > Self.maxDeliveredMCPFallbackAttemptIDs {
            let expired = session.codexDeliveredMCPFallbackAttemptOrder.removeFirst()
            session.codexDeliveredMCPFallbackAttemptIDs.remove(expired)
        }
    }

    @discardableResult
    private func removeQueuedCodexFallbackForDeliveredAttempt(
        _ attemptID: UUID,
        session: AgentTabSession
    ) -> Bool {
        recordDeliveredMCPFallbackAttempt(attemptID, session: session)
        guard let index = session.codexFallbackQueue.firstIndex(where: { entry in
            if case let .mcp(entryAttemptID) = entry.origin {
                return entryAttemptID == attemptID
            }
            return false
        }) else { return false }
        let removed = session.codexFallbackQueue.remove(at: index)
        if session.codexFallbackQueue.isEmpty, session.codexFallbackDispatchInFlight == nil {
            session.codexFallbackPumpTask?.cancel()
            session.codexFallbackPumpTask = nil
            session.codexFallbackSuccessorRetryTask?.cancel()
            session.codexFallbackSuccessorRetryTask = nil
            session.mcpFollowUpRunPending = false
        }
        logCodex("[AgentModeVM] sendCodexNativeMessage: removed queued Codex fallback after provider accepted attempt \(attemptID) queueID=\(removed.id)")
        session.isDirty = true
        viewModel?.publishMCPStateChange(for: session)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        viewModel?.scheduleSave(for: session.tabID)
        return true
    }

    @discardableResult
    private func dropDeliveredClaimedCodexFallbackIfNeeded(
        _ head: AgentTabSession.CodexFallbackQueueEntry,
        session: AgentTabSession
    ) -> Bool {
        guard case let .mcp(attemptID) = head.origin,
              session.codexDeliveredMCPFallbackAttemptIDs.contains(attemptID)
        else { return false }
        if session.codexFallbackDispatchInFlight?.id == head.id {
            session.codexFallbackDispatchInFlight = nil
        }
        viewModel?.finalizeAttachmentsForTurn(
            for: session,
            reservationID: head.attachmentReservationID,
            disposition: .keepFiles
        )
        session.codexSteerAckTracker.resolve(attemptID: attemptID, state: .startAccepted)
        logCodex("[AgentModeVM] dispatchClaimedCodexFallback: dropped queued fallback \(head.id) because provider already accepted MCP attempt \(attemptID)")
        viewModel?.publishMCPStateChange(for: session)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        viewModel?.scheduleSave(for: session.tabID)
        return true
    }

    private func enqueueCodexFallback(
        session: AgentTabSession,
        context: AgentTabSession.CodexFallbackSubmissionContext?,
        text: String,
        images: [AgentImageAttachment],
        selection: (model: String?, reasoningEffort: String?, serviceTier: String?),
        attachmentReservationID: UUID?,
        reason: CodexTurnFallbackDecision,
        controller: any CodexSessionControlling
    ) -> NativeSendOutcome {
        guard let threadID = session.codexConversationID,
              let runID = session.runID,
              let runAttemptID = session.activeRunAttemptID
        else {
            return .stale(reason: "Codex could not queue fallback delivery because its run lineage changed.")
        }
        let submission = fallbackSubmissionContext(context, text: text, images: images)
        if session.codexFallbackQueue.contains(where: { $0.id == submission.queueID })
            || session.codexFallbackDispatchInFlight?.id == submission.queueID
        {
            return .queuedFallback(queueID: submission.queueID, reason: reason)
        }
        let entry = AgentTabSession.CodexFallbackQueueEntry(
            id: submission.queueID,
            providerText: submission.providerText,
            images: submission.images,
            taggedFileAttachments: submission.taggedFileAttachments,
            model: selection.model,
            reasoningEffort: selection.reasoningEffort,
            serviceTier: selection.serviceTier,
            attachmentReservationID: attachmentReservationID,
            optimisticUserItemID: submission.optimisticUserItemID,
            draftText: submission.draftText,
            origin: submission.origin,
            fallbackReason: reason,
            originThreadID: threadID,
            originControllerInstanceID: ObjectIdentifier(controller),
            originControllerGeneration: session.codexControllerGeneration,
            originRunID: runID,
            originRunAttemptID: runAttemptID,
            blockingTurn: recoverableCodexFallbackBlockingTurn(session: session),
            state: .queued
        )
        detachCodexFallbackAttachmentReservation(attachmentReservationID, session: session)
        session.codexFallbackQueue.append(entry)
        if case let .mcp(attemptID) = submission.origin {
            session.codexSteerAckTracker.resolve(
                attemptID: attemptID,
                state: .durablyQueued(queueID: submission.queueID)
            )
        } else if session.mcpControlContext != nil {
            Task { @MainActor [weak viewModel, weak session] in
                guard let viewModel, let session else { return }
                await viewModel.signalCodexInstructionDelivered(for: session)
            }
        }
        session.isDirty = true
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        viewModel?.scheduleSave(for: session.tabID)
        if Self.codexFallbackReasonAllowsIdlePump(reason) {
            scheduleCodexFallbackIdlePump(session: session, queueID: submission.queueID)
        }
        return .queuedFallback(queueID: submission.queueID, reason: reason)
    }

    /// Heads the idle pump may release once a thread read reports `.idle`.
    private static func codexFallbackReasonAllowsIdlePump(_ reason: CodexTurnFallbackDecision) -> Bool {
        switch reason {
        case .noActiveTurn, .resumedThreadActive:
            true
        default:
            false
        }
    }

    /// A resumed-thread head bound to the current identified turn is released only by that
    /// turn's correlated completion through the terminal commit barrier, never by the idle pump.
    private func codexFallbackHeadAwaitsCorrelatedCompletion(
        _ head: AgentTabSession.CodexFallbackQueueEntry,
        session: AgentTabSession
    ) -> Bool {
        guard head.fallbackReason == .resumedThreadActive,
              let blockingTurn = head.blockingTurn,
              let identity = session.codexAuthoritativeActiveTurn,
              authoritativeCodexTurnIsCurrent(identity, session: session)
        else { return false }
        return codexFallbackBlockingTurn(for: identity) == blockingTurn
    }

    /// True while an earlier send still waits, unbound, behind the current resumed-thread marker.
    /// Later input joins that wait so the resumed turn's identity (or the idle pump) releases the
    /// whole queue in FIFO order.
    private func codexResumedThreadWaitIsPending(
        behind anonymous: AgentTabSession.CodexAnonymousTurnLiveness,
        session: AgentTabSession
    ) -> Bool {
        guard anonymousCodexTurnIsCurrent(anonymous, session: session) else { return false }
        return session.codexFallbackQueue.contains { entry in
            entry.state == .queued
                && entry.fallbackReason == .resumedThreadActive
                && entry.blockingTurn == nil
                && entry.originThreadID == anonymous.threadID
                && entry.originControllerInstanceID == anonymous.controllerInstanceID
                && entry.originControllerGeneration == anonymous.controllerGeneration
                && entry.originRunID == anonymous.runID
                && entry.originRunAttemptID == anonymous.runAttemptID
        }
    }

    private func scheduleCodexFallbackIdlePump(
        session: AgentTabSession,
        queueID: UUID
    ) {
        guard session.codexFallbackPumpTask == nil else { return }
        session.codexFallbackPumpTask = Task { @MainActor [weak self, weak session] in
            defer { session?.codexFallbackPumpTask = nil }
            guard let self, let session else { return }
            await pumpCodexFallbackIfAuthoritativelyIdle(session: session, queueID: queueID)
        }
    }

    private func pumpCodexFallbackIfAuthoritativelyIdle(
        session: AgentTabSession,
        queueID: UUID
    ) async {
        var retryDelayNanos: UInt64 = 100_000_000
        while !Task.isCancelled {
            guard session.codexFallbackDispatchInFlight == nil,
                  let head = session.codexFallbackQueue.first,
                  head.id == queueID,
                  head.state == .queued,
                  Self.codexFallbackReasonAllowsIdlePump(head.fallbackReason),
                  !codexFallbackHeadAwaitsCorrelatedCompletion(head, session: session),
                  let controller = session.codexController,
                  ObjectIdentifier(controller) == head.originControllerInstanceID,
                  session.codexControllerGeneration == head.originControllerGeneration,
                  session.codexConversationID == head.originThreadID,
                  session.runID == head.originRunID,
                  session.activeRunAttemptID == head.originRunAttemptID
            else { return }
            do {
                let snapshot = try await controller.readThreadSnapshot(includeTurns: true, timeout: 2)
                // The head may have been claimed or made successor-eligible during the read, or a
                // replayed `turn/started` may have bound it to the identified resumed turn. Once
                // bound, only that turn's correlated completion releases it, so its terminal
                // publication and successor transition are never bypassed by an idle read.
                guard let currentHead = session.codexFallbackQueue.first,
                      currentHead.id == queueID,
                      currentHead.state == .queued,
                      !codexFallbackHeadAwaitsCorrelatedCompletion(currentHead, session: session)
                else { return }
                if snapshot.conversationID == head.originThreadID,
                   snapshot.runtimeStatus == .idle,
                   snapshot.currentTurnID == nil,
                   snapshot.activeTurnIDs.isEmpty
                {
                    if let blockingTurn = currentHead.blockingTurn,
                       session.codexAuthoritativeActiveTurn?.turnID == blockingTurn.turnID
                    {
                        session.codexAuthoritativeActiveTurn = nil
                    }
                    session.codexAnonymousActiveTurn = nil
                    _ = await dispatchCodexFallbackHead(
                        session: session,
                        expectedQueueID: queueID,
                        beginsSuccessorAttempt: false
                    )
                    return
                }
            } catch {
                // Snapshot failures are transient; keep one bounded-backoff pump for this head.
            }
            try? await Task.sleep(nanoseconds: retryDelayNanos)
            retryDelayNanos = min(retryDelayNanos * 2, 1_000_000_000)
        }
    }

    private func activateCodexFallbackAttachmentReservation(
        _ entry: AgentTabSession.CodexFallbackQueueEntry,
        session: AgentTabSession
    ) -> Bool {
        guard !entry.images.isEmpty else { return true }
        guard let reservationID = entry.attachmentReservationID else { return false }
        guard case .idle = session.attachmentTurnState else { return false }
        session.attachmentTurnState = .reserved(
            reservationID: reservationID,
            attachments: entry.images
        )
        return true
    }

    private func claimCodexFallbackHead(
        session: AgentTabSession,
        expectedQueueID: UUID,
        beginsSuccessorAttempt: Bool
    ) -> AgentTabSession.CodexFallbackQueueEntry? {
        guard session.codexFallbackDispatchInFlight == nil,
              var head = session.codexFallbackQueue.first,
              head.id == expectedQueueID,
              let controller = session.codexController,
              ObjectIdentifier(controller) == head.originControllerInstanceID,
              session.codexControllerGeneration == head.originControllerGeneration,
              session.codexConversationID == head.originThreadID,
              session.runID == head.originRunID
        else { return nil }
        if beginsSuccessorAttempt {
            guard !session.runState.isActive else { return nil }
        } else {
            guard session.activeRunAttemptID == head.originRunAttemptID else { return nil }
        }
        guard activateCodexFallbackAttachmentReservation(head, session: session) else { return nil }
        if beginsSuccessorAttempt {
            _ = session.beginRunAttempt(source: "codex.fallback.successor")
        }
        _ = session.codexFallbackQueue.removeFirst()
        head.state = .dispatching
        session.codexFallbackDispatchInFlight = head
        session.runState = .running
        if beginsSuccessorAttempt {
            session.mcpFollowUpRunPending = false
        }
        viewModel?.setAgentRunActive(session.tabID, isActive: true)
        viewModel?.publishMCPStateChange(for: session)
        beginTrackedCodexUserTurn(session)
        setRunningStatus("Sending queued message…", source: .transport, session: session, urgent: true)
        return head
    }

    @discardableResult
    private func dispatchCodexFallbackHead(
        session: AgentTabSession,
        expectedQueueID: UUID,
        beginsSuccessorAttempt: Bool
    ) async -> Bool {
        guard let head = claimCodexFallbackHead(
            session: session,
            expectedQueueID: expectedQueueID,
            beginsSuccessorAttempt: beginsSuccessorAttempt
        ) else {
            return false
        }
        await dispatchClaimedCodexFallback(head, session: session)
        return true
    }

    private func dispatchClaimedCodexFallback(
        _ head: AgentTabSession.CodexFallbackQueueEntry,
        session: AgentTabSession
    ) async {
        if dropDeliveredClaimedCodexFallbackIfNeeded(head, session: session) {
            return
        }
        guard let controller = session.codexController,
              ObjectIdentifier(controller) == head.originControllerInstanceID
        else {
            await failCodexFallbackDispatch(
                session: session,
                entry: head,
                message: "Codex queued follow-up lost its controller before dispatch."
            )
            return
        }
        let usageDispatchTicket = session.registerCodexUsageDispatch(requestedModel: head.model)
        do {
            _ = try await controller.startUserTurn(
                text: head.providerText,
                images: head.images,
                model: head.model,
                reasoningEffort: head.reasoningEffort,
                serviceTier: head.serviceTier
            )
            session.acceptCodexUsageDispatch(usageDispatchTicket)
            guard var inFlight = session.codexFallbackDispatchInFlight,
                  inFlight.id == head.id,
                  session.codexController.map(ObjectIdentifier.init) == head.originControllerInstanceID
            else { return }
            if case .lifecycleStarted = inFlight.state {
                session.codexFallbackDispatchInFlight = nil
            } else {
                inFlight.state = .awaitingLifecycleStart
                session.codexFallbackDispatchInFlight = inFlight
            }
            await applySuccessfulCodexNativeSend(
                for: session,
                runID: session.runID ?? head.originRunID,
                attachments: head.images,
                attachmentReservationID: head.attachmentReservationID
            )
            if let ownership = session.activeRunOwnership {
                session.recordRunProgress(
                    ownership: ownership,
                    kind: .stageTransition,
                    stage: .running
                )
            }
        } catch {
            settleCodexUsageDispatchAfterStartFailure(
                usageDispatchTicket,
                error: error,
                session: session
            )
            await failCodexFallbackDispatch(
                session: session,
                entry: head,
                message: "Codex queued follow-up failed to start: \(error.localizedDescription)"
            )
        }
    }

    private func failCodexFallbackDispatch(
        session: AgentTabSession,
        entry: AgentTabSession.CodexFallbackQueueEntry,
        message: String
    ) async {
        if session.codexFallbackQueue.first?.id == entry.id {
            session.codexFallbackQueue.removeFirst()
        }
        if session.codexFallbackDispatchInFlight?.id == entry.id {
            session.codexFallbackDispatchInFlight = nil
        }
        session.mcpFollowUpRunPending = false
        session.codexPendingTurnKind = nil
        viewModel?.finalizeAttachmentsForTurn(
            for: session,
            reservationID: entry.attachmentReservationID,
            disposition: .restoreToPending
        )
        session.appendItem(.error(message, sequenceIndex: session.nextSequenceIndex))
        if session.activeRunOwnership != nil {
            await finalizeCodexRun(
                session,
                turnStatus: .failed,
                reason: "fallback-dispatch-failed",
                errorMessage: nil,
                notifyOnCompleted: false
            )
        } else {
            session.runState = .failed
            viewModel?.setAgentRunActive(session.tabID, isActive: false)
        }
        if !session.codexFallbackQueue.isEmpty {
            abandonCodexFallbackQueue(
                session: session,
                reason: "Codex queued follow-ups were cancelled after an earlier queued dispatch failed."
            )
        }
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        viewModel?.scheduleSave(for: session.tabID)
    }

    private enum CodexFallbackAbandonmentMode: Equatable {
        case restoreInput
        case discardInput
    }

    private func abandonCodexFallbackQueue(
        session: AgentTabSession,
        reason: String,
        mode: CodexFallbackAbandonmentMode = .restoreInput
    ) {
        session.codexFallbackPumpTask?.cancel()
        session.codexFallbackPumpTask = nil
        session.codexFallbackSuccessorRetryTask?.cancel()
        session.codexFallbackSuccessorRetryTask = nil
        session.mcpFollowUpRunPending = false
        let queued = session.codexFallbackQueue
        session.codexFallbackQueue.removeAll()
        for entry in queued {
            if case let .mcp(attemptID) = entry.origin {
                session.codexSteerAckTracker.markStale(attemptID: attemptID, reason: reason)
            }
            if let optimisticUserItemID = entry.optimisticUserItemID,
               let index = session.items.firstIndex(where: { $0.id == optimisticUserItemID })
            {
                _ = session.removeItem(at: index)
            }
            if mode == .restoreInput {
                let pendingImageIDs = Set(session.pendingImageAttachments.map(\.id))
                session.pendingImageAttachments.append(contentsOf: entry.images.filter {
                    !pendingImageIDs.contains($0.id)
                })
                let pendingTaggedIDs = Set(session.pendingTaggedFileAttachments.map(\.id))
                session.pendingTaggedFileAttachments.append(contentsOf: entry.taggedFileAttachments.filter {
                    !pendingTaggedIDs.contains($0.id)
                })
                if case .manual = entry.origin,
                   !entry.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    viewModel?.restoreCodexFallbackDraft(
                        tabID: session.tabID,
                        text: entry.draftText,
                        message: reason
                    )
                }
            }
        }
        if let inFlight = session.codexFallbackDispatchInFlight {
            if case let .mcp(attemptID) = inFlight.origin {
                session.codexSteerAckTracker.markStale(attemptID: attemptID, reason: reason)
            }
            viewModel?.finalizeAttachmentsForTurn(
                for: session,
                reservationID: inFlight.attachmentReservationID,
                disposition: .keepFiles
            )
            session.codexFallbackDispatchInFlight = nil
            if mode == .restoreInput {
                session.appendItem(.error(reason, sequenceIndex: session.nextSequenceIndex))
            }
        }
        viewModel?.publishMCPStateChange(for: session)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        viewModel?.scheduleSave(for: session.tabID)
    }

    package func handleMCPControlReset(
        for session: AgentTabSession,
        reason: String
    ) {
        guard session.codexFallbackSuccessorRetryTask != nil
            || !session.codexFallbackQueue.isEmpty
            || session.codexFallbackDispatchInFlight != nil
        else {
            return
        }
        abandonCodexFallbackQueue(session: session, reason: reason)
    }

    /// A replayed `turn/started` can name the turn a cold-resumed thread was already running after
    /// sends queued behind the anonymous resumed-thread marker. Bind every such entry to the
    /// identified turn so its completion releases them, in order, through the terminal commit barrier.
    private func bindResumedThreadFallbacks(
        to identity: AgentTabSession.CodexAuthoritativeTurnIdentity,
        session: AgentTabSession
    ) {
        let blockingTurn = codexFallbackBlockingTurn(for: identity)
        for index in session.codexFallbackQueue.indices {
            let entry = session.codexFallbackQueue[index]
            guard entry.state == .queued,
                  entry.fallbackReason == .resumedThreadActive,
                  entry.blockingTurn == nil,
                  entry.originThreadID == identity.threadID,
                  entry.originControllerInstanceID == identity.controllerInstanceID,
                  entry.originControllerGeneration == identity.controllerGeneration,
                  entry.originRunID == identity.runID,
                  entry.originRunAttemptID == identity.runAttemptID
            else { continue }
            session.codexFallbackQueue[index].blockingTurn = blockingTurn
        }
    }

    private func rebindCodexFallbackBlockers(
        from previousBlockingTurn: AgentTabSession.CodexFallbackBlockingTurn?,
        to blockingTurn: AgentTabSession.CodexFallbackBlockingTurn,
        session: AgentTabSession
    ) {
        if var inFlight = session.codexFallbackDispatchInFlight,
           inFlight.blockingTurn == previousBlockingTurn
        {
            inFlight.blockingTurn = blockingTurn
            session.codexFallbackDispatchInFlight = inFlight
        }
        for index in session.codexFallbackQueue.indices {
            guard session.codexFallbackQueue[index].state == .queued,
                  session.codexFallbackQueue[index].blockingTurn == previousBlockingTurn
            else { continue }
            session.codexFallbackQueue[index].blockingTurn = blockingTurn
        }
    }

    private func bindCodexFallbackQueueToStartedTurn(
        _ identity: AgentTabSession.CodexAuthoritativeTurnIdentity,
        session: AgentTabSession
    ) {
        guard var inFlight = session.codexFallbackDispatchInFlight else { return }
        // Successor dispatches begin a new run attempt, so lineage deliberately
        // excludes runAttemptID.
        guard identity.threadID == inFlight.originThreadID,
              identity.controllerInstanceID == inFlight.originControllerInstanceID,
              identity.controllerGeneration == inFlight.originControllerGeneration,
              identity.runID == inFlight.originRunID
        else { return }
        let previousBlockingTurn = inFlight.blockingTurn
        let blockingTurn = codexFallbackBlockingTurn(for: identity)
        switch inFlight.state {
        case .awaitingLifecycleStart:
            session.codexFallbackDispatchInFlight = nil
        case .dispatching:
            inFlight.state = .lifecycleStarted
            session.codexFallbackDispatchInFlight = inFlight
        case .lifecycleStarted:
            return
        case .queued, .eligibleForSuccessor:
            return
        }
        rebindCodexFallbackBlockers(
            from: previousBlockingTurn,
            to: blockingTurn,
            session: session
        )
    }

    private func codexFallbackSuccessorForCompletion(
        turnID: String?,
        status: CodexNativeSessionController.TurnStatus,
        completedIdentity: AgentTabSession.CodexAuthoritativeTurnIdentity?,
        session: AgentTabSession
    ) -> AgentRunTerminalCommitBarrier.ProviderSuccessor? {
        guard status == .completed,
              let turnID,
              let completedIdentity,
              completedIdentity.turnID == turnID,
              var head = session.codexFallbackQueue.first,
              head.state == .queued,
              head.blockingTurn == codexFallbackBlockingTurn(for: completedIdentity)
        else { return nil }
        head.state = .eligibleForSuccessor(completedTurnID: turnID)
        session.codexFallbackQueue[0] = head
        return .init(
            id: head.id,
            transitionKind: .relatedFollowUp,
            consumeAfterPublication: { [weak self, weak session] revision, publicationResult in
                guard let self, let session,
                      revision.providerSuccessorID == head.id
                else { return false }
                switch publicationResult {
                case .accepted:
                    break
                case let .rejected(reason):
                    guard Self.codexFallbackPublicationRejectionIsRetryable(reason) else {
                        abandonCodexFallbackQueue(
                            session: session,
                            reason: "Codex queued follow-up was cancelled because terminal publication was permanently rejected (\(reason))."
                        )
                        return false
                    }
                    viewModel?.publishMCPStateChange(for: session)
                    return false
                case .stale:
                    session.mcpFollowUpRunPending = false
                    abandonCodexFallbackQueue(
                        session: session,
                        reason: "Codex queued follow-up was cancelled because terminal publication became stale."
                    )
                    viewModel?.publishMCPStateChange(for: session)
                    return false
                }
                guard session.codexFallbackQueue.first?.id == head.id,
                      session.codexFallbackQueue.first?.state == .eligibleForSuccessor(completedTurnID: turnID)
                else {
                    session.mcpFollowUpRunPending = false
                    viewModel?.publishMCPStateChange(for: session)
                    return false
                }
                guard let claimedHead = claimCodexFallbackHead(
                    session: session,
                    expectedQueueID: head.id,
                    beginsSuccessorAttempt: true
                ) else {
                    viewModel?.publishMCPStateChange(for: session)
                    return false
                }
                Task { @MainActor [weak self, weak session, claimedHead] in
                    guard let self, let session else { return }
                    await dispatchClaimedCodexFallback(claimedHead, session: session)
                }
                return true
            }
        )
    }

    private static func codexFallbackPublicationRejectionIsRetryable(_ reason: String) -> Bool {
        switch reason {
        case "activation_replaced",
             "different_commit_already_published",
             "missing_successor_epoch",
             "missing_terminal_publication_envelope",
             "session_or_activation_mismatch",
             "stale_activation",
             "unknown_epoch",
             "view_model_deallocated":
            false
        default:
            true
        }
    }

    private func scheduleCodexFallbackSuccessorRetryIfNeeded(
        session: AgentTabSession,
        request: AgentRunTerminalCommitBarrier.Request,
        providerSuccessor: AgentRunTerminalCommitBarrier.ProviderSuccessor
    ) {
        guard session.codexFallbackSuccessorRetryTask == nil,
              let head = session.codexFallbackQueue.first,
              head.id == providerSuccessor.id,
              case .eligibleForSuccessor = head.state
        else { return }
        session.codexFallbackSuccessorRetryTask = Task { @MainActor [weak self, weak session] in
            defer { session?.codexFallbackSuccessorRetryTask = nil }
            var retryDelayNanos: UInt64 = 10_000_000
            while !Task.isCancelled {
                guard let self, let session,
                      let head = session.codexFallbackQueue.first,
                      head.id == providerSuccessor.id,
                      case .eligibleForSuccessor = head.state,
                      let terminalCommitBarrier
                else { return }
                _ = await terminalCommitBarrier.commit(request)
                guard session.codexFallbackQueue.first?.id == providerSuccessor.id,
                      session.codexFallbackQueue.first?.state == head.state
                else { return }
                try? await Task.sleep(nanoseconds: retryDelayNanos)
                retryDelayNanos = min(retryDelayNanos * 2, 1_000_000_000)
            }
        }
    }

    private func abandonCodexFallbackQueueBlockedByTerminalTurn(
        _ completedIdentity: AgentTabSession.CodexAuthoritativeTurnIdentity?,
        status: CodexNativeSessionController.TurnStatus,
        session: AgentTabSession
    ) {
        guard status != .completed,
              let completedIdentity
        else { return }
        let blocker = codexFallbackBlockingTurn(for: completedIdentity)
        let queuedDependsOnCompletedTurn = session.codexFallbackQueue.contains {
            $0.blockingTurn == blocker
        }
        let inFlightDependsOnCompletedTurn = session.codexFallbackDispatchInFlight?.blockingTurn == blocker
        guard queuedDependsOnCompletedTurn || inFlightDependsOnCompletedTurn else { return }
        abandonCodexFallbackQueue(
            session: session,
            reason: "Codex queued follow-ups were cancelled because the turn they followed ended with \(status)."
        )
    }

    static func normalizedCodexSelectionModelRaw(
        from raw: String?,
        capabilities: CodexModelCapabilitySnapshot = .shared
    ) -> String {
        let specifier = CodexModelSpecifier(raw: raw, capabilities: capabilities)
        guard let baseModel = specifier.baseModel else { return AgentModel.defaultModel.rawValue }
        if let serviceTier = specifier.appServerServiceTierParam {
            return "\(baseModel)-\(serviceTier)"
        }
        return baseModel
    }

    package func shouldShowNativeSlashCommand(
        _ command: NativeSlashCommand,
        session: AgentTabSession
    ) -> Bool {
        if session.profile == .knowledge, command != .compact {
            return false
        }
        return switch command {
        case .compact:
            !session.runState.isActive && hasKnownCodexThread(session)
        case .goal:
            goalSupportEnabled()
        case .computerUse:
            computerUseEnabled()
        }
    }

    private func hasKnownCodexThread(_ session: AgentTabSession) -> Bool {
        if session.codexController?.hasActiveThread == true {
            return true
        }
        return hasPersistedCodexThreadMetadata(session)
    }

    private func hasPersistedCodexThreadMetadata(_ session: AgentTabSession) -> Bool {
        if let conversationID = session.codexConversationID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !conversationID.isEmpty
        {
            return true
        }
        if let rolloutPath = session.codexRolloutPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rolloutPath.isEmpty
        {
            return true
        }
        return false
    }

    private func isHeadlessAgent(_: AgentProviderKind) -> Bool {
        false
    }

    private func stopCodexToolTracking(
        for session: AgentTabSession
    ) {
        let runID = session.runID
        let mcpHost = mcpHost
        guard let controller = toolTrackingByTabID.removeValue(forKey: session.tabID) else {
            guard let runID else { return }
            Task { await mcpHost.unregisterToolObservers(for: runID) }
            return
        }
        Task {
            await controller.stopTracking()
            if let runID {
                await mcpHost.unregisterToolObservers(for: runID)
            }
        }
    }

    private func stopCodexToolTrackingAndWait(
        for session: AgentTabSession
    ) async {
        let runID = session.runID
        guard let controller = toolTrackingByTabID.removeValue(forKey: session.tabID) else {
            if let runID {
                await mcpHost.unregisterToolObservers(for: runID)
            }
            return
        }
        await controller.stopTracking()
        if let runID {
            await mcpHost.unregisterToolObservers(for: runID)
        }
    }

    private func stopCodexToolTrackingAndWait(
        for session: AgentTabSession,
        matchingRunID runID: UUID?
    ) async {
        guard let runID else { return }
        guard let controller = toolTrackingByTabID[session.tabID] else {
            await mcpHost.unregisterToolObservers(for: runID)
            return
        }
        guard controller.trackedRunID == runID else {
            await mcpHost.unregisterToolObservers(for: runID)
            return
        }
        toolTrackingByTabID.removeValue(forKey: session.tabID)
        await controller.stopTracking()
        await mcpHost.unregisterToolObservers(for: runID)
    }

    package func handleProviderSwitch(
        from oldAgent: AgentProviderKind,
        to newAgent: AgentProviderKind,
        session: AgentTabSession
    ) {
        if isHeadlessAgent(oldAgent) || isHeadlessAgent(newAgent) {
            session.providerSessionID = nil
        }
        if oldAgent == .codexExec, newAgent != .codexExec {
            cancelCodexThreadNameSync(for: session.tabID)
            cancelCodexIdleShutdown(for: session.tabID)
            cancelCodexTransportClosedFallback(for: session.tabID)
            stopBashLivenessTask(for: session.tabID)
            stopCodexStallWatchdog(for: session.tabID)
            session.endCodexUsageExecution(reason: "agent-switched")
            if let controller = session.codexController {
                Task { await controller.shutdown() }
            }
            session.codexController = nil
            session.codexControllerPermissionProfile = nil
            session.codexControllerSessionProfile = nil
            session.codexControllerTaskLabelKind = nil
            session.codexControllerWorkspacePath = nil
            session.pendingCodexComputerUseActivation = nil
            session.codexControllerFeatureState = nil
            session.codexEventTask?.cancel()
            session.codexEventTask = nil
            session.codexEventTaskRunID = nil
            session.codexLastEventAt = nil
            stopCodexToolTracking(for: session)
            resetCodexWatchdogState(session)
            resetCodexResumeTimeoutState(for: session)
            session.codexConversationID = nil
            session.codexRolloutPath = nil
            session.codexContextUsage = nil
            viewModel?.clearContextUsageSnapshot(for: session)
            session.codexModel = nil
            session.codexReasoningEffort = nil
            session.codexNeedsReconnect = false
        }
    }

    func handleToolPreferencesChanged(for session: AgentTabSession) {
        guard session.selectedAgent == .codexExec else { return }
        cancelCodexIdleShutdown(for: session.tabID)
        session.codexToolPreferencesGeneration += 1
        session.codexNeedsReconnect = true
        guard !session.runState.isActive else {
            updateCodexStallWatchdogState(for: session)
            return
        }
        // Keep the controller warm, but reconnect on the next send so thread-level
        // config overrides are rebuilt from current preferences. Active turns keep
        // their existing settings until the next turn starts.
        stopCodexToolTracking(for: session)
    }

    private func startCodexNativeSession(
        controller: (any CodexSessionControlling)?,
        existingRef: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?,
        allowMissingRolloutFallback: Bool
    ) async throws -> CodexNativeSessionStartResult {
        guard let controller else {
            return CodexNativeSessionStartResult(
                sessionRef: nil,
                fallbackReason: nil
            )
        }
        do {
            let ref = try await controller.startOrResume(
                existing: existingRef,
                baseInstructions: baseInstructions,
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier
            )
            return CodexNativeSessionStartResult(
                sessionRef: ref,
                fallbackReason: nil
            )
        } catch {
            guard allowMissingRolloutFallback,
                  Self.shouldRetryCodexStartWithoutResume(existingRef: existingRef, error: error)
            else {
                throw error
            }
            // A missing rollout that settled before Stop must not start a replacement thread.
            try Task.checkCancellation()
            logCodex("[AgentModeVM][CodexReconnect] resume failed due to missing rollout path; retrying with a fresh thread start")
            let ref = try await controller.startOrResume(
                existing: nil,
                baseInstructions: baseInstructions,
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier
            )
            return CodexNativeSessionStartResult(
                sessionRef: ref,
                fallbackReason: .missingRollout
            )
        }
    }

    private static func shouldRetryCodexStartWithoutResume(
        existingRef: CodexNativeSessionController.SessionRef?,
        error: Error
    ) -> Bool {
        guard existingRef != nil else { return false }
        if error is CancellationError { return false }

        let nsError = error as NSError
        let candidates = [
            error.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion
        ].compactMap(\.self)

        return candidates.contains { isMissingRolloutErrorMessage($0) }
    }

    private static func normalizedCodexResumeTimeoutTarget(
        conversationID: String?,
        rolloutPath: String?
    ) -> AgentCodexResumeTimeoutState? {
        let normalizedConversationID = conversationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedConversationID = normalizedConversationID,
              !resolvedConversationID.isEmpty
        else {
            return nil
        }
        let normalizedRolloutPath = rolloutPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentCodexResumeTimeoutState(
            conversationID: resolvedConversationID,
            rolloutPath: normalizedRolloutPath?.isEmpty == false ? normalizedRolloutPath : nil,
            consecutiveTimeouts: 0
        )
    }

    /// Message classification follows the requested operation. Timeout accounting remains
    /// stricter because it requires a usable target identity.
    private static func isCodexResumeAttempt(_ existingRef: CodexNativeSessionController.SessionRef?) -> Bool {
        existingRef != nil
    }

    private static func codexNativeSessionFailurePrefix(attemptedResume: Bool) -> String {
        attemptedResume ? "Codex native resume failed:" : "Codex native start failed:"
    }

    private static func isCodexNativeSessionFailureText(_ text: String) -> Bool {
        text.hasPrefix(codexNativeSessionFailurePrefix(attemptedResume: false))
            || text.hasPrefix(codexNativeSessionFailurePrefix(attemptedResume: true))
    }

    private func resetCodexResumeTimeoutState(for session: AgentTabSession) {
        session.codexResumeTimeoutState = .init()
    }

    @discardableResult
    private func recordCodexResumeTimeout(
        for session: AgentTabSession,
        existingRef: CodexNativeSessionController.SessionRef
    ) -> Int {
        guard let target = Self.normalizedCodexResumeTimeoutTarget(
            conversationID: existingRef.conversationID,
            rolloutPath: existingRef.rolloutPath
        ) else {
            resetCodexResumeTimeoutState(for: session)
            return 0
        }

        if session.codexResumeTimeoutState.conversationID == target.conversationID,
           session.codexResumeTimeoutState.rolloutPath == target.rolloutPath
        {
            session.codexResumeTimeoutState.consecutiveTimeouts += 1
        } else {
            session.codexResumeTimeoutState = AgentCodexResumeTimeoutState(
                conversationID: target.conversationID,
                rolloutPath: target.rolloutPath,
                consecutiveTimeouts: 1
            )
        }

        let count = session.codexResumeTimeoutState.consecutiveTimeouts
        logCodex("[AgentModeVM][CodexReconnect] recorded resume timeout for tab \(session.tabID) targetConversation=\(target.conversationID ?? "nil") targetRollout=\(target.rolloutPath ?? "nil") count=\(count)")
        return count
    }

    private enum CodexNativeSessionFailureKind {
        case timeout
        case inboundFrameLimit
        case threadSystemError
        case other
    }

    private static func codexNativeSessionFailureKind(for error: Error) -> CodexNativeSessionFailureKind {
        if CodexAppServerClient.isTimeoutError(error) {
            return .timeout
        }
        if CodexAppServerClient.isInboundFrameLimitError(error) {
            return .inboundFrameLimit
        }
        if case .threadInSystemErrorState? = error as? CodexSessionControllerError {
            return .threadSystemError
        }
        return .other
    }

    /// User guidance appended after a failed native start/resume. Every resume failure keeps the
    /// saved thread: Handoff or a new thread happen only by explicit user action.
    private static func codexNativeSessionFailureGuidance(
        kind: CodexNativeSessionFailureKind,
        attemptedResume: Bool,
        resumeTimeoutCount: Int?
    ) -> String? {
        guard attemptedResume else { return nil }
        switch kind {
        case .timeout:
            let count = resumeTimeoutCount ?? 0
            guard count >= 2 else {
                return "Your saved thread was kept. Send again to retry the same thread."
            }
            return "Codex has timed out resuming this thread \(count) times in a row. Your saved thread was kept. Send again to retry, or use Handoff to continue in a new thread."
        case .inboundFrameLimit:
            let limitMegabytes = CodexAppServerClient.Config.maxInboundFrameBytes / (1024 * 1024)
            return "Codex sent more than \(limitMegabytes) MB of thread history, which this Codex version can't skip. Update Codex and retry, or use Handoff to continue in a new thread."
        case .threadSystemError:
            return "Codex reports this thread is in an error state. Your saved thread was kept. Retry, or use Handoff."
        case .other:
            return nil
        }
    }

    /// A start attempt still owns the tab's controller slot when the slot is empty (already detached,
    /// e.g. by Stop) or holds the attempt's own controller. A successor controller is never touched.
    private static func codexStartAttemptOwnsControllerSlot(
        _ controller: (any CodexSessionControlling)?,
        session: AgentTabSession
    ) -> Bool {
        guard let activeController = session.codexController else { return true }
        guard let controller else { return false }
        return sameCodexControllerInstance(activeController, controller)
    }

    /// True only while the tab's controller slot holds exactly `controller`. A start result is
    /// applied only to the controller that produced it; once Stop detached it or a successor
    /// replaced it, the result is a late success.
    private static func codexControllerSlotHolds(
        _ controller: (any CodexSessionControlling)?,
        session: AgentTabSession
    ) -> Bool {
        guard let controller, let activeController = session.codexController else { return false }
        return sameCodexControllerInstance(activeController, controller)
    }

    /// Run identity of one native start/resume attempt, captured before its first suspension.
    private struct CodexStartAttemptIdentity {
        let runOwnership: AgentRunOwnership?
        let runID: UUID
        /// The tab's run-attempt generation when the attempt started. It survives a later attempt's
        /// terminal teardown, which clears that attempt's ownership, run ID, and controller.
        let runAttemptGeneration: UInt64
    }

    /// True while no successor has taken the tab since the attempt started: no later run attempt
    /// has begun (even one that has since ended and released its controller), no other run attempt
    /// or run ID is active, and the controller slot is empty or still holds `controller`. A
    /// superseded attempt keeps its own error item but must not change the tab's resume-timeout
    /// count, reconnect flag, controller, or authentication-recovery state.
    private static func codexStartAttemptOwnsSessionState(
        _ attempt: CodexStartAttemptIdentity,
        controller: (any CodexSessionControlling)?,
        session: AgentTabSession
    ) -> Bool {
        guard session.runAttemptGeneration == attempt.runAttemptGeneration else {
            return false
        }
        if let currentOwnership = session.activeRunOwnership, currentOwnership != attempt.runOwnership {
            return false
        }
        if let currentRunID = session.runID, currentRunID != attempt.runID {
            return false
        }
        return codexStartAttemptOwnsControllerSlot(controller, session: session)
    }

    /// A send is superseded once a later run took the tab while this send's startup was pending:
    /// a later run attempt began (even if it has since ended and released its controller and run
    /// ID), a different run attempt owns it now, or (after Stop ended this send's attempt) a later
    /// run already installed its own controller and may have finished. Stop detaches the stopped
    /// attempt's own controller, so a stopped send finds an empty slot unless a later run filled it.
    private static func codexSendIsSupersededBySuccessor(
        sendRunOwnership: AgentRunOwnership?,
        sendRunAttemptGeneration: UInt64,
        session: AgentTabSession,
        isCancelled: Bool
    ) -> Bool {
        if session.runAttemptGeneration != sendRunAttemptGeneration {
            return true
        }
        if let currentOwnership = session.activeRunOwnership {
            return currentOwnership != sendRunOwnership
        }
        return isCancelled && sendRunOwnership != nil && session.codexController != nil
    }

    /// Quiet outcome for a native start/resume whose request was cancelled (user Stop) or whose
    /// late success arrived after cancellation. The app-server may still be processing the resume,
    /// so only the captured controller is invalidated, and only while no successor owns the tab.
    /// No error item is appended, and the resume timeout count is left untouched.
    private func discardCancelledCodexNativeSessionStart(
        session: AgentTabSession,
        attempt: CodexStartAttemptIdentity,
        controller: (any CodexSessionControlling)?,
        attemptedResume: Bool,
        lateSuccess: Bool,
        preserveRunID: Bool
    ) {
        let operation = attemptedResume ? "resume" : "start"
        logCodex("[AgentModeVM][CodexReconnect] native \(operation) cancelled for tab \(session.tabID) lateSuccess=\(lateSuccess); keeping saved thread metadata")
        guard let controller,
              Self.codexStartAttemptOwnsSessionState(attempt, controller: controller, session: session)
        else {
            return
        }
        _ = invalidateCodexControllerForReconnect(
            session: session,
            expectedController: controller,
            source: attemptedResume ? "resume-cancelled" : "start-cancelled",
            preserveRunID: preserveRunID
        )
    }

    /// Presents one failed native start/resume attempt and keeps the saved thread. Cleanup targets
    /// only the attempt's captured controller. Once a successor owns the tab, the attempt still
    /// shows its error item but leaves the timeout count, controller, and reconnect flag alone.
    private func handleCodexNativeSessionStartFailure(
        _ error: Error,
        session: AgentTabSession,
        attempt: CodexStartAttemptIdentity,
        controller: (any CodexSessionControlling)?,
        existingRef: CodexNativeSessionController.SessionRef?,
        preserveRunID: Bool
    ) {
        let attemptedResume = Self.isCodexResumeAttempt(existingRef)
        let failureKind = Self.codexNativeSessionFailureKind(for: error)
        let ownsSessionState = Self.codexStartAttemptOwnsSessionState(attempt, controller: controller, session: session)
        var resumeTimeoutCount: Int?
        switch failureKind {
        case .timeout:
            // The count only drives guidance; it never changes which request is sent.
            if ownsSessionState, attemptedResume, let existingRef {
                resumeTimeoutCount = recordCodexResumeTimeout(for: session, existingRef: existingRef)
            }
        case .inboundFrameLimit, .threadSystemError, .other:
            if ownsSessionState {
                resetCodexResumeTimeoutState(for: session)
            }
        }
        // A poisoned control plane or an oversized inbound frame (which already terminated the
        // app-server transport) replaces the controller; other failures only mark reconnect.
        let invalidationSource: String? = switch failureKind {
        case .timeout:
            attemptedResume ? "resume-timeout" : "start-timeout"
        case .inboundFrameLimit:
            "inbound-frame-limit"
        case .threadSystemError, .other:
            nil
        }
        let invalidatedController: Bool = if ownsSessionState, let invalidationSource, let controller {
            invalidateCodexControllerForReconnect(
                session: session,
                expectedController: controller,
                source: invalidationSource,
                preserveRunID: preserveRunID
            )
        } else {
            false
        }
        if !invalidatedController, ownsSessionState {
            markCodexReconnectNeeded(for: session, source: "ensure-error")
        }
        var failureText = "\(Self.codexNativeSessionFailurePrefix(attemptedResume: attemptedResume)) \(error.localizedDescription)"
        if let guidance = Self.codexNativeSessionFailureGuidance(
            kind: failureKind,
            attemptedResume: attemptedResume,
            resumeTimeoutCount: resumeTimeoutCount
        ) {
            failureText += " \(guidance)"
        }
        session.appendItem(AgentChatItem.error(failureText, sequenceIndex: session.nextSequenceIndex))
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    private func makeCodexRunLease(
        tabID: UUID,
        runID: UUID,
        sessionProfile: AgentSessionProfile = .standard,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false,
        additionalRestrictedTools: Set<String> = [],
        runHasNativeShell: Bool = false
    ) -> MCPBootstrapLease? {
        guard shouldManageCodexTooling else { return nil }
        viewModel?.bindPendingOracleReviewContext(tabID: tabID, runID: runID)
        let leaseSpec = MCPBootstrapLeaseSpec.agentMode(
            tabID: tabID,
            runID: runID,
            gateID: UUID(),
            windowID: windowID,
            agent: .codexExec,
            sessionProfile: sessionProfile,
            taskLabelKind: taskLabelKind,
            allowsAgentExternalControlTools: allowsAgentExternalControlTools,
            additionalRestrictedTools: additionalRestrictedTools,
            runHasNativeShell: runHasNativeShell
        )
        return MCPBootstrapLease(
            spec: leaseSpec,
            runCoordinator: runCoordinator,
            mcpServerEnabler: { [weak viewModel] in
                await viewModel?.ensureMCPServerEnabledForThreadStart()
            },
            policyInstaller: MCPBootstrapLease.agentModePolicyInstaller(connectionPolicyInstaller)
        )
    }

    private static func resumeRecoveryMessage() -> String {
        "Codex couldn't resume the previous thread because its rollout file was missing. Started a fresh thread."
    }

    private static func recoveryMessage(for fallbackReason: CodexNativeSessionFallbackReason) -> String {
        switch fallbackReason {
        case .missingRollout:
            resumeRecoveryMessage()
        }
    }

    private static func isMissingRolloutErrorMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        guard normalized.contains("rollout") else { return false }
        let hasLoadFailure = normalized.contains("failed to load rollout")
            || normalized.contains("failed loading rollout")
            || normalized.contains("failed to open rollout")
        let hasMissingFileSignal = normalized.contains("no such file")
            || normalized.contains("os error 2")
            || normalized.contains("enoent")
        return hasLoadFailure && hasMissingFileSignal
    }

    private static func isRetriableStreamErrorMessage(_ message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.hasPrefix("reconnecting")
            || normalized.contains("reconnecting...")
            || normalized.contains("will retry")
            || normalized.contains("retrying")
    }

    /// Identity comparison is safe because CodexSessionControlling is class-constrained.
    private static func sameCodexControllerInstance(
        _ lhs: any CodexSessionControlling,
        _ rhs: any CodexSessionControlling
    ) -> Bool {
        ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
    }

    private func clearCodexRecoveryAttempt(for runID: UUID?) {
        guard let runID else { return }
        codexRecoveryAttemptedRunIDs.remove(runID)
    }

    package func scheduleCodexThreadNameSyncIfPossible(
        for session: AgentTabSession,
        name rawName: String?,
        explicitThreadID rawThreadID: String?,
        source: String
    ) {
        guard session.selectedAgent == .codexExec,
              let controller = session.codexController
        else { return }
        let validatedName = AgentSession.validatedName(rawName ?? "")
        guard !validatedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let trimmedThreadID = rawThreadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitThreadID = trimmedThreadID?.isEmpty == false ? trimmedThreadID : nil
        let tabID = session.tabID
        pendingCodexThreadNameSyncByTabID[tabID] = PendingCodexThreadNameSync(
            tabID: tabID,
            name: validatedName,
            explicitThreadID: explicitThreadID,
            source: source,
            controller: controller
        )
        guard codexThreadNameSyncTaskByTabID[tabID] == nil else { return }
        let generation = UUID()
        codexThreadNameSyncTaskByTabID[tabID] = (
            generation: generation,
            task: Task { [weak self, weak session] in
                guard let self else { return }
                await runCodexThreadNameSyncLoop(tabID: tabID, generation: generation, session: session)
            }
        )
    }

    private func runCodexThreadNameSyncLoop(
        tabID: UUID,
        generation: UUID,
        session weakSession: AgentTabSession?
    ) async {
        defer {
            if codexThreadNameSyncTaskByTabID[tabID]?.generation == generation {
                codexThreadNameSyncTaskByTabID.removeValue(forKey: tabID)
            }
        }
        while !Task.isCancelled {
            guard let pending = pendingCodexThreadNameSyncByTabID.removeValue(forKey: tabID) else { return }
            guard let session = weakSession,
                  session.selectedAgent == .codexExec,
                  let activeController = session.codexController,
                  Self.sameCodexControllerInstance(activeController, pending.controller)
            else {
                continue
            }
            let sessionThreadID = session.codexConversationID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedThreadID = pending.explicitThreadID
                ?? (sessionThreadID?.isEmpty == false ? sessionThreadID : nil)
            do {
                try await pending.controller.setThreadName(pending.name, threadID: resolvedThreadID)
            } catch is CancellationError {
                return
            } catch {
                logCodex("[AgentModeVM][CodexThreadName] failed to sync thread name for tab \(pending.tabID) source=\(pending.source): \(error.localizedDescription)")
            }
        }
    }

    private func cancelCodexThreadNameSync(for tabID: UUID) {
        pendingCodexThreadNameSyncByTabID.removeValue(forKey: tabID)
        codexThreadNameSyncTaskByTabID.removeValue(forKey: tabID)?.task.cancel()
    }

    private func stopAllCodexThreadNameSyncTasks() {
        pendingCodexThreadNameSyncByTabID.removeAll()
        let tasks = codexThreadNameSyncTaskByTabID.values.map(\.task)
        codexThreadNameSyncTaskByTabID.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    /// Returns `true` if the caller still owns the run and should proceed with finalization.
    /// Returns `false` if a newer run has started and the caller should silently exit.
    private func shouldFinalizeAfterRecovery(
        session: AgentTabSession,
        expectedRunID: UUID?,
        source: String
    ) -> Bool {
        guard let expectedRunID else { return false }
        if session.runID != expectedRunID {
            clearCodexRecoveryAttempt(for: expectedRunID)
            let currentRunID = session.runID?.uuidString ?? "nil"
            logCodex("[AgentModeVM][CodexRecovery] ignoring stale \(source) recovery result for tab \(session.tabID); run moved on from \(expectedRunID.uuidString) to \(currentRunID)")
            return false
        }
        return true
    }

    private func applyCodexNativeSessionStartResult(
        _ startResult: CodexNativeSessionStartResult,
        to session: AgentTabSession,
        preferenceGenerationAtStart: Int
    ) {
        if let fallbackReason = startResult.fallbackReason {
            let recoveryNoticeItem = AgentChatItem.system(
                Self.recoveryMessage(for: fallbackReason),
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(recoveryNoticeItem)
            viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        }
        if let ref = startResult.sessionRef {
            cancelCodexTransportClosedFallback(for: session.tabID)
            let normalizedThreadID = ref.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedThreadID.isEmpty {
                // Never persist resume metadata without a usable thread ID: a stored
                // rollout path whose thread ID is missing would strand every later
                // send on the persisted-state integrity error. Drop both fields so
                // the next transport start classifies as a fresh thread/start.
                logCodex("[AgentModeVM][CodexReconnect] start result carried no usable thread ID for tab \(session.tabID); clearing native thread metadata instead of persisting an invalid resume reference")
                session.codexConversationID = nil
                session.codexRolloutPath = nil
            } else {
                session.codexConversationID = normalizedThreadID
                session.codexRolloutPath = ref.rolloutPath
                installResumedActiveThreadMarkerIfNeeded(session: session)
            }
            session.codexModel = ref.model
            session.codexReasoningEffort = ref.reasoningEffort
            // Always clear the reconnect flag after a successful start/resume.
            // If preferences changed during the async startOrResume (generation mismatch),
            // do NOT re-trigger a reconnect: the typed turn dispatch already sends the latest
            // configOverrides and turn-scoped policy on every call, so the updated
            // preferences take effect on the next turn without a costly reconnect.
            session.codexNeedsReconnect = false
            if session.codexToolPreferencesGeneration == preferenceGenerationAtStart {
                logCodex("[AgentModeVM][CodexReconnect] reconnect flag cleared for tab \(session.tabID) generation=\(preferenceGenerationAtStart)")
            } else {
                logCodex("[AgentModeVM][CodexReconnect] reconnect flag cleared despite generation mismatch (current=\(session.codexToolPreferencesGeneration) started=\(preferenceGenerationAtStart)); next turn carries updated config")
            }
            session.isDirty = true
            viewModel?.scheduleSave(for: session.tabID)
            scheduleCodexThreadNameSyncIfPossible(
                for: session,
                name: viewModel?.codexThreadDisplayName(for: session.tabID),
                explicitThreadID: ref.conversationID,
                source: "start-or-resume"
            )
        }
        resetCodexResumeTimeoutState(for: session)
    }

    /// A resumed thread can already be running a turn this coordinator never saw start (cold
    /// resume). The controller learns that only from the resume snapshot, never from an
    /// authoritative `turn/started`, so mark the thread busy with an anonymous `.unknown` turn:
    /// new text queues behind it and the idle pump releases the queue once a read reports
    /// `.idle`. Never fabricates a `turn/started` (accounting and usage side effects).
    private func installResumedActiveThreadMarkerIfNeeded(session: AgentTabSession) {
        guard let controller = session.codexController,
              controller.lastKnownRuntimeStatus?.isActive == true,
              let threadID = session.codexConversationID,
              let runID = session.runID,
              let runAttemptID = session.activeRunAttemptID
        else { return }
        if let identity = session.codexAuthoritativeActiveTurn {
            // A current identity already names the running turn.
            guard !authoritativeCodexTurnIsCurrent(identity, session: session) else { return }
            // Provably stale (another thread, controller, run or attempt): it can never correlate
            // a lifecycle event again, and would make the resumed turn's replayed `turn/started`
            // look like an identity mismatch.
            session.codexAuthoritativeActiveTurn = nil
            if session.codexPendingSteerLifecycleReconciliation?.priorIdentity == identity {
                session.codexPendingSteerLifecycleReconciliation = nil
            }
            if session.codexRoutingObservedTurnID == identity.turnID {
                session.codexRoutingObservedTurnID = nil
            }
        }
        if let current = session.codexAnonymousActiveTurn,
           anonymousCodexTurnIsCurrent(current, session: session)
        {
            return
        }
        session.codexAnonymousActiveTurn = .init(
            threadID: threadID,
            turnKind: .unknown,
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration,
            runID: runID,
            runAttemptID: runAttemptID
        )
        logCodex("[AgentModeVM][CodexReconnect] resumed thread \(threadID) is active without a known turn identity for tab \(session.tabID); new input queues until it is idle")
    }

    private func recoveryFailureMessage(
        for trigger: CodexRecoveryTrigger,
        recoveryAlreadyAttempted: Bool = false
    ) -> String {
        switch trigger {
        case .unexpectedStreamEnd:
            if recoveryAlreadyAttempted {
                return "Codex events stream ended unexpectedly after an automatic recovery attempt. The run may need to be restarted."
            }
            return "Codex events stream ended unexpectedly. The run may need to be restarted."
        case .stallWatchdog:
            if recoveryAlreadyAttempted {
                return "Codex run stalled again after an automatic recovery attempt. Reconnect required."
            }
            let thresholdSeconds = Int(codexStallWatchdogRecoveryThreshold)
            if thresholdSeconds > 0 {
                return "Codex run stalled (no progress for \(thresholdSeconds)s). Reconnect required."
            }
            return "Codex run stalled. Reconnect required."
        }
    }

    private static func codexStallWatchdogWarningMessage() -> String {
        "Repo Prompt thinks Codex has stalled or timed out. You can stop and resume."
    }

    private func appendCodexStallWatchdogWarningIfNeeded(
        to session: AgentTabSession,
        reason: String
    ) {
        if session.codexWatchdogState.warnedSinceLastProgress {
            session.codexWatchdogState.isPausedAfterWarning = true
            session.codexWatchdogState.requiresColdTeardownOnCancel = true
            logCodex("[AgentModeVM][CodexWatchdog] suppressing duplicate stall warning for tab \(session.tabID) reason=\(reason)")
            return
        }
        session.codexWatchdogState.warnedSinceLastProgress = true
        session.codexWatchdogState.isPausedAfterWarning = true
        session.codexWatchdogState.requiresColdTeardownOnCancel = true
        setRunningStatus(
            Self.codexStallWatchdogWarningMessage(),
            source: .transport,
            session: session,
            urgent: true
        )
        logCodex("[AgentModeVM][CodexWatchdog] recorded non-rendering stall warning for tab \(session.tabID) reason=\(reason)")
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true, scope: .runtimeMetrics)
    }

    private func attemptCodexRecovery(
        session: AgentTabSession,
        trigger: CodexRecoveryTrigger,
        sourceController: (any CodexSessionControlling)?
    ) async -> CodexRecoveryOutcome {
        guard session.selectedAgent == .codexExec, session.runState.isActive else {
            return .skipped
        }
        if trigger == .stallWatchdog {
            guard !hasPendingCodexInteraction(for: session) else {
                return .skipped
            }
        }
        guard let runID = session.runID else {
            if trigger == .stallWatchdog {
                appendCodexStallWatchdogWarningIfNeeded(to: session, reason: "missing-run-id")
                return .skipped
            }
            return .unrecoverable(recoveryFailureMessage(for: trigger))
        }
        if let sourceController {
            guard let activeController = session.codexController,
                  Self.sameCodexControllerInstance(activeController, sourceController)
            else {
                return .skipped
            }
        }
        if trigger == .stallWatchdog {
            let hardToolReasonsBeforeProbe = hardLocalToolLivenessReasons(for: session)
            if !hardToolReasonsBeforeProbe.isEmpty {
                recordCodexWatchdogProgress(for: session)
                logCodex("[AgentModeVM][CodexWatchdog] suppressing watchdog for tab \(session.tabID) while strong local tool liveness remains active reasons=\(hardToolReasonsBeforeProbe.joined(separator: ","))")
                return .skipped
            }
            if let probeController = sourceController ?? session.codexController {
                do {
                    let snapshot = try await probeController.readThreadSnapshot(
                        includeTurns: false,
                        timeout: codexRecoveryProbeTimeout
                    )
                    let hardToolReasonsAfterProbe = hardLocalToolLivenessReasons(for: session)
                    if !hardToolReasonsAfterProbe.isEmpty {
                        recordCodexWatchdogProgress(for: session)
                        logCodex("[AgentModeVM][CodexWatchdog] suppressing watchdog after probe for tab \(session.tabID) because strong local tool liveness became active reasons=\(hardToolReasonsAfterProbe.joined(separator: ","))")
                        return .skipped
                    }
                    if !snapshot.hasActiveTurn {
                        logCodex("[AgentModeVM][CodexWatchdog] stall probe found no active turn for tab \(session.tabID)")
                        let activeTurnID = session.codexAuthoritativeActiveTurn?.turnID
                        if let failure = await probeController.pendingTurnFailure(
                            turnID: activeTurnID
                        ) {
                            if await attemptManagedCodexAuthRecovery(
                                for: session,
                                issue: nil,
                                message: failure.message,
                                sourceController: probeController
                            ) {
                                return .skipped
                            }
                            await finalizeCodexRun(
                                session,
                                turnStatus: .failed,
                                reason: "stall-watchdog-explicit-error",
                                errorMessage: failure.message,
                                notifyOnCompleted: false,
                                deleteDeferredFilesWhenFailureHasNoInFlight: true
                            )
                            await probeController.acknowledgePendingTurnFailure(
                                turnID: activeTurnID,
                                failure: failure
                            )
                            return .skipped
                        }
                        appendCodexStallWatchdogWarningIfNeeded(to: session, reason: "probe-no-active-turn")
                        return .skipped
                    }
                    recordCodexWatchdogProgress(for: session)
                    reconcileCodexReportedWaitingFlags(snapshot.activeFlags, session: session)
                    logCodex("[AgentModeVM][CodexWatchdog] stall probe confirmed active Codex snapshot for tab \(session.tabID) activeFlags=\(snapshot.activeFlags.joined(separator: ",")); treating as liveness")
                    return .skipped
                } catch {
                    let hardToolReasonsAfterFailedProbe = hardLocalToolLivenessReasons(for: session)
                    if !hardToolReasonsAfterFailedProbe.isEmpty {
                        recordCodexWatchdogProgress(for: session)
                        logCodex("[AgentModeVM][CodexWatchdog] suppressing watchdog after failed probe for tab \(session.tabID) because strong local tool liveness remains active reasons=\(hardToolReasonsAfterFailedProbe.joined(separator: ","))")
                        return .skipped
                    }
                    logCodex("[AgentModeVM][CodexWatchdog] stall probe failed for tab \(session.tabID): \(error.localizedDescription)")
                    appendCodexStallWatchdogWarningIfNeeded(to: session, reason: "probe-failed")
                    return .skipped
                }
            }
            appendCodexStallWatchdogWarningIfNeeded(to: session, reason: "missing-probe-controller")
            return .skipped
        }
        if let sourceController {
            guard let activeController = session.codexController,
                  Self.sameCodexControllerInstance(activeController, sourceController)
            else {
                return .skipped
            }
        }

        guard codexRecoveryAttemptedRunIDs.insert(runID).inserted else {
            return .unrecoverable(recoveryFailureMessage(for: trigger, recoveryAlreadyAttempted: true))
        }

        let recoveryStartedAt = Date()
        setRunningStatus("Reconnecting…", source: .reconnect, session: session, urgent: true)
        session.codexLastEventAt = recoveryStartedAt
        recordCodexWatchdogProgress(for: session, at: recoveryStartedAt)
        viewModel?.setAgentRunActive(session.tabID, isActive: true)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)

        let cancelEventTask = switch trigger {
        case .unexpectedStreamEnd:
            false
        case .stallWatchdog:
            true
        }
        let invalidated = invalidateCodexControllerForReconnect(
            session: session,
            expectedController: sourceController,
            source: trigger.reconnectSource,
            cancelEventTask: cancelEventTask,
            preserveRunID: true
        )
        if !invalidated {
            if let sourceController,
               let activeController = session.codexController,
               !Self.sameCodexControllerInstance(activeController, sourceController)
            {
                return .skipped
            }
            _ = markCodexReconnectNeeded(for: session, source: trigger.reconnectSource)
        }

        await ensureCodexNativeSession(
            session: session,
            policyAlreadyInstalled: false,
            allowMissingRolloutFallback: false,
            preserveExistingRunID: true
        )

        guard session.runID == runID,
              session.runState.isActive,
              let recoveredController = session.codexController,
              recoveredController.hasActiveThread
        else {
            let alreadyReportedStartFailure = session.items.last.map {
                $0.kind == .error && Self.isCodexNativeSessionFailureText($0.text)
            } ?? false
            return .unrecoverable(alreadyReportedStartFailure ? nil : recoveryFailureMessage(for: trigger))
        }

        let recoveredAt = Date()
        session.codexLastEventAt = recoveredAt
        recordCodexWatchdogProgress(for: session, at: recoveredAt)
        updateCodexStallWatchdogState(for: session)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        return .recovered
    }

    private func clearCodexPendingAuthRetryTurn(_ session: AgentTabSession) {
        session.codexPendingAuthRetryTurn = nil
    }

    private func clearCodexAuthRecoveryAttempt(for runID: UUID?) {
        guard let runID else { return }
        codexAuthRecoveryAttemptedRunIDs.remove(runID)
    }

    private func applySuccessfulCodexNativeSend(
        for session: AgentTabSession,
        runID: UUID,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?
    ) async {
        setRunningStatus("Waiting for response…", source: .transport, session: session, urgent: true)
        viewModel?.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session: session)
        viewModel?.markAttachmentsConsumed(for: session, reservationID: attachmentReservationID)
        updateCodexStallWatchdogState(for: session)
    }

    @discardableResult
    private func attemptManagedCodexAuthRecovery(
        for session: AgentTabSession,
        issue: CodexNativeSessionController.ServerRequestIssue?,
        message: String,
        sourceController: (any CodexSessionControlling)?
    ) async -> Bool {
        guard session.selectedAgent == .codexExec, session.runState.isActive else { return false }
        guard session.pendingApproval == nil, session.runState != .waitingForApproval else { return false }
        if let issue {
            guard CodexManagedAuthRecoveryClassifier.isRecoverable(issue: issue) else { return false }
        } else {
            guard CodexManagedAuthRecoveryClassifier.isRecoverable(message: message) else { return false }
        }
        guard let runID = session.runID,
              var pendingTurn = session.codexPendingAuthRetryTurn,
              !pendingTurn.retryAttempted,
              codexAuthRecoveryAttemptedRunIDs.insert(runID).inserted
        else {
            return false
        }

        pendingTurn.retryAttempted = true
        session.codexPendingAuthRetryTurn = pendingTurn
        setRunningStatus("Refreshing Codex authentication…", source: .reconnect, session: session, urgent: true)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)

        switch await authRecovery.refreshManagedAccount() {
        case let .requiresUserLogin(guidance):
            _ = markCodexReconnectNeeded(for: session, source: "managed-auth-recovery-required")
            await finalizeCodexRun(
                session,
                turnStatus: .failed,
                reason: "managed-auth-recovery-required",
                errorMessage: guidance,
                notifyOnCompleted: false,
                deleteDeferredFilesWhenFailureHasNoInFlight: true
            )
            return true
        case let .executableUnavailable(message):
            await finalizeCodexRun(
                session,
                turnStatus: .failed,
                reason: "codex-executable-unavailable",
                errorMessage: message,
                notifyOnCompleted: false,
                deleteDeferredFilesWhenFailureHasNoInFlight: true
            )
            return true
        case .recovered:
            break
        }

        _ = invalidateCodexControllerForReconnect(
            session: session,
            expectedController: sourceController,
            source: "managed-auth-recovery"
        )
        await ensureCodexNativeSession(
            session: session,
            policyAlreadyInstalled: false,
            allowMissingRolloutFallback: false
        )
        guard session.runState.isActive,
              let controller = session.codexController,
              controller.hasActiveThread,
              let replayTurn = session.codexPendingAuthRetryTurn
        else {
            _ = markCodexReconnectNeeded(for: session, source: "managed-auth-recovery-no-controller")
            await finalizeCodexRun(
                session,
                turnStatus: .failed,
                reason: "managed-auth-recovery-no-controller",
                errorMessage: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage,
                notifyOnCompleted: false,
                deleteDeferredFilesWhenFailureHasNoInFlight: true
            )
            return true
        }

        guard replayTurn.expectedTurnID == nil else {
            return false
        }
        let usageDispatchTicket = session.registerCodexUsageDispatch(requestedModel: replayTurn.model)
        do {
            _ = try await controller.startUserTurn(
                text: replayTurn.text,
                images: replayTurn.images,
                model: replayTurn.model,
                reasoningEffort: replayTurn.reasoningEffort,
                serviceTier: replayTurn.serviceTier
            )
            session.acceptCodexUsageDispatch(usageDispatchTicket)
            await applySuccessfulCodexNativeSend(
                for: session,
                runID: runID,
                attachments: replayTurn.images,
                attachmentReservationID: replayTurn.attachmentReservationID
            )
            viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
            return true
        } catch {
            settleCodexUsageDispatchAfterStartFailure(
                usageDispatchTicket,
                error: error,
                session: session
            )
            _ = markCodexReconnectNeeded(for: session, source: "managed-auth-recovery-replay-failed")
            await finalizeCodexRun(
                session,
                turnStatus: .failed,
                reason: "managed-auth-recovery-replay-failed",
                errorMessage: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage,
                notifyOnCompleted: false,
                deleteDeferredFilesWhenFailureHasNoInFlight: true
            )
            return true
        }
    }

    @discardableResult
    private func markCodexReconnectNeeded(
        for session: AgentTabSession,
        source: String,
        scheduleSave: Bool = true
    ) -> Bool {
        let wasReconnectNeeded = session.codexNeedsReconnect
        session.codexNeedsReconnect = true
        if !wasReconnectNeeded {
            session.isDirty = true
            if scheduleSave {
                viewModel?.scheduleSave(for: session.tabID)
            }
        }
        logCodex("[AgentModeVM][CodexReconnect] reconnect flag set for tab \(session.tabID) source=\(source) (changed=\(!wasReconnectNeeded))")
        return !wasReconnectNeeded
    }

    private func codexFeatureReconnectSource(
        previous: AgentTabSession.CodexControllerFeatureState?,
        desired: AgentTabSession.CodexControllerFeatureState
    ) -> String {
        guard let previous else { return "feature-state-unknown" }
        if previous.computerUseEnabled != desired.computerUseEnabled {
            return desired.computerUseEnabled ? "computer-use-enabled" : "computer-use-disabled"
        }
        if previous.goalSupportEnabled != desired.goalSupportEnabled {
            return desired.goalSupportEnabled ? "goal-support-enabled" : "goal-support-disabled"
        }
        if previous.reasoningSummariesEnabled != desired.reasoningSummariesEnabled {
            return desired.reasoningSummariesEnabled ? "reasoning-summaries-enabled" : "reasoning-summaries-disabled"
        }
        return "feature-state-unknown"
    }

    @discardableResult
    private func invalidateCodexControllerForReconnect(
        session: AgentTabSession,
        expectedController: (any CodexSessionControlling)?,
        source: String,
        cancelEventTask: Bool = true,
        preserveRunID: Bool = false
    ) -> Bool {
        let controllerToShutdown: (any CodexSessionControlling)?
        if let expectedController {
            guard let activeController = session.codexController,
                  Self.sameCodexControllerInstance(activeController, expectedController)
            else {
                return false
            }
            controllerToShutdown = activeController
        } else {
            controllerToShutdown = session.codexController
        }
        cancelCodexTransportClosedFallback(for: session.tabID)
        markCodexReconnectNeeded(for: session, source: source)
        cancelCodexIdleShutdown(for: session.tabID)
        stopBashLivenessTask(for: session.tabID)
        stopCodexStallWatchdog(for: session.tabID)
        if cancelEventTask {
            session.codexEventTask?.cancel()
        }
        session.codexEventTask = nil
        session.codexEventTaskRunID = nil
        session.codexLastEventAt = nil
        resetCodexWatchdogState(session)
        abandonCodexFallbackQueue(
            session: session,
            reason: "Codex queued follow-up was cancelled because the controller was replaced."
        )
        session.endCodexUsageExecution(reason: "controller-replaced")
        session.codexController = nil
        session.codexControllerPermissionProfile = nil
        session.codexControllerSessionProfile = nil
        session.codexControllerTaskLabelKind = nil
        session.codexControllerWorkspacePath = nil
        session.codexControllerFeatureState = nil
        if !preserveRunID {
            session.runID = nil
        }
        if let controllerToShutdown {
            Task {
                await controllerToShutdown.shutdown()
            }
        }
        return true
    }

    private func scheduleCodexTransportClosedFallback(
        for session: AgentTabSession,
        sourceController: any CodexSessionControlling
    ) {
        let tabID = session.tabID
        let runID = session.runID
        let graceIntervalNanos = UInt64(codexTransportClosedRecoveryGraceInterval * 1_000_000_000)
        codexTransportClosedFallbackTasksByTabID.set(
            tabID,
            task: Task { [weak self, weak session] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: graceIntervalNanos)
                guard !Task.isCancelled else { return }
                guard let session,
                      session.runID == runID,
                      session.selectedAgent == .codexExec,
                      session.runState.isActive,
                      !self.hasPendingCodexInteraction(for: session),
                      let activeController = session.codexController,
                      Self.sameCodexControllerInstance(activeController, sourceController)
                else {
                    return
                }
                logCodex("[AgentModeVM][CodexRecovery] transport-closed grace expired for tab \(tabID); attempting fallback recovery")
                switch await attemptCodexRecovery(
                    session: session,
                    trigger: .unexpectedStreamEnd,
                    sourceController: sourceController
                ) {
                case .recovered:
                    return
                case .skipped:
                    return
                case let .unrecoverable(errorMessage):
                    guard shouldFinalizeAfterRecovery(session: session, expectedRunID: runID, source: "transport-closed-fallback") else { return }
                    await finalizeCodexRun(
                        session,
                        turnStatus: .failed,
                        reason: "transport-closed-fallback",
                        errorMessage: errorMessage,
                        deleteDeferredFilesWhenFailureHasNoInFlight: true
                    )
                }
            }
        )
    }

    private func cancelCodexTransportClosedFallback(for tabID: UUID) {
        codexTransportClosedFallbackTasksByTabID.cancel(tabID)
    }

    private func stopAllCodexTransportClosedFallbackTasks() {
        codexTransportClosedFallbackTasksByTabID.cancelAll()
    }

    private func failCodexStartupForWorkspaceResolution(
        session: AgentTabSession,
        error: Error
    ) async {
        let message = Self.providerStartupFailureMessage(for: error)
        if session.activeRunOwnership != nil, terminalCommitBarrier != nil {
            await finalizeCodexRun(
                session,
                turnStatus: .failed,
                reason: "workspace-resolution",
                errorMessage: message,
                notifyOnCompleted: false,
                deleteDeferredFilesWhenFailureHasNoInFlight: true
            )
            return
        }
        let alreadyReported = session.items.last.map { $0.kind == .error && $0.text == message } ?? false
        if !alreadyReported {
            session.appendItem(AgentChatItem.error(message, sequenceIndex: session.nextSequenceIndex))
        }
        session.runState = .failed
        setRunningStatus(nil, source: nil, session: session)
        viewModel?.setAgentRunActive(session.tabID, isActive: false)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        viewModel?.scheduleSave(for: session.tabID)
    }

    private static func providerStartupFailureMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty
        {
            return description
        }
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? String(describing: error) : description
    }

    package func ensureCodexNativeSession(
        session: AgentTabSession,
        policyAlreadyInstalled: Bool = false,
        allowMissingRolloutFallback: Bool = true,
        deferReconnectForCurrentActiveTurn: Bool = false,
        preserveExistingRunID: Bool = false,
        semanticRunState: AgentSessionRunState? = nil
    ) async {
        guard session.selectedAgent == .codexExec else { return }
        let effectiveRunState = semanticRunState ?? session.runState
        cancelCodexIdleShutdown(for: session.tabID)

        if session.codexNeedsReconnect,
           let activeController = session.codexController,
           activeController.hasActiveThread
        {
            guard !deferReconnectForCurrentActiveTurn else {
                logCodex("[AgentModeVM][CodexReconnect] deferring reconnect for tab \(session.tabID) until the active Codex thread goes idle")
                if let runID = session.runID {
                    await ensureCodexToolTrackingForReadySessionIfNeeded(for: session, runID: runID)
                }
                return
            }
            if invalidateCodexControllerForReconnect(
                session: session,
                expectedController: activeController,
                source: "idle-controller-reconnect"
            ) {
                await ensureCodexNativeSession(
                    session: session,
                    policyAlreadyInstalled: false,
                    allowMissingRolloutFallback: allowMissingRolloutFallback,
                    semanticRunState: semanticRunState
                )
                return
            }
        }

        let currentTaskLabelKind = session.mcpControlContext?.taskLabelKind
        let runtimeWorkspacePath: String?
        do {
            runtimeWorkspacePath = try workspacePathProvider(session)
        } catch {
            await failCodexStartupForWorkspaceResolution(session: session, error: error)
            return
        }
        let wantsGoalSupport = session.profile == .standard && goalSupportEnabled()
        let wantsReasoningSummaries = reasoningSummariesEnabled()
        let codexComputerUseFeatureEnabled = computerUseEnabled()
        let permissionProfileAllowsComputerUse = session.permissionProfile != .mcpSafeDefaults
        if !codexComputerUseFeatureEnabled
            || session.profile == .knowledge
            || !permissionProfileAllowsComputerUse
        {
            session.pendingCodexComputerUseActivation = nil
        }
        let wantsComputerUse = session.profile == .standard
            && permissionProfileAllowsComputerUse
            && session.wantsCodexComputerUseForNextTurn
            && codexComputerUseFeatureEnabled
        let desiredFeatureState = AgentTabSession.CodexControllerFeatureState(
            computerUseEnabled: wantsComputerUse,
            goalSupportEnabled: wantsGoalSupport,
            reasoningSummariesEnabled: wantsReasoningSummaries
        )
        if let existingController = session.codexController,
           session.codexControllerFeatureState != desiredFeatureState
        {
            _ = invalidateCodexControllerForReconnect(
                session: session,
                expectedController: existingController,
                source: codexFeatureReconnectSource(
                    previous: session.codexControllerFeatureState,
                    desired: desiredFeatureState
                )
            )
        }
        if let existingController = session.codexController,
           session.codexControllerWorkspacePath != runtimeWorkspacePath
        {
            _ = invalidateCodexControllerForReconnect(
                session: session,
                expectedController: existingController,
                source: "workspace-path-change"
            )
        }
        if let existingController = session.codexController,
           let existingProfile = session.codexControllerPermissionProfile,
           existingProfile != session.permissionProfile
           || session.codexControllerSessionProfile != session.profile
           || session.codexControllerTaskLabelKind != currentTaskLabelKind
        {
            let source = if existingProfile != session.permissionProfile {
                "permission-profile-change"
            } else if session.codexControllerSessionProfile != session.profile {
                "session-profile-change"
            } else {
                "task-label-kind-change"
            }
            _ = invalidateCodexControllerForReconnect(
                session: session,
                expectedController: existingController,
                source: source
            )
        }

        let runID: UUID = {
            if preserveExistingRunID, let existingRunID = session.runID {
                return existingRunID
            }
            if let existingController = session.codexController {
                _ = existingController
                if let existingRunID = session.runID {
                    return existingRunID
                }
            }
            let freshRunID = UUID()
            session.runID = freshRunID
            return freshRunID
        }()

        func prepareCodexController() -> (any CodexSessionControlling)? {
            if session.codexController == nil {
                let controller = codexControllerFactory(
                    runID,
                    session.tabID,
                    windowID,
                    runtimeWorkspacePath,
                    session.permissionProfile,
                    session.profile,
                    currentTaskLabelKind,
                    wantsComputerUse
                )
                session.codexController = controller
                session.codexControllerPermissionProfile = session.permissionProfile
                session.codexControllerSessionProfile = session.profile
                session.codexControllerTaskLabelKind = currentTaskLabelKind
                session.codexControllerWorkspacePath = runtimeWorkspacePath
                session.codexControllerFeatureState = desiredFeatureState
            }
            guard let controller = session.codexController else { return nil }
            session.beginCodexUsageExecutionIfNeeded()
            controller.ensureEventsStreamReady()
            if session.codexEventTask == nil || session.codexEventTaskRunID != runID {
                session.codexEventTask?.cancel()
                logCodex("[AgentModeVM] Setting up codex event listener task")
                // Capture run identity at task start for stale-task protection.
                let taskRunID = runID
                session.codexEventTaskRunID = taskRunID
                session.codexEventTask = Task { [weak self, weak session] in
                    guard let self, let session else {
                        return
                    }
                    logCodex("[AgentModeVM] Event task: starting to iterate controller.events")
                    for await event in controller.events {
                        guard !Task.isCancelled else { break }
                        // Guard against stale events from a previous run reaching a new session.
                        guard session.runID == taskRunID else { break }
                        guard let activeController = session.codexController,
                              Self.sameCodexControllerInstance(activeController, controller)
                        else {
                            break
                        }
                        logCodex("[AgentModeVM] Event task: received event \(event)")
                        await handleCodexNativeEvent(event, session: session, sourceController: controller)
                    }
                    logCodex("[AgentModeVM] Event task: events stream ended")
                    cancelCodexTransportClosedFallback(for: session.tabID)

                    // --- Stream ended without an explicit terminal event ---
                    // If the task was cancelled (intentional teardown) or run has moved on, do nothing.
                    guard !Task.isCancelled else { return }
                    guard session.runID == taskRunID else { return }

                    guard session.runState.isActive else {
                        guard invalidateCodexControllerForReconnect(
                            session: session,
                            expectedController: controller,
                            source: "unexpected-stream-end",
                            cancelEventTask: false
                        ) else {
                            return
                        }
                        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
                        viewModel?.scheduleSave(for: session.tabID)
                        return
                    }

                    if hasPendingCodexInteraction(for: session) {
                        logCodex("[AgentModeVM][CodexRecovery] events stream ended while Codex interaction is pending for tab \(session.tabID); preserving pending UI and restarting listener")
                        session.codexEventTask = nil
                        session.codexEventTaskRunID = nil
                        viewModel?.reconcileInteractiveRunState(session)
                        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
                        viewModel?.publishMCPStateChange(for: session)
                        await ensureCodexNativeSession(
                            session: session,
                            policyAlreadyInstalled: true,
                            preserveExistingRunID: true
                        )
                        return
                    }

                    switch await attemptCodexRecovery(
                        session: session,
                        trigger: .unexpectedStreamEnd,
                        sourceController: controller
                    ) {
                    case .recovered:
                        return
                    case .skipped:
                        return
                    case let .unrecoverable(errorMessage):
                        guard shouldFinalizeAfterRecovery(session: session, expectedRunID: taskRunID, source: "unexpected-stream-end") else { return }
                        await finalizeCodexRun(
                            session,
                            turnStatus: .failed,
                            reason: "unexpected-stream-end",
                            errorMessage: errorMessage,
                            deleteDeferredFilesWhenFailureHasNoInFlight: true
                        )
                    }
                }
            }
            return controller
        }
        guard prepareCodexController() != nil else { return }

        let hasActiveThread = session.codexController?.hasActiveThread == true

        let requiresTransportStart = !hasActiveThread || session.codexNeedsReconnect
        let shouldBootstrapSessionInitialization = effectiveRunState.isActive || requiresTransportStart
        let hasLiveRunRoute = shouldManageCodexTooling
            ? (viewModel?.hasLiveRunRouteInCurrentMCPServer(runID) ?? false)
            : true
        let shouldForceReconnectForMissingLiveRoute = shouldManageCodexTooling
            && shouldBootstrapSessionInitialization
            && hasActiveThread
            && !requiresTransportStart
            && !hasLiveRunRoute
        if shouldForceReconnectForMissingLiveRoute {
            logCodex("[AgentModeVM][CodexReconnect] forcing reconnect for tab \(session.tabID) because run \(runID) has cached tool policy but no live MCP route")
            let expectedController = session.codexController
            _ = invalidateCodexControllerForReconnect(
                session: session,
                expectedController: expectedController,
                source: "missing-live-route"
            )
            await ensureCodexNativeSession(
                session: session,
                policyAlreadyInstalled: false,
                allowMissingRolloutFallback: allowMissingRolloutFallback,
                semanticRunState: semanticRunState
            )
            return
        }
        let shouldInstallPolicy = shouldManageCodexTooling
            && shouldBootstrapSessionInitialization
            && !policyAlreadyInstalled
            && requiresTransportStart
        let shouldWaitForRouting = requiresTransportStart
        if shouldInstallPolicy {
            // Codex installs MCP policy only at transport start, so a live thread keeps the
            // delegation policy resolved here until its next transport start.
            let delegationPolicy = viewModel?.mcpDelegationRunToolPolicy(for: session) ?? .leaf
            guard let lease = makeCodexRunLease(
                tabID: session.tabID,
                runID: runID,
                sessionProfile: session.profile,
                taskLabelKind: session.mcpControlContext?.taskLabelKind,
                allowsAgentExternalControlTools: delegationPolicy.allowsAgentExternalControlTools,
                additionalRestrictedTools: delegationPolicy.additionalRestrictedTools,
                // The controller prepared above captured its shell-tool launch value; the
                // policy installs at this transport start, so both describe the same process.
                runHasNativeShell: session.profile == .standard
                    && (session.codexController?.runHasNativeShell ?? false)
            ) else { return }
            let acquired = await lease.acquire()
            guard acquired else { return }

            await lease.providerInitializationStarted(provider: AgentProviderKind.codexExec.rawValue)
            await ensureCodexNativeSession(
                session: session,
                policyAlreadyInstalled: true,
                allowMissingRolloutFallback: allowMissingRolloutFallback,
                semanticRunState: semanticRunState
            )

            let providerReady = effectiveRunState.isActive
                && session.codexController?.hasActiveThread == true
            await lease.providerInitializationCompleted(
                provider: AgentProviderKind.codexExec.rawValue,
                outcome: providerReady ? "ready" : (Task.isCancelled ? "cancelled" : "failed")
            )
            guard effectiveRunState.isActive,
                  session.codexController?.hasActiveThread == true
            else {
                // Startup failure path: avoid holding the global gate waiting for
                // routing, which can add visible latency before the next user send.
                await lease.failAndRelease()
                return
            }

            if shouldWaitForRouting {
                _ = await lease.releaseWhenRouted(timeoutMs: codexLeaseRoutingTimeoutMs)
            } else {
                await lease.releaseWithoutRoutingWait()
            }
            return
        }
        guard requiresTransportStart else {
            await ensureCodexToolTrackingForReadySessionIfNeeded(for: session, runID: runID)
            return
        }

        let preferenceGenerationAtStart = session.codexToolPreferencesGeneration
        let selection = effectiveCodexSelection(for: session)
        let basePrompt = SystemPromptService.agentModePrompt(
            agentKind: .codexExec,
            taskLabelKind: session.mcpControlContext?.taskLabelKind,
            codeMapsDisabled: globalCodeMapsDisabled(),
            sessionProfile: session.profile,
            delegationAudience: (viewModel?.mcpDelegationRunToolPolicy(for: session) ?? .leaf).promptAudience
        )
        let existingRef: CodexNativeSessionController.SessionRef? = {
            let threadID = session.codexConversationID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedThreadID = threadID?.isEmpty == false ? threadID : nil
            let rolloutPath = session.codexRolloutPath?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedRolloutPath = rolloutPath?.isEmpty == false ? rolloutPath : nil

            // Native metadata, not transcript contents or a reconnect request, establishes
            // whether a Codex thread already exists. A rollout without its required thread
            // ID deliberately remains an invalid resume reference so the controller reports
            // the persisted-state integrity error before launching Codex.
            guard normalizedThreadID != nil || normalizedRolloutPath != nil else {
                return nil
            }
            return CodexNativeSessionController.SessionRef(
                conversationID: normalizedThreadID ?? "",
                rolloutPath: normalizedRolloutPath,
                model: session.codexModel,
                reasoningEffort: session.codexReasoningEffort
            )
        }()
        // The attempt's own controller: every cleanup below targets it, never whichever controller
        // the tab holds by the time a failure or late success settles.
        let startController = session.codexController
        let attemptedResume = Self.isCodexResumeAttempt(existingRef)
        let startAttempt = CodexStartAttemptIdentity(
            runOwnership: session.activeRunOwnership,
            runID: runID,
            runAttemptGeneration: session.runAttemptGeneration
        )
        do {
            let startResult = try await startCodexNativeSession(
                controller: startController,
                existingRef: existingRef,
                baseInstructions: basePrompt,
                model: selection.model,
                reasoningEffort: selection.reasoningEffort,
                serviceTier: selection.serviceTier,
                allowMissingRolloutFallback: allowMissingRolloutFallback
            )
            // Late success after Stop, or after the slot moved on to another controller: never
            // apply metadata, dispatch, or start tool tracking.
            guard !Task.isCancelled,
                  Self.codexControllerSlotHolds(startController, session: session)
            else {
                discardCancelledCodexNativeSessionStart(
                    session: session,
                    attempt: startAttempt,
                    controller: startController,
                    attemptedResume: attemptedResume,
                    lateSuccess: true,
                    preserveRunID: preserveExistingRunID
                )
                return
            }
            applyCodexNativeSessionStartResult(
                startResult,
                to: session,
                preferenceGenerationAtStart: preferenceGenerationAtStart
            )
            await ensureCodexToolTrackingForReadySessionIfNeeded(for: session, runID: runID)
        } catch {
            // The settled error alone classifies the outcome (never `Task.isCancelled`): a genuine
            // failure that settled before Stop stays visible on its attempt.
            if error is CancellationError {
                discardCancelledCodexNativeSessionStart(
                    session: session,
                    attempt: startAttempt,
                    controller: startController,
                    attemptedResume: attemptedResume,
                    lateSuccess: false,
                    preserveRunID: preserveExistingRunID
                )
                return
            }
            var effectiveError: Error = error
            var failedController = startController
            // A superseded attempt reports its own error without spending the successor run's
            // one authentication recovery or changing its status and reconnect state.
            if session.runState.isActive,
               Self.codexStartAttemptOwnsSessionState(startAttempt, controller: startController, session: session),
               let runID = session.runID,
               CodexManagedAuthRecoveryClassifier.isRecoverable(message: error.localizedDescription),
               codexAuthRecoveryAttemptedRunIDs.insert(runID).inserted
            {
                setRunningStatus("Refreshing Codex authentication…", source: .reconnect, session: session, urgent: true)
                viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
                switch await authRecovery.refreshManagedAccount() {
                case let .requiresUserLogin(guidance):
                    if Self.codexStartAttemptOwnsSessionState(startAttempt, controller: startController, session: session) {
                        _ = markCodexReconnectNeeded(for: session, source: "managed-auth-recovery-required-during-start")
                    }
                    effectiveError = AIProviderError.invalidConfiguration(detail: guidance)
                case let .executableUnavailable(message):
                    effectiveError = AIProviderError.invalidConfiguration(detail: message)
                case .recovered:
                    // A refresh that succeeded after Stop must not start a replacement controller.
                    guard !Task.isCancelled else {
                        discardCancelledCodexNativeSessionStart(
                            session: session,
                            attempt: startAttempt,
                            controller: startController,
                            attemptedResume: attemptedResume,
                            lateSuccess: true,
                            preserveRunID: preserveExistingRunID
                        )
                        return
                    }
                    // Replace only the attempt's own controller; a detached or successor slot
                    // keeps the original auth failure instead.
                    guard let ownedStartController = startController,
                          let activeController = session.codexController,
                          Self.sameCodexControllerInstance(activeController, ownedStartController),
                          Self.codexStartAttemptOwnsSessionState(startAttempt, controller: ownedStartController, session: session)
                    else {
                        break
                    }
                    // The replacement serves the same run: `prepareCodexController()` builds it and
                    // its event listener under the captured run ID, and the send dispatches only
                    // while `session.runID` is still set, so the run ID survives the replacement.
                    _ = invalidateCodexControllerForReconnect(
                        session: session,
                        expectedController: ownedStartController,
                        source: "managed-auth-recovery-during-start",
                        preserveRunID: true
                    )
                    guard let recoveredController = prepareCodexController() else {
                        effectiveError = AIProviderError.invalidConfiguration(detail: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
                        break
                    }
                    failedController = recoveredController
                    do {
                        let recoveredStartResult = try await startCodexNativeSession(
                            controller: recoveredController,
                            existingRef: existingRef,
                            baseInstructions: basePrompt,
                            model: selection.model,
                            reasoningEffort: selection.reasoningEffort,
                            serviceTier: selection.serviceTier,
                            allowMissingRolloutFallback: allowMissingRolloutFallback
                        )
                        guard !Task.isCancelled,
                              Self.codexControllerSlotHolds(recoveredController, session: session)
                        else {
                            discardCancelledCodexNativeSessionStart(
                                session: session,
                                attempt: startAttempt,
                                controller: recoveredController,
                                attemptedResume: attemptedResume,
                                lateSuccess: true,
                                preserveRunID: preserveExistingRunID
                            )
                            return
                        }
                        applyCodexNativeSessionStartResult(
                            recoveredStartResult,
                            to: session,
                            preferenceGenerationAtStart: preferenceGenerationAtStart
                        )
                        await ensureCodexToolTrackingForReadySessionIfNeeded(for: session, runID: runID)
                        return
                    } catch is CancellationError {
                        discardCancelledCodexNativeSessionStart(
                            session: session,
                            attempt: startAttempt,
                            controller: recoveredController,
                            attemptedResume: attemptedResume,
                            lateSuccess: false,
                            preserveRunID: preserveExistingRunID
                        )
                        return
                    } catch {
                        effectiveError = error
                    }
                }
            }
            handleCodexNativeSessionStartFailure(
                effectiveError,
                session: session,
                attempt: startAttempt,
                controller: failedController,
                existingRef: existingRef,
                preserveRunID: preserveExistingRunID
            )
        }
    }

    private enum CodexTurnDispatchPlan {
        case start
        case steer(AgentTabSession.CodexAuthoritativeTurnIdentity)
        case fallback(CodexTurnFallbackDecision)
    }

    private func codexTurnDispatchPlan(
        wasRunAlreadyActive: Bool,
        session: AgentTabSession
    ) -> CodexTurnDispatchPlan {
        guard wasRunAlreadyActive else {
            // Cold send: the resume inside `ensureCodexNativeSession` may have found the thread
            // already running. A replayed `turn/started` installs a real identity; otherwise the
            // resumed-thread marker stands in for the unknown turn.
            if let identity = session.codexAuthoritativeActiveTurn,
               authoritativeCodexTurnIsCurrent(identity, session: session)
            {
                return .fallback(.nonSteerableTurn(kind: identity.turnKind))
            }
            // The resume may have finished before this run had lineage (a slash command or a
            // reconnect outside a run), when the marker could not be installed. Reconcile the
            // controller's retained status now, including for an already-ready controller.
            installResumedActiveThreadMarkerIfNeeded(session: session)
            if let anonymous = session.codexAnonymousActiveTurn,
               anonymousCodexTurnIsCurrent(anonymous, session: session)
            {
                return .fallback(.resumedThreadActive)
            }
            return .start
        }
        guard let identity = session.codexAuthoritativeActiveTurn else {
            if let anonymous = session.codexAnonymousActiveTurn {
                if codexResumedThreadWaitIsPending(behind: anonymous, session: session) {
                    return .fallback(.resumedThreadActive)
                }
                return .fallback(.nonSteerableTurn(kind: anonymous.turnKind))
            }
            return .fallback(.activeWithoutAuthoritativeIdentity)
        }
        guard authoritativeCodexTurnIsCurrent(identity, session: session) else {
            return .fallback(.staleAuthoritativeIdentity)
        }
        if session.codexPendingSteerLifecycleReconciliation?.priorIdentity == identity {
            return .fallback(.staleAuthoritativeIdentity)
        }
        guard identity.turnKind == .user else {
            return .fallback(.nonSteerableTurn(kind: identity.turnKind))
        }
        return .steer(identity)
    }

    /// Names the run-owned MCP scopes that were still active when the steering drain ended.
    /// Counts and ages only; the transcript keeps this as the durable rejection record.
    nonisolated static func activeSendDrainFailureMessage(
        _ blockers: AgentRunWaitDrainBlockers
    ) -> String {
        var parts: [String] = []
        if blockers.childAgentRunWaitCount > 0 {
            var part = blockers.childAgentRunWaitCount == 1
                ? "1 child agent_run.wait scope"
                : "\(blockers.childAgentRunWaitCount) child agent_run.wait scopes"
            if let age = blockers.oldestChildAgentRunWaitAgeSeconds {
                part += " (oldest \(age)s)"
            }
            parts.append(part)
        }
        if blockers.oracleInvocationCount > 0 {
            var part = blockers.oracleInvocationCount == 1
                ? "1 ask_oracle invocation"
                : "\(blockers.oracleInvocationCount) ask_oracle invocations"
            if let age = blockers.oldestOracleInvocationAgeSeconds {
                part += " (oldest \(age)s)"
            }
            parts.append(part)
        }
        guard !parts.isEmpty else {
            return "Codex did not send because run-owned MCP wait scopes did not drain after steering wake."
        }
        return "Codex did not send because \(parts.joined(separator: " and ")) did not finish after steering wake."
    }

    @discardableResult
    func sendCodexNativeMessage(
        session: AgentTabSession,
        text: String,
        attachments: [AgentImageAttachment],
        fallbackContext: AgentTabSession.CodexFallbackSubmissionContext? = nil,
        attachmentReservationID: UUID? = nil,
        policyAlreadyInstalled: Bool = false,
        terminalizeRejectedSend: Bool = true
    ) async -> NativeSendOutcome {
        logCodex("[AgentModeVM] sendCodexNativeMessage called for tab \(session.tabID)")
        // Startup can outlive Stop; these identify the send's own run attempt afterwards, including
        // after a later attempt has begun and already ended.
        let sendRunOwnership = session.activeRunOwnership
        let sendRunAttemptGeneration = session.runAttemptGeneration
        let wasRunAlreadyActive = session.runState.isActive
        let activeSendRunID = wasRunAlreadyActive ? session.runID : nil
        let shouldDrainActiveAgentRunWaits = fallbackContext?.origin.isMCP != true
        if let activeSendRunID, shouldDrainActiveAgentRunWaits {
            let drainOutcome = await activeAgentRunWaitDrain(activeSendRunID, "codex-native-active-send")
            if Task.isCancelled || drainOutcome == .cancelled {
                viewModel?.finalizeAttachmentsForTurn(
                    for: session,
                    reservationID: attachmentReservationID,
                    disposition: .restoreToPending
                )
                return .cancelled
            }
            if case let .timedOut(blockers) = drainOutcome {
                let message = Self.activeSendDrainFailureMessage(blockers)
                logCodex("[AgentModeVM] sendCodexNativeMessage: \(message)")
                viewModel?.finalizeAttachmentsForTurn(
                    for: session,
                    reservationID: attachmentReservationID,
                    disposition: .restoreToPending
                )
                session.appendItem(AgentChatItem.error(message, sequenceIndex: session.nextSequenceIndex))
                viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
                viewModel?.scheduleSave(for: session.tabID)
                return .failed(message: message)
            }
            guard session.runID == activeSendRunID,
                  session.runState.isActive,
                  session.selectedAgent == .codexExec
            else {
                viewModel?.finalizeAttachmentsForTurn(
                    for: session,
                    reservationID: attachmentReservationID,
                    disposition: .restoreToPending
                )
                return .stale(reason: "Codex did not send because the active run changed while waiting for run-owned MCP wait scopes to drain.")
            }
        }
        session.waitingPrompt = nil
        clearCodexNativeToolLiveness(session)
        setRunningStatus("Initializing…", source: .transport, session: session, urgent: true)
        session.runState = .running
        let sendStartedAt = Date()
        session.codexLastEventAt = sendStartedAt
        recordCodexWatchdogProgress(for: session, at: sendStartedAt)
        viewModel?.setAgentRunActive(session.tabID, isActive: true)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        cancelCodexIdleShutdown(for: session.tabID)

        let selection = effectiveCodexSelection(for: session)
        session.codexPendingAuthRetryTurn = .init(
            text: text,
            images: attachments,
            model: selection.model,
            reasoningEffort: selection.reasoningEffort,
            serviceTier: selection.serviceTier,
            attachmentReservationID: attachmentReservationID,
            expectedTurnID: wasRunAlreadyActive
                ? session.codexAuthoritativeActiveTurn?.turnID
                : nil
        )

        await ensureCodexNativeSession(
            session: session,
            policyAlreadyInstalled: policyAlreadyInstalled,
            deferReconnectForCurrentActiveTurn: wasRunAlreadyActive
        )
        // A successor run took the tab while this send's startup was pending (Stop, then a new
        // send, possibly already finished or stopped). Everything below reads the tab's current
        // controller and run, which belong to the successor or to nobody, so leave reconnect,
        // auth-retry, terminal, and dispatch state untouched. Startup already showed any genuine
        // error from this attempt; its attachments were settled by its own terminal commit.
        if Self.codexSendIsSupersededBySuccessor(
            sendRunOwnership: sendRunOwnership,
            sendRunAttemptGeneration: sendRunAttemptGeneration,
            session: session,
            isCancelled: Task.isCancelled
        ) {
            logCodex("[AgentModeVM] sendCodexNativeMessage: a newer run replaced this send during startup; leaving it untouched")
            return .stale(reason: "Codex did not send because a newer run replaced this one while Codex was starting.")
        }
        guard let controller = session.codexController,
              controller.hasActiveThread
        else {
            logCodex("[AgentModeVM] sendCodexNativeMessage: no active thread after ensure, failing run")
            markCodexReconnectNeeded(for: session, source: "send-no-active-thread")
            clearCodexAuthRecoveryAttempt(for: session.runID)
            clearCodexPendingAuthRetryTurn(session)
            let message = "Codex native send failed: session not ready"
            let alreadyReportedStartFailure = session.items.last.map {
                $0.kind == .error && Self.isCodexNativeSessionFailureText($0.text)
            } ?? false
            // Stop cancelled startup before readiness and startup reported nothing, so this is a
            // cancellation, not a send failure (same shape as a cancelled send below). A genuine
            // start failure has already been reported and keeps the failure path.
            if Task.isCancelled, !alreadyReportedStartFailure {
                if terminalizeRejectedSend {
                    await finalizeCodexRun(
                        session,
                        turnStatus: .interrupted,
                        reason: "startup-cancelled",
                        notifyOnCompleted: false
                    )
                } else {
                    viewModel?.finalizeAttachmentsForTurn(
                        for: session,
                        reservationID: attachmentReservationID,
                        disposition: .restoreToPending
                    )
                    setRunningStatus(nil, source: nil, session: session)
                    viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
                }
                return .cancelled
            }
            if terminalizeRejectedSend {
                await finalizeCodexRun(
                    session,
                    turnStatus: .failed,
                    reason: "send-no-active-thread",
                    errorMessage: alreadyReportedStartFailure ? nil : message,
                    notifyOnCompleted: false,
                    deleteDeferredFilesWhenFailureHasNoInFlight: false
                )
            } else {
                viewModel?.finalizeAttachmentsForTurn(
                    for: session,
                    reservationID: attachmentReservationID,
                    disposition: .restoreToPending
                )
                if !alreadyReportedStartFailure {
                    session.appendItem(AgentChatItem.error(message, sequenceIndex: session.nextSequenceIndex))
                }
                setRunningStatus(nil, source: nil, session: session)
                viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
                viewModel?.scheduleSave(for: session.tabID)
            }
            return .failed(message: message)
        }

        guard let sendRunID = session.runID else {
            clearCodexPendingAuthRetryTurn(session)
            let message = "Codex native send failed: run not ready"
            if terminalizeRejectedSend {
                await finalizeCodexRun(
                    session,
                    turnStatus: .failed,
                    reason: "send-no-run",
                    errorMessage: message,
                    notifyOnCompleted: false
                )
            } else {
                viewModel?.finalizeAttachmentsForTurn(
                    for: session,
                    reservationID: attachmentReservationID,
                    disposition: .restoreToPending
                )
                session.appendItem(AgentChatItem.error(message, sequenceIndex: session.nextSequenceIndex))
                setRunningStatus(nil, source: nil, session: session)
                viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
                viewModel?.scheduleSave(for: session.tabID)
            }
            return .failed(message: message)
        }

        let dispatchPlan = codexTurnDispatchPlan(
            wasRunAlreadyActive: wasRunAlreadyActive,
            session: session
        )
        let sendThreadID = session.codexConversationID
        if case let .fallback(decision) = dispatchPlan {
            clearCodexPendingAuthRetryTurn(session)
            return enqueueCodexFallback(
                session: session,
                context: fallbackContext,
                text: text,
                images: attachments,
                selection: selection,
                attachmentReservationID: attachmentReservationID,
                reason: decision,
                controller: controller
            )
        }

        // Only `turn/start` dispatches register accounting work; `turn/steer` joins the already
        // dispatched turn and never produces a second `turn/started`, so it registers nothing.
        var usageDispatchTicket: CodexDispatchTicket?
        do {
            setRunningStatus("Sending message…", source: .transport, session: session, urgent: true)
            switch dispatchPlan {
            case .start:
                beginTrackedCodexUserTurn(session)
                logCodex("[AgentModeVM] sendCodexNativeMessage: calling controller.startUserTurn")
                usageDispatchTicket = session.registerCodexUsageDispatch(requestedModel: selection.model)
                _ = try await controller.startUserTurn(
                    text: text,
                    images: attachments,
                    model: selection.model,
                    reasoningEffort: selection.reasoningEffort,
                    serviceTier: selection.serviceTier
                )
                session.acceptCodexUsageDispatch(usageDispatchTicket)
            case let .steer(identity):
                logCodex("[AgentModeVM] sendCodexNativeMessage: calling controller.steerUserTurn expectedTurnID=\(identity.turnID)")
                do {
                    let receipt = try await controller.steerUserTurn(
                        text: text,
                        images: attachments,
                        expectedTurnID: identity.turnID
                    )
                    if receipt.acceptedTurnID != identity.turnID {
                        await reconcileAcceptedCodexSteerMismatch(
                            from: identity,
                            acceptedTurnID: receipt.acceptedTurnID,
                            controller: controller,
                            session: session
                        )
                    }
                } catch let mismatch as CodexTurnSteerError {
                    guard case let .expectedTurnMismatch(expectedTurnID, actualTurnID, failure) = mismatch,
                          let actualTurnID = actualTurnID?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !actualTurnID.isEmpty,
                          session.codexAuthoritativeActiveTurn == identity,
                          authoritativeCodexTurnIsCurrent(identity, session: session),
                          session.codexController.map(ObjectIdentifier.init) == ObjectIdentifier(controller)
                    else {
                        throw mismatch
                    }
                    logCodex(
                        "[AgentModeVM] sendCodexNativeMessage: retrying turn/steer once expected=\(expectedTurnID) actual=\(actualTurnID)"
                    )
                    let reconciliation = AgentTabSession.CodexPendingSteerLifecycleReconciliation(
                        priorIdentity: identity,
                        acceptedDispatchTurnID: actualTurnID
                    )
                    session.codexPendingSteerLifecycleReconciliation = reconciliation
                    do {
                        let receipt = try await controller.steerUserTurn(
                            text: text,
                            images: attachments,
                            expectedTurnID: actualTurnID
                        )
                        guard receipt.acceptedTurnID == actualTurnID else {
                            throw CodexTurnSteerError.expectedTurnMismatch(
                                expectedTurnID: expectedTurnID,
                                actualTurnID: actualTurnID,
                                failure: failure
                            )
                        }
                        guard await controller.prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
                            expectedCurrentTurnID: identity.turnID,
                            acceptedDispatchTurnID: actualTurnID
                        ) else {
                            throw CodexTurnSteerError.expectedTurnMismatch(
                                expectedTurnID: expectedTurnID,
                                actualTurnID: actualTurnID,
                                failure: failure
                            )
                        }
                        if session.codexPendingSteerLifecycleReconciliation == reconciliation,
                           session.codexAuthoritativeActiveTurn != identity
                        {
                            session.codexPendingSteerLifecycleReconciliation = nil
                        }
                    } catch {
                        if session.codexPendingSteerLifecycleReconciliation == reconciliation {
                            session.codexPendingSteerLifecycleReconciliation = nil
                        }
                        throw CodexTurnSteerError.expectedTurnMismatch(
                            expectedTurnID: expectedTurnID,
                            actualTurnID: actualTurnID,
                            failure: failure
                        )
                    }
                }
            case .fallback:
                preconditionFailure("Fallback dispatch plans return before provider dispatch")
            }
            guard session.runID == sendRunID,
                  session.runState.isActive,
                  let activeController = session.codexController,
                  Self.sameCodexControllerInstance(activeController, controller)
            else {
                if case let .mcp(attemptID) = fallbackContext?.origin {
                    if sendThreadID == session.codexConversationID {
                        removeQueuedCodexFallbackForDeliveredAttempt(attemptID, session: session)
                    } else {
                        logCodex("[AgentModeVM] sendCodexNativeMessage: keeping queued fallback after stale-controller acceptance because the accepted Codex thread is no longer the persisted session thread")
                    }
                    let state: CodexSteerAckTracker.TerminalState = switch dispatchPlan {
                    case .start:
                        .startAccepted
                    case .steer:
                        .steerAccepted
                    case .fallback:
                        preconditionFailure("Fallback dispatch plans return before provider dispatch")
                    }
                    session.codexSteerAckTracker.resolve(attemptID: attemptID, state: state)
                } else if fallbackContext?.origin == .manual,
                          session.mcpControlContext != nil
                {
                    await viewModel?.signalCodexInstructionDelivered(for: session)
                }
                logCodex("[AgentModeVM] sendCodexNativeMessage: provider accepted typed dispatch after the local run/controller changed")
                return .sent
            }
            logCodex("[AgentModeVM] sendCodexNativeMessage: typed turn dispatch returned successfully")
            await applySuccessfulCodexNativeSend(
                for: session,
                runID: sendRunID,
                attachments: attachments,
                attachmentReservationID: attachmentReservationID
            )
            if case let .mcp(attemptID) = fallbackContext?.origin {
                removeQueuedCodexFallbackForDeliveredAttempt(attemptID, session: session)
                let state: CodexSteerAckTracker.TerminalState = switch dispatchPlan {
                case .start:
                    .startAccepted
                case .steer:
                    .steerAccepted
                case .fallback:
                    preconditionFailure("Fallback dispatch plans return before provider dispatch")
                }
                session.codexSteerAckTracker.resolve(attemptID: attemptID, state: state)
            } else if fallbackContext?.origin == .manual,
                      session.mcpControlContext != nil
            {
                await viewModel?.signalCodexInstructionDelivered(for: session)
            }
            return .sent
        } catch let steerError as CodexTurnSteerError {
            session.withdrawCodexUsageDispatch(usageDispatchTicket)
            session.codexPendingTurnKind = nil
            guard session.runID == sendRunID,
                  let activeController = session.codexController,
                  Self.sameCodexControllerInstance(activeController, controller)
            else {
                return .stale(reason: "Codex ignored a late steer rejection because the active run/controller changed.")
            }
            let decision: CodexTurnFallbackDecision = switch steerError {
            case let .noActiveTurn(failure):
                .noActiveTurn(failure: failure)
            case let .expectedTurnMismatch(expectedTurnID, actualTurnID, failure):
                .expectedTurnMismatch(
                    expectedTurnID: expectedTurnID,
                    actualTurnID: actualTurnID,
                    failure: failure
                )
            case let .activeTurnNotSteerable(turnKind, failure):
                .activeTurnNotSteerable(turnKind: turnKind, failure: failure)
            }
            clearCodexPendingAuthRetryTurn(session)
            return enqueueCodexFallback(
                session: session,
                context: fallbackContext,
                text: text,
                images: attachments,
                selection: selection,
                attachmentReservationID: attachmentReservationID,
                reason: decision,
                controller: controller
            )
        } catch {
            // Only a proven local preflight failure can clear an unaccepted exact ticket.
            // JSON-RPC request failures, cancellation, lost receipts and other uncertain outcomes
            // remain covered until a lifecycle completion or execution teardown proves their state.
            settleCodexUsageDispatchAfterStartFailure(
                usageDispatchTicket,
                error: error,
                session: session
            )
            session.codexPendingTurnKind = nil
            guard session.runID == sendRunID,
                  let activeController = session.codexController,
                  Self.sameCodexControllerInstance(activeController, controller)
            else {
                logCodex("[AgentModeVM] sendCodexNativeMessage: ignoring late send error for stale controller - \(error.localizedDescription)")
                return .stale(reason: "Codex ignored a late send failure because the active run/controller changed.")
            }
            if error is CancellationError {
                clearCodexPendingAuthRetryTurn(session)
                if terminalizeRejectedSend {
                    await finalizeCodexRun(
                        session,
                        turnStatus: .interrupted,
                        reason: "send-cancelled",
                        notifyOnCompleted: false
                    )
                } else {
                    viewModel?.finalizeAttachmentsForTurn(
                        for: session,
                        reservationID: attachmentReservationID,
                        disposition: .restoreToPending
                    )
                    setRunningStatus(nil, source: nil, session: session)
                    viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
                }
                return .cancelled
            }
            logCodex("[AgentModeVM] sendCodexNativeMessage: error - \(error)")
            if await attemptManagedCodexAuthRecovery(
                for: session,
                issue: nil,
                message: error.localizedDescription,
                sourceController: controller
            ) {
                return session.runState.isActive
                    ? .sent
                    : .failed(message: "Codex native send failed after managed authentication recovery.")
            }
            markCodexReconnectNeeded(for: session, source: "send-error")
            clearCodexAuthRecoveryAttempt(for: session.runID)
            clearCodexPendingAuthRetryTurn(session)
            let message = "Codex native send failed: \(error.localizedDescription)"
            if terminalizeRejectedSend {
                await finalizeCodexRun(
                    session,
                    turnStatus: .failed,
                    reason: "send-error",
                    errorMessage: message,
                    notifyOnCompleted: false
                )
            } else {
                viewModel?.finalizeAttachmentsForTurn(
                    for: session,
                    reservationID: attachmentReservationID,
                    disposition: .restoreToPending
                )
                session.appendItem(AgentChatItem.error(message, sequenceIndex: session.nextSequenceIndex))
                setRunningStatus(nil, source: nil, session: session)
                viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
                viewModel?.scheduleSave(for: session.tabID)
            }
            return .failed(message: message)
        }
    }

    private func ensureCodexToolTrackingForReadySessionIfNeeded(for session: AgentTabSession, runID: UUID) async {
        #if DEBUG
            testReadySessionToolTrackingRequestsByTabID[session.tabID, default: 0] += 1
        #endif
        guard shouldManageCodexTooling else { return }
        guard session.selectedAgent == .codexExec else { return }
        guard session.runID == runID else { return }
        guard session.codexController?.hasActiveThread == true else { return }
        await ensureCodexToolTrackingIfNeeded(for: session, runID: runID)
    }

    func ensureCodexToolTrackingIfNeeded(for session: AgentTabSession, runID: UUID) async {
        guard shouldManageCodexTooling else { return }
        let controller = toolTrackingByTabID[session.tabID] ?? {
            let c = AgentToolTrackingController(mcpHost: mcpHost)
            toolTrackingByTabID[session.tabID] = c
            return c
        }()
        await controller.startTracking(
            runID: runID,
            clientNameHint: AgentProviderKind.codexExec.mcpClientNameHint,
            onCalled: { [weak self, weak session] invocationID, toolName, args in
                guard let self, let session else { return }
                handleCodexToolCall(invocationID: invocationID, toolName: toolName, args: args, session: session)
            },
            onCompleted: { [weak self, weak session] invocationID, toolName, args, resultJSON, isError in
                guard let self, let session else { return }
                handleCodexToolResult(invocationID: invocationID, toolName: toolName, args: args, resultJSON: resultJSON, isError: isError, session: session)
            }
        )
    }

    private func handleCodexToolCall(
        invocationID: UUID?,
        toolName: String,
        args: [String: Value]?,
        session: AgentTabSession
    ) {
        guard isRepoPromptTrackerToolName(toolName) else { return }
        logCodexTranscriptOrdering(
            "tracker toolCall received",
            session: session,
            extra: "tool=\(toolName) invocationID=\(invocationID?.uuidString ?? "nil")"
        )
        recordCodexWatchdogProgress(for: session)
        updateCodexStallWatchdogState(for: session)
        guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else {
            flushPendingAssistantDelta(session)
            return
        }
        sealAssistantBoundary(session)
        let argsJSON = Self.encodeArgsToJSON(args)
        let toolItem = AgentChatItem.toolCall(
            name: toolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            sequenceIndex: session.nextSequenceIndex
        )
        session.appendItem(toolItem)
        viewModel?.requestUIRefresh(tabID: session.tabID)
    }

    private func handleCodexToolResult(
        invocationID: UUID?,
        toolName: String,
        args: [String: Value]?,
        resultJSON: String,
        isError: Bool,
        session: AgentTabSession
    ) {
        guard isRepoPromptTrackerToolName(toolName) else { return }
        logCodexTranscriptOrdering(
            "tracker toolResult received",
            session: session,
            extra: "tool=\(toolName) invocationID=\(invocationID?.uuidString ?? "nil") isError=\(isError)"
        )
        recordCodexWatchdogProgress(for: session)
        updateCodexStallWatchdogState(for: session)
        guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else {
            flushPendingAssistantDelta(session)
            return
        }
        sealAssistantBoundary(session)
        let argsJSON = Self.encodeArgsToJSON(args)
        let canonicalToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(toolName) ?? toolName
        var correlationPath = "none"
        var inspectedItemCount = 0
        let matchingIndex: Int? = {
            func namesMatch(_ candidate: String?) -> Bool {
                (MCPIntegrationHelper.canonicalRepoPromptToolName(candidate) ?? candidate) == canonicalToolName
            }
            if let invocationID {
                let indexedCandidates = session.indexedToolItemIndices(invocationID: invocationID)
                inspectedItemCount += indexedCandidates.count
                if let indexedMatch = indexedCandidates.last(where: { namesMatch(session.items[$0].toolName) }) {
                    correlationPath = "invocation_id"
                    return indexedMatch
                }
                let fallback = session.activeTurnToolItemIndices(where: {
                    $0.toolInvocationID == invocationID && namesMatch($0.toolName)
                })
                inspectedItemCount += fallback.scannedItemCount
                correlationPath = fallback.lastIndex == nil ? "none" : "invocation_id_active_turn_scan"
                return fallback.lastIndex
            }
            let fallbackSignature = AgentTabSession.canonicalToolInvocationSignature(
                toolName: canonicalToolName,
                argsJSON: argsJSON
            )
            let signatureCandidates = session.indexedToolItemIndices(signature: fallbackSignature)
            inspectedItemCount += signatureCandidates.count
            if let argsMatchedIndex = signatureCandidates.last(where: {
                session.items[$0].toolInvocationID == nil && namesMatch(session.items[$0].toolName)
            }) {
                correlationPath = "signature"
                return argsMatchedIndex
            }
            let signatureFallback = session.activeTurnToolItemIndices(where: {
                $0.toolInvocationID == nil
                    && namesMatch($0.toolName)
                    && AgentTabSession.canonicalToolInvocationSignature(
                        toolName: $0.toolName,
                        argsJSON: $0.toolArgsJSON
                    ) == fallbackSignature
            })
            inspectedItemCount += signatureFallback.scannedItemCount
            if let argsMatchedIndex = signatureFallback.lastIndex {
                correlationPath = "signature_active_turn_scan"
                return argsMatchedIndex
            }
            let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(canonicalToolName)
            let nameCandidates = session.indexedNilInvocationToolItemIndices(
                normalizedToolName: normalizedToolName
            )
            inspectedItemCount += nameCandidates.count
            if let nameMatchedIndex = nameCandidates.last(where: { namesMatch(session.items[$0].toolName) }) {
                correlationPath = "name_fallback"
                return nameMatchedIndex
            }
            let nameFallback = session.activeTurnToolItemIndices(where: {
                $0.toolInvocationID == nil && namesMatch($0.toolName)
            })
            inspectedItemCount += nameFallback.scannedItemCount
            correlationPath = nameFallback.lastIndex == nil ? "none" : "name_active_turn_scan"
            return nameFallback.lastIndex
        }()
        MCPToolObserverAttributionContext.record(
            correlationPath: correlationPath,
            scannedItemCount: inspectedItemCount
        )
        if let index = matchingIndex {
            // Prevent apply_patch terminal → running regression.
            if Self.shouldIgnoreApplyPatchRunningRegression(
                existingResultJSON: session.items[index].toolResultJSON,
                incomingResultJSON: resultJSON,
                toolName: toolName
            ) {
                return
            }
            var updated = session.items[index]
            updated.kind = .toolResult
            updated.toolResultJSON = resultJSON
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            updated.toolIsError = isError
            updated.text = resultJSON
            session.replaceItem(at: index, with: updated)
        } else {
            let toolResultItem = AgentChatItem.toolResult(
                name: toolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: resultJSON,
                isError: isError,
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(toolResultItem)
        }
        reconcileCodexCommandExecutionRunningUpdate(
            toolName: toolName,
            argsJSON: argsJSON,
            resultJSON: resultJSON,
            isError: isError,
            session: session
        )
        viewModel?.requestUIRefresh(tabID: session.tabID)
    }

    /// Returns `true` when an incoming apply_patch running payload should be ignored
    /// because the existing transcript item already holds a terminal result.
    private static func shouldIgnoreApplyPatchRunningRegression(
        existingResultJSON: String?,
        incomingResultJSON: String,
        toolName: String
    ) -> Bool {
        let normalized = Self.normalizedExternalToolName(toolName)
        guard normalized == "apply_patch" else { return false }
        guard CodexNativeSessionController.applyPatchResultIndicatesTerminal(raw: existingResultJSON) else {
            return false
        }
        return CodexNativeSessionController.applyPatchResultIndicatesRunning(raw: incomingResultJSON)
    }

    private static func encodeArgsToJSON(_ args: [String: Value]?) -> String? {
        guard let args, !args.isEmpty else { return nil }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(args)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func enqueueAssistantDelta(
        _ delta: String,
        scope explicitScope: CodexNativeSessionController.ItemScope? = nil,
        session: AgentTabSession
    ) {
        let effectiveScope = explicitScope ?? session.pendingCodexAssistantScope
        if let pendingScope = session.pendingCodexAssistantScope,
           let effectiveScope,
           pendingScope != effectiveScope
        {
            sealAssistantBoundary(session)
        } else if explicitScope != nil,
                  session.pendingCodexAssistantScope == nil,
                  !session.pendingAssistantDelta.isEmpty
                  || session.items.last.map({ $0.kind == .assistant && $0.isStreaming }) == true
        {
            sealAssistantBoundary(session)
        }
        if let effectiveScope {
            session.pendingCodexAssistantScope = effectiveScope
        }
        let existingAssistantText: String = {
            if let effectiveScope,
               let rowID = session.codexAssistantRowIDByScope[effectiveScope],
               let row = session.items.first(where: { $0.id == rowID })
            {
                return row.text
            }
            guard let lastItem = session.items.last, lastItem.kind == .assistant, lastItem.isStreaming else {
                return ""
            }
            return lastItem.text
        }()
        let normalizedDelta = CodexProviderHelpers.normalizedAssistantDeltaForAppend(
            existingText: existingAssistantText + session.pendingAssistantDelta,
            delta: delta
        )
        session.pendingAssistantDelta += normalizedDelta
        guard session.assistantDeltaFlushTask == nil else { return }
        session.assistantDeltaTaskGeneration &+= 1
        let taskGeneration = session.assistantDeltaTaskGeneration
        let assistantDeltaFlushDelayNanos = assistantDeltaFlushDelayNanos
        session.assistantDeltaFlushTask = Task { @MainActor [weak self, session] in
            do {
                try await Task.sleep(nanoseconds: assistantDeltaFlushDelayNanos)
            } catch {
                return
            }
            guard session.assistantDeltaTaskGeneration == taskGeneration,
                  Self.flushPendingAssistantDeltaState(session)
            else { return }
            session.assistantDeltaFlushGeneration &+= 1
            self?.viewModel?.requestAssistantPresentationRefresh(
                session: session,
                sourceItemsRevision: session.sourceItemsRevision,
                flushGeneration: session.assistantDeltaFlushGeneration
            )
        }
    }

    private static func clearPendingAssistantDeltaState(_ session: AgentTabSession) {
        session.pendingAssistantDelta = ""
        session.assistantDeltaTaskGeneration &+= 1
        session.assistantDeltaFlushTask?.cancel()
        session.assistantDeltaFlushTask = nil
    }

    @discardableResult
    private static func flushPendingAssistantDeltaState(_ session: AgentTabSession) -> Bool {
        guard !session.pendingAssistantDelta.isEmpty else { return false }
        let delta = session.pendingAssistantDelta
        let scope = session.pendingCodexAssistantScope
        clearPendingAssistantDeltaState(session)
        applyAssistantDelta(delta, scope: scope, session: session)
        return true
    }

    private func clearPendingAssistantDelta(_ session: AgentTabSession) {
        Self.clearPendingAssistantDeltaState(session)
        session.pendingCodexAssistantScope = nil
    }

    #if DEBUG
        func test_enqueueAssistantDelta(_ delta: String, session: AgentTabSession) {
            enqueueAssistantDelta(delta, session: session)
        }

        func test_flushPendingAssistantDelta(_ session: AgentTabSession) {
            flushPendingAssistantDelta(session)
        }
    #endif

    private func flushPendingAssistantDelta(_ session: AgentTabSession) {
        guard !session.pendingAssistantDelta.isEmpty || session.assistantDeltaFlushTask != nil else { return }
        guard Self.flushPendingAssistantDeltaState(session) else {
            Self.clearPendingAssistantDeltaState(session)
            return
        }
        session.assistantDeltaFlushGeneration &+= 1
        viewModel?.requestAssistantPresentationRefresh(
            session: session,
            sourceItemsRevision: session.sourceItemsRevision,
            flushGeneration: session.assistantDeltaFlushGeneration
        )
    }

    @discardableResult
    private static func endActiveAssistantSegmentState(_ session: AgentTabSession) -> Bool {
        session.endStreamingAssistantRows()
    }

    private func sealAssistantBoundary(_ session: AgentTabSession) {
        let didFlush = Self.flushPendingAssistantDeltaState(session)
        let didSeal = Self.endActiveAssistantSegmentState(session)
        session.pendingCodexAssistantScope = nil
        guard didFlush || didSeal else { return }
        session.assistantDeltaFlushGeneration &+= 1
        viewModel?.requestAssistantPresentationRefresh(
            session: session,
            sourceItemsRevision: session.sourceItemsRevision,
            flushGeneration: session.assistantDeltaFlushGeneration
        )
    }

    private static func applyAssistantDelta(
        _ delta: String,
        scope: CodexNativeSessionController.ItemScope?,
        session: AgentTabSession
    ) {
        let targetIndex: Int? = {
            if let scope,
               let rowID = session.codexAssistantRowIDByScope[scope],
               let index = session.items.firstIndex(where: { $0.id == rowID })
            {
                return index
            }
            guard let index = session.items.indices.last,
                  session.items[index].kind == .assistant,
                  session.items[index].isStreaming
            else {
                return nil
            }
            return index
        }()
        if let targetIndex {
            session.mutateItem(at: targetIndex) { item in
                item.text += CodexProviderHelpers.normalizedAssistantDeltaForAppend(
                    existingText: item.text,
                    delta: delta
                )
            }
            if let scope {
                session.codexAssistantRowIDByScope[scope] = session.items[targetIndex].id
            }
        } else {
            guard AgentDisplayableText.hasDisplayableBody(delta) else { return }
            var assistantItem = AgentChatItem.assistant(delta, sequenceIndex: session.nextSequenceIndex)
            assistantItem.isStreaming = true
            session.appendItem(assistantItem)
            if let scope {
                session.codexAssistantRowIDByScope[scope] = assistantItem.id
            }
        }
    }

    private func reconcileAssistantCompletion(
        _ payload: CodexNativeSessionController.AssistantCompletionPayload,
        session: AgentTabSession
    ) {
        if session.pendingCodexAssistantScope == payload.scope {
            flushPendingAssistantDelta(session)
            session.pendingCodexAssistantScope = nil
        } else if !session.pendingAssistantDelta.isEmpty
            || session.assistantDeltaFlushTask != nil
            || session.items.last.map({ $0.kind == .assistant && $0.isStreaming }) == true
        {
            sealAssistantBoundary(session)
        }

        var didChange = false
        if let rowID = session.codexAssistantRowIDByScope[payload.scope],
           let index = session.items.firstIndex(where: { $0.id == rowID })
        {
            if !AgentDisplayableText.hasDisplayableBody(payload.text) {
                _ = session.removeItem(at: index)
                session.codexAssistantRowIDByScope.removeValue(forKey: payload.scope)
                didChange = true
            } else {
                let existingText = session.items[index].text
                let existingUTF8 = existingText.utf8
                let completedUTF8 = payload.text.utf8
                var reconciledText = existingText
                if !completedUTF8.elementsEqual(existingUTF8) {
                    if completedUTF8.starts(with: existingUTF8) {
                        reconciledText += String(decoding: completedUTF8.dropFirst(existingUTF8.count), as: UTF8.self)
                    } else {
                        reconciledText = payload.text
                    }
                }
                if reconciledText != existingText || session.items[index].isStreaming {
                    session.mutateItem(at: index) { item in
                        item.text = reconciledText
                        item.isStreaming = false
                    }
                    didChange = true
                }
            }
        } else if AgentDisplayableText.hasDisplayableBody(payload.text) {
            var assistantItem = AgentChatItem.assistant(
                payload.text,
                sequenceIndex: session.nextSequenceIndex
            )
            assistantItem.isStreaming = false
            session.appendItem(assistantItem)
            session.codexAssistantRowIDByScope[payload.scope] = assistantItem.id
            didChange = true
        }

        guard didChange else { return }
        session.assistantDeltaFlushGeneration &+= 1
        viewModel?.requestAssistantPresentationRefresh(
            session: session,
            sourceItemsRevision: session.sourceItemsRevision,
            flushGeneration: session.assistantDeltaFlushGeneration
        )
    }

    private func setRunningStatus(
        _ text: String?,
        source: AgentTabSession.RunningStatusSource?,
        session: AgentTabSession,
        urgent: Bool = false
    ) {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (normalized?.isEmpty == false) ? normalized : nil
        let normalizedSource = value == nil ? nil : source
        guard session.runningStatusText != value || session.runningStatusSource != normalizedSource else { return }
        session.runningStatusText = value
        session.runningStatusSource = normalizedSource
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: urgent)
    }

    private static func reasoningAggregationKey(
        for payload: CodexNativeSessionController.ReasoningDeltaPayload
    ) -> String? {
        let trimmedItemID = payload.itemID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let itemID = trimmedItemID, !itemID.isEmpty, let index = payload.index {
            return "reasoning:\(itemID):\(index)"
        }
        if let itemID = trimmedItemID, !itemID.isEmpty {
            return itemID
        }
        if let groupID = payload.groupID?.trimmingCharacters(in: .whitespacesAndNewlines), !groupID.isEmpty {
            return normalizedReasoningGroupID(groupID) ?? groupID
        }
        if let index = payload.index {
            return "reasoning-\(index)"
        }
        return nil
    }

    private static func normalizedReasoningGroupID(_ groupID: String) -> String? {
        for prefix in ["summary:", "text:"] where groupID.hasPrefix(prefix) {
            let suffix = groupID.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !suffix.isEmpty else { return nil }
            return "reasoning:\(suffix)"
        }
        return nil
    }

    private static func latestReasoningSummaryTitle(
        from markdown: String,
        maxTitleLength: Int = 80
    ) -> String? {
        let normalized = ReasoningTextFormatter.normalize(markdown)
        var latestTitle: String?
        for line in normalized.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("**"), trimmed.hasSuffix("**"), trimmed.count > 4 else {
                continue
            }
            let title = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= maxTitleLength else {
                continue
            }
            latestTitle = title
        }
        return latestTitle
    }

    private static func hasPendingReasoningTitle(_ markdown: String) -> Bool {
        guard let firstLine = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else {
            return false
        }
        return firstLine.hasPrefix("**") && !firstLine.hasSuffix("**")
    }

    private static func parseReasoningSummary(
        from markdown: String,
        maxTitleLength: Int = 80
    ) -> (title: String, bodyMarkdown: String?)? {
        let normalized = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let lines = normalized.components(separatedBy: .newlines)
        guard let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        let firstLine = lines[firstIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard firstLine.hasPrefix("**"), firstLine.hasSuffix("**"), firstLine.count > 4 else { return nil }
        let rawTitle = String(firstLine.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty, rawTitle.count <= maxTitleLength else { return nil }
        let remainingLines = Array(lines[(firstIndex + 1)...])
        let body = remainingLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (rawTitle, body.isEmpty ? nil : body)
    }

    private static func shouldUseReasoningSummaryAsStatus(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return false }
        guard let firstWord = trimmed.split(whereSeparator: \.isWhitespace).first else { return false }
        let normalizedFirstWord = firstWord
            .trimmingCharacters(in: CharacterSet(charactersIn: ":.,!?()[]{}\"'“”‘’"))
            .lowercased()
        return normalizedFirstWord.hasSuffix("ing")
    }

    private static func renderedReasoningMarkdown(
        for segment: AgentTabSession.CodexReasoningSegmentState
    ) -> String? {
        let summary = segment.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = segment.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty,
           let parsed = parseReasoningSummary(from: summary),
           parsed.bodyMarkdown == nil,
           body.isEmpty
        {
            return nil
        }
        if !summary.isEmpty, hasPendingReasoningTitle(summary), body.isEmpty {
            return nil
        }
        let parts = [summary, body].filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    @discardableResult
    private func upsertReasoningTranscript(
        for key: String,
        session: AgentTabSession
    ) -> Bool {
        guard var segment = session.codexReasoningSegmentsByKey[key] else { return false }
        guard let markdown = Self.renderedReasoningMarkdown(for: segment) else {
            session.codexReasoningSegmentsByKey[key] = segment
            return false
        }
        if let transcriptItemID = segment.transcriptItemID,
           let index = session.items.firstIndex(where: { $0.id == transcriptItemID })
        {
            guard session.items[index].text != markdown || !session.items[index].isStreaming else {
                return false
            }
            session.mutateItem(at: index) { item in
                item.text = markdown
                item.isStreaming = true
            }
            session.codexReasoningSegmentsByKey[key] = segment
            return true
        }
        var thinkingItem = AgentChatItem.thinking(markdown, sequenceIndex: session.nextSequenceIndex)
        thinkingItem.isStreaming = true
        session.appendItem(thinkingItem)
        segment.transcriptItemID = thinkingItem.id
        session.codexReasoningSegmentsByKey[key] = segment
        return true
    }

    private func applyReasoningDelta(
        _ payload: CodexNativeSessionController.ReasoningDeltaPayload,
        session: AgentTabSession
    ) {
        guard !payload.text.isEmpty else { return }
        let key = Self.reasoningAggregationKey(for: payload) ?? UUID().uuidString
        var segment = session.codexReasoningSegmentsByKey[key] ?? .init()
        let previousStatusTitle = segment.statusTitle
        switch payload.kind {
        case .summary:
            segment.summaryMarkdown += payload.text
            segment.summaryMarkdown = ReasoningTextFormatter.normalize(segment.summaryMarkdown)
        case .text:
            segment.bodyMarkdown += payload.text
        }
        if let title = Self.latestReasoningSummaryTitle(from: segment.summaryMarkdown),
           Self.shouldUseReasoningSummaryAsStatus(title)
        {
            segment.statusTitle = title
        } else {
            segment.statusTitle = nil
        }
        session.codexReasoningSegmentsByKey[key] = segment
        let didUpdateTranscript = upsertReasoningTranscript(for: key, session: session)
        if let title = segment.statusTitle {
            setRunningStatus(title, source: .reasoning, session: session, urgent: true)
        } else if let previousStatusTitle,
                  session.runningStatusSource == .reasoning,
                  session.runningStatusText == previousStatusTitle
        {
            setRunningStatus(nil, source: nil, session: session, urgent: true)
        }
        if didUpdateTranscript {
            viewModel?.requestUIRefresh(tabID: session.tabID)
        }
    }

    private static func insertTranscriptItem(
        _ item: AgentChatItem,
        at index: Int,
        session: AgentTabSession
    ) {
        var insertedItem = item
        session.mutateItemsBatch { items in
            let insertionIndex = min(max(index, 0), items.count)
            guard insertionIndex < items.count else {
                insertedItem.sequenceIndex = session.nextSequenceIndex
                items.append(insertedItem)
                return
            }
            let insertionSequence = items[insertionIndex].sequenceIndex
            for shiftedIndex in insertionIndex ..< items.count {
                items[shiftedIndex].sequenceIndex += 1
            }
            insertedItem.sequenceIndex = insertionSequence
            items.insert(insertedItem, at: insertionIndex)
        }
    }

    private func reconcileReasoningCompletion(
        _ payload: CodexNativeSessionController.ReasoningCompletionPayload,
        session: AgentTabSession
    ) {
        let itemID = payload.scope.itemID
        let keyPrefix = "reasoning:\(itemID):"
        let count = max(payload.summary.count, payload.content.count)
        let authoritativeKeys = Set((0 ..< count).map { "\(keyPrefix)\($0)" })
        let existingKeys = session.codexReasoningSegmentsByKey.keys.filter {
            $0 == itemID || $0 == "reasoning:\(itemID)" || $0.hasPrefix(keyPrefix)
        }
        var didChange = false
        for key in existingKeys where !authoritativeKeys.contains(key) {
            if let rowID = session.codexReasoningSegmentsByKey[key]?.transcriptItemID,
               let index = session.items.firstIndex(where: { $0.id == rowID })
            {
                _ = session.removeItem(at: index)
                didChange = true
            }
            session.codexReasoningSegmentsByKey.removeValue(forKey: key)
        }

        var latestStatusTitle: String?
        for index in 0 ..< count {
            let key = "\(keyPrefix)\(index)"
            let summary = index < payload.summary.count
                ? ReasoningTextFormatter.normalize(payload.summary[index])
                : ""
            let content = index < payload.content.count ? payload.content[index] : ""
            var segment = session.codexReasoningSegmentsByKey[key] ?? .init()
            let previousRowID = segment.transcriptItemID
            segment.summaryMarkdown = summary
            segment.bodyMarkdown = content
            if let title = Self.latestReasoningSummaryTitle(from: summary),
               Self.shouldUseReasoningSummaryAsStatus(title)
            {
                segment.statusTitle = title
                latestStatusTitle = title
            } else {
                segment.statusTitle = nil
            }
            session.codexReasoningSegmentsByKey[key] = segment

            guard let markdown = Self.renderedReasoningMarkdown(for: segment) else {
                if let previousRowID,
                   let rowIndex = session.items.firstIndex(where: { $0.id == previousRowID })
                {
                    _ = session.removeItem(at: rowIndex)
                    segment.transcriptItemID = nil
                    session.codexReasoningSegmentsByKey[key] = segment
                    didChange = true
                }
                continue
            }
            if let previousRowID,
               let rowIndex = session.items.firstIndex(where: { $0.id == previousRowID })
            {
                if session.items[rowIndex].text != markdown || session.items[rowIndex].isStreaming {
                    session.mutateItem(at: rowIndex) { item in
                        item.text = markdown
                        item.isStreaming = false
                    }
                    didChange = true
                }
            } else {
                var thinkingItem = AgentChatItem.thinking(
                    markdown,
                    sequenceIndex: session.nextSequenceIndex
                )
                thinkingItem.isStreaming = false
                let higherRowIndex = ((index + 1) ..< count).compactMap { higherIndex -> Int? in
                    let higherKey = "\(keyPrefix)\(higherIndex)"
                    guard let rowID = session.codexReasoningSegmentsByKey[higherKey]?.transcriptItemID else {
                        return nil
                    }
                    return session.items.firstIndex(where: { $0.id == rowID })
                }.min()
                let lowerRowIndex = (0 ..< index).reversed().compactMap { lowerIndex -> Int? in
                    let lowerKey = "\(keyPrefix)\(lowerIndex)"
                    guard let rowID = session.codexReasoningSegmentsByKey[lowerKey]?.transcriptItemID else {
                        return nil
                    }
                    return session.items.firstIndex(where: { $0.id == rowID })
                }.first
                if let insertionIndex = higherRowIndex ?? lowerRowIndex.map({ $0 + 1 }) {
                    Self.insertTranscriptItem(thinkingItem, at: insertionIndex, session: session)
                } else {
                    session.appendItem(thinkingItem)
                }
                segment.transcriptItemID = thinkingItem.id
                session.codexReasoningSegmentsByKey[key] = segment
                didChange = true
            }
        }

        if let latestStatusTitle {
            setRunningStatus(latestStatusTitle, source: .reasoning, session: session, urgent: true)
        } else if session.runningStatusSource == .reasoning {
            setRunningStatus(nil, source: nil, session: session, urgent: true)
        }
        if didChange {
            viewModel?.requestUIRefresh(tabID: session.tabID)
        }
    }

    private func finalizeStreamingItems(in session: AgentTabSession) {
        session.mutateItemsBatch(touchActivity: false) { items in
            for index in items.indices where items[index].isStreaming {
                items[index].isStreaming = false
            }
        }
    }

    private func drainCodexTerminalOutput(
        _ session: AgentTabSession,
        turnStatus: CodexNativeSessionController.TurnStatus
    ) {
        flushCommandExecutionRunningUpdates(session: session)
        flushPendingAssistantDelta(session)
        finalizeStreamingItems(in: session)
        finalizePendingToolCalls(in: session, turnStatus: turnStatus)
        finalizeLingeringRunningBashResults(in: session, turnStatus: turnStatus)
        reconcilePersistedCodexCommandStatusIfNeeded(session: session, force: true)
        session.providerTerminalDrainGeneration &+= 1
    }

    private func recordObservedCodexAssistantCompletion(
        _ scope: CodexNativeSessionController.ItemScope,
        session: AgentTabSession
    ) {
        var scopes = observedCodexAssistantCompletionScopesByTabID[session.tabID] ?? []
        scopes.insert(scope)
        observedCodexAssistantCompletionScopesByTabID[session.tabID] = scopes
    }

    private func latestCodexAssistantSettleCandidate(
        session: AgentTabSession,
        turnID: String?
    ) -> CodexAssistantSettleCandidate? {
        let latestStreamingAssistant = session.items.reversed().first {
            $0.kind == .assistant && $0.isStreaming
        }
        let hasPendingAssistantBuffer = !session.pendingAssistantDelta.isEmpty
            || session.assistantDeltaFlushTask != nil
        guard hasPendingAssistantBuffer || latestStreamingAssistant != nil else {
            return nil
        }

        let scope = session.pendingCodexAssistantScope ?? latestStreamingAssistant.flatMap { item in
            session.codexAssistantRowIDByScope.first(where: { $0.value == item.id })?.key
        }
        guard let scope else { return nil }
        if let turnID,
           !scope.turnID.isEmpty,
           scope.turnID != turnID
        {
            return nil
        }
        guard observedCodexAssistantCompletionScopesByTabID[session.tabID]?.contains(scope) != true else {
            return nil
        }

        let reason = if hasPendingAssistantBuffer {
            "pending-assistant-buffer"
        } else {
            "streaming-assistant-item"
        }
        return CodexAssistantSettleCandidate(
            scope: scope,
            rowID: latestStreamingAssistant?.id ?? session.codexAssistantRowIDByScope[scope],
            reason: reason
        )
    }

    private func pendingCodexTerminalSettleStillNeedsWait(
        _ pending: PendingCodexTerminalSettle,
        session: AgentTabSession
    ) -> Bool {
        if session.pendingCodexAssistantScope == pending.assistantScope,
           !session.pendingAssistantDelta.isEmpty || session.assistantDeltaFlushTask != nil
        {
            return true
        }
        if let rowID = pending.assistantRowID,
           session.items.first(where: { $0.id == rowID })?.isStreaming == true
        {
            return true
        }
        return false
    }

    private func cancelPendingCodexTerminalSettle(for tabID: UUID, reason: String) {
        guard let pending = pendingCodexTerminalSettleByTabID.removeValue(forKey: tabID) else {
            return
        }
        pending.task.cancel()
        logCodex(
            "[AgentModeVM][CodexUI] cancel terminal assistant settle tab=\(tabID) reason=\(reason) turnID=\(pending.turnID ?? "nil")"
        )
    }

    private func clearCodexTerminalSettleState(for tabID: UUID) {
        cancelPendingCodexTerminalSettle(for: tabID, reason: "clear-state")
        observedCodexAssistantCompletionScopesByTabID.removeValue(forKey: tabID)
    }

    private func completePendingCodexTerminalSettle(
        tabID: UUID,
        session: AgentTabSession?,
        generation: UUID,
        trigger: String
    ) async {
        guard let pending = pendingCodexTerminalSettleByTabID[tabID],
              pending.generation == generation
        else {
            return
        }
        pendingCodexTerminalSettleByTabID.removeValue(forKey: tabID)
        pending.task.cancel()

        guard let session,
              session.runID == pending.expectedRunID,
              session.runState.isActive,
              session.activeRunOwnership != nil
        else {
            logCodex(
                "[AgentModeVM][CodexUI] drop terminal assistant settle tab=\(tabID) trigger=\(trigger) reason=stale-run"
            )
            return
        }

        logCodex(
            "[AgentModeVM][CodexUI] complete terminal assistant settle tab=\(tabID) trigger=\(trigger) turnID=\(pending.turnID ?? "nil")"
        )
        await finalizeCodexRun(
            session,
            turnStatus: pending.turnStatus,
            reason: "\(pending.reason)-settled-\(trigger)",
            errorMessage: pending.errorMessage,
            providerSuccessor: pending.providerSuccessor
        )
    }

    private func completePendingCodexTerminalSettleIfReady(
        session: AgentTabSession,
        completedScope: CodexNativeSessionController.ItemScope
    ) async {
        guard let pending = pendingCodexTerminalSettleByTabID[session.tabID] else {
            return
        }
        guard completedScope == pending.assistantScope
            || !pendingCodexTerminalSettleStillNeedsWait(pending, session: session)
        else {
            return
        }
        await completePendingCodexTerminalSettle(
            tabID: session.tabID,
            session: session,
            generation: pending.generation,
            trigger: "assistant-completed"
        )
    }

    private func completePendingCodexTerminalSettleIfPresent(
        session: AgentTabSession,
        trigger: String
    ) async {
        guard let pending = pendingCodexTerminalSettleByTabID[session.tabID] else {
            return
        }
        await completePendingCodexTerminalSettle(
            tabID: session.tabID,
            session: session,
            generation: pending.generation,
            trigger: trigger
        )
    }

    private func deferCodexTerminalFinalizeIfNeeded(
        session: AgentTabSession,
        turnID: String?,
        status: CodexNativeSessionController.TurnStatus,
        failureMessage: String?,
        providerSuccessor: AgentRunTerminalCommitBarrier.ProviderSuccessor?
    ) async -> Bool {
        guard status == .completed,
              session.runState.isActive,
              session.activeRunOwnership != nil,
              terminalCommitBarrier != nil
        else {
            return false
        }
        if let pending = pendingCodexTerminalSettleByTabID[session.tabID] {
            if pending.turnID == turnID {
                return true
            }
            await completePendingCodexTerminalSettle(
                tabID: session.tabID,
                session: session,
                generation: pending.generation,
                trigger: "superseded-turn-completed"
            )
        }
        guard let candidate = latestCodexAssistantSettleCandidate(session: session, turnID: turnID) else {
            return false
        }

        let tabID = session.tabID
        let generation = UUID()
        let expectedRunID = session.runID
        let delayNanos = codexTerminalAssistantSettleDelayNanos
        let task = Task { @MainActor [weak self, weak session] in
            do {
                try await Task.sleep(nanoseconds: delayNanos)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.completePendingCodexTerminalSettle(
                tabID: tabID,
                session: session,
                generation: generation,
                trigger: "timeout"
            )
        }
        pendingCodexTerminalSettleByTabID[tabID] = PendingCodexTerminalSettle(
            generation: generation,
            expectedRunID: expectedRunID,
            turnID: turnID,
            turnStatus: status,
            reason: "turn-completed-\(status)",
            errorMessage: failureMessage,
            providerSuccessor: providerSuccessor,
            assistantScope: candidate.scope,
            assistantRowID: candidate.rowID,
            task: task
        )
        // Remote truncation incident 2026-07-08: Codex can report turn/completed
        // before the matching item/completed full assistant payload reaches the app.
        logCodex(
            "[AgentModeVM][CodexUI] defer terminal assistant settle tab=\(tabID) turnID=\(turnID ?? "nil") itemID=\(candidate.scope.itemID) reason=\(candidate.reason)"
        )
        return true
    }

    private func finalizeCodexRun(
        _ session: AgentTabSession,
        turnStatus: CodexNativeSessionController.TurnStatus,
        reason: String,
        errorMessage: String? = nil,
        notifyOnCompleted: Bool = true,
        deleteDeferredFilesWhenFailureHasNoInFlight: Bool = false,
        providerSuccessor: AgentRunTerminalCommitBarrier.ProviderSuccessor? = nil
    ) async {
        cancelPendingCodexTerminalSettle(for: session.tabID, reason: "finalize-\(reason)")
        guard let ownership = session.activeRunOwnership,
              let terminalCommitBarrier
        else {
            return
        }
        let expectedRunID = session.runID
        drainCodexTerminalOutput(session, turnStatus: turnStatus)

        clearCodexRecoveryAttempt(for: session.runID)
        clearCodexAuthRecoveryAttempt(for: session.runID)
        clearCodexPendingAuthRetryTurn(session)
        cancelCodexTransportClosedFallback(for: session.tabID)
        resetTrackedCodexTurns(session)
        resetCodexWatchdogState(session)
        clearCodexNativeToolLiveness(session)
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()
        session.pendingCodexAssistantScope = nil
        session.codexAssistantRowIDByScope.removeAll()
        observedCodexAssistantCompletionScopesByTabID.removeValue(forKey: session.tabID)
        clearCodexPendingInteractions(in: session)

        let terminalState: AgentSessionRunState = switch turnStatus {
        case .completed:
            .completed
        case .interrupted:
            .cancelled
        case .failed:
            .failed
        }
        let attachmentDisposition: AgentAttachmentTurnDisposition = if turnStatus == .failed {
            if deleteDeferredFilesWhenFailureHasNoInFlight,
               case .idle = session.attachmentTurnState
            {
                .deleteFiles
            } else {
                .restoreToPending
            }
        } else {
            .deleteFiles
        }
        let request = AgentRunTerminalCommitBarrier.Request(
            session: session,
            ownership: ownership,
            expectedRunID: expectedRunID,
            terminalState: terminalState,
            source: "codex.finalize.\(reason)",
            errorText: errorMessage,
            attachmentDisposition: attachmentDisposition,
            finalizeNonCodexUsage: false,
            supportsFollowUp: false,
            providerSuccessor: providerSuccessor,
            notifyTurnComplete: turnStatus == .completed && notifyOnCompleted,
            providerDrainGeneration: session.providerTerminalDrainGeneration,
            providerBuffersAreDrained: { [weak self] in
                self?.codexTerminalBuffersAreDrained(session) == true
            },
            postCommit: { [weak self] in
                guard let self else { return }
                viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
                settleCodexComputerUseActivationAfterTurn(session, reason: reason)
                if session.codexController != nil {
                    scheduleCodexIdleShutdownIfNeeded(for: session, reason: reason)
                }
            }
        )
        _ = await terminalCommitBarrier.commit(request)
        if let providerSuccessor {
            scheduleCodexFallbackSuccessorRetryIfNeeded(
                session: session,
                request: request,
                providerSuccessor: providerSuccessor
            )
        }
    }

    private func settleCodexComputerUseActivationAfterTurn(
        _ session: AgentTabSession,
        reason: String
    ) {
        let hadActivation = session.pendingCodexComputerUseActivation != nil
        session.pendingCodexComputerUseActivation = nil
        guard session.codexControllerFeatureState?.computerUseEnabled == true else { return }
        _ = invalidateCodexControllerForReconnect(
            session: session,
            expectedController: session.codexController,
            source: "computer-use-turn-finished-\(reason)"
        )
        if hadActivation {
            viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        }
    }

    private func codexEventScopeMatches(
        _ event: CodexNativeSessionController.Event,
        session: AgentTabSession
    ) -> Bool {
        let scope: (threadID: String?, turnID: String?, itemID: String?)? = switch event {
        case let .canonicalAssistantDelta(_, itemScope):
            (nil, itemScope.turnID, itemScope.itemID)
        case let .assistantCompleted(payload):
            (nil, payload.scope.turnID, payload.scope.itemID)
        case let .reasoningDelta(payload) where payload.scope != nil:
            (nil, payload.scope?.turnID, payload.scope?.itemID)
        case let .reasoningCompleted(payload):
            (nil, payload.scope.turnID, payload.scope.itemID)
        case let .livenessActivity(activity):
            (activity.threadID, activity.turnID, activity.itemID)
        case let .errorNotification(notification):
            (notification.threadID, notification.turnID, notification.itemID)
        default:
            nil
        }
        guard let scope else { return true }
        let scopedTurnID = scope.turnID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scopedItemID = scope.itemID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scopedThreadID = scope.threadID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let itemScope = CodexNativeSessionController.ItemScope(
            turnID: scopedTurnID,
            itemID: scopedItemID
        )
        if let pending = pendingCodexTerminalSettleByTabID[session.tabID],
           !scopedTurnID.isEmpty,
           !scopedItemID.isEmpty,
           pending.assistantScope == itemScope,
           session.runID == pending.expectedRunID,
           session.runState.isActive
        {
            if !scopedThreadID.isEmpty,
               scopedThreadID != session.codexConversationID
            {
                return false
            }
            return true
        }
        if let threadID = scope.threadID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !threadID.isEmpty,
           threadID != session.codexConversationID
        {
            return false
        }
        if let turnID = scope.turnID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !turnID.isEmpty
        {
            guard turnID == session.codexAuthoritativeActiveTurn?.turnID else {
                return false
            }
        }
        if scope.itemID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           session.codexAuthoritativeActiveTurn == nil,
           session.codexAnonymousActiveTurn == nil
        {
            return false
        }
        return true
    }

    private func handleCodexNativeEvent(
        _ event: CodexNativeSessionController.Event,
        session: AgentTabSession,
        sourceController: (any CodexSessionControlling)? = nil
    ) async {
        CodexDebugLog.log("[AgentModeVM][CodexUI] handleEvent \(debugCodexEventSummary(event)) tab=\(session.tabID)")
        if let sourceController {
            guard let activeController = session.codexController,
                  Self.sameCodexControllerInstance(activeController, sourceController)
            else {
                #if DEBUG
                    if AgentModePerfDiagnostics.isEnabled {
                        let metricKind = codexEventMetricKind(event)
                        AgentModePerfDiagnostics.increment("provider.codex.event.staleDropped.\(metricKind)", tabID: session.tabID)
                        AgentModePerfDiagnostics.event("provider.codex.event.staleDropped", tabID: session.tabID, fields: ["kind": metricKind])
                    }
                #endif
                return
            }
        }
        guard codexEventScopeMatches(event, session: session) else {
            #if DEBUG
                let metricKind = codexEventMetricKind(event)
                AgentModePerfDiagnostics.increment("provider.codex.event.staleScopeDropped.\(metricKind)", tabID: session.tabID)
            #endif
            return
        }
        if let ownership = session.activeRunOwnership {
            let progress: (kind: AgentRunLivenessSignalKind, stage: AgentRunLifecycleStage, retryIntent: AgentRunRetryIntent) = switch event {
            case let .livenessActivity(activity):
                switch activity.kind {
                case .mcpToolProgress, .commandOrProcessOutput, .processExited:
                    (.toolActivity, .running, .none)
                case .serverRequestResolved:
                    (.interaction, .running, .none)
                default:
                    (.providerEvent, .running, .none)
                }
            case let .errorNotification(notification) where notification.willRetry == true:
                (.providerEvent, .retrying, .providerManaged)
            default:
                (.providerEvent, .running, .none)
            }
            session.recordRunProgress(
                ownership: ownership,
                kind: progress.kind,
                stage: progress.stage,
                retryIntent: progress.retryIntent
            )
        }
        #if DEBUG
            if AgentModePerfDiagnostics.isEnabled {
                let metricKind = codexEventMetricKind(event)
                AgentModePerfDiagnostics.increment("provider.codex.event.accepted.\(metricKind)", tabID: session.tabID)
                AgentModePerfDiagnostics.event(
                    "provider.codex.event.accepted",
                    tabID: session.tabID,
                    fields: [
                        "kind": metricKind,
                        "active": String(session.runState.isActive)
                    ]
                )
            }
        #endif
        let shouldKeepTransportClosedFallback: Bool = {
            let message: String
            switch event {
            case let .error(rawMessage):
                message = rawMessage
            case let .errorNotification(notification):
                let willRetry = notification.willRetry ?? Self.isRetriableStreamErrorMessage(notification.message)
                guard !willRetry else { return false }
                message = notification.message
            default:
                return false
            }
            return session.runState.isActive
                && !hasPendingCodexInteraction(for: session)
                && message.localizedCaseInsensitiveContains("transport closed")
        }()
        if !shouldKeepTransportClosedFallback {
            cancelCodexTransportClosedFallback(for: session.tabID)
        }
        let eventTimestamp = Date()
        session.codexLastEventAt = eventTimestamp
        recordCodexWatchdogProgress(for: session, at: eventTimestamp)
        defer {
            updateBashLivenessTaskState(for: session)
            updateCodexStallWatchdogState(for: session)
        }
        switch event {
        case let .assistantDelta(delta):
            guard session.runState.isActive else { return }
            guard !delta.isEmpty else { return }
            clearCodexPendingAuthRetryTurn(session)
            enqueueAssistantDelta(delta, session: session)
            return
        case let .canonicalAssistantDelta(text, scope):
            guard session.runState.isActive else { return }
            guard !text.isEmpty else { return }
            clearCodexPendingAuthRetryTurn(session)
            enqueueAssistantDelta(text, scope: scope, session: session)
            return
        case let .assistantCompleted(payload):
            guard session.runState.isActive else { return }
            clearCodexPendingAuthRetryTurn(session)
            recordObservedCodexAssistantCompletion(payload.scope, session: session)
            reconcileAssistantCompletion(payload, session: session)
            await completePendingCodexTerminalSettleIfReady(
                session: session,
                completedScope: payload.scope
            )
            return
        case let .reasoningDelta(payload):
            guard session.runState.isActive else { return }
            clearCodexPendingAuthRetryTurn(session)
            sealAssistantBoundary(session)
            applyReasoningDelta(payload, session: session)
            return
        case let .reasoningCompleted(payload):
            guard session.runState.isActive else { return }
            clearCodexPendingAuthRetryTurn(session)
            sealAssistantBoundary(session)
            reconcileReasoningCompletion(payload, session: session)
            return
        case let .usageObservation(observation):
            // Accounting eligibility is independent of the active-run context guard (plan §4.1):
            // ownership is the controller generation, so provably owned late usage still lands.
            session.ingestCodexUsageObservation(observation)
        case let .modelRerouted(reroute):
            session.noteCodexModelReroute(reroute)
        case let .tokenUsage(usage):
            guard session.runState.isActive else { return }
            viewModel?.applyCodexNativeContextUsage(usage, session: session)
            session.isDirty = true
            viewModel?.requestUIRefresh(tabID: session.tabID, scope: .runtimeMetrics)
            viewModel?.scheduleSaveForCommandOutput(tabID: session.tabID, minInterval: 2.0)
        case let .approvalRequest(request):
            guard session.runState.isActive else { return }
            clearCodexPendingAuthRetryTurn(session)
            sealAssistantBoundary(session)
            session.pendingApproval = request
            viewModel?.reconcileInteractiveRunState(session)
            viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
            viewModel?.publishMCPStateChange(for: session)
        case let .permissionsRequest(request):
            guard session.runState.isActive else { return }
            clearCodexPendingAuthRetryTurn(session)
            sealAssistantBoundary(session)
            session.pendingPermissionsRequest = request
            viewModel?.reconcileInteractiveRunState(session)
            viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
            viewModel?.publishMCPStateChange(for: session)
        case let .mcpElicitationRequest(request):
            guard session.runState.isActive else { return }
            clearCodexPendingAuthRetryTurn(session)
            sealAssistantBoundary(session)
            let alreadyPending = session.pendingMCPElicitationRequest?.requestID == request.requestID
            let alreadyQueued = session.queuedMCPElicitationRequests.contains { $0.requestID == request.requestID }
            guard !alreadyPending, !alreadyQueued else { return }
            if session.pendingMCPElicitationRequest == nil {
                session.pendingMCPElicitationRequest = request
            } else {
                session.queuedMCPElicitationRequests.append(request)
            }
            viewModel?.reconcileInteractiveRunState(session)
            viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
            viewModel?.publishMCPStateChange(for: session)
        case let .requestUserInput(request):
            guard session.runState.isActive else { return }
            clearCodexPendingAuthRetryTurn(session)
            sealAssistantBoundary(session)
            // Auto-approve RepoPrompt MCP tool approval requests instead of forwarding to the parent agent.
            // Codex expects the literal option label (e.g. "Allow"), not a generic "accept" decision.
            if Self.shouldAutoApproveCodexMCPToolRequest(request) {
                let response = Self.buildAutoApprovalResponse(for: request)
                submitUserInputResponse(session: session, requestID: request.requestID, response: response)
                return
            }
            let alreadyPending = session.pendingUserInputRequest?.requestID == request.requestID
            let alreadyQueued = session.queuedUserInputRequests.contains { $0.requestID == request.requestID }
            guard !alreadyPending, !alreadyQueued else {
                return
            }
            if session.pendingUserInputRequest == nil {
                session.pendingUserInputRequest = request
            } else {
                session.queuedUserInputRequests.append(request)
            }
            viewModel?.reconcileInteractiveRunState(session)
            viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        case let .serverRequestIssue(issue):
            if await attemptManagedCodexAuthRecovery(
                for: session,
                issue: issue,
                message: issue.message,
                sourceController: sourceController
            ) {
                return
            }
            await finalizeCodexRun(
                session,
                turnStatus: .failed,
                reason: "server-request-\(issue.kind.rawValue)",
                errorMessage: issue.message,
                notifyOnCompleted: false,
                deleteDeferredFilesWhenFailureHasNoInFlight: true
            )
        case let .toolCall(toolName, invocationID, argsJSON):
            guard session.runState.isActive else { return }
            clearCodexPendingAuthRetryTurn(session)
            sealAssistantBoundary(session)
            noteCodexNativeToolCall(
                toolName: toolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                session: session,
                at: eventTimestamp
            )
            if AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName) {
                CodexDebugLog.log("[AgentModeVM][CodexUI] skip native explicit RepoPrompt toolCall tool=\(toolName)")
                return
            }
            guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }
            if Self.normalizedExternalToolName(toolName) == "bash" {
                let didUpdate = ensureLiveBashExecutionState(
                    toolName: toolName,
                    invocationID: invocationID,
                    argsJSON: argsJSON,
                    processID: Self.extractProcessIDFromArgsJSON(argsJSON),
                    session: session,
                    observedAt: eventTimestamp
                ) != nil
                if didUpdate {
                    updateBashLivenessTaskState(for: session)
                    CodexDebugLog.log("[AgentModeVM][CodexUI] ensure bash anchor/live-state tool=\(toolName) invocationID=\(invocationID?.uuidString ?? "nil") liveCount=\(session.bashLiveExecutionByKey.count) totalItems=\(session.items.count)")
                    viewModel?.requestUIRefresh(tabID: session.tabID)
                }
                return
            }
            let toolItem = AgentChatItem.toolCall(
                name: toolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(toolItem)
            CodexDebugLog.log("[AgentModeVM][CodexUI] append toolCall tool=\(toolName) invocationID=\(invocationID?.uuidString ?? "nil") argsChars=\(argsJSON?.count ?? 0) totalItems=\(session.items.count)")
            viewModel?.requestUIRefresh(tabID: session.tabID)
        case let .toolResult(toolName, invocationID, argsJSON, resultJSON, isError):
            guard session.runState.isActive else { return }
            clearCodexPendingAuthRetryTurn(session)
            sealAssistantBoundary(session)
            if AgentToolTrackingSupport.isExplicitRepoPromptTool(toolName) {
                CodexDebugLog.log("[AgentModeVM][CodexUI] skip native explicit RepoPrompt toolResult tool=\(toolName)")
                return
            }
            let parsedBashResult = Self.normalizedExternalToolName(toolName) == "bash"
                ? BashToolResultParser.parseLivenessMetadata(raw: resultJSON)
                : nil
            if let parsedBashResult, parsedBashResult.isRunning {
                noteCodexNativeToolCall(
                    toolName: toolName,
                    invocationID: invocationID,
                    argsJSON: argsJSON,
                    session: session,
                    at: eventTimestamp
                )
                noteCodexNativeToolRunningSignal(
                    invocationID: invocationID,
                    processID: parsedBashResult.processID,
                    session: session,
                    at: eventTimestamp
                )
            } else {
                completeCodexNativeTool(
                    toolName: toolName,
                    invocationID: invocationID,
                    argsJSON: argsJSON,
                    session: session
                )
            }
            guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }
            if Self.normalizedExternalToolName(toolName) == "bash" {
                if let parsedBashResult, parsedBashResult.isRunning {
                    if let terminalApplyResult = applyLateRunningOutputToTerminalBashResultIfNeeded(
                        toolName: toolName,
                        invocationID: invocationID,
                        argsJSON: argsJSON,
                        processID: parsedBashResult.processID,
                        appendedOutput: BashToolResultParser.parse(raw: resultJSON, argsJSON: argsJSON).output,
                        session: session
                    ) {
                        guard terminalApplyResult.didChange else { return }
                        updateBashLivenessTaskState(for: session)
                        viewModel?.requestUIRefresh(tabID: session.tabID)
                        viewModel?.scheduleSave(for: session.tabID)
                        return
                    }
                    let didUpdateLive = upsertLiveBashExecution(
                        toolName: toolName,
                        invocationID: invocationID,
                        argsJSON: argsJSON,
                        parsedResult: Self.parsedBashLivenessResult(metadata: parsedBashResult, argsJSON: argsJSON),
                        metadata: parsedBashResult,
                        session: session,
                        observedAt: eventTimestamp
                    )
                    let shouldMaterializeRunningOutput = canMaterializeRunningBashOutput(for: session)
                    let didMaterialize = shouldMaterializeRunningOutput
                        ? (existingBashExecutionLookup(
                            invocationID: invocationID,
                            processID: parsedBashResult.processID,
                            fallbackSignature: Self.canonicalNativeToolFallbackSignature(toolName: toolName, argsJSON: argsJSON),
                            session: session
                        ).map { materializeRunningBashExecution($0.state, session: session) } ?? false)
                        : false
                    if didUpdateLive || didMaterialize {
                        updateBashLivenessTaskState(for: session)
                        viewModel?.requestUIRefresh(
                            tabID: session.tabID,
                            scope: shouldMaterializeRunningOutput ? .full : .transcriptRuntime
                        )
                    }
                    return
                }
                if finalizeLiveBashExecution(
                    toolName: toolName,
                    invocationID: invocationID,
                    argsJSON: argsJSON,
                    resultJSON: resultJSON,
                    statusWord: parsedBashResult?.statusWord ?? (isError == true ? "failed" : "completed"),
                    isError: isError,
                    session: session,
                    observedAt: eventTimestamp
                ) {
                    updateBashLivenessTaskState(for: session)
                    CodexDebugLog.log("[AgentModeVM][CodexUI] finalize bash toolResult tool=\(toolName) invocationID=\(invocationID?.uuidString ?? "nil") liveCount=\(session.bashLiveExecutionByKey.count)")
                    viewModel?.requestUIRefresh(tabID: session.tabID)
                    viewModel?.scheduleSave(for: session.tabID)
                }
                return
            }
            let shouldMirrorTextPayload = true
            let mergedResultJSON: (String?) -> String = { _ in resultJSON }
            // Resolve matching transcript item across all match paths.
            let matchedIndex: Int? = {
                if let invocationID,
                   let index = session.items.lastIndex(where: { $0.toolInvocationID == invocationID })
                {
                    return index
                }
                if let idx = CodexNativeSessionController.matchingBashToolResultIndex(
                    in: session.items,
                    toolName: toolName,
                    invocationID: invocationID,
                    argsJSON: argsJSON,
                    resultJSON: resultJSON
                ) {
                    return idx
                }
                guard invocationID == nil else { return nil }
                return session.items.lastIndex(where: {
                    $0.kind == .toolCall
                        && $0.toolInvocationID == nil
                        && $0.toolName == toolName
                })
            }()
            // Prevent apply_patch terminal → running regression across all match paths.
            if let matchedIndex, Self.shouldIgnoreApplyPatchRunningRegression(
                existingResultJSON: session.items[matchedIndex].toolResultJSON,
                incomingResultJSON: resultJSON,
                toolName: toolName
            ) {
                return
            }
            if let index = matchedIndex {
                let isInvocationMatch = invocationID != nil
                    && session.items[index].toolInvocationID == invocationID
                var updated = session.items[index]
                updated.kind = .toolResult
                if !isInvocationMatch {
                    updated.toolInvocationID = invocationID ?? updated.toolInvocationID
                }
                updated.toolResultJSON = mergedResultJSON(updated.toolResultJSON)
                updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
                updated.toolIsError = isError
                if shouldMirrorTextPayload {
                    updated.text = resultJSON
                }
                session.replaceItem(at: index, with: updated)
            } else {
                let toolResultItem = AgentChatItem.toolResult(
                    name: toolName,
                    invocationID: invocationID,
                    argsJSON: argsJSON,
                    resultJSON: resultJSON,
                    isError: isError,
                    sequenceIndex: session.nextSequenceIndex
                )
                session.appendItem(toolResultItem)
            }
            reconcileCodexCommandExecutionRunningUpdate(
                toolName: toolName,
                argsJSON: argsJSON,
                resultJSON: resultJSON,
                isError: isError,
                session: session
            )
            CodexDebugLog.log("[AgentModeVM][CodexUI] apply toolResult tool=\(toolName) invocationID=\(invocationID?.uuidString ?? "nil") isError=\(isError.map(String.init(describing:)) ?? "nil") resultChars=\(resultJSON.count) totalItems=\(session.items.count)")
            viewModel?.requestUIRefresh(tabID: session.tabID)
        case let .commandExecutionRunning(runningUpdate):
            guard session.runState.isActive
                || shouldApplyCommandExecutionRunningUpdateToInactiveSession(runningUpdate, session: session)
            else { return }
            clearCodexPendingAuthRetryTurn(session)
            if runningUpdate.sealsAssistantBoundary {
                sealAssistantBoundary(session)
            } else {
                flushPendingAssistantDelta(session)
            }
            noteCodexNativeToolRunningSignal(
                invocationID: runningUpdate.invocationID,
                processID: runningUpdate.processID,
                session: session,
                at: eventTimestamp
            )
            enqueueCommandExecutionRunningUpdate(runningUpdate, session: session)
        case let .turnStarted(turnID):
            // Acceptance is lifecycle evidence independent of the optional turn identity.
            // Record it first so a nil-ID start still protects the pending exact dispatch ticket.
            session.acceptCurrentCodexUsageDispatch()
            session.bindCodexUsageTurn(turnID)
            await completePendingCodexTerminalSettleIfPresent(
                session: session,
                trigger: "turn-started"
            )
            cancelCodexIdleShutdown(for: session.tabID)
            clearStaleCodexPendingInteractionsForNewTurn(turnID, session: session)
            guard let turnKind = installAuthoritativeCodexTurnForStart(
                turnID: turnID,
                session: session,
                sourceController: sourceController
            ) else {
                return
            }
            if let identity = session.codexAuthoritativeActiveTurn {
                bindCodexFallbackQueueToStartedTurn(identity, session: session)
            }
            let statusText = turnKind == .compact ? "Compacting context…" : "Thinking…"
            setRunningStatus(statusText, source: .transport, session: session, urgent: true)
            session.runState = .running
            viewModel?.setAgentRunActive(session.tabID, isActive: true)
            viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        case let .turnCompleted(turnID, status, failure):
            // Accounting closure is independent of run-state correlation (plan §4.1): a bound turn
            // that ends without any usage observation is unmeasured work, never measured zero. A
            // nil-ID completion legitimately terminates the identified turn the correlation
            // validates, so that known accounting turn is closed; a nil-ID completion correlated
            // only to an anonymous turn (its `turn/started` carried no identity) ends dispatched
            // work whose identity can never be established, so outstanding work is marked
            // unmeasured now instead of at some later execution teardown. A completion the
            // correlation rejects is not this session's turn and leaves accounting untouched;
            // its outstanding work is still marked at its own closure or execution end
            // (review R2, OracleA P1#2).
            let completion = correlatedCodexTurnKindForCompletion(
                turnID: turnID,
                session: session
            )
            if let turnID {
                session.closeCodexUsageTurn(turnID)
            } else if let completion {
                if let identifiedTurnID = completion.authoritativeIdentity?.turnID {
                    session.closeCodexUsageTurn(identifiedTurnID)
                } else {
                    session.closeUnidentifiedCodexUsageTurn()
                }
            }
            guard let completion else {
                return
            }
            let failureMessage = status == .failed
                ? (failure?.message ?? "Codex turn failed.")
                : nil
            if let failureMessage,
               await attemptManagedCodexAuthRecovery(
                   for: session,
                   issue: nil,
                   message: failureMessage,
                   sourceController: sourceController
               )
            {
                return
            }
            let turnKind = completion.turnKind
            let completedIdentity = completion.authoritativeIdentity
            let providerSuccessor = codexFallbackSuccessorForCompletion(
                turnID: turnID,
                status: status,
                completedIdentity: completedIdentity,
                session: session
            )
            abandonCodexFallbackQueueBlockedByTerminalTurn(
                completedIdentity,
                status: status,
                session: session
            )
            if turnKind == .compact {
                if status == .completed {
                    markCodexContextCompacted(session)
                }
                await finalizeCodexRun(
                    session,
                    turnStatus: status,
                    reason: "compact-turn-completed-\(status)",
                    errorMessage: failureMessage,
                    providerSuccessor: providerSuccessor
                )
                CodexDebugLog.log("[AgentModeVM][CodexUI] compact turnCompleted turnID=\(turnID ?? "nil") status=\(status) runState=\(session.runState)")
                return
            }
            if session.runState == .cancelled, status != .interrupted { return }
            if session.runState == .failed, status != .failed { return }
            if await deferCodexTerminalFinalizeIfNeeded(
                session: session,
                turnID: turnID,
                status: status,
                failureMessage: failureMessage,
                providerSuccessor: providerSuccessor
            ) {
                return
            }
            await finalizeCodexRun(
                session,
                turnStatus: status,
                reason: "turn-completed-\(status)",
                errorMessage: failureMessage,
                providerSuccessor: providerSuccessor
            )
            CodexDebugLog.log("[AgentModeVM][CodexUI] turnCompleted turnID=\(turnID ?? "nil") status=\(status) items=\(session.items.count) runState=\(session.runState)")
        case .contextCompacted:
            markCodexContextCompacted(session)
        case let .livenessActivity(activity):
            guard session.runState.isActive else { return }
            if !activity.activeFlags.isEmpty {
                reconcileCodexReportedWaitingFlags(activity.activeFlags, session: session)
            }
            if activity.kind == .threadStatusChanged,
               activity.activeFlags.isEmpty,
               session.runningStatusSource == .transport
            {
                setRunningStatus("Codex is active…", source: .transport, session: session, urgent: true)
            }
            viewModel?.setAgentRunActive(session.tabID, isActive: true)
            viewModel?.requestUIRefresh(tabID: session.tabID, scope: .runtimeMetrics)
        case let .errorNotification(notification):
            let willRetry: Bool
            if let structuredWillRetry = notification.willRetry {
                willRetry = structuredWillRetry
            } else {
                willRetry = Self.isRetriableStreamErrorMessage(notification.message)
                recordCodexRetryHeuristicFallback(session: session, message: notification.message)
            }
            if willRetry, session.runState.isActive {
                if let ownership = session.activeRunOwnership {
                    session.recordRunProgress(
                        ownership: ownership,
                        kind: .providerEvent,
                        stage: .retrying,
                        retryIntent: .providerManaged
                    )
                }
                setRunningStatus(notification.message, source: .reconnect, session: session, urgent: true)
                viewModel?.setAgentRunActive(session.tabID, isActive: true)
                viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true, scope: .runtimeMetrics)
                return
            }
            if await attemptManagedCodexAuthRecovery(
                for: session,
                issue: nil,
                message: notification.message,
                sourceController: sourceController
            ) {
                return
            }
            await handleTerminalCodexError(
                notification.message,
                session: session,
                sourceController: sourceController
            )
        case let .error(message):
            let willRetry = Self.isRetriableStreamErrorMessage(message)
            recordCodexRetryHeuristicFallback(session: session, message: message)
            if willRetry, session.runState.isActive {
                if let ownership = session.activeRunOwnership {
                    session.recordRunProgress(
                        ownership: ownership,
                        kind: .providerEvent,
                        stage: .retrying,
                        retryIntent: .providerManaged
                    )
                }
                setRunningStatus(message, source: .reconnect, session: session, urgent: true)
                viewModel?.setAgentRunActive(session.tabID, isActive: true)
                viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true, scope: .runtimeMetrics)
                return
            }
            if await attemptManagedCodexAuthRecovery(
                for: session,
                issue: nil,
                message: message,
                sourceController: sourceController
            ) {
                return
            }
            await handleTerminalCodexError(
                message,
                session: session,
                sourceController: sourceController
            )
        case let .system(message):
            let systemItem = AgentChatItem.system(message, sequenceIndex: session.nextSequenceIndex)
            session.appendItem(systemItem)
            viewModel?.requestUIRefresh(tabID: session.tabID)
        }
    }

    private func handleTerminalCodexError(
        _ message: String,
        session: AgentTabSession,
        sourceController: (any CodexSessionControlling)?
    ) async {
        let isTransportClosed = message.localizedCaseInsensitiveContains("transport closed")
        if isTransportClosed {
            if !session.runState.isActive {
                _ = invalidateCodexControllerForReconnect(
                    session: session,
                    expectedController: sourceController,
                    source: "transport-closed",
                    cancelEventTask: false
                )
                setRunningStatus(nil, source: nil, session: session)
                clearCodexPendingInteractions(in: session)
                viewModel?.reconcileInteractiveRunState(session)
                viewModel?.publishMCPStateChange(for: session)
                viewModel?.setAgentRunActive(session.tabID, isActive: false)
                viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
                viewModel?.scheduleSave(for: session.tabID)
                scheduleCodexIdleShutdownIfNeeded(for: session, reason: "transport-closed-idle")
                return
            }
            if !hasPendingCodexInteraction(for: session) {
                setRunningStatus("Reconnecting…", source: .reconnect, session: session, urgent: true)
                viewModel?.setAgentRunActive(session.tabID, isActive: true)
                viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true, scope: .runtimeMetrics)
                if let sourceController {
                    scheduleCodexTransportClosedFallback(for: session, sourceController: sourceController)
                }
            }
            return
        }
        await finalizeCodexRun(
            session,
            turnStatus: .failed,
            reason: "error",
            errorMessage: message,
            notifyOnCompleted: false,
            deleteDeferredFilesWhenFailureHasNoInFlight: true
        )
    }

    private func recordCodexRetryHeuristicFallback(
        session: AgentTabSession,
        message: String
    ) {
        #if DEBUG
            if AgentModePerfDiagnostics.isEnabled {
                AgentModePerfDiagnostics.increment("provider.codex.retry.heuristicFallback", tabID: session.tabID)
                AgentModePerfDiagnostics.event(
                    "provider.codex.retry.heuristicFallback",
                    tabID: session.tabID,
                    fields: ["message": String(message.prefix(160))]
                )
            }
        #endif
    }

    private static func normalizedExternalToolName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()
        if let webCanonical = AgentWebToolCanonicalNames.canonicalToolCardName(lowered) {
            return webCanonical
        }
        let suffix = lowered.split(separator: ".").last.map(String.init) ?? lowered
        switch suffix {
        case "local_shell", "shell", "unified_exec", "exec_command", "run_shell_command":
            return "bash"
        default:
            return AgentWebToolCanonicalNames.canonicalToolCardName(suffix) ?? suffix
        }
    }

    private static func initialRunningCommandExecutionJSON(argsJSON: String?) -> String {
        var payload: [String: Any] = [
            "type": "commandExecution",
            "status": "running"
        ]
        if let command = extractCommandFromArgsJSON(argsJSON) {
            payload["command"] = command
        }
        if let processID = extractProcessIDFromArgsJSON(argsJSON) {
            payload["processId"] = processID
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return #"{"type":"commandExecution","status":"running"}"#
    }

    private static func extractCommandFromArgsJSON(_ argsJSON: String?) -> String? {
        guard let argsJSON = argsJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !argsJSON.isEmpty else {
            return nil
        }
        if let data = argsJSON.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: []),
           let command = extractCommandValue(from: value)
        {
            return command
        }
        return argsJSON
    }

    private static func extractCommandValue(from value: Any) -> String? {
        if let object = value as? [String: Any] {
            for key in ["command", "cmd", "input", "text", "value", "argv", "args"] {
                if let command = extractCommandValue(from: object[key] as Any) {
                    return command
                }
            }
            if let invocation = object["invocation"],
               let command = extractCommandValue(from: invocation)
            {
                return command
            }
            if let arguments = object["arguments"],
               let command = extractCommandValue(from: arguments)
            {
                return command
            }
            for nested in object.values {
                if let command = extractCommandValue(from: nested) {
                    return command
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            let parts = array
                .compactMap { element -> String? in
                    if let string = element as? String {
                        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    if let number = element as? NSNumber {
                        let trimmed = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    return nil
                }
            if !parts.isEmpty {
                return parts.joined(separator: " ")
            }
            for nested in array {
                if let command = extractCommandValue(from: nested) {
                    return command
                }
            }
            return nil
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("\""),
               let data = trimmed.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: data, options: []),
               let command = extractCommandValue(from: nested)
            {
                return command
            }
            if let unquoted = unquotedCommandText(trimmed) {
                return unquoted
            }
            return trimmed
        }
        if let number = value as? NSNumber {
            let trimmed = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func unquotedCommandText(_ raw: String) -> String? {
        guard raw.count >= 2 else { return nil }
        guard let first = raw.first, let last = raw.last, first == last, first == "\"" || first == "'" else {
            return nil
        }
        let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    private static func extractProcessIDFromArgsJSON(_ argsJSON: String?) -> String? {
        guard let argsJSON = argsJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !argsJSON.isEmpty else {
            return nil
        }
        guard let data = argsJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        for key in ["processId", "process_id"] {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let value = object[key] as? NSNumber {
                let text = value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    private static func bashExecutionKey(
        invocationID: UUID?,
        fallbackSignature: String?,
        processID: String? = nil
    ) -> String? {
        if let invocationID {
            return "invocation:\(invocationID.uuidString)"
        }
        if let fallbackSignature = fallbackSignature?.trimmingCharacters(in: .whitespacesAndNewlines), !fallbackSignature.isEmpty {
            return "signature:\(fallbackSignature)"
        }
        if let processID = processID?.trimmingCharacters(in: .whitespacesAndNewlines), !processID.isEmpty {
            return "process:\(processID)"
        }
        return nil
    }

    private static func canonicalProcessIDSet(_ raw: String?) -> Set<String> {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return []
        }
        var values: Set<String> = [raw]
        if raw.hasPrefix("session:") {
            let stripped = String(raw.dropFirst("session:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                values.insert(stripped)
            }
        } else {
            values.insert("session:\(raw)")
        }
        return values
    }

    private static func processIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        let lhsSet = canonicalProcessIDSet(lhs)
        guard !lhsSet.isEmpty else { return false }
        let rhsSet = canonicalProcessIDSet(rhs)
        guard !rhsSet.isEmpty else { return false }
        return !lhsSet.isDisjoint(with: rhsSet)
    }

    private func existingBashExecutionLookup(
        invocationID: UUID?,
        processID: String?,
        fallbackSignature: String?,
        session: AgentTabSession
    ) -> (key: String, state: AgentBashLiveExecutionState)? {
        if let invocationID,
           let key = Self.bashExecutionKey(invocationID: invocationID, fallbackSignature: nil),
           let state = session.bashLiveExecutionByKey[key]
        {
            return (key, state)
        }
        if let fallbackSignature,
           let key = Self.bashExecutionKey(invocationID: nil, fallbackSignature: fallbackSignature),
           let state = session.bashLiveExecutionByKey[key]
        {
            return (key, state)
        }
        if let processID,
           let match = session.bashLiveExecutionByKey.first(where: { Self.processIDsMatch($0.value.processID, processID) })
        {
            return (match.key, match.value)
        }
        return nil
    }

    private func bashTranscriptItemIndex(
        toolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        processID: String?,
        session: AgentTabSession
    ) -> Int? {
        if let invocationID,
           let index = session.items.lastIndex(where: {
               $0.toolInvocationID == invocationID && Self.normalizedExternalToolName($0.toolName) == "bash"
           })
        {
            return index
        }
        let normalizedProcessID = processID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedProcessID, !normalizedProcessID.isEmpty {
            return session.items.lastIndex(where: { item in
                guard Self.normalizedExternalToolName(item.toolName) == "bash" else { return false }
                return Self.processIDsMatch(BashToolResultParser.parseLivenessMetadata(raw: item.toolResultJSON).processID, normalizedProcessID)
            })
        }
        let fallbackSignature = Self.canonicalNativeToolFallbackSignature(toolName: toolName, argsJSON: argsJSON)
        if let argsMatchedIndex = session.items.lastIndex(where: { item in
            guard Self.normalizedExternalToolName(item.toolName) == "bash" else { return false }
            return Self.canonicalNativeToolFallbackSignature(toolName: item.toolName ?? toolName, argsJSON: item.toolArgsJSON) == fallbackSignature
        }) {
            return argsMatchedIndex
        }
        return nil
    }

    private func shouldApplyCommandExecutionRunningUpdateToInactiveSession(
        _ runningUpdate: CodexNativeSessionController.CommandExecutionRunningUpdate,
        session: AgentTabSession
    ) -> Bool {
        guard session.selectedAgent == .codexExec else { return false }
        if existingBashExecutionLookup(
            invocationID: runningUpdate.invocationID,
            processID: runningUpdate.processID,
            fallbackSignature: nil,
            session: session
        ) != nil {
            return true
        }
        guard let index = bashTranscriptItemIndex(
            toolName: "bash",
            invocationID: runningUpdate.invocationID,
            argsJSON: nil,
            processID: runningUpdate.processID,
            session: session
        ) else {
            return false
        }
        let item = session.items[index]
        let metadata = BashToolResultParser.parseLivenessMetadata(raw: item.toolResultJSON)
        if metadata.isRunning { return true }
        return Self.isTerminalBashTranscriptItem(item, metadata: metadata)
    }

    private func canMaterializeRunningBashOutput(for session: AgentTabSession) -> Bool {
        viewModel?.canBuildOrPublishActiveTranscriptBindings(for: session) ?? true
    }

    private static func isTerminalBashTranscriptItem(
        _ item: AgentChatItem,
        metadata: BashToolResultParser.Metadata
    ) -> Bool {
        guard item.kind == .toolResult else { return false }
        guard !metadata.isRunning else { return false }
        if item.toolIsError != nil { return true }
        if metadata.exitCode != nil { return true }
        return AgentTranscriptToolStatusSemantics.isTerminalStatusWord(metadata.statusWord)
    }

    private static func shouldRetainLateRunningOutputForTerminalBashResult(
        _ item: AgentChatItem,
        metadata: BashToolResultParser.Metadata
    ) -> Bool {
        if item.toolIsError == true { return true }
        if let exitCode = metadata.exitCode, exitCode != 0 { return true }
        let normalizedStatus = AgentTranscriptToolStatusSemantics.normalizedStatusWord(metadata.statusWord)
        return normalizedStatus == "failed" || normalizedStatus == "cancelled"
    }

    private func applyLateRunningOutputToTerminalBashResultIfNeeded(
        toolName: String = "bash",
        invocationID: UUID?,
        argsJSON: String?,
        processID: String?,
        appendedOutput: String?,
        session: AgentTabSession
    ) -> LiveBashRunningApplyResult? {
        guard let index = bashTranscriptItemIndex(
            toolName: toolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            processID: processID,
            session: session
        ) else { return nil }
        let item = session.items[index]
        let metadata = BashToolResultParser.parseLivenessMetadata(raw: item.toolResultJSON)
        guard Self.isTerminalBashTranscriptItem(item, metadata: metadata) else { return nil }
        guard Self.shouldRetainLateRunningOutputForTerminalBashResult(item, metadata: metadata),
              let mergedJSON = Self.commandExecutionTerminalResultJSONByMergingLateOutput(
                  raw: item.toolResultJSON,
                  appendedOutput: appendedOutput
              ),
              mergedJSON != item.toolResultJSON
        else {
            return .noChange
        }
        var updated = item
        updated.toolResultJSON = mergedJSON
        updated.text = mergedJSON
        session.replaceItem(at: index, with: updated)
        return .materializedTranscript
    }

    private static func commandExecutionTerminalResultJSONByMergingLateOutput(
        raw: String?,
        appendedOutput: String?
    ) -> String? {
        guard let incomingOutput = appendedOutput,
              !incomingOutput.isEmpty,
              let raw,
              let data = raw.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let existingOutput = commandExecutionOutputText(from: object)
        guard let mergedOutput = mergeCommandRunningOutput(existing: existingOutput, incoming: incomingOutput),
              mergedOutput != existingOutput
        else { return nil }
        object["aggregatedOutput"] = mergedOutput
        object.removeValue(forKey: "aggregated_output")
        guard JSONSerialization.isValidJSONObject(object),
              let encoded = try? JSONSerialization.data(withJSONObject: object, options: []),
              let json = String(data: encoded, encoding: .utf8)
        else { return nil }
        return json
    }

    private static func commandExecutionOutputText(from object: [String: Any]) -> String? {
        for key in [
            "aggregatedOutput", "aggregated_output",
            "formattedOutput", "formatted_output",
            "recentOutput", "recent_output",
            "combinedOutput", "combined_output",
            "output", "stdout", "stderr", "text", "message", "content", "result", "log", "logs"
        ] {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return value
            }
        }
        return nil
    }

    private func ensureLiveBashExecutionState(
        toolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        processID: String?,
        metadata: BashToolResultParser.Metadata? = nil,
        session: AgentTabSession,
        observedAt: Date,
        createAnchorIfNeeded: Bool = true
    ) -> AgentBashLiveExecutionState? {
        let fallbackSignature = Self.canonicalNativeToolFallbackSignature(toolName: toolName, argsJSON: argsJSON)
        let desiredKey = Self.bashExecutionKey(
            invocationID: invocationID,
            fallbackSignature: fallbackSignature,
            processID: processID
        )
        if let existing = existingBashExecutionLookup(
            invocationID: invocationID,
            processID: processID,
            fallbackSignature: fallbackSignature,
            session: session
        ) {
            if existing.key != desiredKey, let desiredKey {
                let migrated = AgentBashLiveExecutionState(
                    executionKey: desiredKey,
                    transcriptItemID: existing.state.transcriptItemID,
                    toolName: existing.state.toolName,
                    invocationID: invocationID ?? existing.state.invocationID,
                    fallbackSignature: fallbackSignature,
                    processID: processID ?? existing.state.processID,
                    command: existing.state.command,
                    statusWord: existing.state.statusWord,
                    exitCode: existing.state.exitCode,
                    output: existing.state.output,
                    isSummaryOnly: existing.state.isSummaryOnly,
                    lastSignalAt: observedAt
                )
                session.removeBashLiveExecution(forKey: existing.key)
                session.setBashLiveExecution(migrated)
                return migrated
            }
            return existing.state
        }
        guard createAnchorIfNeeded else { return nil }
        var itemIndex: Int
        if let existingIndex = bashTranscriptItemIndex(toolName: toolName, invocationID: invocationID, argsJSON: argsJSON, processID: processID, session: session) {
            itemIndex = existingIndex
            var item = session.items[itemIndex]
            var didChange = false
            if item.kind != .toolResult {
                item.kind = .toolResult
                didChange = true
            }
            if item.toolInvocationID == nil, let invocationID {
                item.toolInvocationID = invocationID
                didChange = true
            }
            if item.toolArgsJSON == nil, let argsJSON {
                item.toolArgsJSON = argsJSON
                didChange = true
            }
            if item.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                let runningJSON = Self.initialRunningCommandExecutionJSON(argsJSON: argsJSON)
                item.toolResultJSON = runningJSON
                item.text = runningJSON
                didChange = true
            }
            if didChange {
                session.replaceItem(at: itemIndex, with: item)
            }
        } else {
            let runningJSON = Self.initialRunningCommandExecutionJSON(argsJSON: argsJSON)
            let runningItem = AgentChatItem.toolResult(
                name: toolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: runningJSON,
                isError: false,
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(runningItem)
            itemIndex = session.items.count - 1
        }
        let item = session.items[itemIndex]
        let livenessMetadata = metadata ?? BashToolResultParser.parseLivenessMetadata(raw: item.toolResultJSON)
        guard let executionKey = desiredKey ?? Self.bashExecutionKey(invocationID: item.toolInvocationID, fallbackSignature: fallbackSignature, processID: livenessMetadata.processID) else {
            return nil
        }
        let state = AgentBashLiveExecutionState(
            executionKey: executionKey,
            transcriptItemID: item.id,
            toolName: toolName,
            invocationID: invocationID ?? item.toolInvocationID,
            fallbackSignature: fallbackSignature,
            processID: processID ?? livenessMetadata.processID,
            command: Self.extractCommandFromArgsJSON(argsJSON ?? item.toolArgsJSON),
            statusWord: livenessMetadata.statusWord ?? "running",
            exitCode: livenessMetadata.exitCode,
            output: nil,
            isSummaryOnly: livenessMetadata.isSummaryOnly,
            lastSignalAt: observedAt
        )
        session.setBashLiveExecution(state)
        return state
    }

    @discardableResult
    private func upsertLiveBashExecution(
        toolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        parsedResult: BashToolResultParser.ParsedResult,
        metadata: BashToolResultParser.Metadata? = nil,
        session: AgentTabSession,
        observedAt: Date,
        createAnchorIfNeeded: Bool = true
    ) -> Bool {
        guard var state = ensureLiveBashExecutionState(
            toolName: toolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            processID: parsedResult.processID,
            metadata: metadata,
            session: session,
            observedAt: observedAt,
            createAnchorIfNeeded: createAnchorIfNeeded
        ) else {
            return false
        }
        let previous = state
        state.processID = parsedResult.processID ?? state.processID
        state.command = parsedResult.command ?? state.command ?? Self.extractCommandFromArgsJSON(argsJSON)
        state.statusWord = parsedResult.statusWord ?? (parsedResult.isRunning ? "running" : state.statusWord)
        state.exitCode = parsedResult.isRunning ? nil : (parsedResult.exitCode ?? state.exitCode)
        state.output = Self.mergeCommandRunningOutput(existing: state.output, incoming: parsedResult.output)
        state.isSummaryOnly = parsedResult.isRunning ? parsedResult.isSummaryOnly : (state.isSummaryOnly || parsedResult.isSummaryOnly)
        state.lastSignalAt = observedAt
        guard state != previous else { return false }
        session.setBashLiveExecution(state)
        return true
    }

    private static func parsedBashLivenessResult(
        metadata: BashToolResultParser.Metadata,
        argsJSON: String?
    ) -> BashToolResultParser.ParsedResult {
        BashToolResultParser.ParsedResult(
            isRunning: metadata.isRunning,
            command: extractCommandFromArgsJSON(argsJSON),
            statusWord: metadata.statusWord,
            exitCode: metadata.exitCode,
            output: nil,
            processID: metadata.processID,
            isSummaryOnly: metadata.isSummaryOnly
        )
    }

    @discardableResult
    private func applyLiveBashRunningUpdate(
        _ runningUpdate: CodexNativeSessionController.CommandExecutionRunningUpdate,
        session: AgentTabSession,
        observedAt: Date
    ) -> LiveBashRunningApplyResult {
        let sourceItemsRevisionBefore = session.sourceItemsRevision
        let liveExecutionsBefore = session.bashLiveExecutionByKey
        let existingLookup = existingBashExecutionLookup(
            invocationID: runningUpdate.invocationID,
            processID: runningUpdate.processID,
            fallbackSignature: nil,
            session: session
        )
        let canMaterializeRunningOutput = canMaterializeRunningBashOutput(for: session)
        let shouldMaterializeToTranscript: Bool = {
            guard canMaterializeRunningOutput else { return false }
            guard let existingLookup else { return true }
            guard let item = session.items.first(where: { $0.id == existingLookup.state.transcriptItemID }) else {
                return true
            }
            if item.kind != .toolResult || item.toolIsError == true {
                return true
            }
            return !BashToolResultParser.parse(raw: item.toolResultJSON, argsJSON: item.toolArgsJSON).isRunning
        }()
        if let terminalApplyResult = applyLateRunningOutputToTerminalBashResultIfNeeded(
            invocationID: runningUpdate.invocationID,
            argsJSON: nil,
            processID: runningUpdate.processID,
            appendedOutput: runningUpdate.appendedOutput,
            session: session
        ) {
            return terminalApplyResult
        }
        if existingLookup == nil,
           let processID = runningUpdate.processID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !processID.isEmpty,
           let transcriptItem = session.items.last(where: { item in
               guard Self.normalizedExternalToolName(item.toolName) == "bash" else { return false }
               return Self.processIDsMatch(BashToolResultParser.parseLivenessMetadata(raw: item.toolResultJSON).processID, processID)
           })
        {
            let parsed = BashToolResultParser.parseLivenessMetadata(raw: transcriptItem.toolResultJSON)
            if !parsed.isRunning,
               transcriptItem.toolIsError == false || parsed.exitCode == 0 || parsed.statusWord == "completed"
            {
                return .noChange
            }
        }
        guard var state = existingLookup?.state ?? ensureLiveBashExecutionState(
            toolName: "bash",
            invocationID: runningUpdate.invocationID,
            argsJSON: nil,
            processID: runningUpdate.processID,
            session: session,
            observedAt: observedAt
        ) else {
            return .noChange
        }
        let previous = state
        state.processID = runningUpdate.processID ?? state.processID
        state.statusWord = "running"
        state.exitCode = nil
        state.isSummaryOnly = false
        state.output = Self.mergeCommandRunningOutput(existing: state.output, incoming: runningUpdate.appendedOutput)
        state.lastSignalAt = observedAt
        guard state != previous else {
            if session.sourceItemsRevision != sourceItemsRevisionBefore {
                return canMaterializeRunningOutput ? .materializedTranscript : .liveStateOnly
            }
            if session.bashLiveExecutionByKey != liveExecutionsBefore {
                return .liveStateOnly
            }
            return .noChange
        }
        session.setBashLiveExecution(state)
        if shouldMaterializeToTranscript {
            if materializeRunningBashExecution(state, session: session) {
                return .materializedTranscript
            }
        }
        if session.sourceItemsRevision != sourceItemsRevisionBefore {
            return canMaterializeRunningOutput ? .materializedTranscript : .liveStateOnly
        }
        return .liveStateOnly
    }

    @discardableResult
    private func materializeRunningBashExecution(
        _ state: AgentBashLiveExecutionState,
        session: AgentTabSession
    ) -> Bool {
        guard let index = session.items.firstIndex(where: { $0.id == state.transcriptItemID }) else {
            return false
        }
        var item = session.items[index]
        let nextJSON = state.renderedResultJSON
        let desiredIsError = item.toolIsError == true
        let shouldUpdate = item.kind != .toolResult
            || item.toolResultJSON != nextJSON
            || item.toolIsError != desiredIsError
            || item.toolInvocationID != state.invocationID
            || item.toolName != state.toolName
        guard shouldUpdate else { return false }
        item.kind = .toolResult
        item.toolName = state.toolName
        item.toolInvocationID = state.invocationID ?? item.toolInvocationID
        item.toolResultJSON = nextJSON
        item.toolIsError = desiredIsError
        item.text = nextJSON
        session.replaceItem(at: index, with: item)
        return true
    }

    @discardableResult
    private func finalizeLiveBashExecution(
        toolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        resultJSON: String?,
        statusWord: String,
        isError: Bool?,
        session: AgentTabSession,
        observedAt: Date
    ) -> Bool {
        flushPendingCommandRunningUpdatesBeforeFinalization(session: session, observedAt: observedAt)
        let metadata = BashToolResultParser.parseLivenessMetadata(raw: resultJSON)
        let fallbackSignature = Self.canonicalNativeToolFallbackSignature(toolName: toolName, argsJSON: argsJSON)
        guard let liveState = existingBashExecutionLookup(
            invocationID: invocationID,
            processID: metadata.processID,
            fallbackSignature: fallbackSignature,
            session: session
        )?.state ?? ensureLiveBashExecutionState(
            toolName: toolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            processID: metadata.processID,
            session: session,
            observedAt: observedAt
        ) else {
            return false
        }
        guard let index = session.items.firstIndex(where: { $0.id == liveState.transcriptItemID }) else {
            session.removeBashLiveExecution(forKey: liveState.executionKey)
            return false
        }
        var item = session.items[index]
        let baseJSON = liveState.renderedResultJSON
        let finalJSON: String = if let resultJSON, !resultJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            CodexNativeSessionController.mergeCommandExecutionCompletionPayload(
                existing: baseJSON,
                incoming: resultJSON,
                argsJSON: argsJSON ?? item.toolArgsJSON
            )
        } else {
            Self.withCommandExecutionTerminalStatus(raw: baseJSON, status: statusWord)
        }
        item.kind = .toolResult
        item.toolInvocationID = invocationID ?? item.toolInvocationID
        item.toolArgsJSON = argsJSON ?? item.toolArgsJSON
        item.toolResultJSON = finalJSON
        item.toolIsError = isError ?? item.toolIsError
        item.text = finalJSON
        session.replaceItem(at: index, with: item)
        session.removeBashLiveExecution(forKey: liveState.executionKey)
        return true
    }

    private func rebuildLiveBashExecutionState(from session: AgentTabSession) {
        session.clearBashLiveExecutions()
        for item in session.items {
            guard item.kind == .toolResult else { continue }
            guard Self.normalizedExternalToolName(item.toolName) == "bash" else { continue }
            let metadata = BashToolResultParser.parseLivenessMetadata(raw: item.toolResultJSON)
            if metadata.isRunning {
                _ = upsertLiveBashExecution(
                    toolName: item.toolName ?? "bash",
                    invocationID: item.toolInvocationID,
                    argsJSON: item.toolArgsJSON,
                    parsedResult: Self.parsedBashLivenessResult(metadata: metadata, argsJSON: item.toolArgsJSON),
                    metadata: metadata,
                    session: session,
                    observedAt: item.timestamp
                )
            }
        }
    }

    private func commandRunningUpdateKey(_ update: CodexNativeSessionController.CommandExecutionRunningUpdate) -> String {
        if let processID = update.processID, !processID.isEmpty {
            return "process:\(processID)"
        }
        if let invocationID = update.invocationID {
            return "invocation:\(invocationID.uuidString)"
        }
        return "unknown"
    }

    @discardableResult
    private func flushPendingCommandRunningUpdatesBeforeFinalization(
        session: AgentTabSession,
        observedAt: Date
    ) -> LiveBashRunningApplyResult {
        session.pendingCommandRunningFlushTask?.cancel()
        session.pendingCommandRunningFlushTask = nil
        session.pendingCommandRunningFlushUsesLiveOutputDelay = false
        guard !session.pendingCommandRunningByKey.isEmpty else { return .noChange }
        let updates = Array(session.pendingCommandRunningByKey.values)
        session.pendingCommandRunningByKey.removeAll()
        var applyResult: LiveBashRunningApplyResult = .noChange
        for update in updates {
            applyResult.merge(applyLiveBashRunningUpdate(update, session: session, observedAt: observedAt))
            CodexDebugLog.log("[AgentModeVM][CodexUI] commandExecutionRunning pre-finalize invocationID=\(update.invocationID?.uuidString ?? "nil") processID=\(update.processID ?? "nil") outputChars=\(update.appendedOutput?.count ?? 0)")
        }
        #if DEBUG
            if AgentModePerfDiagnostics.isEnabled {
                AgentModePerfDiagnostics.increment("provider.codex.commandRunning.flushBeforeFinalize", tabID: session.tabID)
                AgentModePerfDiagnostics.event(
                    "provider.codex.commandRunning.flushBeforeFinalize",
                    tabID: session.tabID,
                    fields: [
                        "batchSize": String(updates.count),
                        "didChange": String(applyResult.didChange)
                    ]
                )
            }
        #endif
        return applyResult
    }

    private static func mergeCommandRunningOutput(
        existing: String?,
        incoming: String?
    ) -> String? {
        let existingValue = (existing?.isEmpty == false) ? existing : nil
        let incomingValue = (incoming?.isEmpty == false) ? incoming : nil
        switch (existingValue, incomingValue) {
        case (nil, nil):
            return nil
        case (let value?, nil), (nil, let value?):
            return capMergedCommandRunningOutput(value)
        case let (existingValue?, incomingValue?):
            let existingTail = capMergedCommandRunningOutput(existingValue)
            let incomingTail = capMergedCommandRunningOutput(incomingValue)
            let merged = existingTail + incomingTail
            return capMergedCommandRunningOutput(merged)
        }
    }

    private static func capMergedCommandRunningOutput(_ raw: String) -> String {
        let maxCharacters = maxMergedCommandRunningOutputCharacters
        guard raw.count > maxCharacters else { return raw }
        return String(raw.suffix(maxCharacters))
    }

    private func mergeCommandRunningUpdates(
        _ existing: CodexNativeSessionController.CommandExecutionRunningUpdate,
        with incoming: CodexNativeSessionController.CommandExecutionRunningUpdate
    ) -> CodexNativeSessionController.CommandExecutionRunningUpdate {
        let invocationID = incoming.invocationID ?? existing.invocationID
        let processID = incoming.processID ?? existing.processID
        let appendedOutput = Self.mergeCommandRunningOutput(
            existing: existing.appendedOutput,
            incoming: incoming.appendedOutput
        )
        return .init(
            invocationID: invocationID,
            processID: processID,
            appendedOutput: appendedOutput,
            sealsAssistantBoundary: existing.sealsAssistantBoundary || incoming.sealsAssistantBoundary
        )
    }

    private func commandRunningCoalesceDelayNanos(
        for update: CodexNativeSessionController.CommandExecutionRunningUpdate
    ) -> UInt64 {
        if update.sealsAssistantBoundary {
            return commandRunningStatusCoalesceDelayNanos
        }
        let hasOutput = update.appendedOutput?.isEmpty == false
        return hasOutput ? commandRunningLiveOutputCoalesceDelayNanos : commandRunningStatusCoalesceDelayNanos
    }

    #if DEBUG
        @_spi(TestSupport)
        public func test_handleCodexNativeEvent(
            _ event: CodexNativeSessionController.Event,
            session: AgentTabSession
        ) async {
            await handleCodexNativeEvent(event, session: session)
        }

        @_spi(TestSupport)
        public func test_handleCodexTrackerToolCall(
            invocationID: UUID?,
            toolName: String,
            args: [String: Value]? = nil,
            session: AgentTabSession
        ) {
            handleCodexToolCall(
                invocationID: invocationID,
                toolName: toolName,
                args: args,
                session: session
            )
        }

        @_spi(TestSupport)
        public func test_handleCodexTrackerToolResult(
            invocationID: UUID?,
            toolName: String,
            args: [String: Value]? = nil,
            resultJSON: String,
            isError: Bool,
            session: AgentTabSession
        ) {
            handleCodexToolResult(
                invocationID: invocationID,
                toolName: toolName,
                args: args,
                resultJSON: resultJSON,
                isError: isError,
                session: session
            )
        }

        @_spi(TestSupport)
        public func test_hasPendingCodexTerminalSettle(tabID: UUID) -> Bool {
            pendingCodexTerminalSettleByTabID[tabID] != nil
        }

        @_spi(TestSupport)
        public func test_readySessionToolTrackingRequestCount(tabID: UUID) -> Int {
            testReadySessionToolTrackingRequestsByTabID[tabID, default: 0]
        }

        @_spi(TestSupport)
        public func test_forcePendingCodexTerminalSettleTimeout(
            session: AgentTabSession
        ) async {
            guard let pending = pendingCodexTerminalSettleByTabID[session.tabID] else {
                return
            }
            await completePendingCodexTerminalSettle(
                tabID: session.tabID,
                session: session,
                generation: pending.generation,
                trigger: "test-timeout"
            )
        }

        @_spi(TestSupport)
        public func test_claimCodexFallbackHead(
            session: AgentTabSession,
            expectedQueueID: UUID,
            beginsSuccessorAttempt: Bool
        ) -> Bool {
            claimCodexFallbackHead(
                session: session,
                expectedQueueID: expectedQueueID,
                beginsSuccessorAttempt: beginsSuccessorAttempt
            ) != nil
        }

        @_spi(TestSupport)
        public func test_recordDeliveredCodexFallbackAttempt(
            _ attemptID: UUID,
            session: AgentTabSession
        ) {
            removeQueuedCodexFallbackForDeliveredAttempt(attemptID, session: session)
        }

        @_spi(TestSupport)
        public func test_dispatchClaimedCodexFallback(session: AgentTabSession) async {
            guard let head = session.codexFallbackDispatchInFlight else { return }
            await dispatchClaimedCodexFallback(head, session: session)
        }

        @_spi(TestSupport)
        public static func test_mergeCommandRunningUpdates(
            existing: CodexNativeSessionController.CommandExecutionRunningUpdate,
            incoming: CodexNativeSessionController.CommandExecutionRunningUpdate
        ) -> CodexNativeSessionController.CommandExecutionRunningUpdate {
            let invocationID = incoming.invocationID ?? existing.invocationID
            let processID = incoming.processID ?? existing.processID
            let appendedOutput = mergeCommandRunningOutput(
                existing: existing.appendedOutput,
                incoming: incoming.appendedOutput
            )
            return .init(
                invocationID: invocationID,
                processID: processID,
                appendedOutput: appendedOutput,
                sealsAssistantBoundary: existing.sealsAssistantBoundary || incoming.sealsAssistantBoundary
            )
        }

        @_spi(TestSupport)
        public static var test_maxMergedCommandRunningOutputCharacters: Int {
            maxMergedCommandRunningOutputCharacters
        }

        @_spi(TestSupport)
        public static func test_collapseCodexModelOptions(
            _ options: [AgentModelOption]
        ) -> [AgentModelOption] {
            collapseCodexModelOptions(options, capabilities: .seedOnly)
        }

        @_spi(TestSupport)
        public static func test_shouldTreatRunningProcessAsAlive(
            observedAliveProcessIDs: Set<String>,
            processID: String,
            firstSeenAt: Date?,
            now: Date,
            graceInterval: TimeInterval,
            isAlive: Bool
        ) -> Bool {
            shouldTreatRunningProcessAsAlive(
                processID: processID,
                observedAliveProcessIDs: observedAliveProcessIDs,
                firstSeenAt: firstSeenAt,
                now: now,
                graceInterval: graceInterval,
                processIsAlive: { _ in isAlive }
            )
        }

        @_spi(TestSupport)
        public static func test_shouldRetryCodexStartWithoutResume(
            existingRef: CodexNativeSessionController.SessionRef?,
            errorDescription: String
        ) -> Bool {
            let error = NSError(
                domain: "CodexAgentModeCoordinatorTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: errorDescription]
            )
            return shouldRetryCodexStartWithoutResume(existingRef: existingRef, error: error)
        }
    #endif

    private func enqueueCommandExecutionRunningUpdate(
        _ runningUpdate: CodexNativeSessionController.CommandExecutionRunningUpdate,
        session: AgentTabSession
    ) {
        let key = commandRunningUpdateKey(runningUpdate)
        let didMerge = session.pendingCommandRunningByKey[key] != nil
        if let existing = session.pendingCommandRunningByKey[key] {
            session.pendingCommandRunningByKey[key] = mergeCommandRunningUpdates(existing, with: runningUpdate)
        } else {
            session.pendingCommandRunningByKey[key] = runningUpdate
        }
        #if DEBUG
            if AgentModePerfDiagnostics.isEnabled {
                AgentModePerfDiagnostics.increment("provider.codex.commandRunning.enqueue", tabID: session.tabID)
                if didMerge {
                    AgentModePerfDiagnostics.increment("provider.codex.commandRunning.merge", tabID: session.tabID)
                }
                AgentModePerfDiagnostics.event(
                    "provider.codex.commandRunning.enqueue",
                    tabID: session.tabID,
                    fields: [
                        "merged": String(didMerge),
                        "pendingKeys": String(session.pendingCommandRunningByKey.count),
                        "outputChars": String(runningUpdate.appendedOutput?.count ?? 0)
                    ]
                )
            }
        #endif
        let delayNanos = commandRunningCoalesceDelayNanos(for: runningUpdate)
        let usesLiveOutputDelay = delayNanos == commandRunningLiveOutputCoalesceDelayNanos
        if let existingTask = session.pendingCommandRunningFlushTask {
            guard session.pendingCommandRunningFlushUsesLiveOutputDelay, !usesLiveOutputDelay else { return }
            existingTask.cancel()
            session.pendingCommandRunningFlushTask = nil
        }
        session.pendingCommandRunningFlushUsesLiveOutputDelay = usesLiveOutputDelay
        session.pendingCommandRunningFlushTask = Task { [weak self, weak session] in
            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled else { return }
            guard let self, let session else { return }
            flushCommandExecutionRunningUpdates(session: session)
        }
    }

    private func flushCommandExecutionRunningUpdates(session: AgentTabSession) {
        #if DEBUG
            let diagnosticsStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        session.pendingCommandRunningFlushTask?.cancel()
        session.pendingCommandRunningFlushTask = nil
        session.pendingCommandRunningFlushUsesLiveOutputDelay = false
        guard !session.pendingCommandRunningByKey.isEmpty else { return }
        let updates = Array(session.pendingCommandRunningByKey.values)
        session.pendingCommandRunningByKey.removeAll()
        #if DEBUG
            if AgentModePerfDiagnostics.isEnabled {
                AgentModePerfDiagnostics.increment("provider.codex.commandRunning.flush", tabID: session.tabID)
                AgentModePerfDiagnostics.event(
                    "provider.codex.commandRunning.flushStart",
                    tabID: session.tabID,
                    fields: ["batchSize": String(updates.count)]
                )
            }
        #endif

        let observedAt = Date()
        var applyResult: LiveBashRunningApplyResult = .noChange
        for update in updates {
            applyResult.merge(applyLiveBashRunningUpdate(update, session: session, observedAt: observedAt))
            CodexDebugLog.log("[AgentModeVM][CodexUI] commandExecutionRunning invocationID=\(update.invocationID?.uuidString ?? "nil") processID=\(update.processID ?? "nil") outputChars=\(update.appendedOutput?.count ?? 0)")
        }
        guard applyResult.didChange else {
            #if DEBUG
                if AgentModePerfDiagnostics.isEnabled {
                    AgentModePerfDiagnostics.increment("provider.codex.commandRunning.flushNoChange", tabID: session.tabID)
                    AgentModePerfDiagnostics.event("provider.codex.commandRunning.flushNoChange", tabID: session.tabID, fields: ["batchSize": String(updates.count)])
                }
            #endif
            return
        }
        updateBashLivenessTaskState(for: session)
        #if DEBUG
            if AgentModePerfDiagnostics.isEnabled {
                AgentModePerfDiagnostics.increment("provider.codex.commandRunning.flushDidUpdate", tabID: session.tabID)
                if let diagnosticsStartMS {
                    AgentModePerfDiagnostics.event(
                        "provider.codex.commandRunning.flushComplete",
                        tabID: session.tabID,
                        fields: [
                            "batchSize": String(updates.count),
                            "duration": AgentModePerfDiagnostics.formatElapsedMS(since: diagnosticsStartMS),
                            "liveBash": String(session.bashLiveExecutionByKey.count)
                        ]
                    )
                }
            }
        #endif
        switch applyResult {
        case .noChange:
            break
        case .liveStateOnly:
            viewModel?.requestUIRefresh(tabID: session.tabID, scope: .transcriptRuntime)
        case .materializedTranscript:
            viewModel?.requestUIRefresh(tabID: session.tabID)
        }
    }

    private func updateBashLivenessTaskState(for session: AgentTabSession) {
        guard session.selectedAgent == .codexExec else {
            stopBashLivenessTask(for: session.tabID)
            return
        }
        if session.bashLiveExecutionByKey.values.contains(where: { execution in
            guard execution.isRunning,
                  let processID = execution.processID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !processID.isEmpty
            else {
                return false
            }
            return Self.isCandidatePOSIXProcessID(processID)
        }) {
            ensureBashLivenessTask(for: session)
        } else {
            stopBashLivenessTask(for: session.tabID)
        }
    }

    private func ensureBashLivenessTask(for session: AgentTabSession) {
        if bashLivenessTasksByTabID.hasTask(for: session.tabID) {
            return
        }
        bashLivenessTasksByTabID.set(
            session.tabID,
            task: Task { [weak self, weak session] in
                while !Task.isCancelled {
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: bashLivenessPollIntervalNanos)
                    guard !Task.isCancelled else { return }
                    guard let session else { return }
                    pollBashLiveness(for: session)
                }
            }
        )
    }

    private func stopBashLivenessTask(for tabID: UUID) {
        bashObservedAliveProcessIDsByTabID.removeValue(forKey: tabID)
        bashRunningProcessFirstSeenByTabID.removeValue(forKey: tabID)
        bashLivenessTasksByTabID.cancel(tabID)
    }

    private func stopAllBashLivenessTasks() {
        bashLivenessTasksByTabID.cancelAll()
        bashObservedAliveProcessIDsByTabID.removeAll()
        bashRunningProcessFirstSeenByTabID.removeAll()
    }

    private func scheduleCodexIdleShutdownIfNeeded(
        for session: AgentTabSession,
        reason: String,
        effectiveRunState: AgentSessionRunState? = nil
    ) {
        let runState = effectiveRunState ?? session.runState
        guard session.selectedAgent == .codexExec,
              session.codexController != nil,
              session.pendingApproval == nil,
              !runState.isActive
        else {
            cancelCodexIdleShutdown(for: session.tabID)
            return
        }
        cancelCodexIdleShutdown(for: session.tabID)
        let tabID = session.tabID
        let delayNanos = codexIdleShutdownDelayNanos
        logCodex("[AgentModeVM][CodexIdle] scheduled shutdown in 300s for tab \(tabID) reason=\(reason)")
        codexIdleShutdownTasksByTabID.set(
            tabID,
            task: Task { [weak self, weak session] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: delayNanos)
                defer { self.codexIdleShutdownTasksByTabID.remove(tabID) }
                guard !Task.isCancelled else { return }
                guard let session else { return }
                guard session.selectedAgent == .codexExec,
                      session.codexController != nil,
                      session.pendingApproval == nil,
                      !session.runState.isActive
                else {
                    return
                }
                if session.codexConversationID != nil || session.codexRolloutPath != nil {
                    markCodexReconnectNeeded(for: session, source: "idle-timeout", scheduleSave: false)
                }
                logCodex("[AgentModeVM][CodexIdle] shutting down idle app-server for tab \(tabID) reason=\(reason)")
                await shutdownCodexSession(session)
                viewModel?.requestUIRefresh(tabID: tabID, urgent: true)
                viewModel?.scheduleSave(for: tabID)
            }
        )
    }

    private func cancelCodexIdleShutdown(for tabID: UUID) {
        codexIdleShutdownTasksByTabID.cancel(tabID)
    }

    private func stopAllCodexIdleShutdownTasks() {
        codexIdleShutdownTasksByTabID.cancelAll()
    }

    private func updateCodexStallWatchdogState(for session: AgentTabSession) {
        guard codexStallWatchdogProbeThreshold > 0, codexStallWatchdogRecoveryThreshold > 0 else {
            stopCodexStallWatchdog(for: session.tabID)
            return
        }
        guard session.selectedAgent == .codexExec,
              session.codexController != nil,
              session.runState.isActive,
              !hasPendingCodexInteraction(for: session)
        else {
            stopCodexStallWatchdog(for: session.tabID)
            return
        }
        guard !session.codexWatchdogState.isPausedAfterWarning else {
            stopCodexStallWatchdog(for: session.tabID)
            return
        }
        ensureCodexStallWatchdog(for: session)
    }

    package func agentModeViewModel(
        _ viewModel: any AgentSessionHost,
        didChangeRunInteractionStateFor session: AgentTabSession,
        reason: AgentRunInteractionStateChangeReason
    ) {
        handleRunInteractionStateChange(for: session, reason: reason)
    }

    private func handleRunInteractionStateChange(
        for session: AgentTabSession,
        reason: AgentRunInteractionStateChangeReason
    ) {
        _ = reason
        updateCodexStallWatchdogState(for: session)
    }

    private func ensureCodexStallWatchdog(for session: AgentTabSession) {
        guard !codexStallWatchdogTasksByTabID.hasTask(for: session.tabID) else { return }
        let tabID = session.tabID
        codexStallWatchdogTasksByTabID.set(
            tabID,
            task: Task { [weak self, weak session] in
                var removedTaskEntry = false
                defer {
                    if let self, !removedTaskEntry {
                        self.codexStallWatchdogTasksByTabID.remove(tabID)
                    }
                }
                while !Task.isCancelled {
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: codexStallWatchdogPollIntervalNanos)
                    guard !Task.isCancelled else { return }
                    guard let session else { return }
                    guard session.selectedAgent == .codexExec,
                          session.codexController != nil,
                          session.runState.isActive,
                          !hasPendingCodexInteraction(for: session)
                    else {
                        codexStallWatchdogTasksByTabID.remove(tabID)
                        removedTaskEntry = true
                        return
                    }
                    let now = Date()
                    if shouldSuppressCodexWatchdog(for: session, now: now) {
                        continue
                    }
                    let referenceDate = codexWatchdogReferenceDate(for: session)
                    guard now.timeIntervalSince(referenceDate) >= codexStallWatchdogProbeThreshold else {
                        continue
                    }
                    let hardToolReasons = hardLocalToolLivenessReasons(for: session)
                    if !hardToolReasons.isEmpty {
                        recordCodexWatchdogProgress(for: session, at: now)
                        logCodex("[AgentModeVM][CodexWatchdog] suppressing watchdog for tab \(tabID) because strong local tool liveness is still active reasons=\(hardToolReasons.joined(separator: ","))")
                        continue
                    }
                    logCodex("[AgentModeVM][CodexWatchdog] probe threshold reached for tab \(tabID); evaluating recovery")
                    let watchdogRunID = session.runID
                    switch await attemptCodexRecovery(
                        session: session,
                        trigger: .stallWatchdog,
                        sourceController: session.codexController
                    ) {
                    case .recovered, .skipped:
                        codexStallWatchdogTasksByTabID.remove(tabID)
                        removedTaskEntry = true
                        updateCodexStallWatchdogState(for: session)
                        return
                    case let .unrecoverable(errorMessage):
                        guard shouldFinalizeAfterRecovery(session: session, expectedRunID: watchdogRunID, source: "stall-watchdog") else {
                            codexStallWatchdogTasksByTabID.remove(tabID)
                            removedTaskEntry = true
                            updateCodexStallWatchdogState(for: session)
                            return
                        }
                        await finalizeCodexRun(
                            session,
                            turnStatus: .failed,
                            reason: "stall-watchdog",
                            errorMessage: errorMessage,
                            notifyOnCompleted: false,
                            deleteDeferredFilesWhenFailureHasNoInFlight: true
                        )
                        codexStallWatchdogTasksByTabID.remove(tabID)
                        removedTaskEntry = true
                        return
                    }
                }
            }
        )
    }

    private func stopCodexStallWatchdog(for tabID: UUID) {
        codexStallWatchdogTasksByTabID.cancel(tabID)
    }

    private func stopAllCodexStallWatchdogTasks() {
        codexStallWatchdogTasksByTabID.cancelAll()
    }

    private func pollBashLiveness(for session: AgentTabSession) {
        guard session.selectedAgent == .codexExec else {
            stopBashLivenessTask(for: session.tabID)
            return
        }
        let now = Date()
        let activeExecutions = session.bashLiveExecutionByKey.values.filter { execution in
            guard execution.isRunning,
                  let processID = execution.processID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !processID.isEmpty
            else {
                return false
            }
            return Self.isCandidatePOSIXProcessID(processID)
        }
        let processIDs = Set(activeExecutions.compactMap(\.processID))
        var observedAliveProcessIDs = bashObservedAliveProcessIDsByTabID[session.tabID] ?? []
        var firstSeenByProcessID = bashRunningProcessFirstSeenByTabID[session.tabID] ?? [:]
        firstSeenByProcessID = firstSeenByProcessID.filter { processIDs.contains($0.key) }
        for processID in processIDs {
            if firstSeenByProcessID[processID] == nil {
                firstSeenByProcessID[processID] = now
            }
            if Self.processIsAlive(processID) {
                observedAliveProcessIDs.insert(processID)
            }
        }
        bashObservedAliveProcessIDsByTabID[session.tabID] = observedAliveProcessIDs
        bashRunningProcessFirstSeenByTabID[session.tabID] = firstSeenByProcessID

        var didFinalize = false
        var hasAliveRunningProcess = false
        for execution in activeExecutions {
            guard let processID = execution.processID else { continue }
            if now.timeIntervalSince(execution.lastSignalAt) < bashSignalQuietPollGraceInterval {
                hasAliveRunningProcess = true
                continue
            }
            if Self.shouldTreatRunningProcessAsAlive(
                processID: processID,
                observedAliveProcessIDs: observedAliveProcessIDs,
                firstSeenAt: firstSeenByProcessID[processID],
                now: now,
                graceInterval: bashUnobservedProcessFinalizeGraceInterval,
                processIsAlive: Self.processIsAlive
            ) {
                hasAliveRunningProcess = true
                continue
            }
            if finalizeLiveBashExecution(
                toolName: execution.toolName,
                invocationID: execution.invocationID,
                argsJSON: session.items.first(where: { $0.id == execution.transcriptItemID })?.toolArgsJSON,
                resultJSON: nil,
                statusWord: "finished",
                isError: false,
                session: session,
                observedAt: now
            ) {
                didFinalize = true
            }
        }

        if didFinalize {
            updateBashLivenessTaskState(for: session)
            viewModel?.requestUIRefresh(tabID: session.tabID)
            viewModel?.scheduleSave(for: session.tabID)
        }
        if !hasAliveRunningProcess {
            stopBashLivenessTask(for: session.tabID)
        }
    }

    private static func runningBashProcessScan(in items: [AgentChatItem]) -> RunningBashProcessScan {
        var entries: [RunningBashProcessScanEntry] = []
        var processIDs: Set<String> = []
        for index in items.indices {
            let item = items[index]
            guard item.kind == .toolResult else { continue }
            guard normalizedExternalToolName(item.toolName) == "bash" else { continue }
            let parsed = BashToolResultParser.parseLivenessMetadata(raw: item.toolResultJSON)
            guard parsed.isRunning else { continue }
            guard let processID = parsed.processID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !processID.isEmpty,
                  isCandidatePOSIXProcessID(processID)
            else {
                continue
            }
            entries.append(.init(index: index, processID: processID))
            processIDs.insert(processID)
        }
        return RunningBashProcessScan(entries: entries, processIDs: processIDs)
    }

    private static func shouldTreatRunningProcessAsAlive(
        processID: String,
        observedAliveProcessIDs: Set<String>,
        firstSeenAt: Date?,
        now: Date,
        graceInterval: TimeInterval,
        processIsAlive: (String) -> Bool
    ) -> Bool {
        if observedAliveProcessIDs.contains(processID) {
            return processIsAlive(processID)
        }
        guard let firstSeenAt else {
            return true
        }
        guard now.timeIntervalSince(firstSeenAt) >= graceInterval else {
            return true
        }
        return processIsAlive(processID)
    }

    private static func processIsAlive(_ processID: String) -> Bool {
        guard let pidValue = Int32(processID), pidValue > 0 else {
            return true
        }
        #if canImport(Darwin)
            errno = 0
            let result = kill(pidValue, 0)
            if result == 0 {
                return true
            }
            return errno == EPERM
        #else
            return true
        #endif
    }

    private static func isCandidatePOSIXProcessID(_ processID: String) -> Bool {
        guard let pidValue = Int32(processID), pidValue > 0 else {
            return false
        }
        return true
    }

    #if DEBUG
        private func codexEventMetricKind(_ event: CodexNativeSessionController.Event) -> String {
            switch event {
            case .assistantDelta: "assistantDelta"
            case .canonicalAssistantDelta: "canonicalAssistantDelta"
            case .assistantCompleted: "assistantCompleted"
            case .reasoningDelta: "reasoningDelta"
            case .reasoningCompleted: "reasoningCompleted"
            case .tokenUsage: "tokenUsage"
            case .usageObservation: "usageObservation"
            case .modelRerouted: "modelRerouted"
            case .approvalRequest: "approvalRequest"
            case .permissionsRequest: "permissionsRequest"
            case .requestUserInput: "requestUserInput"
            case .mcpElicitationRequest: "mcpElicitationRequest"
            case .serverRequestIssue: "serverRequestIssue"
            case .toolCall: "toolCall"
            case .toolResult: "toolResult"
            case .commandExecutionRunning: "commandExecutionRunning"
            case .turnStarted: "turnStarted"
            case .turnCompleted: "turnCompleted"
            case .contextCompacted: "contextCompacted"
            case .livenessActivity: "livenessActivity"
            case .errorNotification: "errorNotification"
            case .error: "error"
            case .system: "system"
            }
        }
    #endif

    private func debugCodexEventSummary(_ event: CodexNativeSessionController.Event) -> String {
        switch event {
        case let .assistantDelta(delta):
            "assistantDelta chars=\(delta.count)"
        case let .canonicalAssistantDelta(text, scope):
            "canonicalAssistantDelta chars=\(text.count) turnID=\(scope.turnID) itemID=\(scope.itemID)"
        case let .assistantCompleted(payload):
            "assistantCompleted chars=\(payload.text.count) turnID=\(payload.scope.turnID) itemID=\(payload.scope.itemID)"
        case let .reasoningDelta(payload):
            "reasoningDelta kind=\(payload.kind) chars=\(payload.text.count) itemID=\(payload.itemID ?? "nil") groupID=\(payload.groupID ?? "nil")"
        case let .reasoningCompleted(payload):
            "reasoningCompleted summary=\(payload.summary.count) content=\(payload.content.count) turnID=\(payload.scope.turnID) itemID=\(payload.scope.itemID)"
        case let .tokenUsage(usage):
            "tokenUsage modelContextWindow=\(usage.modelContextWindow.map(String.init(describing:)) ?? "nil") lastTotalTokens=\(usage.lastTotalTokens.map(String.init(describing:)) ?? "nil") totalTotalTokens=\(usage.totalTotalTokens.map(String.init(describing:)) ?? "nil")"
        case let .usageObservation(observation):
            "usageObservation ordinal=\(observation.ordinal) turnID=\(observation.turnID ?? "nil") attribution=\(observation.turnAttribution.rawValue)"
        case let .modelRerouted(reroute):
            "modelRerouted turnID=\(reroute.turnID ?? "nil") from=\(reroute.fromModel) to=\(reroute.toModel)"
        case let .approvalRequest(request):
            "approvalRequest kind=\(request.kind)"
        case .permissionsRequest:
            "permissionsRequest"
        case let .requestUserInput(request):
            "requestUserInput questions=\(request.questions.count)"
        case let .mcpElicitationRequest(request):
            "mcpElicitationRequest server=\(request.serverName ?? "nil")"
        case let .serverRequestIssue(issue):
            "serverRequestIssue kind=\(issue.kind.rawValue) method=\(issue.method)"
        case let .toolCall(name, invocationID, _):
            "toolCall tool=\(name) invocationID=\(invocationID?.uuidString ?? "nil")"
        case let .toolResult(name, invocationID, _, resultJSON, isError):
            "toolResult tool=\(name) invocationID=\(invocationID?.uuidString ?? "nil") isError=\(isError.map(String.init(describing:)) ?? "nil") resultChars=\(resultJSON.count)"
        case let .commandExecutionRunning(update):
            "commandExecutionRunning invocationID=\(update.invocationID?.uuidString ?? "nil") processID=\(update.processID ?? "nil") outputChars=\(update.appendedOutput?.count ?? 0)"
        case let .turnStarted(turnID):
            "turnStarted turnID=\(turnID ?? "nil")"
        case let .turnCompleted(turnID, status, failure):
            "turnCompleted turnID=\(turnID ?? "nil") status=\(status) failure=\(failure != nil)"
        case let .contextCompacted(turnID):
            "contextCompacted turnID=\(turnID ?? "nil")"
        case let .livenessActivity(activity):
            "livenessActivity kind=\(activity.kind.rawValue) method=\(activity.method) activeFlags=\(activity.activeFlags.joined(separator: ","))"
        case let .errorNotification(notification):
            "errorNotification willRetry=\(notification.willRetry.map(String.init(describing:)) ?? "nil") message=\(notification.message)"
        case let .error(message):
            "error chars=\(message.count)"
        case let .system(message):
            "system chars=\(message.count)"
        }
    }

    package func reconcileCodexCommandExecutionRunningUpdate(
        toolName: String,
        argsJSON: String?,
        resultJSON: String?,
        isError: Bool?,
        session: AgentTabSession
    ) {
        let observedAt = Date()
        if Self.normalizedExternalToolName(toolName) == "write_stdin",
           let runningUpdate = CodexNativeSessionController.commandExecutionRunningUpdate(
               fromToolName: toolName,
               argsJSON: argsJSON,
               resultJSON: resultJSON,
               isError: isError
           )
        {
            let applyResult = applyLiveBashRunningUpdate(runningUpdate, session: session, observedAt: observedAt)
            guard applyResult.didChange else { return }
            updateBashLivenessTaskState(for: session)
            switch applyResult {
            case .noChange:
                break
            case .liveStateOnly:
                viewModel?.requestUIRefresh(tabID: session.tabID, scope: .transcriptRuntime)
            case .materializedTranscript:
                viewModel?.requestUIRefresh(tabID: session.tabID)
            }
            return
        }
        guard Self.normalizedExternalToolName(toolName) == "bash" else { return }
        let metadata = BashToolResultParser.parseLivenessMetadata(raw: resultJSON)
        let parsedResult = Self.parsedBashLivenessResult(metadata: metadata, argsJSON: argsJSON)
        if parsedResult.isRunning {
            if let terminalApplyResult = applyLateRunningOutputToTerminalBashResultIfNeeded(
                toolName: toolName,
                invocationID: nil,
                argsJSON: argsJSON,
                processID: parsedResult.processID,
                appendedOutput: parsedResult.output,
                session: session
            ) {
                guard terminalApplyResult.didChange else { return }
                updateBashLivenessTaskState(for: session)
                viewModel?.requestUIRefresh(tabID: session.tabID)
                viewModel?.scheduleSave(for: session.tabID)
                return
            }
            if upsertLiveBashExecution(
                toolName: toolName,
                invocationID: nil,
                argsJSON: argsJSON,
                parsedResult: parsedResult,
                metadata: metadata,
                session: session,
                observedAt: observedAt
            ) {
                let shouldMaterializeRunningOutput = canMaterializeRunningBashOutput(for: session)
                if shouldMaterializeRunningOutput,
                   let state = existingBashExecutionLookup(
                       invocationID: nil,
                       processID: parsedResult.processID,
                       fallbackSignature: Self.canonicalNativeToolFallbackSignature(toolName: toolName, argsJSON: argsJSON),
                       session: session
                   )?.state
                {
                    _ = materializeRunningBashExecution(state, session: session)
                }
                updateBashLivenessTaskState(for: session)
                viewModel?.requestUIRefresh(
                    tabID: session.tabID,
                    scope: shouldMaterializeRunningOutput ? .full : .transcriptRuntime
                )
            }
            return
        }
        if finalizeLiveBashExecution(
            toolName: toolName,
            invocationID: nil,
            argsJSON: argsJSON,
            resultJSON: resultJSON,
            statusWord: parsedResult.statusWord ?? (isError == true ? "failed" : "completed"),
            isError: isError,
            session: session,
            observedAt: observedAt
        ) {
            updateBashLivenessTaskState(for: session)
            viewModel?.requestUIRefresh(tabID: session.tabID)
            viewModel?.scheduleSave(for: session.tabID)
        }
    }

    @discardableResult
    private func applyCodexCommandExecutionRunningUpdate(
        _ runningUpdate: CodexNativeSessionController.CommandExecutionRunningUpdate,
        session: AgentTabSession
    ) -> Bool {
        applyLiveBashRunningUpdate(runningUpdate, session: session, observedAt: Date()).didChange
    }

    @discardableResult
    private func applyCodexCommandExecutionRunningUpdate(
        _ runningUpdate: CodexNativeSessionController.CommandExecutionRunningUpdate,
        session: AgentTabSession,
        runningItemIndex: inout CodexNativeSessionController.CommandExecutionRunningItemIndex?
    ) -> Bool {
        runningItemIndex = nil
        return applyLiveBashRunningUpdate(runningUpdate, session: session, observedAt: Date()).didChange
    }

    func reconcilePersistedCodexCommandStatusIfNeeded(
        session: AgentTabSession,
        force: Bool = false
    ) {
        if !force {
            guard !session.hasReconciledPersistedCodexCommandStatus else { return }
        }
        session.hasReconciledPersistedCodexCommandStatus = true
        guard session.selectedAgent == .codexExec else { return }
        guard let rolloutPath = session.codexRolloutPath else {
            rebuildLiveBashExecutionState(from: session)
            updateBashLivenessTaskState(for: session)
            return
        }
        var reconciledItems = session.items
        let didReconcile = CodexNativeSessionController.reconcilePersistedCommandExecutionStatuses(
            in: &reconciledItems,
            rolloutPath: rolloutPath
        )
        if didReconcile {
            session.setItemsSilently(reconciledItems, reason: .codexCommandStatusReconciliation)
        }
        rebuildLiveBashExecutionState(from: session)
        updateBashLivenessTaskState(for: session)
        guard didReconcile else { return }
        session.isDirty = true
        viewModel?.requestUIRefresh(tabID: session.tabID)
        viewModel?.scheduleSave(for: session.tabID)
    }

    private func finalizePendingToolCalls(
        in session: AgentTabSession,
        turnStatus: CodexNativeSessionController.TurnStatus
    ) {
        var didUpdate = false
        let fallbackResultJSON = Self.fallbackToolResultJSON(for: turnStatus)
        let terminalState = Self.agentSessionRunState(for: turnStatus)
        for index in session.items.indices {
            guard session.items[index].kind == .toolCall else { continue }
            var updated = session.items[index]
            let isAgentControlTool = AgentTranscriptIO.isAgentControlToolName(updated.toolName)
            let isRepoPromptTool = MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(updated.toolName)
            if isRepoPromptTool, !isAgentControlTool {
                continue
            }
            let agentControlFallback = isAgentControlTool
                ? AgentTranscriptIO.terminalFallbackToolResult(for: terminalState, item: updated)
                : nil
            updated.kind = .toolResult
            let existingResult = updated.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines)
            if existingResult?.isEmpty != false {
                let resultJSON = agentControlFallback?.json ?? fallbackResultJSON
                updated.toolResultJSON = resultJSON
                updated.text = resultJSON
            } else {
                updated.text = updated.toolResultJSON ?? fallbackResultJSON
            }
            if let agentControlFallback {
                updated.toolIsError = agentControlFallback.isError
            } else if turnStatus == .failed, updated.toolIsError == nil {
                updated.toolIsError = true
            }
            session.replaceItem(at: index, with: updated)
            didUpdate = true
        }
        if didUpdate {
            session.isDirty = true
        }
    }

    private static func agentSessionRunState(for turnStatus: CodexNativeSessionController.TurnStatus) -> AgentSessionRunState {
        switch turnStatus {
        case .completed:
            .completed
        case .interrupted:
            .cancelled
        case .failed:
            .failed
        }
    }

    private func finalizeLingeringRunningBashResults(
        in session: AgentTabSession,
        turnStatus: CodexNativeSessionController.TurnStatus
    ) {
        let terminalStatus = Self.terminalCommandStatusWord(for: turnStatus)
        let shouldError = (turnStatus == .failed)
        var didUpdate = false
        for execution in Array(session.bashLiveExecutionByKey.values) where execution.isRunning {
            if finalizeLiveBashExecution(
                toolName: execution.toolName,
                invocationID: execution.invocationID,
                argsJSON: session.items.first(where: { $0.id == execution.transcriptItemID })?.toolArgsJSON,
                resultJSON: nil,
                statusWord: terminalStatus,
                isError: shouldError,
                session: session,
                observedAt: Date()
            ) {
                didUpdate = true
            }
        }

        if didUpdate {
            updateBashLivenessTaskState(for: session)
        }
    }

    private static func fallbackToolResultJSON(for turnStatus: CodexNativeSessionController.TurnStatus) -> String {
        let status: String = (turnStatus == .failed) ? "failed" : "unknown"
        let payload: [String: Any] = [
            "status": status,
            "note": "No tool result payload was received before the turn ended."
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return "{\"status\":\"\(status)\"}"
    }

    private static func terminalCommandStatusWord(for turnStatus: CodexNativeSessionController.TurnStatus) -> String {
        switch turnStatus {
        case .completed:
            "completed"
        case .interrupted:
            "cancelled"
        case .failed:
            "failed"
        }
    }

    private static func withCommandExecutionTerminalStatus(raw: String?, status: String) -> String {
        let trimmedRaw = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var object: [String: Any] = [:]
        if let raw,
           let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            object = json
        } else if !trimmedRaw.isEmpty {
            object["aggregatedOutput"] = trimmedRaw
        }

        if (object["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            object["type"] = "commandExecution"
        }
        object["status"] = status

        if object["processId"] == nil, let processID = object["process_id"] {
            object["processId"] = processID
        }
        object.removeValue(forKey: "process_id")

        let hasExitCode =
            object["exitCode"] != nil
                || object["exit_code"] != nil
                || object["code"] != nil
        if !hasExitCode {
            switch status {
            case "completed":
                object["exitCode"] = 0
            case "failed", "cancelled", "canceled":
                object["exitCode"] = 1
            default:
                break
            }
        }

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"type":"commandExecution","status":"\#(status)"}"#
        }
        return json
    }

    package func submitApprovalDecision(
        session: AgentTabSession,
        decision: AgentApprovalDecision
    ) {
        guard let request = session.pendingApproval,
              let controller = session.codexController
        else {
            return
        }
        if case .acceptWithExecpolicyAmendment = decision,
           request.kind != .commandExecution
        {
            return
        }
        let result = buildApprovalResult(decision: decision, request: request)
        session.pendingApproval = nil
        viewModel?.reconcileInteractiveRunState(session)
        handleRunInteractionStateChange(for: session, reason: .approvalResponseSubmitted)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        guard case let .codex(requestID) = request.requestID else {
            return
        }
        Task { [controller] in
            await controller.respondToServerRequest(id: requestID, result: result)
        }
    }

    package func submitPermissionsDecision(
        session: AgentTabSession,
        request: AgentPermissionsRequest,
        decision: AgentApprovalDecision
    ) {
        guard let controller = session.codexController,
              session.pendingPermissionsRequest?.id == request.id
        else {
            return
        }
        let result = Self.buildPermissionsResult(decision: decision, request: request)
        session.pendingPermissionsRequest = nil
        viewModel?.reconcileInteractiveRunState(session)
        handleRunInteractionStateChange(for: session, reason: .permissionsResponseSubmitted)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        viewModel?.recordMCPInteractionResolution(for: session, interactionID: request.id)
        let authoritativeTurnID = session.codexAuthoritativeActiveTurn?.turnID
        Task { [controller] in
            await controller.respondToServerRequest(id: request.requestID, result: result)
            if case .cancel = decision, let authoritativeTurnID {
                _ = try? await controller.interruptUserTurn(expectedTurnID: authoritativeTurnID)
            } else if case .cancel = decision {
                _ = try? await controller.reconcileAndInterruptCurrentTurn()
            }
        }
    }

    package func submitMCPElicitationResponse(
        session: AgentTabSession,
        request: AgentMCPElicitationRequest,
        response: AgentMCPElicitationResponse
    ) {
        guard let controller = session.codexController,
              session.pendingMCPElicitationRequest?.id == request.id
        else {
            return
        }
        session.pendingMCPElicitationRequest = nil
        if !session.queuedMCPElicitationRequests.isEmpty {
            session.pendingMCPElicitationRequest = session.queuedMCPElicitationRequests.removeFirst()
        }
        viewModel?.reconcileInteractiveRunState(session)
        handleRunInteractionStateChange(for: session, reason: .mcpElicitationResponseSubmitted)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        viewModel?.publishMCPStateChange(for: session)
        viewModel?.recordMCPInteractionResolution(for: session, interactionID: request.id)
        let authoritativeTurnID = session.codexAuthoritativeActiveTurn?.turnID
        Task { [controller] in
            await controller.respondToServerRequest(id: request.requestID, result: response.jsonObject)
            if response.action == .cancel, let authoritativeTurnID {
                _ = try? await controller.interruptUserTurn(expectedTurnID: authoritativeTurnID)
            } else if response.action == .cancel {
                _ = try? await controller.reconcileAndInterruptCurrentTurn()
            }
        }
    }

    package func submitUserInputResponse(
        session: AgentTabSession,
        requestID: CodexAppServerRequestID,
        response: AgentRequestUserInputResponse
    ) {
        guard let controller = session.codexController else {
            return
        }
        Task { [controller] in
            await controller.respondToServerRequest(id: requestID, result: response.jsonObject)
        }
    }

    // MARK: - MCP Tool Auto-Approval

    /// Returns true when all questions in a `requestUserInput` event are MCP tool-call approval
    /// prompts. RepoPrompt hosts the MCP server, so it can unconditionally trust its own tools.
    private static func shouldAutoApproveCodexMCPToolRequest(_ request: AgentRequestUserInputRequest) -> Bool {
        guard !request.questions.isEmpty else { return false }
        return request.questions.allSatisfy { $0.id.hasPrefix("mcp_tool_call_approval") }
    }

    /// Builds an auto-approval response that answers each MCP approval question with a
    /// session-scoped option when available, falling back to the first option label.
    private static func buildAutoApprovalResponse(for request: AgentRequestUserInputRequest) -> AgentRequestUserInputResponse {
        var answers: [String: [String]] = [:]
        for question in request.questions where question.id.hasPrefix("mcp_tool_call_approval") {
            let label = question.options.first(where: { $0.label == "Allow for this session" })?.label
                ?? question.options.first?.label
                ?? "Allow"
            answers[question.id] = [label]
        }
        return AgentRequestUserInputResponse(answersByQuestionID: answers)
    }

    private static func buildPermissionsResult(decision: AgentApprovalDecision, request: AgentPermissionsRequest) -> [String: Any] {
        let permissions: [String: Any]
        let scope: String
        switch decision {
        case .accept:
            permissions = request.permissionsObject
            scope = "turn"
        case .acceptForSession:
            permissions = request.permissionsObject
            scope = "session"
        case .decline, .cancel, .acceptWithExecpolicyAmendment:
            permissions = [:]
            scope = "turn"
        }
        return [
            "permissions": permissions,
            "scope": scope,
            "strictAutoReview": false
        ]
    }

    private func buildApprovalResult(decision: AgentApprovalDecision, request: AgentApprovalRequest) -> [String: Any] {
        // The server request id already scopes routing. Keep payload to `{ decision }`.
        let decisionValue: String
        switch decision {
        case .accept:
            decisionValue = "accept"
        case .decline:
            decisionValue = "decline"
        case .cancel:
            decisionValue = "cancel"
        case .acceptForSession:
            decisionValue = "acceptForSession"
        case let .acceptWithExecpolicyAmendment(amendment):
            guard request.kind == .commandExecution else {
                decisionValue = "decline"
                break
            }
            if let data = amendment.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data)
            {
                return [
                    "decision": [
                        "acceptWithExecpolicyAmendment": [
                            "execpolicy_amendment": parsed
                        ]
                    ]
                ]
            }
            decisionValue = "acceptForSession"
        }
        return ["decision": decisionValue]
    }

    package func clearCodexSessionState(_ session: AgentTabSession) {
        clearCodexTerminalSettleState(for: session.tabID)
        cancelCodexThreadNameSync(for: session.tabID)
        cancelCodexIdleShutdown(for: session.tabID)
        stopCodexStallWatchdog(for: session.tabID)
        clearCodexRecoveryAttempt(for: session.runID)
        resetCodexResumeTimeoutState(for: session)
        session.codexConversationID = nil
        session.codexRolloutPath = nil
        session.codexContextUsage = nil
        viewModel?.clearContextUsageSnapshot(for: session)
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()
        session.pendingCodexAssistantScope = nil
        session.codexAssistantRowIDByScope.removeAll()
        session.runningStatusSource = nil
        session.pendingCommandRunningFlushTask?.cancel()
        session.pendingCommandRunningFlushTask = nil
        session.pendingCommandRunningByKey.removeAll()
        session.attachmentTurnState = .idle
        clearPendingAssistantDelta(session)
        session.codexModel = nil
        session.codexReasoningEffort = nil
        abandonCodexFallbackQueue(
            session: session,
            reason: "Codex queued follow-up was cancelled because the session was cleared.",
            mode: .discardInput
        )
        resetTrackedCodexTurns(session)
        session.codexNeedsReconnect = false
        session.pendingCodexComputerUseActivation = nil
        clearCodexPendingInteractions(in: session)
        cancelCodexTransportClosedFallback(for: session.tabID)
        stopBashLivenessTask(for: session.tabID)
        session.endCodexUsageExecution(reason: "controller-reset")
        if let controller = session.codexController {
            Task { await controller.shutdown() }
        }
        session.codexController = nil
        session.codexControllerPermissionProfile = nil
        session.codexControllerSessionProfile = nil
        session.codexControllerTaskLabelKind = nil
        session.codexControllerWorkspacePath = nil
        session.codexControllerFeatureState = nil
        session.codexEventTask?.cancel()
        session.codexEventTask = nil
        session.codexEventTaskRunID = nil
        session.codexLastEventAt = nil
        resetCodexWatchdogState(session)
        clearCodexNativeToolLiveness(session)
        stopCodexToolTracking(for: session)
    }

    func drainCodexTerminalBuffersForCancellation(_ session: AgentTabSession) {
        guard session.selectedAgent == .codexExec else { return }
        clearCodexTerminalSettleState(for: session.tabID)
        drainCodexTerminalOutput(session, turnStatus: .interrupted)
        abandonCodexFallbackQueue(
            session: session,
            reason: "Codex queued follow-up was cancelled with the active run."
        )
        resetTrackedCodexTurns(session)
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()
        session.pendingCodexAssistantScope = nil
        session.codexAssistantRowIDByScope.removeAll()
    }

    func codexTerminalBuffersAreDrained(_ session: AgentTabSession) -> Bool {
        session.pendingCommandRunningByKey.isEmpty
            && session.pendingCommandRunningFlushTask == nil
            && session.pendingAssistantDelta.isEmpty
            && session.assistantDeltaFlushTask == nil
    }

    struct CodexCancellationTarget {
        let controller: any CodexSessionControlling
        let authoritativeTurnIdentity: AgentTabSession.CodexAuthoritativeTurnIdentity?
    }

    func captureCodexCancellationTarget(
        _ session: AgentTabSession,
        expectedRunID: UUID?
    ) -> CodexCancellationTarget? {
        guard session.selectedAgent == .codexExec,
              let controller = session.codexController
        else { return nil }
        let authoritativeTurnIdentity: AgentTabSession.CodexAuthoritativeTurnIdentity? = if let identity = session.codexAuthoritativeActiveTurn,
                                                                                            identity.runID == expectedRunID,
                                                                                            authoritativeCodexTurnIsCurrent(identity, session: session),
                                                                                            identity.controllerInstanceID == ObjectIdentifier(controller)
        {
            identity
        } else {
            nil
        }
        return .init(
            controller: controller,
            authoritativeTurnIdentity: authoritativeTurnIdentity
        )
    }

    func prepareCodexCancellationTeardown(
        _ session: AgentTabSession,
        expectedRunID: UUID?,
        capturedTarget: CodexCancellationTarget?
    ) -> (@MainActor () async -> Void)? {
        guard session.selectedAgent == .codexExec else { return nil }
        let controller = capturedTarget?.controller ?? session.codexController
        let authoritativeTurnIdentity = capturedTarget?.authoritativeTurnIdentity
        if session.codexConversationID != nil || session.codexRolloutPath != nil {
            markCodexReconnectNeeded(for: session, source: "user-cancel-detached", scheduleSave: false)
        }
        cancelCodexThreadNameSync(for: session.tabID)
        cancelCodexIdleShutdown(for: session.tabID)
        cancelCodexTransportClosedFallback(for: session.tabID)
        stopCodexStallWatchdog(for: session.tabID)
        stopBashLivenessTask(for: session.tabID)
        session.endCodexUsageExecution(reason: "user-cancel-detached")
        session.codexController = nil
        session.codexControllerPermissionProfile = nil
        session.codexControllerSessionProfile = nil
        session.codexControllerTaskLabelKind = nil
        session.codexControllerWorkspacePath = nil
        session.codexControllerFeatureState = nil
        session.runID = nil
        session.codexEventTask?.cancel()
        session.codexEventTask = nil
        session.codexEventTaskRunID = nil
        session.codexLastEventAt = nil
        resetCodexWatchdogState(session)
        clearCodexNativeToolLiveness(session)
        settleCodexComputerUseActivationAfterTurn(session, reason: "user-cancel")
        return { [weak self] in
            if let controller {
                if let authoritativeTurnIdentity {
                    do {
                        _ = try await controller.interruptUserTurn(
                            expectedTurnID: authoritativeTurnIdentity.turnID
                        )
                    } catch {
                        CodexDebugLog.log(
                            "[AgentModeVM][CodexCancel] interrupt reconciliation failed: \(error.localizedDescription)"
                        )
                    }
                } else {
                    do {
                        _ = try await controller.reconcileAndInterruptCurrentTurn()
                    } catch {
                        CodexDebugLog.log(
                            "[AgentModeVM][CodexCancel] active-turn reconciliation failed: \(error.localizedDescription)"
                        )
                    }
                }
                await controller.shutdown()
            }
            await self?.stopCodexToolTrackingAndWait(for: session, matchingRunID: expectedRunID)
        }
    }

    func cancelCodexRun(_ session: AgentTabSession) async {
        guard session.selectedAgent == .codexExec else { return }
        let expectedRunID = session.runID
        let capturedTarget = captureCodexCancellationTarget(
            session,
            expectedRunID: expectedRunID
        )
        drainCodexTerminalBuffersForCancellation(session)
        let teardown = prepareCodexCancellationTeardown(
            session,
            expectedRunID: expectedRunID,
            capturedTarget: capturedTarget
        )
        await teardown?()
    }

    package func shutdownCodexSession(
        _ session: AgentTabSession,
        clearTabScopedCoordinatorState: Bool = true,
        detachedRunID: UUID? = nil
    ) async {
        let shutdownRunID = clearTabScopedCoordinatorState ? session.runID : detachedRunID
        if clearTabScopedCoordinatorState {
            cancelCodexThreadNameSync(for: session.tabID)
            cancelCodexIdleShutdown(for: session.tabID)
            cancelCodexTransportClosedFallback(for: session.tabID)
            stopCodexStallWatchdog(for: session.tabID)
            stopBashLivenessTask(for: session.tabID)
        }
        clearCodexRecoveryAttempt(for: session.runID)
        session.pendingCommandRunningFlushTask?.cancel()
        session.pendingCommandRunningFlushTask = nil
        session.pendingCommandRunningByKey.removeAll()
        session.attachmentTurnState = .idle
        abandonCodexFallbackQueue(
            session: session,
            reason: "Codex queued follow-up was cancelled because the session shut down."
        )
        resetTrackedCodexTurns(session)
        session.pendingCodexComputerUseActivation = nil
        session.endCodexUsageExecution(reason: "session-shutdown")
        if let controller = session.codexController {
            await controller.shutdown()
        }
        session.codexController = nil
        session.codexControllerPermissionProfile = nil
        session.codexControllerSessionProfile = nil
        session.codexControllerTaskLabelKind = nil
        session.codexControllerWorkspacePath = nil
        session.codexControllerFeatureState = nil
        session.runID = nil
        session.codexEventTask?.cancel()
        session.codexEventTask = nil
        session.codexEventTaskRunID = nil
        session.codexLastEventAt = nil
        resetCodexWatchdogState(session)
        if clearTabScopedCoordinatorState {
            await stopCodexToolTrackingAndWait(for: session)
        } else {
            await stopCodexToolTrackingAndWait(for: session, matchingRunID: shutdownRunID)
        }
    }
}

#if DEBUG
    package extension CodexAgentModeCoordinator {
        @MainActor
        func testSimulateRepoPromptToolCall(
            invocationID: UUID?,
            toolName: String,
            args: [String: Value]?,
            session: AgentTabSession
        ) {
            handleCodexToolCall(invocationID: invocationID, toolName: toolName, args: args, session: session)
        }

        @MainActor
        func testSimulateRepoPromptToolResult(
            invocationID: UUID?,
            toolName: String,
            args: [String: Value]?,
            resultJSON: String,
            isError: Bool,
            session: AgentTabSession
        ) {
            handleCodexToolResult(
                invocationID: invocationID,
                toolName: toolName,
                args: args,
                resultJSON: resultJSON,
                isError: isError,
                session: session
            )
        }

        @MainActor
        internal func testFinalizePendingToolCalls(
            in session: AgentTabSession,
            turnStatus: CodexNativeSessionController.TurnStatus
        ) {
            finalizePendingToolCalls(in: session, turnStatus: turnStatus)
        }

        @MainActor
        func testSimulateBashRunningUpdate(
            invocationID: UUID?,
            processID: String,
            appendedOutput: String,
            sealsAssistantBoundary: Bool,
            session: AgentTabSession
        ) async {
            let update = CodexNativeSessionController.CommandExecutionRunningUpdate(
                invocationID: invocationID,
                processID: processID,
                appendedOutput: appendedOutput.isEmpty ? nil : appendedOutput,
                sealsAssistantBoundary: sealsAssistantBoundary
            )
            await handleCodexNativeEvent(.commandExecutionRunning(update), session: session)
        }
    }
#endif
