import Foundation
import MCP
import OSLog

@MainActor
package final class ClaudeAgentModeCoordinator {
    package typealias ClaudeControllerFactory = (
        _ runID: UUID,
        _ tabID: UUID,
        _ windowID: Int,
        _ launchSettings: ControllerLaunchSettings
    ) throws -> any NativeAgentRuntimeControlling

    /// Closure that waits until the given runID has zero active MCP tool executions.
    /// Throws `CancellationError` if the calling Task is cancelled.
    package typealias MCPToolIdleWaiter = (_ runID: UUID) async throws -> Void
    package typealias MCPToolEndedCountProvider = (_ runID: UUID) -> Int
    package typealias MCPActiveToolQuery = (_ runID: UUID) -> Bool
    package typealias ActiveAgentRunWaitQuery = (_ runID: UUID) -> Bool

    private enum SteeringInterruptSafePointResult {
        case ready
        case cancelled
        case timedOut(
            snapshot: ClaudeAgentToolTrackingHandler.ExplicitProviderToolResultAckSnapshot,
            localCount: Int,
            stillActive: Bool
        )
    }

    private struct FallbackReplacementClaim: Equatable {
        let id: UUID
        let runID: UUID
        let runAttemptID: UUID?
    }

    private struct TrackedPrivateFallbackController {
        let claim: FallbackReplacementClaim
        let controller: any NativeAgentRuntimeControlling
    }

    private enum ControllerLifecycleError: Error {
        case superseded
        case claimedStartupFailure(Error, FallbackReplacementClaim)
    }

    struct DetachedClaudeController {
        fileprivate let controller: any NativeAgentRuntimeControlling
        fileprivate let toolHandler: ClaudeAgentToolTrackingHandler?
    }

    struct AutoPermissionValidationKey: Equatable {
        let agentKind: AgentProviderKind
        let runtimeVariant: ClaudeCodeRuntimeVariant
        let baseModel: String
    }

    package struct ControllerLaunchSettings: Equatable {
        let runtimeVariant: ClaudeCodeRuntimeVariant
        let workspacePath: String?
        let permissionMode: String?
        let allowNativeBashTool: Bool?
        let mcpStrictMode: Bool?
        let sessionProfile: AgentSessionProfile
        let toolSearchEnabled: Bool?
        /// Effort-free identity used to invalidate Auto across base-model or
        /// backend-selection changes.
        let autoPermissionValidationKey: AutoPermissionValidationKey?
        /// `.directCodeMode` when the process was launched under it; `nil` for native or a launch
        /// that can never be `code_mode` eligible. Claude reads `tools/list` at connect, so a
        /// change recycles the controller like the Bash toggle.
        let repoPromptToolsMode: RepoPromptToolsMode?

        init(
            runtimeVariant: ClaudeCodeRuntimeVariant,
            workspacePath: String?,
            permissionMode: String?,
            allowNativeBashTool: Bool?,
            mcpStrictMode: Bool?,
            sessionProfile: AgentSessionProfile,
            toolSearchEnabled: Bool?,
            autoPermissionValidationKey: AutoPermissionValidationKey? = nil,
            repoPromptToolsMode: RepoPromptToolsMode? = nil
        ) {
            self.runtimeVariant = runtimeVariant
            self.workspacePath = workspacePath
            self.permissionMode = permissionMode
            self.allowNativeBashTool = allowNativeBashTool
            self.mcpStrictMode = mcpStrictMode
            self.sessionProfile = sessionProfile
            self.toolSearchEnabled = toolSearchEnabled
            self.autoPermissionValidationKey = autoPermissionValidationKey
            self.repoPromptToolsMode = repoPromptToolsMode
        }
    }

    private enum PreparationKind: Equatable {
        case initialization
        case liveSettings
    }

    private struct JoinablePreparation {
        let id: UUID
        let kind: PreparationKind
        let task: Task<Void, Never>
    }

    private struct DispatchReservation {
        let id: UUID
        let runID: UUID
        let runAttemptID: UUID?
    }

    /// The tab slot is absent or describes `session.claudeController`.
    private struct ControllerEffortEvidence {
        let controllerIdentifier: ObjectIdentifier
        let initializationGeneration: UInt64
        let acknowledgedEffort: ClaudeCodeEffortLevel?
    }

    private enum AutoEffortReadiness {
        case ready
        case retry
        case deferred
        /// A genuine Auto effort change cannot apply until the controller's current turn
        /// settles. Dispatch may await a just-interrupted turn's authoritative completion;
        /// other callers keep treating this as deferred.
        case awaitingTurnIdle
    }

    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "ClaudeSteering")
    private static let flagSettingsLogger = Logger(subsystem: "com.repoprompt.agents", category: "ClaudeFlagSettings")

    private weak var viewModel: (any ClaudeAgentModeCoordinatorHost)?
    private let windowID: Int
    private let workspacePathProvider: (AgentTabSession) throws -> String?
    private let claudeControllerFactory: ClaudeControllerFactory
    private let mcpHost: any AgentMCPHosting
    private let awaitNoActiveMCPTools: MCPToolIdleWaiter?
    private let toolEndedCount: MCPToolEndedCountProvider
    private let hasActiveMCPTools: MCPActiveToolQuery
    private let hasActiveChildAgentRunWaits: ActiveAgentRunWaitQuery
    private let steeringInterruptSafePointTimeoutSeconds: TimeInterval
    private let globalCodeMapsDisabled: @MainActor () -> Bool
    private var interruptedTurnSettlementTimeoutSeconds: TimeInterval = 5.0
    /// Step 12: how long a steer holds its own write after an acknowledged interrupt of a turn with
    /// no visible output, so the CLI's result for that turn arrives while it is still the
    /// controller's only outstanding turn. Capped at the interrupt's 1.5 s control timeout.
    private var unstartedInterruptResultWaitSeconds: TimeInterval = 1.5

    /// Per-tab tool tracking handler for Claude sessions.
    /// Each tab gets its own handler instance to isolate correlation state across concurrent sessions.
    private var toolHandlerByTabID: [UUID: ClaudeAgentToolTrackingHandler] = [:]
    private var controllerLaunchSettingsByTabID: [UUID: ControllerLaunchSettings] = [:]
    private var controllerEffortEvidenceByTabID: [UUID: ControllerEffortEvidence] = [:]
    private var preparationByTabID: [UUID: JoinablePreparation] = [:]
    private var dispatchReservationByTabID: [UUID: DispatchReservation] = [:]
    /// Written user messages awaiting the provider's affirmative evidence (their own turn's
    /// `turnCompleted(.completed)` from the controller that wrote them), keyed by the controller
    /// turn ID returned by the write. An entry outlives its run attempt (a late completion still
    /// refines that same delivery attempt) but never the writing controller's event delivery: it
    /// ends at the turn's own completion, when no router can deliver that controller's events
    /// any more, when the controller is gone, or at `stop()`.
    private var dispatchHandoffsByTurnID: [UUID: WrittenDispatchHandoff] = [:]

    private struct WrittenDispatchHandoff {
        let tabID: UUID
        let runAttemptID: UUID?
        let handoff: AgentProviderHandoff
        /// The controller that performed the write. Weak: evidence never keeps a process alive,
        /// and a deallocated controller can emit nothing more for this turn.
        weak var controller: AnyObject?
        /// O49 marks, placed only on the turn the CLI had begun: the controller attributed model
        /// output, reasoning, or a tool call to this very turn (`startedTurnID`). Never a queued or
        /// older retained turn.
        ///
        /// RepoPrompt's own Stop, window close, or quit, placed before the run detaches. Final: no
        /// interrupt outcome withdraws it. The message settles as accepted at its cancelled/failed
        /// end or at run end, without waiting for the CLI's result.
        var teardownRequestedByRepoPrompt = false
        /// A steer or cleanup interrupt of this turn awaits `interruptTurn`'s outcome. Provisional:
        /// it proves nothing until the interrupt is acknowledged.
        var interruptPending = false
        /// A cancelled/failed completion that arrived while `interruptPending`; decided once the
        /// interrupt outcome is known.
        var completionDuringInterrupt: NativeAgentRuntimeTurnStatus?
        /// Step 12: RepoPrompt's own interrupt (steer or cleanup) of this turn before the CLI was
        /// credited with starting it, placed only while it was the writing controller's sole
        /// unresolved written turn. Accepts only with both an acknowledged interrupt and the CLI's
        /// own exclusive `.cancelled` result for this turn, in either order.
        var unstartedInterrupt: UnstartedInterrupt?
    }

    /// Which mark `noteRepoPromptInterruptRequested` placed, so the interrupt's outcome resolves
    /// exactly that mark.
    private enum RepoPromptInterruptMark {
        /// O49 `interruptPending` on the started turn.
        case started(UUID)
        /// Step 12 `unstartedInterrupt` on the sole unresolved written turn.
        case unstarted(UUID)
    }

    /// Step 12: the two halves of gated acceptance for an interrupt before first visible output.
    private struct UnstartedInterrupt {
        /// `interruptTurn` returned `.acknowledged`.
        var acknowledged = false
        /// The CLI's exclusive `.cancelled` result arrived before the acknowledgement.
        var providerCancelledResultHeld = false
    }

    private var controllerRetirementGenerationByTabID: [UUID: UUID] = [:]
    /// Tabs whose unhealthy launch was retired for RepoPrompt MCP recovery: the successor must
    /// resume this conversation and prove RepoPrompt MCP connected before any turn is submitted.
    /// Kept until that evidence arrives, so every later preparation re-proves it. Each arming has
    /// a fresh generation, so a confirmation that resumes after a suspension can tell whether the
    /// recovery it was confirming is still the tab's current one.
    private struct PendingRepoPromptMCPRecovery {
        let conversationID: String
        let generation: UUID
    }

    private var pendingRepoPromptMCPRecoveryByTabID: [UUID: PendingRepoPromptMCPRecovery] = [:]
    static let repoPromptMCPRecoveryEvidenceTimeoutSeconds: TimeInterval = 20
    private var fallbackReplacementClaimByTabID: [UUID: FallbackReplacementClaim] = [:]
    private var privateFallbackControllerByTabID: [UUID: TrackedPrivateFallbackController] = [:]
    #if DEBUG
        /// How many readiness calls joined an in-flight preparation instead of starting one.
        private(set) var testPreparationJoinCount = 0
        private var testStopToolTrackingGate: (() async -> Void)?
        private var testBeforePromptCacheRetentionSync: ((AgentTabSession) -> Void)?
        private var testResumeRecoveryHandoffBeforeCommitGate: (@MainActor () async -> Void)?
    #endif
    private var pendingResumeTransferTasksByTabID: [UUID: Task<NativeAgentRuntimeSessionRef, Never>] = [:]
    private var pendingResumeTransferGenerationByTabID: [UUID: UUID] = [:]
    private var retiredResumeTransferTasksByTabID: [UUID: [Task<NativeAgentRuntimeSessionRef, Never>]] = [:]
    package var toolTrackingHooks: AgentToolTrackingHooks = .noOp {
        didSet {
            for handler in toolHandlerByTabID.values {
                handler.hooks = toolTrackingHooks
            }
        }
    }

    package init(
        windowID: Int,
        workspacePathProvider: @escaping (AgentTabSession) throws -> String?,
        mcpHost: any AgentMCPHosting,
        globalCodeMapsDisabled: @escaping @MainActor () -> Bool,
        claudeControllerFactory: ClaudeControllerFactory? = nil,
        awaitNoActiveMCPTools: MCPToolIdleWaiter? = nil,
        toolEndedCount: @escaping MCPToolEndedCountProvider = { _ in 0 },
        hasActiveMCPTools: @escaping MCPActiveToolQuery = { _ in false },
        hasActiveChildAgentRunWaits: @escaping ActiveAgentRunWaitQuery = { _ in false },
        steeringInterruptSafePointTimeoutSeconds: TimeInterval = 2.0
    ) {
        self.windowID = windowID
        self.workspacePathProvider = workspacePathProvider
        self.mcpHost = mcpHost
        self.claudeControllerFactory = claudeControllerFactory ?? { runID, tabID, windowID, launchSettings in
            try Self.makeDefaultController(
                runID: runID,
                tabID: tabID,
                windowID: windowID,
                launchSettings: launchSettings,
                mcpHost: mcpHost
            )
        }
        self.awaitNoActiveMCPTools = awaitNoActiveMCPTools
        self.toolEndedCount = toolEndedCount
        self.hasActiveMCPTools = hasActiveMCPTools
        self.hasActiveChildAgentRunWaits = hasActiveChildAgentRunWaits
        self.steeringInterruptSafePointTimeoutSeconds = steeringInterruptSafePointTimeoutSeconds
        self.globalCodeMapsDisabled = globalCodeMapsDisabled
    }

    private static func makeDefaultController(
        runID: UUID,
        tabID: UUID,
        windowID: Int,
        launchSettings: ControllerLaunchSettings,
        mcpHost: any AgentMCPHosting
    ) throws -> any NativeAgentRuntimeControlling {
        let coreConfig = try ClaudeCodeAgentConfig.agentMode(
            runtimeVariant: launchSettings.runtimeVariant,
            permissionMode: launchSettings.permissionMode,
            allowNativeBashTool: launchSettings.allowNativeBashTool,
            disallowedBuiltInTools: ClaudeCodeIntegrationConfiguration.disallowedTools(
                for: .agentRun,
                allowNativeBashTool: launchSettings.allowNativeBashTool ?? false,
                sessionProfile: launchSettings.sessionProfile
            ),
            mcpStrictMode: launchSettings.mcpStrictMode,
            toolSearchEnabled: launchSettings.toolSearchEnabled
        )
        let runtimeConfig = ClaudeCompatiblePluginBridge.runtimeConfig(from: coreConfig, mode: .agentMode)
        return ClaudeCompatibleNativeSessionAdapter(runtimeConfig: runtimeConfig) {
            ClaudeNativeProcessSessionController(
                runID: runID,
                tabID: tabID,
                windowID: windowID,
                workspacePath: launchSettings.workspacePath,
                config: coreConfig,
                mcpHost: mcpHost,
                commandSelection: coreConfig.commandSelection
            )
        }
    }

    @discardableResult
    private func updateProviderSessionIDIfNeeded(
        _ candidate: String?,
        for session: AgentTabSession,
        scheduleSave: Bool = true
    ) -> Bool {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              session.providerSessionID != candidate
        else {
            return false
        }
        session.providerSessionID = candidate
        guard scheduleSave else { return true }
        session.isDirty = true
        viewModel?.scheduleSave(for: session.tabID)
        return true
    }

    package func attach(viewModel: any ClaudeAgentModeCoordinatorHost) {
        self.viewModel = viewModel
    }

    package func stop() {
        preparationByTabID.values.forEach { $0.task.cancel() }
        preparationByTabID.removeAll()
        dispatchReservationByTabID.removeAll()
        // No controller event is processed after stop: written messages stay delivery-unknown.
        let writtenHandoffs = Array(dispatchHandoffsByTurnID.values)
        dispatchHandoffsByTurnID.removeAll()
        writtenHandoffs.forEach(Self.settleWithoutCompletion)
        controllerEffortEvidenceByTabID.removeAll()
        if let viewModel {
            for session in viewModel.sessions.values {
                publishClaudePermissionState(.notStarted, for: session)
            }
        }
        controllerLaunchSettingsByTabID.removeAll()
        controllerRetirementGenerationByTabID.removeAll()
        pendingRepoPromptMCPRecoveryByTabID.removeAll()
        fallbackReplacementClaimByTabID.removeAll()
        let privateFallbackControllers = privateFallbackControllerByTabID.values.map(\.controller)
        privateFallbackControllerByTabID.removeAll()
        for controller in privateFallbackControllers {
            Task { await controller.shutdown() }
        }
        let resumeTransferTasks = Array(pendingResumeTransferTasksByTabID.values)
            + retiredResumeTransferTasksByTabID.values.flatMap(\.self)
        resumeTransferTasks.forEach { $0.cancel() }
        pendingResumeTransferTasksByTabID.removeAll()
        pendingResumeTransferGenerationByTabID.removeAll()
        retiredResumeTransferTasksByTabID.removeAll()
    }

    /// Detaches every tab-scoped Claude tool tracker from the coordinator map without blocking.
    ///
    /// Call from workspace-switch discard before the foreground session map is cleared so
    /// recycled tab IDs do not inherit stale tracking state. Do not call from `stop()`, which
    /// also runs when agent mode UI is hidden while sessions remain alive.
    package func detachAllClaudeToolTrackingHandlersForWorkspaceSwitch() {
        let handlers = toolHandlerByTabID
        toolHandlerByTabID.removeAll()
        for (tabID, handler) in handlers {
            let session = AgentTabSession(tabID: tabID)
            Task { await handler.stopTracking(for: session) }
        }
    }

    private func finalizeSession(
        _ session: AgentTabSession,
        state: AgentSessionRunState,
        save: Bool = false
    ) {
        session.runState = state
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus(nil, source: nil)
        viewModel?.setAgentRunActive(session.tabID, isActive: false)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        if save {
            viewModel?.scheduleSave(for: session.tabID)
        }
    }

    /// The session's current controller together with its events stream and the stream's
    /// generation, captured from the same controller so a caller can key long-lived consumption
    /// on the controller's identity and the stream it reads.
    func eventSubscription(
        for session: AgentTabSession
    ) async -> (controller: any NativeAgentRuntimeControlling, subscription: NativeAgentRuntimeEventsSubscription)? {
        guard let controller = session.claudeController else { return nil }
        // The controller ensures the stream has a live continuation before returning. This
        // handles the case where the stream was finished by handleStdoutEOF or another path
        // that called finishEventsStreamIfNeeded.
        return await (controller, controller.eventsSubscription())
    }

    /// The PID of the session's current, healthy Claude launch's spawned process, bound to its
    /// RepoPrompt MCP launch token, or `nil`. It may not be registered for RepoPrompt MCP routing
    /// yet (the host's proof then fails and the turn waits).
    func repoPromptMCPLaunchAgentPID(for session: AgentTabSession) async -> pid_t? {
        guard let controller = session.claudeController else { return nil }
        return await controller.repoPromptMCPLaunchAgentPID
    }

    func hasTurnInFlight(for session: AgentTabSession) async -> Bool {
        guard let controller = session.claudeController else { return false }
        return await controller.hasTurnInFlight
    }

    package func scheduleApplyCurrentClaudeModelAndEffortIfPossible(
        for session: AgentTabSession,
        reason: String
    ) {
        guard session.selectedAgent.usesClaudeNativeRuntime,
              session.claudeController != nil
        else {
            return
        }
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            await applyCurrentClaudeModelAndEffortIfPossible(for: session, reason: reason)
        }
    }

    func applyCurrentClaudeModelAndEffortIfPossible(
        for session: AgentTabSession,
        reason: String
    ) async {
        guard session.selectedAgent.usesClaudeNativeRuntime,
              let controller = session.claudeController
        else {
            return
        }

        guard isAutoSensitive(session: session) else {
            let model = effectiveClaudeModel(for: session)
            let effortLevel = currentClaudeEffortLevel(for: session)
            do {
                try await controller.applyModelAndEffort(model: model, effortLevel: effortLevel)
                Self.flagSettingsLogger.debug(
                    "Applied Claude flag settings for tab=\(session.tabID.uuidString, privacy: .public) reason=\(reason, privacy: .public) model=\(model ?? "default", privacy: .public) effort=\(effortLevel.rawValue, privacy: .public)"
                )
            } catch {
                Self.flagSettingsLogger.error(
                    "Failed applying Claude flag settings for tab=\(session.tabID.uuidString, privacy: .public) reason=\(reason, privacy: .public) model=\(model ?? "default", privacy: .public) effort=\(effortLevel.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
            return
        }

        if preparationByTabID[session.tabID] != nil
            || dispatchReservationByTabID[session.tabID] != nil
        {
            markAutoIntentPending(
                for: session,
                reason: "Claude Auto settings changed during preparation and will apply before the next turn."
            )
            return
        }

        let preparationID = UUID()
        let task = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            _ = await applyAutoSensitiveEffortIfNeeded(
                for: session,
                expectedController: controller,
                reason: reason
            )
        }
        preparationByTabID[session.tabID] = JoinablePreparation(
            id: preparationID,
            kind: .liveSettings,
            task: task
        )
        await task.value
        if preparationByTabID[session.tabID]?.id == preparationID {
            preparationByTabID.removeValue(forKey: session.tabID)
        }
    }

    func ensureClaudeToolTrackingIfNeeded(for session: AgentTabSession, runID: UUID) async {
        let handler = toolHandler(for: session)
        await handler.startTracking(runID: runID, session: session, clientNameHint: session.selectedAgent.mcpClientNameHint)
    }

    private func toolHandler(for session: AgentTabSession) -> ClaudeAgentToolTrackingHandler {
        if let existing = toolHandlerByTabID[session.tabID] {
            existing.hooks = toolTrackingHooks
            return existing
        }
        let handler = ClaudeAgentToolTrackingHandler(mcpHost: mcpHost, hooks: toolTrackingHooks)
        toolHandlerByTabID[session.tabID] = handler
        return handler
    }

    package func ensureClaudeNativeSession(
        session: AgentTabSession
    ) async {
        _ = await ensureClaudeNativeSessionReadiness(session: session)
    }

    private func ensureClaudeNativeSessionReadiness(
        session: AgentTabSession
    ) async -> Bool {
        while true {
            if let existing = preparationByTabID[session.tabID] {
                #if DEBUG
                    testPreparationJoinCount += 1
                #endif
                await existing.task.value
                let wasCancelled = existing.task.isCancelled
                if preparationByTabID[session.tabID]?.id == existing.id {
                    preparationByTabID.removeValue(forKey: session.tabID)
                }
                guard !wasCancelled else { return false }
                if existing.kind == .initialization {
                    return true
                }
                continue
            }

            let preparationID = UUID()
            let task = Task { @MainActor [weak self, weak session] in
                guard let self, let session else { return }
                await performEnsureClaudeNativeSession(session: session)
            }
            preparationByTabID[session.tabID] = JoinablePreparation(
                id: preparationID,
                kind: .initialization,
                task: task
            )
            await task.value
            let wasCancelled = task.isCancelled
            if preparationByTabID[session.tabID]?.id == preparationID {
                preparationByTabID.removeValue(forKey: session.tabID)
            }
            return !wasCancelled
        }
    }

    private func performEnsureClaudeNativeSession(
        session: AgentTabSession
    ) async {
        guard session.selectedAgent.usesClaudeNativeRuntime, !Task.isCancelled else { return }
        await awaitPendingClaudeResumeTransferIfNeeded(for: session)
        guard !Task.isCancelled else { return }

        if let controller = session.claudeController,
           let replacementClaim = fallbackReplacementClaimByTabID[session.tabID],
           sessionOwnsInstalledFallbackReplacementClaim(
               replacementClaim,
               controller: controller,
               for: session
           )
        {
            return
        }

        let runID = session.runID ?? UUID()
        session.runID = runID
        let runAttemptID = session.activeRunAttemptID
        let launchModelRaw = session.selectedModelRaw
        let launchKey = viewModel?.provisionalClaudeContextWindowKey(for: session)
        let runtimeVariant = session.selectedAgent.claudeRuntimeVariant ?? .standard
        let runtimePermission = effectiveClaudeRuntimePermission(for: session)
        let permissionResolution = effectiveClaudePermissionResolution(
            for: session,
            selectedModelRaw: launchModelRaw,
            runtimePermission: runtimePermission
        )
        guard let effectivePermissionMode = permissionResolution.launchMode else {
            if case let .blockedAuto(candidacy) = permissionResolution.reason {
                publishClaudePermissionState(
                    .blocked(
                        requestedMode: permissionResolution.requestedMode,
                        reason: candidacy,
                        runID: session.runID,
                        runAttemptID: runAttemptID
                    ),
                    for: session
                )
            }
            return
        }
        let autoPermissionValidationKey = autoPermissionValidationKey(
            for: permissionResolution,
            session: session,
            selectedModelRaw: launchModelRaw,
            runtimeVariant: runtimeVariant
        )
        let effectiveAllowNativeBashTool = session.profile == .knowledge ? false : runtimePermission.allowNativeBashTool
        let effectiveMCPStrictMode = session.profile == .knowledge ? true : runtimePermission.mcpStrictMode
        let effectiveToolSearchEnabled = session.profile == .knowledge ? false : nil
        let effectiveRepoPromptToolsMode = launchRepoPromptToolsMode(for: session)

        // If the session's Claude runtime variant or effective permission mode no
        // longer matches the controller, recycle it so the next process launches
        // with the correct backend environment and permission behavior.
        // Skip if a turn is still in flight — the mismatch persists and we will
        // recycle on the next idle call.
        let currentLaunchSettings = controllerLaunchSettingsByTabID[session.tabID]
        let runtimeVariantChanged = currentLaunchSettings.map { $0.runtimeVariant != runtimeVariant } ?? false
        let permissionModeChanged = currentLaunchSettings?.permissionMode != effectivePermissionMode
        let bashToolChanged = currentLaunchSettings?.allowNativeBashTool != effectiveAllowNativeBashTool
        let mcpStrictModeChanged = currentLaunchSettings?.mcpStrictMode != effectiveMCPStrictMode
        let sessionProfileChanged = currentLaunchSettings?.sessionProfile != session.profile
        let toolSearchChanged = currentLaunchSettings?.toolSearchEnabled != effectiveToolSearchEnabled
        let autoPermissionValidationKeyChanged =
            currentLaunchSettings?.autoPermissionValidationKey != autoPermissionValidationKey
        let repoPromptToolsModeChanged = currentLaunchSettings?.repoPromptToolsMode != effectiveRepoPromptToolsMode
        // A launch whose RepoPrompt MCP connection was lost is restarted here, at a turn boundary,
        // resuming its conversation; it is never silently reused.
        var repoPromptMCPRecoveryRequired = false
        if let existingController = session.claudeController {
            let health = await existingController.currentRepoPromptMCPHealth
            guard !Task.isCancelled, sessionOwnsClaudeController(existingController, for: session) else { return }
            repoPromptMCPRecoveryRequired = health.isUnhealthy
        }
        if let existingController = session.claudeController,
           runtimeVariantChanged || permissionModeChanged || bashToolChanged || mcpStrictModeChanged
           || sessionProfileChanged || toolSearchChanged || autoPermissionValidationKeyChanged
           || repoPromptToolsModeChanged || repoPromptMCPRecoveryRequired
        {
            let hasTurnInFlight = await existingController.hasTurnInFlight
            guard !Task.isCancelled,
                  sessionOwnsClaudeController(existingController, for: session)
            else {
                return
            }
            guard !hasTurnInFlight else {
                if isAutoSensitive(session: session) {
                    markAutoIntentPending(
                        for: session,
                        reason: "Claude Auto settings changed during an active turn and will apply before the next turn."
                    )
                }
                return
            }
            if repoPromptMCPRecoveryRequired, !runtimeVariantChanged {
                guard await armRepoPromptMCPRecovery(for: session, controller: existingController),
                      !Task.isCancelled
                else {
                    clearStaleRepoPromptMCPRecoveryStatus(for: session)
                    return
                }
            }
            await recycleClaudeControllerForLaunchSettingsChange(
                session: session,
                existingController: existingController,
                runtimeVariantChanged: runtimeVariantChanged
            )
            guard !Task.isCancelled else { return }
        }

        let runtimeWorkspacePath: String?
        do {
            runtimeWorkspacePath = try workspacePathProvider(session)
        } catch {
            let message = Self.providerStartupFailureMessage(for: error)
            let errorItem = AgentChatItem.error(message, sequenceIndex: session.nextSequenceIndex)
            session.appendItem(errorItem)
            finalizeSession(session, state: .failed, save: true)
            return
        }

        if let existingController = session.claudeController,
           controllerLaunchSettingsByTabID[session.tabID]?.workspacePath != runtimeWorkspacePath
        {
            guard let detached = detachClaudeController(
                existingController,
                from: session,
                removeToolTracking: true
            ) else {
                return
            }
            _ = await retireClaudeController(
                detached,
                for: session,
                captureProviderSessionID: true
            )
            guard !Task.isCancelled else { return }
        }

        if session.claudeController == nil {
            let launchSettings = ControllerLaunchSettings(
                runtimeVariant: runtimeVariant,
                workspacePath: runtimeWorkspacePath,
                permissionMode: effectivePermissionMode,
                allowNativeBashTool: effectiveAllowNativeBashTool,
                mcpStrictMode: effectiveMCPStrictMode,
                sessionProfile: session.profile,
                toolSearchEnabled: effectiveToolSearchEnabled,
                autoPermissionValidationKey: autoPermissionValidationKey,
                repoPromptToolsMode: effectiveRepoPromptToolsMode
            )
            let createdController: any NativeAgentRuntimeControlling
            do {
                createdController = try claudeControllerFactory(
                    runID,
                    session.tabID,
                    windowID,
                    launchSettings
                )
            } catch {
                let message = Self.providerStartupFailureMessage(for: error)
                let errorItem = AgentChatItem.error(message, sequenceIndex: session.nextSequenceIndex)
                session.appendItem(errorItem)
                finalizeSession(session, state: .failed, save: true)
                return
            }
            invalidateControllerRetirement(for: session)
            invalidateFallbackReplacementClaim(for: session)
            session.claudeController = createdController
            controllerLaunchSettingsByTabID[session.tabID] = launchSettings
            publishClaudePermissionState(
                .initializing(
                    ownership: permissionOwnership(
                        controller: createdController,
                        runID: runID,
                        runAttemptID: runAttemptID
                    ),
                    launchSettings: launchSettings,
                    requestedMode: permissionResolution.requestedMode
                ),
                for: session
            )
            await createdController.ensureEventsStreamReady()
            guard !Task.isCancelled else { return }
            guard sessionOwnsClaudeController(createdController, for: session) else {
                await createdController.shutdown()
                return
            }
        }

        guard let controller = session.claudeController else { return }
        let model = effectiveClaudeModel(selectedModelRaw: launchModelRaw)
        let launchEffortLevel = currentClaudeEffortLevel(for: session)
        guard !Task.isCancelled,
              session.runID == runID,
              session.activeRunAttemptID == runAttemptID,
              session.runState.isActive,
              sessionOwnsClaudeController(controller, for: session)
        else {
            clearStaleRepoPromptMCPRecoveryStatus(for: session)
            return
        }
        do {
            let sessionRef = try await startOrResumeWithFallback(
                controller: controller,
                session: session,
                runID: runID,
                model: model,
                effortLevel: launchEffortLevel,
                runtimeVariant: runtimeVariant,
                effectivePermissionMode: effectivePermissionMode,
                effectiveAllowNativeBashTool: effectiveAllowNativeBashTool,
                effectiveMCPStrictMode: effectiveMCPStrictMode,
                effectiveToolSearchEnabled: effectiveToolSearchEnabled,
                autoPermissionValidationKey: autoPermissionValidationKey,
                effectiveRepoPromptToolsMode: effectiveRepoPromptToolsMode
            )
            guard !Task.isCancelled else { return }
            if let launchKey {
                viewModel?.syncSpawnResolvedClaudeConfiguredContextWindow(
                    sessionRef.configuredContextWindow,
                    launchKey: launchKey,
                    for: session
                )
            }
            #if DEBUG
                testBeforePromptCacheRetentionSync?(session)
            #endif
            if sessionOwnsClaudeController(controller, for: session) {
                session.claudePromptCacheRetention = sessionRef.promptCacheRetention
            }
            updateProviderSessionIDIfNeeded(sessionRef.sessionID, for: session)
            guard let installedController = session.claudeController else {
                return
            }
            if pendingRepoPromptMCPRecoveryByTabID[session.tabID] != nil {
                guard await confirmRepoPromptMCPRecovery(
                    for: session,
                    controller: installedController,
                    runID: runID,
                    runAttemptID: runAttemptID
                ) else { return }
            }
            let controllerIdentifier = ObjectIdentifier(installedController as AnyObject)
            if let installedLaunchSettings = controllerLaunchSettingsByTabID[session.tabID],
               let effortEvidence = controllerEffortEvidenceByTabID[session.tabID],
               effortEvidence.controllerIdentifier == controllerIdentifier,
               effortEvidence.initializationGeneration == sessionRef.initializationGeneration,
               let acknowledgedEffort = effortEvidence.acknowledgedEffort
            {
                let acknowledgement = ClaudePermissionAcknowledgement(
                    ownership: permissionOwnership(
                        controller: installedController,
                        runID: runID,
                        runAttemptID: runAttemptID
                    ),
                    launchSettings: installedLaunchSettings,
                    requestedMode: permissionResolution.requestedMode,
                    acknowledgedEffort: acknowledgedEffort
                )
                let installedAuto = installedLaunchSettings.permissionMode?
                    .caseInsensitiveCompare(
                        ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode
                    ) == .orderedSame
                let effortChangedDuringInitialization =
                    currentClaudeEffortLevel(for: session) != acknowledgedEffort
                let launchIntentChangedDuringInitialization =
                    hasEffectiveClaudeControllerLaunchSettingsMismatch(for: session)
                if installedAuto,
                   effortChangedDuringInitialization || launchIntentChangedDuringInitialization
                {
                    let currentResolution = effectiveClaudePermissionResolution(
                        for: session,
                        selectedModelRaw: session.selectedModelRaw
                    )
                    publishClaudePermissionState(
                        .pendingNextTurn(
                            active: acknowledgement,
                            requestedMode: currentResolution.requestedMode,
                            reason: "Claude Auto settings changed during initialization and will apply before the next turn."
                        ),
                        for: session
                    )
                } else {
                    publishClaudePermissionState(.acknowledged(acknowledgement), for: session)
                }
            }
        } catch ControllerLifecycleError.superseded {
            return
        } catch let ControllerLifecycleError.claimedStartupFailure(error, claim) {
            guard !Task.isCancelled,
                  sessionOwnsDetachedFallbackReplacementClaim(claim, for: session)
            else {
                invalidateFallbackReplacementClaim(claim, for: session)
                return
            }
            invalidateFallbackReplacementClaim(claim, for: session)
            let errorItem = AgentChatItem.error(
                "Claude native start failed: \(error.localizedDescription)",
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(errorItem)
            publishClaudePermissionState(
                .failed(
                    ownership: nil,
                    requestedMode: permissionResolution.requestedMode,
                    message: error.localizedDescription
                ),
                for: session
            )
            finalizeSession(session, state: .failed, save: true)
        } catch {
            guard !Task.isCancelled,
                  session.runID == runID,
                  session.activeRunAttemptID == runAttemptID,
                  session.runState.isActive,
                  sessionOwnsClaudeController(controller, for: session)
            else {
                return
            }

            let requiresReplacement = await controller.requiresReplacementAfterTerminalStartupFailure
            guard !Task.isCancelled,
                  session.runID == runID,
                  session.activeRunAttemptID == runAttemptID,
                  session.runState.isActive,
                  sessionOwnsClaudeController(controller, for: session)
            else {
                return
            }

            if requiresReplacement {
                guard let detached = detachClaudeController(
                    controller,
                    from: session,
                    removeToolTracking: true
                ) else {
                    return
                }
                let retired = await retireClaudeController(
                    detached,
                    for: session,
                    captureProviderSessionID: false
                )
                guard retired,
                      !Task.isCancelled,
                      session.runID == runID,
                      session.activeRunAttemptID == runAttemptID,
                      session.runState.isActive,
                      session.claudeController == nil
                else {
                    return
                }
            }

            let errorItem = AgentChatItem.error(
                "Claude native start failed: \(error.localizedDescription)",
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(errorItem)
            publishClaudePermissionState(
                .failed(
                    ownership: session.claudeController.map {
                        permissionOwnership(
                            controller: $0,
                            runID: runID,
                            runAttemptID: runAttemptID
                        )
                    },
                    requestedMode: permissionResolution.requestedMode,
                    message: error.localizedDescription
                ),
                for: session
            )
            finalizeSession(session, state: .failed, save: true)
        }
    }

    // MARK: - RepoPrompt MCP health recovery

    /// Arms recovery of a launch whose RepoPrompt MCP connection was lost, just before the caller
    /// retires it: the successor resumes exactly this conversation (the implicit fresh fallback is
    /// suppressed for it) and must prove RepoPrompt MCP connected before a turn is submitted.
    /// Without a conversation to resume nothing restarts and the dispatch fails visibly.
    private func armRepoPromptMCPRecovery(
        for session: AgentTabSession,
        controller: any NativeAgentRuntimeControlling,
        stoppedRunningTurn: Bool = false
    ) async -> Bool {
        let sessionRef = await controller.currentSessionRef()
        guard sessionOwnsClaudeController(controller, for: session) else { return false }
        let conversationID = [sessionRef.sessionID, session.providerSessionID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let conversationID else {
            failRepoPromptMCPRecovery(
                for: session,
                message: "RepoPrompt MCP disconnected from Claude and there is no conversation to resume, so nothing was sent. Start a new conversation to continue."
            )
            return false
        }
        updateProviderSessionIDIfNeeded(conversationID, for: session)
        session.recoveryResumeFallbackSuppressedConversationID = conversationID
        pendingRepoPromptMCPRecoveryByTabID[session.tabID] = PendingRepoPromptMCPRecovery(
            conversationID: conversationID,
            generation: UUID()
        )
        if stoppedRunningTurn, session.runState.isActive {
            session.appendItem(.system(
                Self.repoPromptMCPStoppedRunningTurnNotice,
                sequenceIndex: session.nextSequenceIndex
            ))
        }
        setRepoPromptMCPRecoveryStatus(
            stoppedRunningTurn
                ? Self.repoPromptMCPStoppedTurnStatus
                : Self.repoPromptMCPRestartingStatus,
            for: session
        )
        Self.logger.notice(
            "Claude RepoPrompt MCP recovery armed tab=\(session.tabID.uuidString, privacy: .public) stoppedRunningTurn=\(stoppedRunningTurn, privacy: .public)"
        )
        return true
    }

    static let repoPromptMCPRestartingStatus = "Restarting Claude to reconnect RepoPrompt MCP…"
    static let repoPromptMCPStoppedTurnStatus = "Stopped the running turn to reconnect RepoPrompt tools…"
    static let repoPromptMCPWaitingStatus = "Waiting for RepoPrompt MCP to reconnect…"
    static let repoPromptMCPStoppedRunningTurnNotice = "RepoPrompt tools disconnected during the running turn, so it was stopped to reconnect them. Claude is restarting and resuming this conversation; your new message is sent once RepoPrompt MCP reconnects."

    /// Recovery status is shown only while a dispatch is active: an idle tab never shows it.
    private func setRepoPromptMCPRecoveryStatus(_ text: String, for session: AgentTabSession) {
        guard session.runState.isActive else { return }
        session.setRunningStatus(text, source: .transport)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    /// Clears a recovery status left behind once no dispatch is active any more. Another
    /// attempt's status (or any non-recovery status) is never touched.
    private func clearStaleRepoPromptMCPRecoveryStatus(for session: AgentTabSession) {
        guard !session.runState.isActive,
              session.runningStatusSource == .transport,
              let text = session.runningStatusText,
              [
                  Self.repoPromptMCPRestartingStatus,
                  Self.repoPromptMCPStoppedTurnStatus,
                  Self.repoPromptMCPWaitingStatus
              ].contains(text)
        else { return }
        session.setRunningStatus(nil, source: nil)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    /// Waits for the recovered launch's fresh RepoPrompt MCP connected evidence. On failure the
    /// launch is retired (recovery stays pending for the next attempt), the failure is shown, and
    /// nothing is submitted. A wait or retirement that was superseded (another run or attempt,
    /// another recovery generation) or cancelled changes nothing.
    private func confirmRepoPromptMCPRecovery(
        for session: AgentTabSession,
        controller: any NativeAgentRuntimeControlling,
        runID: UUID,
        runAttemptID: UUID?
    ) async -> Bool {
        guard let generation = pendingRepoPromptMCPRecoveryByTabID[session.tabID]?.generation else {
            return true
        }
        func stillCurrent() -> Bool {
            !Task.isCancelled
                && session.runID == runID
                && session.activeRunAttemptID == runAttemptID
                && session.runState.isActive
                && pendingRepoPromptMCPRecoveryByTabID[session.tabID]?.generation == generation
        }
        setRepoPromptMCPRecoveryStatus(Self.repoPromptMCPWaitingStatus, for: session)
        let outcome = await controller.awaitRepoPromptMCPConnectedEvidence(
            timeoutSeconds: Self.repoPromptMCPRecoveryEvidenceTimeoutSeconds,
            pollIntervalSeconds: 0.25
        )
        guard stillCurrent(), sessionOwnsClaudeController(controller, for: session) else {
            clearStaleRepoPromptMCPRecoveryStatus(for: session)
            return false
        }
        switch outcome {
        case .connected:
            pendingRepoPromptMCPRecoveryByTabID.removeValue(forKey: session.tabID)
            session.setRunningStatus("Thinking…", source: .transport)
            viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
            Self.logger.notice(
                "Claude RepoPrompt MCP recovery confirmed tab=\(session.tabID.uuidString, privacy: .public)"
            )
            return true
        case let .notConnected(reason):
            if let detached = detachClaudeController(controller, from: session, removeToolTracking: true) {
                _ = await retireClaudeController(detached, for: session, captureProviderSessionID: true)
            }
            // Retirement suspends: a superseding run, attempt or recovery owns the session now.
            guard stillCurrent() else {
                Self.logger.notice(
                    "Claude RepoPrompt MCP recovery failure superseded during retirement tab=\(session.tabID.uuidString, privacy: .public)"
                )
                clearStaleRepoPromptMCPRecoveryStatus(for: session)
                return false
            }
            failRepoPromptMCPRecovery(
                for: session,
                message: "RepoPrompt MCP did not reconnect after Claude restarted (\(reason)). Nothing was sent; send your message again to retry."
            )
            return false
        }
    }

    /// Fails the active user dispatch visibly. Without one (no dispatch is active), nothing is
    /// finalized and no recovery status is left on the idle tab: the pending recovery stays, and
    /// the next dispatch retries it.
    private func failRepoPromptMCPRecovery(for session: AgentTabSession, message: String) {
        Self.logger.error(
            "Claude RepoPrompt MCP recovery failed tab=\(session.tabID.uuidString, privacy: .public) active=\(session.runState.isActive, privacy: .public): \(message, privacy: .public)"
        )
        guard session.runState.isActive else {
            clearStaleRepoPromptMCPRecoveryStatus(for: session)
            return
        }
        session.appendItem(.error(message, sequenceIndex: session.nextSequenceIndex))
        finalizeSession(session, state: .failed, save: true)
    }

    /// Drops a pending recovery when the tab's conversation ends (reset or provider identity
    /// change): it applied only to that conversation.
    private func clearRepoPromptMCPRecovery(for session: AgentTabSession) {
        guard let pending = pendingRepoPromptMCPRecoveryByTabID.removeValue(forKey: session.tabID) else { return }
        if session.recoveryResumeFallbackSuppressedConversationID == pending.conversationID {
            session.recoveryResumeFallbackSuppressedConversationID = nil
        }
    }

    private func hasEffectiveClaudeControllerLaunchSettingsMismatch(
        for session: AgentTabSession
    ) -> Bool {
        guard session.claudeController != nil else { return false }
        let runtimeVariant = session.selectedAgent.claudeRuntimeVariant ?? .standard
        let runtimeWorkspacePath: String?
        do {
            runtimeWorkspacePath = try workspacePathProvider(session)
        } catch {
            return true
        }
        let runtimePermission = effectiveClaudeRuntimePermission(for: session)
        let permissionResolution = effectiveClaudePermissionResolution(
            for: session,
            selectedModelRaw: session.selectedModelRaw,
            runtimePermission: runtimePermission
        )
        guard let effectivePermissionMode = permissionResolution.launchMode else {
            return true
        }
        let expected = ControllerLaunchSettings(
            runtimeVariant: runtimeVariant,
            workspacePath: runtimeWorkspacePath,
            permissionMode: effectivePermissionMode,
            allowNativeBashTool: session.profile == .knowledge ? false : runtimePermission.allowNativeBashTool,
            mcpStrictMode: session.profile == .knowledge ? true : runtimePermission.mcpStrictMode,
            sessionProfile: session.profile,
            toolSearchEnabled: session.profile == .knowledge ? false : nil,
            autoPermissionValidationKey: autoPermissionValidationKey(
                for: permissionResolution,
                session: session,
                selectedModelRaw: session.selectedModelRaw,
                runtimeVariant: runtimeVariant
            ),
            repoPromptToolsMode: launchRepoPromptToolsMode(for: session)
        )
        return controllerLaunchSettingsByTabID[session.tabID] != expected
    }

    private func effectiveClaudeRuntimeVariantChanged(
        for session: AgentTabSession
    ) -> Bool {
        let runtimeVariant = session.selectedAgent.claudeRuntimeVariant ?? .standard
        return controllerLaunchSettingsByTabID[session.tabID].map { $0.runtimeVariant != runtimeVariant } ?? false
    }

    private func recycleClaudeControllerForLaunchSettingsChange(
        session: AgentTabSession,
        existingController: any NativeAgentRuntimeControlling,
        runtimeVariantChanged: Bool
    ) async {
        guard let detached = detachClaudeController(
            existingController,
            from: session,
            removeToolTracking: true
        ) else {
            return
        }
        if runtimeVariantChanged {
            // Provider session IDs are backend-specific. Reusing a standard Claude
            // session when switching to CC Moonshot/CC Zai/CC Custom can keep the
            // old process/session alive and bypass the compatible backend env.
            session.providerSessionID = nil
            session.isDirty = true
            viewModel?.scheduleSave(for: session.tabID)
        }
        _ = await retireClaudeController(
            detached,
            for: session,
            captureProviderSessionID: !runtimeVariantChanged
        )
    }

    private func detachClaudeController(
        _ controller: any NativeAgentRuntimeControlling,
        from session: AgentTabSession,
        removeToolTracking: Bool,
        preserveFallbackReplacementClaim: Bool = false
    ) -> DetachedClaudeController? {
        guard sessionOwnsClaudeController(controller, for: session) else { return nil }
        let toolHandler = removeToolTracking ? toolHandlerByTabID.removeValue(forKey: session.tabID) : nil
        clearClaudeControllerLaunchMetadata(
            for: session,
            preserveFallbackReplacementClaim: preserveFallbackReplacementClaim
        )
        return DetachedClaudeController(controller: controller, toolHandler: toolHandler)
    }

    private func clearClaudeControllerLaunchMetadata(
        for session: AgentTabSession,
        preserveFallbackReplacementClaim: Bool = false
    ) {
        session.claudeController = nil
        controllerLaunchSettingsByTabID.removeValue(forKey: session.tabID)
        controllerEffortEvidenceByTabID.removeValue(forKey: session.tabID)
        publishClaudePermissionState(.notStarted, for: session)
        if !preserveFallbackReplacementClaim {
            invalidateFallbackReplacementClaim(for: session)
        }
    }

    private func stopToolTracking(
        _ detached: DetachedClaudeController,
        for session: AgentTabSession
    ) async {
        #if DEBUG
            if let testStopToolTrackingGate {
                await testStopToolTrackingGate()
            }
        #endif
        await detached.toolHandler?.stopTracking(for: session)
    }

    @discardableResult
    private func retireClaudeController(
        _ detached: DetachedClaudeController,
        for session: AgentTabSession,
        captureProviderSessionID: Bool,
        scheduleProviderSessionSave: Bool = true
    ) async -> Bool {
        let generation = UUID()
        controllerRetirementGenerationByTabID[session.tabID] = generation
        if captureProviderSessionID {
            let sessionRef = await detached.controller.currentSessionRef()
            if controllerRetirementGenerationByTabID[session.tabID] == generation,
               session.claudeController == nil
            {
                updateProviderSessionIDIfNeeded(
                    sessionRef.sessionID,
                    for: session,
                    scheduleSave: scheduleProviderSessionSave
                )
            }
        }
        await detached.controller.shutdown()
        await stopToolTracking(detached, for: session)
        guard controllerRetirementGenerationByTabID[session.tabID] == generation else {
            return false
        }
        controllerRetirementGenerationByTabID.removeValue(forKey: session.tabID)
        return true
    }

    private func invalidateControllerRetirement(for session: AgentTabSession) {
        controllerRetirementGenerationByTabID.removeValue(forKey: session.tabID)
    }

    private func beginFallbackReplacementClaim(
        for session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID?
    ) -> FallbackReplacementClaim {
        invalidateFallbackReplacementClaim(for: session)
        let claim = FallbackReplacementClaim(
            id: UUID(),
            runID: runID,
            runAttemptID: runAttemptID
        )
        fallbackReplacementClaimByTabID[session.tabID] = claim
        return claim
    }

    private func sessionOwnsDetachedFallbackReplacementClaim(
        _ claim: FallbackReplacementClaim,
        for session: AgentTabSession
    ) -> Bool {
        fallbackReplacementClaimByTabID[session.tabID] == claim
            && session.runID == claim.runID
            && session.activeRunAttemptID == claim.runAttemptID
            && session.runState.isActive
            && session.claudeController == nil
    }

    private func sessionOwnsInstalledFallbackReplacementClaim(
        _ claim: FallbackReplacementClaim,
        controller: any NativeAgentRuntimeControlling,
        for session: AgentTabSession
    ) -> Bool {
        fallbackReplacementClaimByTabID[session.tabID] == claim
            && session.runID == claim.runID
            && session.activeRunAttemptID == claim.runAttemptID
            && session.runState.isActive
            && sessionOwnsClaudeController(controller, for: session)
    }

    private func trackPrivateFallbackController(
        _ controller: any NativeAgentRuntimeControlling,
        for session: AgentTabSession,
        claim: FallbackReplacementClaim
    ) -> Bool {
        guard sessionOwnsDetachedFallbackReplacementClaim(claim, for: session),
              privateFallbackControllerByTabID[session.tabID] == nil
        else {
            return false
        }
        privateFallbackControllerByTabID[session.tabID] = TrackedPrivateFallbackController(
            claim: claim,
            controller: controller
        )
        return true
    }

    private func removeTrackedPrivateFallbackController(
        for tabID: UUID,
        claim: FallbackReplacementClaim,
        controller: (any NativeAgentRuntimeControlling)? = nil
    ) -> (any NativeAgentRuntimeControlling)? {
        guard let tracked = privateFallbackControllerByTabID[tabID],
              tracked.claim == claim,
              controller.map({ controllersAreIdentical($0, tracked.controller) }) ?? true
        else {
            return nil
        }
        privateFallbackControllerByTabID.removeValue(forKey: tabID)
        return tracked.controller
    }

    private func scheduleShutdownTrackedPrivateFallbackController(
        for session: AgentTabSession,
        claim: FallbackReplacementClaim
    ) {
        guard let controller = removeTrackedPrivateFallbackController(
            for: session.tabID,
            claim: claim
        ) else {
            return
        }
        guard !sessionOwnsClaudeController(controller, for: session) else { return }
        Task { await controller.shutdown() }
    }

    private func invalidateFallbackReplacementClaim(for session: AgentTabSession) {
        guard let claim = fallbackReplacementClaimByTabID.removeValue(forKey: session.tabID) else {
            return
        }
        scheduleShutdownTrackedPrivateFallbackController(for: session, claim: claim)
    }

    private func invalidateFallbackReplacementClaim(
        _ claim: FallbackReplacementClaim,
        for session: AgentTabSession
    ) {
        if fallbackReplacementClaimByTabID[session.tabID] == claim {
            fallbackReplacementClaimByTabID.removeValue(forKey: session.tabID)
        }
        scheduleShutdownTrackedPrivateFallbackController(for: session, claim: claim)
    }

    #if DEBUG
        package func test_discardRuntimeState(for session: AgentTabSession) {
            preparationByTabID.removeValue(forKey: session.tabID)?.task.cancel()
            dispatchReservationByTabID.removeValue(forKey: session.tabID)
            controllerEffortEvidenceByTabID.removeValue(forKey: session.tabID)
            session.claudePermissionSessionState = .notStarted
            session.claudeController = nil
            controllerLaunchSettingsByTabID.removeValue(forKey: session.tabID)
            controllerRetirementGenerationByTabID.removeValue(forKey: session.tabID)
            invalidateFallbackReplacementClaim(for: session)
            pendingResumeTransferTasksByTabID.removeValue(forKey: session.tabID)?.cancel()
            pendingResumeTransferGenerationByTabID.removeValue(forKey: session.tabID)
            let retiredTasks = retiredResumeTransferTasksByTabID.removeValue(forKey: session.tabID) ?? []
            retiredTasks.forEach { $0.cancel() }
            if let toolHandler = toolHandlerByTabID.removeValue(forKey: session.tabID) {
                Task { await toolHandler.stopTracking(for: session) }
            }
        }

        func test_setControllerLaunchSettings(
            _ settings: ControllerLaunchSettings,
            for session: AgentTabSession
        ) {
            if session.claudeController != nil {
                invalidateControllerRetirement(for: session)
                invalidateFallbackReplacementClaim(for: session)
            }
            controllerLaunchSettingsByTabID[session.tabID] = settings
        }

        func test_controllerLaunchSettings(
            for session: AgentTabSession
        ) -> ControllerLaunchSettings? {
            controllerLaunchSettingsByTabID[session.tabID]
        }

        func test_trackedClaudeRunID(
            for session: AgentTabSession
        ) -> UUID? {
            toolHandlerByTabID[session.tabID]?.currentTrackedRunID
        }

        func test_setUnstartedInterruptResultWaitSeconds(_ seconds: TimeInterval) {
            unstartedInterruptResultWaitSeconds = seconds
        }

        func test_setInterruptedTurnSettlementTimeoutSeconds(_ seconds: TimeInterval) {
            interruptedTurnSettlementTimeoutSeconds = seconds
        }

        func test_setStopToolTrackingGate(_ gate: (() async -> Void)?) {
            testStopToolTrackingGate = gate
        }

        func test_setBeforePromptCacheRetentionSync(
            _ hook: ((AgentTabSession) -> Void)?
        ) {
            testBeforePromptCacheRetentionSync = hook
        }

        func test_setResumeRecoveryHandoffBeforeCommitGate(_ gate: (@MainActor () async -> Void)?) {
            testResumeRecoveryHandoffBeforeCommitGate = gate
        }

        func test_hasFallbackReplacementClaim(
            for session: AgentTabSession
        ) -> Bool {
            fallbackReplacementClaimByTabID[session.tabID] != nil
        }

        func test_pendingRepoPromptMCPRecoveryConversationID(
            for session: AgentTabSession
        ) -> String? {
            pendingRepoPromptMCPRecoveryByTabID[session.tabID]?.conversationID
        }

        func test_hasTrackedPrivateFallbackController(
            for session: AgentTabSession
        ) -> Bool {
            privateFallbackControllerByTabID[session.tabID] != nil
        }

        func test_hasPendingOrRetiredResumeTransfers(
            for session: AgentTabSession
        ) -> Bool {
            hasPendingResumeTransfer(for: session)
                || pendingResumeTransferGenerationByTabID[session.tabID] != nil
        }

        static func test_shouldRetryFreshStartWithoutResume(
            after error: Error,
            existingSessionID: String?
        ) -> Bool {
            shouldRetryFreshStartWithoutResume(
                after: error,
                existingSessionID: existingSessionID
            )
        }
    #endif

    private func controllersAreIdentical(
        _ lhs: any NativeAgentRuntimeControlling,
        _ rhs: any NativeAgentRuntimeControlling
    ) -> Bool {
        ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
    }

    private func sessionOwnsClaudeController(
        _ controller: any NativeAgentRuntimeControlling,
        for session: AgentTabSession
    ) -> Bool {
        guard let currentController = session.claudeController else { return false }
        return controllersAreIdentical(currentController, controller)
    }

    private func shutdownClaudeControllerIfUnowned(
        _ controller: any NativeAgentRuntimeControlling,
        by session: AgentTabSession
    ) async {
        guard !sessionOwnsClaudeController(controller, for: session) else { return }
        await controller.shutdown()
    }

    private func recordStartupEffortEvidence(
        from sessionRef: NativeAgentRuntimeSessionRef,
        controller: any NativeAgentRuntimeControlling,
        launchEffortLevel: ClaudeCodeEffortLevel,
        for session: AgentTabSession
    ) {
        guard sessionOwnsClaudeController(controller, for: session) else { return }
        let controllerIdentifier = ObjectIdentifier(controller as AnyObject)
        let existingEvidence = controllerEffortEvidenceByTabID[session.tabID]
        let acknowledgedEffort: ClaudeCodeEffortLevel? = if sessionRef.initializedDuringCall {
            launchEffortLevel
        } else if existingEvidence?.controllerIdentifier == controllerIdentifier,
                  existingEvidence?.initializationGeneration == sessionRef.initializationGeneration
        {
            existingEvidence?.acknowledgedEffort
        } else {
            nil
        }
        controllerEffortEvidenceByTabID[session.tabID] = ControllerEffortEvidence(
            controllerIdentifier: controllerIdentifier,
            initializationGeneration: sessionRef.initializationGeneration,
            acknowledgedEffort: acknowledgedEffort
        )
    }

    private func startOrResumeWithFallback(
        controller: any NativeAgentRuntimeControlling,
        session: AgentTabSession,
        runID: UUID,
        model: String?,
        effortLevel: ClaudeCodeEffortLevel,
        runtimeVariant: ClaudeCodeRuntimeVariant,
        effectivePermissionMode: String,
        effectiveAllowNativeBashTool: Bool?,
        effectiveMCPStrictMode: Bool?,
        effectiveToolSearchEnabled: Bool?,
        autoPermissionValidationKey: AutoPermissionValidationKey?,
        effectiveRepoPromptToolsMode: RepoPromptToolsMode?
    ) async throws -> NativeAgentRuntimeSessionRef {
        let existingSessionID = session.providerSessionID
        let runAttemptID = session.activeRunAttemptID
        // R6 owner capture: this start (launch reservation, startup permission mode) and its fresh
        // fallback carry the scope of the run attempt captured here, never one read later.
        let runtimeOwner = session.runtimeSessionScope(processRunID: runID)
        let systemPromptOverride = agentModeSystemPromptOverride(for: session)
        if let pendingConversationID = pendingRepoPromptMCPRecoveryByTabID[session.tabID]?.conversationID {
            if pendingConversationID == existingSessionID {
                // Every start of a pending RepoPrompt MCP recovery resumes exactly that
                // conversation; an unavailable resume asks the user rather than starting fresh.
                session.recoveryResumeFallbackSuppressedConversationID = pendingConversationID
            } else {
                // The tab moved to another (or no) conversation: that recovery no longer applies.
                clearRepoPromptMCPRecovery(for: session)
            }
        }
        if controller.joinsRetirementBeforeSuccessor {
            // R6: a retired registered runtime of this tab (any provider, for example a Codex
            // controller retired by a provider switch) finishes its cleanup before this start
            // reserves; the start then proceeds only while it is still current.
            await session.joinRuntimeRetirements()
            guard !Task.isCancelled,
                  session.runID == runID,
                  session.activeRunAttemptID == runAttemptID,
                  session.runState.isActive,
                  sessionOwnsClaudeController(controller, for: session)
            else {
                await shutdownClaudeControllerIfUnowned(controller, by: session)
                throw ControllerLifecycleError.superseded
            }
        }
        do {
            let sessionRef = try await AgentRuntimeOperationOwner.$session.withValue(runtimeOwner) {
                try await controller.startOrResume(
                    existingSessionID: existingSessionID,
                    model: model,
                    effortLevel: effortLevel,
                    systemPromptOverride: systemPromptOverride
                )
            }
            recordStartupEffortEvidence(
                from: sessionRef,
                controller: controller,
                launchEffortLevel: effortLevel,
                for: session
            )
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID,
                  session.runState.isActive,
                  sessionOwnsClaudeController(controller, for: session)
            else {
                await shutdownClaudeControllerIfUnowned(controller, by: session)
                throw ControllerLifecycleError.superseded
            }
            if let existingSessionID, session.recoveryResumeFallbackSuppressedConversationID == existingSessionID {
                // Phase 4: the recovery dispatch resumed its conversation; the suppression ends.
                session.recoveryResumeFallbackSuppressedConversationID = nil
                session.recoveryResumeUnavailableConversationID = nil
            }
            return sessionRef
        } catch ControllerLifecycleError.superseded {
            throw ControllerLifecycleError.superseded
        } catch {
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID,
                  session.runState.isActive,
                  sessionOwnsClaudeController(controller, for: session)
            else {
                await shutdownClaudeControllerIfUnowned(controller, by: session)
                throw ControllerLifecycleError.superseded
            }
            switch Self.resumeFailureDisposition(
                after: error,
                existingSessionID: existingSessionID,
                suppressedConversationID: session.recoveryResumeFallbackSuppressedConversationID
            ) {
            case .rethrow:
                throw error
            case let .requireExplicitChoice(conversationID):
                // Phase 4: a recovery dispatch never falls back to an implicit fresh conversation.
                // The startup failed before any input write; the user chooses explicitly.
                session.recoveryResumeUnavailableConversationID = conversationID
                throw AgentRecoveryResumeFallbackRequired(conversationID: conversationID)
            case .retryFresh:
                break
            }

            let replacementClaim = beginFallbackReplacementClaim(
                for: session,
                runID: runID,
                runAttemptID: runAttemptID
            )
            guard let detached = detachClaudeController(
                controller,
                from: session,
                removeToolTracking: true,
                preserveFallbackReplacementClaim: true
            ) else {
                invalidateFallbackReplacementClaim(replacementClaim, for: session)
                throw ControllerLifecycleError.superseded
            }
            let shouldResumeToolTracking = detached.toolHandler != nil
            let retired = await retireClaudeController(
                detached,
                for: session,
                captureProviderSessionID: false
            )
            guard retired,
                  sessionOwnsDetachedFallbackReplacementClaim(replacementClaim, for: session)
            else {
                invalidateFallbackReplacementClaim(replacementClaim, for: session)
                throw ControllerLifecycleError.superseded
            }

            let launchSettings: ControllerLaunchSettings
            let freshController: any NativeAgentRuntimeControlling
            do {
                let retryWorkspacePath = try workspacePathProvider(session)
                launchSettings = ControllerLaunchSettings(
                    runtimeVariant: runtimeVariant,
                    workspacePath: retryWorkspacePath,
                    permissionMode: effectivePermissionMode,
                    allowNativeBashTool: effectiveAllowNativeBashTool,
                    mcpStrictMode: effectiveMCPStrictMode,
                    sessionProfile: session.profile,
                    toolSearchEnabled: effectiveToolSearchEnabled,
                    autoPermissionValidationKey: autoPermissionValidationKey,
                    repoPromptToolsMode: effectiveRepoPromptToolsMode
                )
                freshController = try claudeControllerFactory(
                    runID,
                    session.tabID,
                    windowID,
                    launchSettings
                )
            } catch {
                guard sessionOwnsDetachedFallbackReplacementClaim(replacementClaim, for: session) else {
                    invalidateFallbackReplacementClaim(replacementClaim, for: session)
                    throw ControllerLifecycleError.superseded
                }
                throw ControllerLifecycleError.claimedStartupFailure(error, replacementClaim)
            }

            guard sessionOwnsDetachedFallbackReplacementClaim(replacementClaim, for: session),
                  trackPrivateFallbackController(
                      freshController,
                      for: session,
                      claim: replacementClaim
                  )
            else {
                invalidateFallbackReplacementClaim(replacementClaim, for: session)
                await shutdownClaudeControllerIfUnowned(freshController, by: session)
                throw ControllerLifecycleError.superseded
            }
            publishClaudePermissionState(
                .initializing(
                    ownership: permissionOwnership(
                        controller: freshController,
                        runID: runID,
                        runAttemptID: runAttemptID
                    ),
                    launchSettings: launchSettings,
                    requestedMode: effectivePermissionMode
                ),
                for: session
            )
            let sessionRef: NativeAgentRuntimeSessionRef
            do {
                sessionRef = try await AgentRuntimeOperationOwner.$session.withValue(runtimeOwner) {
                    try await freshController.startOrResume(
                        existingSessionID: nil,
                        model: model,
                        effortLevel: effortLevel,
                        systemPromptOverride: systemPromptOverride
                    )
                }
            } catch {
                guard sessionOwnsDetachedFallbackReplacementClaim(replacementClaim, for: session),
                      let failedPrivateController = removeTrackedPrivateFallbackController(
                          for: session.tabID,
                          claim: replacementClaim,
                          controller: freshController
                      )
                else {
                    invalidateFallbackReplacementClaim(replacementClaim, for: session)
                    throw ControllerLifecycleError.superseded
                }
                await failedPrivateController.shutdown()
                guard sessionOwnsDetachedFallbackReplacementClaim(replacementClaim, for: session) else {
                    invalidateFallbackReplacementClaim(replacementClaim, for: session)
                    throw ControllerLifecycleError.superseded
                }
                throw ControllerLifecycleError.claimedStartupFailure(error, replacementClaim)
            }
            guard sessionOwnsDetachedFallbackReplacementClaim(replacementClaim, for: session) else {
                invalidateFallbackReplacementClaim(replacementClaim, for: session)
                throw ControllerLifecycleError.superseded
            }

            let handoffOwnershipMaintained: Bool
            if let viewModel {
                #if DEBUG
                    let beforeCommit = testResumeRecoveryHandoffBeforeCommitGate
                #else
                    let beforeCommit: (@MainActor () async -> Void)? = nil
                #endif
                handoffOwnershipMaintained = await viewModel.stageClaudeResumeRecoveryHandoffIfNeeded(
                    for: session,
                    ifStillOwned: { [weak self, weak session] in
                        guard let self, let session else { return false }
                        return sessionOwnsDetachedFallbackReplacementClaim(
                            replacementClaim,
                            for: session
                        )
                    },
                    beforeCommit: beforeCommit
                )
            } else {
                handoffOwnershipMaintained = sessionOwnsDetachedFallbackReplacementClaim(
                    replacementClaim,
                    for: session
                )
            }
            guard handoffOwnershipMaintained,
                  sessionOwnsDetachedFallbackReplacementClaim(replacementClaim, for: session)
            else {
                invalidateFallbackReplacementClaim(replacementClaim, for: session)
                throw ControllerLifecycleError.superseded
            }

            let trimmedFreshSessionID = sessionRef.sessionID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let freshSessionID = trimmedFreshSessionID.flatMap { $0.isEmpty ? nil : $0 }
            guard removeTrackedPrivateFallbackController(
                for: session.tabID,
                claim: replacementClaim,
                controller: freshController
            ) != nil else {
                invalidateFallbackReplacementClaim(replacementClaim, for: session)
                throw ControllerLifecycleError.superseded
            }
            invalidateControllerRetirement(for: session)
            session.claudeController = freshController
            recordStartupEffortEvidence(
                from: sessionRef,
                controller: freshController,
                launchEffortLevel: effortLevel,
                for: session
            )
            controllerLaunchSettingsByTabID[session.tabID] = launchSettings
            if session.providerSessionID != freshSessionID {
                session.providerSessionID = freshSessionID
                session.isDirty = true
                viewModel?.scheduleSave(for: session.tabID)
            }
            if shouldResumeToolTracking {
                await ensureClaudeToolTrackingIfNeeded(for: session, runID: runID)
                guard sessionOwnsInstalledFallbackReplacementClaim(
                    replacementClaim,
                    controller: freshController,
                    for: session
                ) else {
                    invalidateFallbackReplacementClaim(replacementClaim, for: session)
                    await shutdownClaudeControllerIfUnowned(freshController, by: session)
                    throw ControllerLifecycleError.superseded
                }
            }
            invalidateFallbackReplacementClaim(replacementClaim, for: session)
            return sessionRef
        }
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

    enum ResumeFailureDisposition: Equatable {
        case rethrow
        case retryFresh
        /// Phase 4 recovery dispatch: the implicit fresh fallback is suppressed for this conversation.
        case requireExplicitChoice(conversationID: String)
    }

    /// What a failed start/resume does next. The implicit fresh retry applies only when the failure
    /// qualifies (`shouldRetryFreshStartWithoutResume`) and no recovery dispatch suppressed it for
    /// exactly this conversation.
    static func resumeFailureDisposition(
        after error: Error,
        existingSessionID: String?,
        suppressedConversationID: String?
    ) -> ResumeFailureDisposition {
        guard shouldRetryFreshStartWithoutResume(after: error, existingSessionID: existingSessionID) else {
            return .rethrow
        }
        if let existingSessionID, suppressedConversationID == existingSessionID {
            return .requireExplicitChoice(conversationID: existingSessionID)
        }
        return .retryFresh
    }

    private static func shouldRetryFreshStartWithoutResume(
        after error: Error,
        existingSessionID: String?
    ) -> Bool {
        if error is ClaudeNativeProcessSessionController.PermissionStageError
            || error is ClaudeAgentToolPreferences.AutoPermissionModeBlockedError
            // R6: a registry refusal never falls back to another (fresh) launch.
            || error is AgentProcessRegistryError
        {
            return false
        }
        guard
            let existingSessionID,
            !existingSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let controllerError = error as? NativeAgentRuntimeControllerError
        else {
            return false
        }
        switch controllerError {
        // Any controller startup/handshake failure while attempting to resume an
        // existing Claude session is safer to recover by starting fresh and
        // injecting a handoff than by hard-failing the run. Fresh starts do not
        // take this path because they have no existing session ID.
        case .processNotRunning,
             .inputWriteFailed,
             .initializationFailed,
             .invalidControlResponse,
             .controlRequestTimedOut:
            return true
        case .liveModelSwitchRequiresRestart,
             .repoPromptMCPRecoveryRequired:
            return false
        }
    }

    private func awaitSteeringInterruptSafePoint(
        session: AgentTabSession,
        runID: UUID,
        handler: ClaudeAgentToolTrackingHandler,
        timeoutSeconds: TimeInterval? = nil
    ) async -> SteeringInterruptSafePointResult {
        let effectiveTimeoutSeconds = timeoutSeconds ?? steeringInterruptSafePointTimeoutSeconds
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(effectiveTimeoutSeconds * 1000)))
        while true {
            guard session.runID == runID, session.runState.isActive else {
                return .cancelled
            }

            do {
                if let awaitNoActiveMCPTools {
                    let reachedLocalIdle = try await awaitOperationUntilDeadline(deadline: deadline) {
                        try await awaitNoActiveMCPTools(runID)
                    }
                    guard reachedLocalIdle else {
                        let snapshot = handler.explicitProviderToolResultAckSnapshot(for: runID)
                        let localCount = toolEndedCount(runID)
                        let stillActive = hasActiveMCPTools(runID) || hasActiveChildAgentRunWaits(runID)
                        logSteeringInterruptSafePointTimeout(
                            runID: runID,
                            snapshot: snapshot,
                            localCount: localCount,
                            stillActive: stillActive
                        )
                        return .timedOut(snapshot: snapshot, localCount: localCount, stillActive: stillActive)
                    }
                }

                let requiredAckCount = toolEndedCount(runID)
                let reachedAckParity = try await awaitOperationUntilDeadline(deadline: deadline) {
                    try await handler.awaitExplicitProviderToolResultAcks(
                        for: runID,
                        atLeast: requiredAckCount
                    )
                }
                let snapshot = handler.explicitProviderToolResultAckSnapshot(for: runID)
                let currentLocalCount = toolEndedCount(runID)
                let ordinaryMCPActive = hasActiveMCPTools(runID)
                let childWaitActive = hasActiveChildAgentRunWaits(runID)
                let stillActive = ordinaryMCPActive || childWaitActive

                guard reachedAckParity else {
                    logSteeringInterruptSafePointTimeout(
                        runID: runID,
                        snapshot: snapshot,
                        localCount: currentLocalCount,
                        stillActive: stillActive
                    )
                    return .timedOut(snapshot: snapshot, localCount: currentLocalCount, stillActive: stillActive)
                }

                if !stillActive,
                   currentLocalCount == requiredAckCount,
                   snapshot.ackCount >= requiredAckCount
                {
                    await Task.yield()
                    return .ready
                }

                guard ContinuousClock.now < deadline else {
                    logSteeringInterruptSafePointTimeout(
                        runID: runID,
                        snapshot: snapshot,
                        localCount: currentLocalCount,
                        stillActive: stillActive
                    )
                    return .timedOut(snapshot: snapshot, localCount: currentLocalCount, stillActive: stillActive)
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch is CancellationError {
                return .cancelled
            } catch {
                let snapshot = handler.explicitProviderToolResultAckSnapshot(for: runID)
                let localCount = toolEndedCount(runID)
                let stillActive = hasActiveMCPTools(runID) || hasActiveChildAgentRunWaits(runID)
                logSteeringInterruptSafePointTimeout(
                    runID: runID,
                    snapshot: snapshot,
                    localCount: localCount,
                    stillActive: stillActive,
                    error: error
                )
                return .timedOut(snapshot: snapshot, localCount: localCount, stillActive: stillActive)
            }
        }
    }

    private func awaitOperationUntilDeadline(
        deadline: ContinuousClock.Instant,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws -> Bool {
        guard ContinuousClock.now < deadline else { return false }
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                try await operation()
                return true
            }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                return false
            }
            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func logSteeringInterruptSafePointTimeout(
        runID: UUID,
        snapshot: ClaudeAgentToolTrackingHandler.ExplicitProviderToolResultAckSnapshot,
        localCount: Int,
        stillActive: Bool,
        error: Error? = nil
    ) {
        let recent = snapshot.recentObservations.map { observation in
            "\(observation.toolName)#\(observation.invocationID?.uuidString ?? "nil"):\(observation.reason):\(observation.ackCountAfterEvent)"
        }.joined(separator: ", ")
        let errorDescription = error.map { String(describing: $0) } ?? "none"
        Self.logger.error(
            "Claude steering safe-point timed out runID=\(runID.uuidString, privacy: .public) localCount=\(localCount) ackCount=\(snapshot.ackCount) stillActive=\(stillActive) trackedRunID=\(snapshot.trackedRunID?.uuidString ?? "nil", privacy: .public) recent=\(recent, privacy: .public) error=\(errorDescription, privacy: .public)"
        )
    }

    /// Records the provider's terminal evidence for a written user message. Only the turn's own
    /// `.completed` result is affirmative acceptance; cancelled/failed results (including ones the
    /// controller synthesizes on process exit) leave delivery unknown, unless RepoPrompt's own Stop
    /// or quit ended that turn after it started (O49, `teardownRequestedByRepoPrompt`). While a
    /// steer interrupt of the turn is pending, the decision waits for its outcome. Called before
    /// any other handling of the completion.
    ///
    /// Step 12: a turn RepoPrompt interrupted before the CLI was credited with starting it
    /// (`unstartedInterrupt`) is accepted only on the CLI's exclusive interrupted-turn `.cancelled`
    /// result (`origin.isExclusiveInterruptedResult`) together with an acknowledged interrupt, in
    /// either order.
    ///
    /// The completion must come from the controller that wrote the turn (`isEmittedBy` is asked
    /// about that controller), so it applies only to that same captured turn and delivery
    /// attempt, never to a successor. It is honored even after the turn's run attempt finalized
    /// and recorded uncertainty: a late `.completed` refines `deliveryUnknown` to accepted.
    func noteClaudeTurnCompleted(
        turnID: UUID,
        status: NativeAgentRuntimeTurnStatus,
        origin: NativeAgentRuntimeTurnCompletionOrigin = .controllerSynthesized,
        isEmittedBy: (AnyObject) -> Bool
    ) {
        guard let written = dispatchHandoffsByTurnID[turnID] else { return }
        guard let writer = written.controller else {
            // The writing controller is gone; nothing more can arrive for this turn.
            dispatchHandoffsByTurnID.removeValue(forKey: turnID)
            Self.settleWithoutCompletion(written)
            return
        }
        guard isEmittedBy(writer) else { return }
        switch status {
        case .completed:
            dispatchHandoffsByTurnID.removeValue(forKey: turnID)
            written.handoff.noteAccepted()
        case .cancelled where written.teardownRequestedByRepoPrompt, .failed where written.teardownRequestedByRepoPrompt:
            // O49: RepoPrompt's own Stop or quit ended a turn the CLI had already begun (output
            // was attributed to it), so the message was received. The basis is that start
            // evidence, not the cancel: a `.failed` from a process exit during the stop is the
            // same received message.
            dispatchHandoffsByTurnID.removeValue(forKey: turnID)
            written.handoff.noteAccepted()
        case .cancelled where written.interruptPending, .failed where written.interruptPending:
            // O49: the steer's mark is provisional; the interrupt outcome decides.
            dispatchHandoffsByTurnID[turnID]?.completionDuringInterrupt = status
        case .cancelled where written.unstartedInterrupt != nil && origin.isExclusiveInterruptedResult:
            // Step 12: the CLI's own interrupted-turn result for exactly this turn. With the
            // interrupt acknowledged it proves receipt; before the acknowledgement it waits for it.
            if written.unstartedInterrupt?.acknowledged == true {
                dispatchHandoffsByTurnID.removeValue(forKey: turnID)
                written.handoff.noteAccepted()
            } else {
                dispatchHandoffsByTurnID[turnID]?.unstartedInterrupt?.providerCancelledResultHeld = true
            }
        case .cancelled, .failed:
            // Includes Step 12's non-qualifying ends: a synthesized or shared-FIFO completion, a
            // result that does not itself report an interruption or names another message, or
            // `.failed`, never proves receipt of a turn that showed no output.
            dispatchHandoffsByTurnID.removeValue(forKey: turnID)
            written.handoff.noteDeliveryUnknown()
        }
    }

    /// O49: the written turn `controller` reports as started, when that same controller wrote it.
    /// Queued turns and older retained handoffs are never the started turn.
    private func startedWrittenTurnID(of controller: any NativeAgentRuntimeControlling) -> UUID? {
        guard let turnID = controller.startedTurnID,
              let written = dispatchHandoffsByTurnID[turnID],
              written.controller === (controller as AnyObject)
        else { return nil }
        return turnID
    }

    /// Step 12: the one written turn of `controller` with no completion yet, when there is exactly
    /// one. More than one means the CLI's next result cannot be tied to a specific turn (FIFO
    /// attribution; a skipped message would take another turn's result).
    private func soleUnresolvedWrittenTurnID(of controller: any NativeAgentRuntimeControlling) -> UUID? {
        let unresolved = dispatchHandoffsByTurnID.filter { _, written in
            written.controller === (controller as AnyObject)
                && written.completionDuringInterrupt == nil
                && written.unstartedInterrupt?.providerCancelledResultHeld != true
        }
        guard unresolved.count == 1 else { return nil }
        return unresolved.first?.key
    }

    /// O49: RepoPrompt is about to interrupt `controller`'s started turn (steer or cleanup). The
    /// mark is provisional until `resolveRepoPromptInterrupt` learns the outcome. Call before
    /// `interruptTurn`, so a result that races the acknowledgement waits for it. Returns the mark
    /// this call placed (nil when nothing was marked or another interrupt is already pending).
    ///
    /// Step 12: with no started turn, the controller's sole unresolved written turn gets the gated
    /// `unstartedInterrupt` mark instead. Steer interrupts before writing its own message, so that
    /// message is never counted here.
    ///
    /// A started turn that still carries an acknowledged unstarted mark gets no O49 mark: after an
    /// acknowledged interrupt and no result of its own, the output now credited to it (FIFO head)
    /// is almost certainly a later message's, so it stays under the Step 12 gate. A started turn
    /// with an unacknowledged unstarted mark drops it and the started path (O49) decides it.
    private func noteRepoPromptInterruptRequested(
        controller: any NativeAgentRuntimeControlling
    ) -> RepoPromptInterruptMark? {
        if let turnID = startedWrittenTurnID(of: controller) {
            guard dispatchHandoffsByTurnID[turnID]?.interruptPending == false,
                  !Self.hasAcknowledgedUnstartedInterrupt(dispatchHandoffsByTurnID[turnID])
            else { return nil }
            dispatchHandoffsByTurnID[turnID]?.interruptPending = true
            dispatchHandoffsByTurnID[turnID]?.unstartedInterrupt = nil
            return .started(turnID)
        }
        guard let turnID = soleUnresolvedWrittenTurnID(of: controller),
              let written = dispatchHandoffsByTurnID[turnID],
              !written.interruptPending,
              written.unstartedInterrupt == nil
        else { return nil }
        dispatchHandoffsByTurnID[turnID]?.unstartedInterrupt = UnstartedInterrupt()
        return .unstarted(turnID)
    }

    /// O49: the interrupt that marked `turnID` returned. Acknowledged: the started message was
    /// received and settles accepted. Otherwise the provisional mark is withdrawn, and a
    /// completion that arrived meanwhile gets its normal outcome. A teardown mark is never
    /// withdrawn here.
    private func resolveRepoPromptInterrupt(
        _ mark: RepoPromptInterruptMark?,
        outcome: NativeAgentRuntimeInterruptOutcome
    ) {
        let turnID: UUID
        switch mark {
        case nil:
            return
        case let .unstarted(markedTurnID):
            guard let written = dispatchHandoffsByTurnID[markedTurnID],
                  let unstarted = written.unstartedInterrupt
            else { return }
            resolveUnstartedInterrupt(markedTurnID, written: written, unstarted: unstarted, outcome: outcome)
            return
        case let .started(markedTurnID):
            turnID = markedTurnID
        }
        guard let written = dispatchHandoffsByTurnID[turnID] else { return }
        if outcome == .acknowledged {
            dispatchHandoffsByTurnID.removeValue(forKey: turnID)
            written.handoff.noteAccepted()
            return
        }
        guard written.completionDuringInterrupt != nil else {
            dispatchHandoffsByTurnID[turnID]?.interruptPending = false
            return
        }
        dispatchHandoffsByTurnID.removeValue(forKey: turnID)
        if written.teardownRequestedByRepoPrompt {
            written.handoff.noteAccepted()
        } else {
            written.handoff.noteDeliveryUnknown()
        }
    }

    /// Step 12: the gated half of `resolveRepoPromptInterrupt`. Acknowledged: accepts when the
    /// CLI's exclusive cancelled result is already held, otherwise waits for it (run end without it
    /// leaves the message uncertain). Not acknowledged (timed out, failed, no turn in flight): the
    /// mark is withdrawn and a held result proves nothing.
    private func resolveUnstartedInterrupt(
        _ turnID: UUID,
        written: WrittenDispatchHandoff,
        unstarted: UnstartedInterrupt,
        outcome: NativeAgentRuntimeInterruptOutcome
    ) {
        guard outcome == .acknowledged else {
            guard unstarted.providerCancelledResultHeld else {
                dispatchHandoffsByTurnID[turnID]?.unstartedInterrupt = nil
                return
            }
            dispatchHandoffsByTurnID.removeValue(forKey: turnID)
            written.handoff.noteDeliveryUnknown()
            return
        }
        guard unstarted.providerCancelledResultHeld else {
            dispatchHandoffsByTurnID[turnID]?.unstartedInterrupt?.acknowledged = true
            return
        }
        dispatchHandoffsByTurnID.removeValue(forKey: turnID)
        written.handoff.noteAccepted()
    }

    /// O49 (Stop and quit): RepoPrompt is about to stop this session's run. Called synchronously
    /// before the run detaches its controller, so the started turn is marked before run end
    /// settles its written messages; the CLI's result is not awaited.
    package func noteRepoPromptTeardownRequested(_ session: AgentTabSession) {
        guard session.selectedAgent.usesClaudeNativeRuntime,
              let controller = session.claudeController,
              let turnID = startedWrittenTurnID(of: controller),
              // Step 12: a suspect started credit (see `noteRepoPromptInterruptRequested`).
              !Self.hasAcknowledgedUnstartedInterrupt(dispatchHandoffsByTurnID[turnID])
        else { return }
        dispatchHandoffsByTurnID[turnID]?.teardownRequestedByRepoPrompt = true
    }

    /// Step 12: `written` carries an unstarted interrupt the CLI acknowledged and no result of its
    /// own has decided it. Such a turn is never promoted to O49 acceptance by a later started credit.
    private static func hasAcknowledgedUnstartedInterrupt(_ written: WrittenDispatchHandoff?) -> Bool {
        written?.unstartedInterrupt?.acknowledged == true
    }

    /// O49: how a written message without its turn's completion ends tracking. Only a teardown
    /// mark accepts; a pending interrupt's provisional mark does not.
    private static func settleWithoutCompletion(_ written: WrittenDispatchHandoff) {
        if written.teardownRequestedByRepoPrompt {
            written.handoff.noteAccepted()
        } else {
            written.handoff.settleIfUnresolved()
        }
    }

    /// A run attempt ended: written messages of that attempt without their turn's completion
    /// become delivery-unknown (never retryable drafts). They stay associated with their turn so
    /// a late completion from the same controller can still prove acceptance.
    func settleWrittenDispatchHandoffs(tabID: UUID, runAttemptID: UUID) {
        for written in dispatchHandoffsByTurnID.values
            where written.tabID == tabID && written.runAttemptID == runAttemptID
        {
            Self.settleWithoutCompletion(written)
        }
    }

    /// An event router of `tabID` finished: no further events can be delivered from controllers
    /// for which `isStillDeliverable` is false. Their written messages end tracking as
    /// delivery-unknown; entries of deallocated controllers end too.
    func releaseWrittenDispatchHandoffs(
        tabID: UUID,
        isStillDeliverable: (AnyObject) -> Bool
    ) {
        let released = dispatchHandoffsByTurnID.filter { _, written in
            guard written.tabID == tabID else { return false }
            guard let writer = written.controller else { return true }
            return !isStillDeliverable(writer)
        }
        for (turnID, written) in released {
            dispatchHandoffsByTurnID.removeValue(forKey: turnID)
            Self.settleWithoutCompletion(written)
        }
    }

    #if DEBUG
        var test_writtenDispatchHandoffCount: Int {
            dispatchHandoffsByTurnID.count
        }

        /// Whether a cancelled/failed completion of `turnID` is held for a pending interrupt.
        func test_holdsCompletionDuringInterrupt(turnID: UUID) -> Bool {
            dispatchHandoffsByTurnID[turnID]?.completionDuringInterrupt != nil
                || dispatchHandoffsByTurnID[turnID]?.unstartedInterrupt?.providerCancelledResultHeld == true
        }

        /// Step 12: whether `turnID` carries the gated unstarted-interrupt mark.
        func test_hasUnstartedInterruptMark(turnID: UUID) -> Bool {
            dispatchHandoffsByTurnID[turnID]?.unstartedInterrupt != nil
        }

        /// Whether `turnID`'s written message is still tracked (no final evidence decided yet).
        func test_tracksWrittenDispatchHandoff(turnID: UUID) -> Bool {
            dispatchHandoffsByTurnID[turnID] != nil
        }

        /// Records `handoff` as written by `controller` under `turnID`, exactly as a successful
        /// `sendClaudeNativeMessage` write does, for routes whose harness cannot prepare a session.
        func test_recordWrittenDispatchHandoff(
            turnID: UUID,
            session: AgentTabSession,
            handoff: AgentProviderHandoff,
            controller: any NativeAgentRuntimeControlling
        ) {
            dispatchHandoffsByTurnID[turnID] = WrittenDispatchHandoff(
                tabID: session.tabID,
                runAttemptID: session.activeRunAttemptID,
                handoff: handoff,
                controller: controller as AnyObject
            )
        }
    #endif

    static let dispatchBaselineRefusedText =
        "Claude native send stopped before anything was sent: this message's pre-send history position couldn't be saved."

    /// Errors the Claude controller throws before writing the user message (see
    /// `ClaudeNativeProcessSessionController.sendUserMessage`). Any other error is ambiguous.
    private static func sendErrorProvesNoWrite(_ error: Error) -> Bool {
        guard let controllerError = error as? NativeAgentRuntimeControllerError else { return false }
        switch controllerError {
        case .processNotRunning, .initializationFailed, .repoPromptMCPRecoveryRequired:
            return true
        default:
            return false
        }
    }

    /// The central Claude native send seam. `handoff` carries the input's committed dispatch
    /// evidence: every return before the controller write reports no handoff; a write that the
    /// controller proves never happened reports no handoff; any other write outcome stays
    /// uncertain until the turn's own completion (`noteClaudeTurnCompleted`). A successful write
    /// is not acceptance.
    @discardableResult
    func sendClaudeNativeMessage(
        session: AgentTabSession,
        text: String,
        attachments _: [AgentImageAttachment],
        handoff: AgentProviderHandoff
    ) async -> Bool {
        defer {
            if !handoff.handoffStarted {
                handoff.noteNoHandoff()
            }
        }
        guard dispatchReservationByTabID[session.tabID] == nil else {
            return false
        }
        // The handoff was recorded against an exact run attempt; never send it under another.
        if let expectedRunAttemptID = handoff.runAttemptID,
           session.activeRunAttemptID != expectedRunAttemptID
        {
            return false
        }
        let dispatchRunID = session.runID ?? UUID()
        session.runID = dispatchRunID
        let dispatchReservation = DispatchReservation(
            id: UUID(),
            runID: dispatchRunID,
            runAttemptID: session.activeRunAttemptID
        )
        dispatchReservationByTabID[session.tabID] = dispatchReservation
        defer {
            if dispatchReservationByTabID[session.tabID]?.id == dispatchReservation.id {
                dispatchReservationByTabID.removeValue(forKey: session.tabID)
            }
        }

        session.waitingPrompt = nil
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus("Thinking…", source: .transport)
        session.runState = .running
        var handler = toolHandler(for: session)
        handler.resetTurnState(for: session)
        viewModel?.setAgentRunActive(session.tabID, isActive: true)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)

        // Durable run-start input (adopted plan §5): provider text whose pending-handoff prefix
        // (e.g. a resume-recovery handoff staged by the session preparation below) was attached to
        // the still-queued carrier before its dispatch commit. Set once, at that commit.
        var committedDurableText: String?
        func blockDurableSend(_ failure: AgentProviderHandoff.CommitFailure) -> Bool {
            handoff.blockBeforeHandoff(failure)
            session.appendItem(.error(failure.userText, sequenceIndex: session.nextSequenceIndex))
            return false
        }

        // One automatic RepoPrompt MCP recovery restart per dispatch, never a loop.
        var repoPromptMCPRecoveryAttempted = false
        for _ in 0 ..< 3 {
            let preparationReady = await ensureClaudeNativeSessionReadiness(session: session)
            guard preparationReady,
                  dispatchReservationIsCurrent(dispatchReservation, for: session)
            else {
                return false
            }
            guard let controller = session.claudeController else {
                if case let .blocked(_, candidacy, _, _) = session.claudePermissionSessionState,
                   let message = candidacy.blockingMessage
                {
                    session.appendItem(
                        .error(
                            "Claude native start blocked: \(message)",
                            sequenceIndex: session.nextSequenceIndex
                        )
                    )
                }
                finalizeSession(session, state: .failed)
                return false
            }

            if hasEffectiveClaudeControllerLaunchSettingsMismatch(for: session) {
                let interrupted = await interruptClaudeTurnIfNeeded(
                    session: session,
                    controller: controller,
                    handler: handler,
                    dispatchReservation: dispatchReservation
                )
                guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                    return false
                }
                guard interrupted else {
                    if !sessionOwnsClaudeController(controller, for: session) {
                        continue
                    }
                    return false
                }
                guard sessionOwnsClaudeController(controller, for: session) else {
                    continue
                }
                await recycleClaudeControllerForLaunchSettingsChange(
                    session: session,
                    existingController: controller,
                    runtimeVariantChanged: effectiveClaudeRuntimeVariantChanged(for: session)
                )
                guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                    return false
                }
                if let runID = session.runID {
                    await ensureClaudeToolTrackingIfNeeded(for: session, runID: runID)
                    guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                        return false
                    }
                    handler = toolHandler(for: session)
                }
                continue
            }

            let hasActiveSession = await controller.hasActiveSession
            guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                return false
            }
            guard sessionOwnsClaudeController(controller, for: session) else {
                continue
            }
            guard hasActiveSession else {
                finalizeSession(session, state: .failed)
                return false
            }

            // Preparation restarts an unhealthy idle launch; one still unhealthy here had a turn in
            // flight (or lost its connection again). This dispatch ends that turn, exactly as a
            // launch-settings recycle does, and restarts once, resuming the conversation.
            let repoPromptMCPHealth = await controller.currentRepoPromptMCPHealth
            guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                return false
            }
            guard sessionOwnsClaudeController(controller, for: session) else {
                continue
            }
            if repoPromptMCPHealth.isUnhealthy {
                guard !repoPromptMCPRecoveryAttempted else {
                    failRepoPromptMCPRecovery(
                        for: session,
                        message: "RepoPrompt MCP disconnected from Claude again right after a restart. Nothing was sent; send your message again to retry."
                    )
                    return false
                }
                let stoppingRunningTurn = await controller.hasTurnInFlight
                guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                    return false
                }
                guard sessionOwnsClaudeController(controller, for: session) else {
                    continue
                }
                let interrupted = await interruptClaudeTurnIfNeeded(
                    session: session,
                    controller: controller,
                    handler: handler,
                    dispatchReservation: dispatchReservation
                )
                guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                    return false
                }
                guard interrupted else {
                    if !sessionOwnsClaudeController(controller, for: session) {
                        continue
                    }
                    return false
                }
                guard sessionOwnsClaudeController(controller, for: session) else {
                    continue
                }
                // Consumed only once this dispatch owns the ended turn: a controller replaced
                // while interrupting is re-examined as a fresh launch, not as a failed restart.
                repoPromptMCPRecoveryAttempted = true
                guard await armRepoPromptMCPRecovery(
                    for: session,
                    controller: controller,
                    stoppedRunningTurn: stoppingRunningTurn
                ) else {
                    return false
                }
                guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                    return false
                }
                await recycleClaudeControllerForLaunchSettingsChange(
                    session: session,
                    existingController: controller,
                    runtimeVariantChanged: false
                )
                guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                    return false
                }
                if let runID = session.runID {
                    await ensureClaudeToolTrackingIfNeeded(for: session, runID: runID)
                    guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                        return false
                    }
                    handler = toolHandler(for: session)
                }
                continue
            }

            let interrupted = await interruptClaudeTurnIfNeeded(
                session: session,
                controller: controller,
                handler: handler,
                dispatchReservation: dispatchReservation
            )
            guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                return false
            }
            guard interrupted else {
                if !sessionOwnsClaudeController(controller, for: session) {
                    continue
                }
                return false
            }
            guard sessionOwnsClaudeController(controller, for: session) else {
                continue
            }

            if isAutoSensitive(session: session) {
                let effortReadiness = await applyAutoSensitiveEffortIfNeeded(
                    for: session,
                    expectedController: controller,
                    reason: "before_dispatch",
                    dispatchReservation: dispatchReservation
                )
                guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                    return false
                }
                switch effortReadiness {
                case .ready:
                    break
                case .retry:
                    continue
                case .deferred:
                    return false
                case .awaitingTurnIdle:
                    guard await awaitInterruptedTurnSettlement(
                        session: session,
                        controller: controller,
                        dispatchReservation: dispatchReservation
                    ) else {
                        return false
                    }
                    continue
                }
                guard sessionOwnsClaudeController(controller, for: session) else {
                    continue
                }
            }

            // Ensure the events stream has a live continuation before sending. If a
            // previous cancel/EOF/reset cycle left eventsContinuation == nil, emit()
            // would silently drop every inbound event. The runner subscribes to the
            // stream *after* this method returns (send → release lease → events(for:)),
            // so events that arrive in between must be buffered in a live stream.
            // ensureEventsStreamReady is idempotent — it only recreates if nil.
            await controller.ensureEventsStreamReady()
            guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                return false
            }
            guard sessionOwnsClaudeController(controller, for: session) else {
                continue
            }

            if isAutoSensitive(session: session) {
                let effortReadiness = await applyAutoSensitiveEffortIfNeeded(
                    for: session,
                    expectedController: controller,
                    reason: "final_before_dispatch",
                    dispatchReservation: dispatchReservation
                )
                guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                    return false
                }
                switch effortReadiness {
                case .ready:
                    break
                case .retry:
                    continue
                case .deferred:
                    return false
                case .awaitingTurnIdle:
                    guard await awaitInterruptedTurnSettlement(
                        session: session,
                        controller: controller,
                        dispatchReservation: dispatchReservation
                    ) else {
                        return false
                    }
                    continue
                }
                guard sessionOwnsClaudeController(controller, for: session) else {
                    continue
                }
            }

            // Deferred durable dispatch commit, after every preparation above that can create the
            // pending-handoff prefix: stage it, attach its exact snapshot to the queued carrier,
            // then commit. If that cannot be completed the send is blocked with its input saved —
            // never sent without its handoff.
            // Untracked input commits too (nothing is written for it) and keeps legacy staging at the
            // write below.
            if !handoff.isCommitted {
                // DOC-02: the recovery store refuses to commit a durable intent whose document
                // original is gone (with only a generic delivery-not-recorded reason), so the
                // sticky document authority decides first: refused with its own reason and settled
                // by the route, exactly like the boundary check below (which stays authoritative).
                guard handoff.documentRefusalAtProviderBoundary() == nil else { return false }
                var durableText = text
                if handoff.isDurable {
                    // Without a host nothing can stage a prefix (`.none`); the late-payload check
                    // below still guards the write.
                    switch await viewModel?.stagePendingHandoffForDurableDispatch(text, session: session) ?? .none {
                    case .none:
                        break
                    case let .staged(staged, snapshot):
                        durableText = staged.text
                        handoff.carryStagedInput(AgentCarriedStagedInput(pendingHandoffStage: staged.pendingHandoffStage))
                        handoff.notePendingHandoff(snapshot)
                    case .failed:
                        return blockDurableSend(.pendingHandoffNotSaved)
                    }
                }
                if case let .failure(failure) = await handoff.commitDispatch(session: session) {
                    return blockDurableSend(failure)
                }
                committedDurableText = durableText
                guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                    return false
                }
                guard sessionOwnsClaudeController(controller, for: session) else {
                    continue
                }
            }

            // This is the final launch-settings validation before dispatch. There is
            // intentionally no suspension between this check and sendUserMessage, so a
            // Safe Managed tightening cannot enqueue a turn on the stale controller.
            if hasEffectiveClaudeControllerLaunchSettingsMismatch(for: session) {
                await recycleClaudeControllerForLaunchSettingsChange(
                    session: session,
                    existingController: controller,
                    runtimeVariantChanged: effectiveClaudeRuntimeVariantChanged(for: session)
                )
                guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                    return false
                }
                if let runID = session.runID {
                    await ensureClaudeToolTrackingIfNeeded(for: session, runID: runID)
                    guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                        return false
                    }
                    handler = toolHandler(for: session)
                }
                continue
            }

            guard dispatchReservationIsCurrent(dispatchReservation, for: session),
                  sessionOwnsClaudeController(controller, for: session)
            else {
                return false
            }
            let baselineRefusal = ClaudeDispatchBaselineRefusal()
            do {
                let outboundText: String
                if handoff.isDurable {
                    // Durable input carries exactly the prefix its intent records. A handoff payload
                    // that preparation created after this input's commit (late bootstrap, e.g. a
                    // controller recycled after the commit) would send it without the history it
                    // needs: blocked, with its input saved.
                    guard !handoff.pendingHandoffCreatedAfterCommit(in: session) else {
                        return blockDurableSend(.pendingHandoffAfterCommit)
                    }
                    outboundText = committedDurableText ?? text
                } else if let viewModel {
                    // Untracked input: a recovery handoff staged during session preparation rides
                    // on this write; this handoff then settles exactly that stage.
                    let staged = viewModel.stagePendingHandoffIfNeeded(text, session: session)
                    outboundText = staged.text
                    handoff.carryStagedInput(AgentCarriedStagedInput(pendingHandoffStage: staged.pendingHandoffStage))
                } else {
                    outboundText = text
                }
                let instructions = agentModeInstructionInjection(for: session)
                let providerBoundText = providerBoundUserMessage(outboundText, instructions: instructions)
                // DOC-02 final document authority: after every startup, readiness, effort, and commit
                // await above, with no suspension before the boundary. A referenced original removed
                // meanwhile refuses the send (settled by the handoff and its route); nothing written.
                guard handoff.documentRefusalAtProviderBoundary() == nil else { return false }
                guard handoff.enterProviderBoundary(in: session) else { return false }
                // R6 owner capture: the dispatch reservation (verified current above) owns this
                // user turn; its scope is captured now and never re-read at write time.
                let runtimeOwner = session.runtimeSessionScope
                // R6: a managed transport re-verifies this dispatch still owns the turn after its
                // registry awaits, immediately before the bytes.
                // Phase 4: inside that same pre-byte admission, the dispatch's history baseline is
                // captured and committed first (gated OFF in production: no read, no write). A
                // baseline that cannot be persisted refuses the write: zero bytes, proven not written.
                let baselineIdentity = handoff.dispatchBaselineIdentity
                // Outbound identity: the transport reports whether its launch is eligible; the claim
                // (dispatch UUID + digest of exactly `providerBoundText`) is fixed before any await,
                // and the UUID reaches the wire only when this admission newly committed it.
                let writeAdmission: @Sendable (Bool) async -> AgentRuntimeWriteAdmission = { @MainActor [weak self, weak session] identityEligible in
                    guard let self, let session,
                          dispatchReservationIsCurrent(dispatchReservation, for: session),
                          sessionOwnsClaudeController(controller, for: session)
                    else { return .denied }
                    var admission = AgentRuntimeWriteAdmission.admittedWithoutIdentity
                    if let viewModel {
                        let claim = identityEligible ? baselineIdentity.map {
                            AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage(
                                uuid: $0.dispatchID,
                                providerBoundText: providerBoundText
                            )
                        } : nil
                        admission = await viewModel.admitClaudeDispatchBaseline(
                            baselineIdentity,
                            outboundUserMessage: claim,
                            session: session
                        )
                        if admission == .denied {
                            baselineRefusal.refused = true
                            return .denied
                        }
                    }
                    // Revalidated after the baseline's awaits.
                    guard dispatchReservationIsCurrent(dispatchReservation, for: session),
                          sessionOwnsClaudeController(controller, for: session)
                    else { return .denied }
                    // DOC-02: the transport's own pre-byte step re-checks the documents after its
                    // registry awaits; a refusal writes zero bytes.
                    guard handoff.documentRefusalAtProviderBoundary() == nil else { return .denied }
                    return admission
                }
                let turnID = try await AgentRuntimeOperationOwner.$session.withValue(runtimeOwner) {
                    try await AgentRuntimeOperationOwner.$writeAdmission.withValue(writeAdmission) {
                        try await controller.sendUserMessage(providerBoundText)
                    }
                }
                // Written: its documents were admitted; release the route's authority closures.
                handoff.installDocumentAuthority(nil)
                // Written: track until the turn's own completion proves acceptance.
                dispatchHandoffsByTurnID[turnID] = WrittenDispatchHandoff(
                    tabID: session.tabID,
                    runAttemptID: dispatchReservation.runAttemptID,
                    handoff: handoff,
                    controller: controller as AnyObject
                )
                guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                    handoff.noteDeliveryUnknown()
                    return false
                }
                guard sessionOwnsClaudeController(controller, for: session) else {
                    handoff.noteDeliveryUnknown()
                    await shutdownClaudeControllerIfUnowned(controller, by: session)
                    return false
                }
                session.claudeExpectedTurnIDs.insert(turnID)
                // Provider-turn accounting identity is registered by the controller's ordered
                // `.dispatched` usage event (successful write + launch-local ordinal), forwarded
                // through the session-owned seam; nothing is registered from here.
                return true
            } catch {
                if handoff.documentRefusalReason != nil {
                    // Refused for its documents at the transport's write admission: the handoff and
                    // its route already settled the input (nothing written). Exactly like the
                    // pre-boundary refusal, the route owns what happens to its run (a start's
                    // runner fails its run; a steering flush ends only a run it stranded), so an
                    // otherwise active run is never ended here and no send-failure row is added.
                    return false
                }
                if !handoff.handoffStarted {
                    handoff.noteNoHandoff(message: error.localizedDescription)
                } else if Self.sendErrorProvesNoWrite(error) {
                    handoff.noteProvenNotWritten(message: error.localizedDescription)
                } else {
                    handoff.noteDeliveryUnknown()
                }
                guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
                    return false
                }
                guard sessionOwnsClaudeController(controller, for: session) else {
                    await shutdownClaudeControllerIfUnowned(controller, by: session)
                    return false
                }
                let errorItem = AgentChatItem.error(
                    baselineRefusal.refused
                        ? Self.dispatchBaselineRefusedText
                        : "Claude native send failed: \(error.localizedDescription)",
                    sequenceIndex: session.nextSequenceIndex
                )
                session.appendItem(errorItem)
                finalizeSession(session, state: .failed, save: true)
                return false
            }
        }

        guard dispatchReservationIsCurrent(dispatchReservation, for: session) else {
            return false
        }
        let errorItem = AgentChatItem.error(
            "Claude native send failed because launch settings changed repeatedly before dispatch.",
            sequenceIndex: session.nextSequenceIndex
        )
        session.appendItem(errorItem)
        finalizeSession(session, state: .failed, save: true)
        return false
    }

    /// An acknowledged interrupt does not end the provider turn; the authoritative
    /// result does. When a genuine Auto effort change needs the controller idle, wait a
    /// bounded time for that settlement while this dispatch still owns the reservation
    /// and controller. Returning false is a real delivery failure (timeout, cancellation,
    /// supersession, or ownership loss), so callers restore drafts as before.
    private func awaitInterruptedTurnSettlement(
        session: AgentTabSession,
        controller: any NativeAgentRuntimeControlling,
        dispatchReservation: DispatchReservation
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(
            by: .milliseconds(Int64(interruptedTurnSettlementTimeoutSeconds * 1000))
        )
        while true {
            guard dispatchReservationIsCurrent(dispatchReservation, for: session),
                  sessionOwnsClaudeController(controller, for: session)
            else {
                return false
            }
            let stillInFlight = await controller.hasTurnInFlight
            guard dispatchReservationIsCurrent(dispatchReservation, for: session),
                  sessionOwnsClaudeController(controller, for: session)
            else {
                return false
            }
            guard stillInFlight else { return true }
            guard ContinuousClock.now < deadline else {
                Self.logger.error(
                    "Claude Auto steering timed out awaiting interrupted turn settlement tab=\(session.tabID.uuidString, privacy: .public) runID=\(dispatchReservation.runID.uuidString, privacy: .public)"
                )
                return false
            }
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return false
            }
        }
    }

    /// Step 12 (P1-B): after an acknowledged interrupt of a turn with no visible output, holds the
    /// steer's own write until the controller has processed that turn's result. The controller fixes
    /// a result's exclusivity when it processes it, so writing the steer first would make the
    /// interrupted turn's result shared and never acceptable. Ends when the turn's evidence is
    /// decided, the controller has no turn in flight (its result was processed), the reservation or
    /// controller ownership is lost, or after `unstartedInterruptResultWaitSeconds`. A timeout is not
    /// a failure: the steer is written and the interrupted turn stays uncertain. Steers that target a
    /// started turn, or whose interrupt was not acknowledged, never wait here.
    private func awaitUnstartedInterruptedTurnResult(
        turnID: UUID,
        session: AgentTabSession,
        controller: any NativeAgentRuntimeControlling,
        dispatchReservation: DispatchReservation
    ) async {
        let deadline = ContinuousClock.now.advanced(
            by: .milliseconds(Int64(min(unstartedInterruptResultWaitSeconds, 1.5) * 1000))
        )
        while ContinuousClock.now < deadline {
            guard dispatchHandoffsByTurnID[turnID]?.unstartedInterrupt?.acknowledged == true,
                  dispatchReservationIsCurrent(dispatchReservation, for: session),
                  sessionOwnsClaudeController(controller, for: session)
            else { return }
            guard await controller.hasTurnInFlight else { return }
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return
            }
        }
    }

    private func interruptClaudeTurnIfNeeded(
        session: AgentTabSession,
        controller: any NativeAgentRuntimeControlling,
        handler: ClaudeAgentToolTrackingHandler,
        dispatchReservation: DispatchReservation
    ) async -> Bool {
        let hadTurnInFlight = await controller.hasTurnInFlight
        guard dispatchReservationIsCurrent(dispatchReservation, for: session),
              sessionOwnsClaudeController(controller, for: session)
        else {
            return false
        }
        guard hadTurnInFlight else { return true }

        switch await awaitSteeringInterruptSafePoint(
            session: session,
            runID: dispatchReservation.runID,
            handler: handler
        ) {
        case .ready:
            break
        case let .timedOut(_, _, stillActive) where !stillActive:
            // Local MCP execution is already idle; a lagging provider ACK should not
            // bounce the queued steer if Claude accepts the native interrupt/resend.
            break
        case .cancelled, .timedOut:
            return false
        }
        guard dispatchReservationIsCurrent(dispatchReservation, for: session),
              sessionOwnsClaudeController(controller, for: session)
        else {
            return false
        }

        let mark = noteRepoPromptInterruptRequested(controller: controller)
        let interruptOutcome = await controller.interruptTurn(reason: "interrupt")
        resolveRepoPromptInterrupt(mark, outcome: interruptOutcome)
        if interruptOutcome == .acknowledged, case let .unstarted(turnID)? = mark {
            await awaitUnstartedInterruptedTurnResult(
                turnID: turnID,
                session: session,
                controller: controller,
                dispatchReservation: dispatchReservation
            )
        }
        guard dispatchReservationIsCurrent(dispatchReservation, for: session),
              sessionOwnsClaudeController(controller, for: session)
        else {
            return false
        }
        switch interruptOutcome {
        case .acknowledged, .noTurnInFlight:
            return true
        case .timedOut, .failed:
            // Race tolerance: the active turn may have naturally completed after our
            // initial hasTurnInFlight check but before the interrupt was acknowledged.
            // Re-check and only proceed if the turn has already ended.
            let stillInFlight = await controller.hasTurnInFlight
            guard dispatchReservationIsCurrent(dispatchReservation, for: session),
                  sessionOwnsClaudeController(controller, for: session)
            else {
                return false
            }
            return !stillInFlight
        }
    }

    package func submitApprovalDecision(
        session: AgentTabSession,
        decision: AgentApprovalDecision
    ) {
        guard let request = session.pendingApproval,
              let controller = session.claudeController,
              case let .claudeControl(requestID) = request.requestID
        else {
            return
        }
        session.pendingApproval = nil
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus("Thinking…", source: .transport)
        session.runState = .running
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        Task { [controller] in
            await controller.respondToPermissionRequest(id: requestID, decision: decision)
        }
    }

    /// Detaches the current Claude controller and its tool tracker synchronously
    /// so a replacement run cannot be affected by the old controller's async cleanup.
    func prepareClaudeCancelSync(_ session: AgentTabSession) -> DetachedClaudeController? {
        guard session.selectedAgent.usesClaudeNativeRuntime else { return nil }
        preparationByTabID.removeValue(forKey: session.tabID)?.task.cancel()
        dispatchReservationByTabID.removeValue(forKey: session.tabID)
        invalidateControllerRetirement(for: session)
        let detached = session.claudeController.flatMap {
            detachClaudeController($0, from: session, removeToolTracking: true)
        }
        if detached == nil {
            clearClaudeControllerLaunchMetadata(for: session)
        }
        session.runID = nil
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        return detached
    }

    private func prepareClaudeProviderIdentityResetSync(
        _ session: AgentTabSession
    ) -> DetachedClaudeController? {
        let detached = prepareClaudeCancelSync(session)
        invalidatePendingClaudeResumeTransfer(for: session)
        clearRepoPromptMCPRecovery(for: session)
        session.providerSessionID = nil
        return detached
    }

    package func handleProviderIdentityTransitionSync(
        session: AgentTabSession,
        from previousAgent: AgentProviderKind,
        to nextAgent: AgentProviderKind
    ) {
        guard previousAgent.usesClaudeNativeRuntime,
              !nextAgent.usesClaudeNativeRuntime || previousAgent != nextAgent
        else {
            return
        }
        let detached = prepareClaudeProviderIdentityResetSync(session)
        if let detached, detached.controller.joinsRetirementBeforeSuccessor {
            // R6: retained so a registered successor of any provider on this tab joins it.
            session.retainRuntimeRetirement { [self] in
                await cancelClaudeRun(session, oldController: detached)
            }
        } else {
            Task { await cancelClaudeRun(session, oldController: detached) }
        }
    }

    package func handleProviderIdentityTransition(
        session: AgentTabSession,
        from previousAgent: AgentProviderKind,
        to nextAgent: AgentProviderKind
    ) async {
        guard previousAgent.usesClaudeNativeRuntime,
              !nextAgent.usesClaudeNativeRuntime || previousAgent != nextAgent
        else {
            return
        }
        let detached = prepareClaudeProviderIdentityResetSync(session)
        await cancelClaudeRun(session, oldController: detached)
    }

    package func prepareForConversationResetSync(_ session: AgentTabSession) {
        let detached = prepareClaudeCancelSync(session)
        invalidatePendingClaudeResumeTransfer(for: session)
        clearRepoPromptMCPRecovery(for: session)
        Task { await cancelClaudeRun(session, oldController: detached) }
    }

    func beginClaudeResumeTransferIfNeeded(
        for session: AgentTabSession,
        oldController: DetachedClaudeController?
    ) {
        guard let oldController else { return }
        guard pendingResumeTransferTasksByTabID[session.tabID] == nil else {
            let task = Task { @MainActor [self, session] in
                await cancelClaudeRunAndCaptureSessionRef(session, oldController: oldController)
            }
            retiredResumeTransferTasksByTabID[session.tabID, default: []].append(task)
            return
        }
        let generation = UUID()
        pendingResumeTransferGenerationByTabID[session.tabID] = generation
        pendingResumeTransferTasksByTabID[session.tabID] = Task { @MainActor [self, session] in
            await cancelClaudeRunAndCaptureSessionRef(session, oldController: oldController)
        }
    }

    func awaitPendingClaudeResumeTransferIfNeeded(
        for session: AgentTabSession,
        scheduleProviderSessionSave: Bool = true
    ) async {
        let retiredTasks = retiredResumeTransferTasksByTabID.removeValue(forKey: session.tabID) ?? []
        for task in retiredTasks {
            _ = await task.value
        }

        guard let task = pendingResumeTransferTasksByTabID[session.tabID],
              let generation = pendingResumeTransferGenerationByTabID[session.tabID]
        else {
            return
        }
        let sessionRef = await task.value
        guard pendingResumeTransferGenerationByTabID[session.tabID] == generation else { return }
        pendingResumeTransferTasksByTabID.removeValue(forKey: session.tabID)
        pendingResumeTransferGenerationByTabID.removeValue(forKey: session.tabID)
        updateProviderSessionIDIfNeeded(
            sessionRef.sessionID,
            for: session,
            scheduleSave: scheduleProviderSessionSave
        )
    }

    func hasPendingResumeTransfer(
        for session: AgentTabSession
    ) -> Bool {
        pendingResumeTransferTasksByTabID[session.tabID] != nil
            || retiredResumeTransferTasksByTabID[session.tabID]?.isEmpty == false
    }

    func invalidatePendingClaudeResumeTransfer(
        for session: AgentTabSession
    ) {
        if let task = pendingResumeTransferTasksByTabID[session.tabID] {
            retiredResumeTransferTasksByTabID[session.tabID, default: []].append(task)
        }
        pendingResumeTransferTasksByTabID.removeValue(forKey: session.tabID)
        pendingResumeTransferGenerationByTabID.removeValue(forKey: session.tabID)
    }

    /// Async cleanup for a synchronously detached controller after cancel.
    func cancelClaudeRun(
        _ session: AgentTabSession,
        oldController: DetachedClaudeController?
    ) async {
        guard let oldController else { return }
        _ = await cancelClaudeRunAndCaptureSessionRef(session, oldController: oldController)
    }

    private func cancelClaudeRunAndCaptureSessionRef(
        _ session: AgentTabSession,
        oldController: DetachedClaudeController
    ) async -> NativeAgentRuntimeSessionRef {
        let controller = oldController.controller
        let mark = noteRepoPromptInterruptRequested(controller: controller)
        let interruptOutcome = await controller.interruptTurn(reason: "interrupt")
        resolveRepoPromptInterrupt(mark, outcome: interruptOutcome)
        await stopToolTracking(oldController, for: session)
        if interruptOutcome == .acknowledged {
            // Give Claude ~200 ms to persist any in-flight state before we
            // tear down the process. The UI doesn't block on this — the
            // controller was already detached by prepareClaudeCancelSync.
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let sessionRef = await controller.currentSessionRef()
        await controller.shutdown()
        return sessionRef
    }

    package func shutdownClaudeSessionIfNeeded(_ session: AgentTabSession) async {
        guard session.claudeController != nil
            || hasPendingResumeTransfer(for: session)
            || session.selectedAgent.usesClaudeNativeRuntime
        else {
            return
        }
        await shutdownClaudeSession(session)
    }

    package func shutdownClaudeSession(
        _ session: AgentTabSession,
        clearTabScopedCoordinatorState: Bool = true,
        detachedRunID: UUID? = nil
    ) async {
        await awaitPendingClaudeResumeTransferIfNeeded(
            for: session,
            scheduleProviderSessionSave: clearTabScopedCoordinatorState
        )
        if let controller = session.claudeController {
            guard let detached = detachClaudeController(
                controller,
                from: session,
                removeToolTracking: clearTabScopedCoordinatorState
            ) else {
                return
            }
            guard await retireClaudeController(
                detached,
                for: session,
                captureProviderSessionID: true,
                scheduleProviderSessionSave: clearTabScopedCoordinatorState
            ) else {
                return
            }
        } else {
            invalidateControllerRetirement(for: session)
            clearClaudeControllerLaunchMetadata(for: session)
        }
        session.runID = nil
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus(nil, source: nil)
        if clearTabScopedCoordinatorState {
            await clearClaudeToolTracking(for: session)
        } else {
            await clearClaudeToolTracking(for: session, matchingRunID: detachedRunID)
        }
    }

    private func clearClaudeToolTracking(
        for session: AgentTabSession
    ) async {
        guard let handler = toolHandlerByTabID.removeValue(forKey: session.tabID) else { return }
        await handler.stopTracking(for: session)
    }

    private func clearClaudeToolTracking(
        for session: AgentTabSession,
        matchingRunID runID: UUID?
    ) async {
        guard let runID else { return }
        guard let handler = toolHandlerByTabID[session.tabID] else { return }
        guard handler.currentTrackedRunID == runID else { return }
        toolHandlerByTabID.removeValue(forKey: session.tabID)
        await handler.stopTracking(for: session)
    }

    // MARK: - Tool Tracking Delegation

    /// Forwarding wrapper for callers that still reference the coordinator for provider tool calls.
    func handleClaudeProviderRepoPromptToolCall(
        invocationID: UUID?,
        toolName: String,
        argsJSON: String?,
        session: AgentTabSession
    ) {
        toolHandler(for: session).handleClaudeProviderRepoPromptToolCall(
            invocationID: invocationID,
            toolName: toolName,
            argsJSON: argsJSON,
            session: session
        )
    }

    /// Forwarding wrapper for callers that still reference the coordinator for suppression checks.
    func shouldSuppressClaudeProviderToolResult(
        toolName: String,
        argsJSON: String?,
        outputJSON: String,
        invocationID: UUID?,
        session: AgentTabSession
    ) -> Bool {
        toolHandler(for: session).shouldSuppressClaudeProviderToolResult(
            toolName: toolName,
            argsJSON: argsJSON,
            outputJSON: outputJSON,
            invocationID: invocationID,
            session: session
        )
    }

    // MARK: - Tool Tracking Public API

    /// Reset turn-scoped correlation state for the given session.
    func resetToolCorrelation(for session: AgentTabSession) {
        toolHandler(for: session).resetTurnState(for: session)
    }

    /// Forward a tracker tool call to the per-tab handler (used by tests and internal paths).
    func handleClaudeTrackerToolCall(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        session: AgentTabSession
    ) {
        toolHandler(for: session).handleTrackerToolCall(
            invocationID: invocationID,
            toolName: toolName,
            args: args,
            session: session
        )
    }

    /// Forward a tracker tool result to the per-tab handler (used by tests and internal paths).
    func handleClaudeTrackerToolResult(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        resultJSON: String,
        isError: Bool,
        session: AgentTabSession
    ) {
        toolHandler(for: session).handleTrackerToolResult(
            invocationID: invocationID,
            toolName: toolName,
            args: args,
            resultJSON: resultJSON,
            isError: isError,
            session: session
        )
    }

    // MARK: - Provider Stream Tool Event Handling

    /// Handle tool events from the Claude provider stream.
    /// Returns `true` when the event was consumed or suppressed.
    @discardableResult
    func handleToolStreamEvent(
        _ event: AgentToolStreamEvent,
        session: AgentTabSession
    ) -> Bool {
        toolHandler(for: session).handleProviderToolEvent(event, session: session)
    }

    private func publishClaudePermissionState(
        _ state: ClaudePermissionSessionState,
        for session: AgentTabSession
    ) {
        guard session.claudePermissionSessionState != state else { return }
        session.claudePermissionSessionState = state
        viewModel?.updatePermissionBindingState(from: session)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    private func permissionOwnership(
        controller: any NativeAgentRuntimeControlling,
        runID: UUID,
        runAttemptID: UUID?
    ) -> ClaudePermissionControllerOwnership {
        ClaudePermissionControllerOwnership(
            controllerIdentifier: ObjectIdentifier(controller as AnyObject),
            runID: runID,
            runAttemptID: runAttemptID
        )
    }

    private func autoPermissionValidationKey(
        for resolution: ClaudeAgentToolPreferences.PermissionModeResolution,
        session: AgentTabSession,
        selectedModelRaw: String?,
        runtimeVariant: ClaudeCodeRuntimeVariant
    ) -> AutoPermissionValidationKey? {
        guard resolution.reason == .eligibleAuto,
              let baseModel = ClaudeModelSpecifier(raw: selectedModelRaw).baseModel
        else {
            return nil
        }
        return AutoPermissionValidationKey(
            agentKind: session.selectedAgent,
            runtimeVariant: runtimeVariant,
            baseModel: baseModel
        )
    }

    private func isAutoSensitive(
        session: AgentTabSession
    ) -> Bool {
        let installedIsAuto = controllerLaunchSettingsByTabID[session.tabID]?.permissionMode?
            .caseInsensitiveCompare(ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode) == .orderedSame
        let desiredMode = effectiveClaudePermissionResolution(
            for: session,
            selectedModelRaw: session.selectedModelRaw
        ).requestedMode
        let desiredIsAuto = desiredMode.caseInsensitiveCompare(
            ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode
        ) == .orderedSame
        return installedIsAuto || desiredIsAuto
    }

    private func currentPermissionAcknowledgement(
        for session: AgentTabSession
    ) -> ClaudePermissionAcknowledgement? {
        switch session.claudePermissionSessionState {
        case let .acknowledged(acknowledgement):
            acknowledgement
        case let .pendingNextTurn(active, _, _):
            active
        case .notStarted, .blocked, .initializing, .failed:
            nil
        }
    }

    private func markAutoIntentPending(
        for session: AgentTabSession,
        reason: String
    ) {
        let resolution = effectiveClaudePermissionResolution(
            for: session,
            selectedModelRaw: session.selectedModelRaw
        )
        publishClaudePermissionState(
            .pendingNextTurn(
                active: currentPermissionAcknowledgement(for: session),
                requestedMode: resolution.requestedMode,
                reason: reason
            ),
            for: session
        )
    }

    private func dispatchReservationIsCurrent(
        _ reservation: DispatchReservation,
        for session: AgentTabSession
    ) -> Bool {
        guard let current = dispatchReservationByTabID[session.tabID] else { return false }
        return current.id == reservation.id
            && current.runID == reservation.runID
            && current.runAttemptID == reservation.runAttemptID
            && session.runID == reservation.runID
            && session.activeRunAttemptID == reservation.runAttemptID
    }

    private func autoEffortWorkIsCurrent(
        reservation: DispatchReservation?,
        controller: any NativeAgentRuntimeControlling,
        session: AgentTabSession
    ) -> Bool {
        guard sessionOwnsClaudeController(controller, for: session) else { return false }
        guard let reservation else { return true }
        return dispatchReservationIsCurrent(reservation, for: session)
    }

    private func applyAutoSensitiveEffortIfNeeded(
        for session: AgentTabSession,
        expectedController: any NativeAgentRuntimeControlling,
        reason: String,
        dispatchReservation: DispatchReservation? = nil
    ) async -> AutoEffortReadiness {
        guard autoEffortWorkIsCurrent(
            reservation: dispatchReservation,
            controller: expectedController,
            session: session
        ) else {
            return .deferred
        }

        let hasTurnInFlight = await expectedController.hasTurnInFlight
        guard autoEffortWorkIsCurrent(
            reservation: dispatchReservation,
            controller: expectedController,
            session: session
        ) else {
            return .deferred
        }

        // Same controller, same launch settings, and the desired effort already
        // acknowledged: nothing needs to change, so an in-flight (for example, just
        // interrupted and still settling) turn does not have to reach idle first.
        let controllerIdentifier = ObjectIdentifier(expectedController as AnyObject)
        let effortLevel = currentClaudeEffortLevel(for: session)
        if !hasEffectiveClaudeControllerLaunchSettingsMismatch(for: session),
           let acknowledged = controllerEffortEvidenceByTabID[session.tabID],
           acknowledged.controllerIdentifier == controllerIdentifier,
           acknowledged.acknowledgedEffort == effortLevel
        {
            if let active = currentPermissionAcknowledgement(for: session) {
                publishClaudePermissionState(.acknowledged(active), for: session)
            }
            return .ready
        }

        guard !hasTurnInFlight else {
            markAutoIntentPending(
                for: session,
                reason: "Effort change pending — applies before the next turn."
            )
            return .awaitingTurnIdle
        }

        guard !hasEffectiveClaudeControllerLaunchSettingsMismatch(for: session) else {
            markAutoIntentPending(
                for: session,
                reason: "Claude Auto model, backend, or permission change pending — applies before the next turn."
            )
            return .retry
        }

        let model = effectiveClaudeModel(for: session)
        do {
            try await expectedController.applyModelAndEffort(
                model: model,
                effortLevel: effortLevel
            )
            guard autoEffortWorkIsCurrent(
                reservation: dispatchReservation,
                controller: expectedController,
                session: session
            ) else {
                return .deferred
            }

            let currentEvidence = controllerEffortEvidenceByTabID[session.tabID]
            let initializationGeneration =
                currentEvidence?.controllerIdentifier == controllerIdentifier
                    ? currentEvidence?.initializationGeneration ?? 0
                    : 0
            controllerEffortEvidenceByTabID[session.tabID] = ControllerEffortEvidence(
                controllerIdentifier: controllerIdentifier,
                initializationGeneration: initializationGeneration,
                acknowledgedEffort: effortLevel
            )
            guard let launchSettings = controllerLaunchSettingsByTabID[session.tabID],
                  let runID = session.runID
            else {
                return .deferred
            }
            let resolution = effectiveClaudePermissionResolution(
                for: session,
                selectedModelRaw: session.selectedModelRaw
            )
            let acknowledgement = ClaudePermissionAcknowledgement(
                ownership: permissionOwnership(
                    controller: expectedController,
                    runID: runID,
                    runAttemptID: session.activeRunAttemptID
                ),
                launchSettings: launchSettings,
                requestedMode: resolution.requestedMode,
                acknowledgedEffort: effortLevel
            )
            if currentClaudeEffortLevel(for: session) == effortLevel,
               !hasEffectiveClaudeControllerLaunchSettingsMismatch(for: session)
            {
                publishClaudePermissionState(.acknowledged(acknowledgement), for: session)
                return .ready
            }

            publishClaudePermissionState(
                .pendingNextTurn(
                    active: acknowledgement,
                    requestedMode: resolution.requestedMode,
                    reason: "Claude Auto settings changed while applying effort and remain pending."
                ),
                for: session
            )
            Self.flagSettingsLogger.debug(
                "Applied idle Claude Auto effort for tab=\(session.tabID.uuidString, privacy: .public) reason=\(reason, privacy: .public) effort=\(effortLevel.rawValue, privacy: .public)"
            )
            return .retry
        } catch {
            guard autoEffortWorkIsCurrent(
                reservation: dispatchReservation,
                controller: expectedController,
                session: session
            ) else {
                return .deferred
            }
            markAutoIntentPending(
                for: session,
                reason: "Effort change pending — \(error.localizedDescription)"
            )
            Self.flagSettingsLogger.error(
                "Failed applying idle Claude Auto effort for tab=\(session.tabID.uuidString, privacy: .public) reason=\(reason, privacy: .public) effort=\(effortLevel.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return .deferred
        }
    }

    /// Native-shell signal for this run's MCP lease (code-mode readiness D2). `true` only when
    /// RepoPrompt itself launches Claude with Bash enabled: the pending launch policy (the value
    /// `performEnsureClaudeNativeSession` compares and recycles against) and, when a controller is
    /// already live, that process's captured launch settings, because a recycle can be deferred
    /// while a turn is in flight. Anything else reports `false`, which keeps `git` visible.
    ///
    /// Standard Agent Mode never puts Bash in `--disallowedTools` (`agentDisallowedTools`), so a
    /// `false` here can leave `git` visible beside an available Bash; it never hides `git`
    /// from a run without a RepoPrompt-configured shell.
    package func runHasNativeShell(for session: AgentTabSession) -> Bool {
        let liveLaunchSettings: ControllerLaunchSettings?? = session.claudeController == nil
            ? .none
            : .some(controllerLaunchSettingsByTabID[session.tabID])
        return Self.runHasNativeShell(
            pendingAllowNativeBashTool: effectiveClaudeRuntimePermission(for: session).allowNativeBashTool,
            sessionProfile: session.profile,
            liveControllerLaunchSettings: liveLaunchSettings
        )
    }

    /// Pure decision behind `runHasNativeShell(for:)`. `liveControllerLaunchSettings` is `nil`
    /// when no controller is live, `.some(nil)` when a live controller has no recorded launch
    /// settings (unknown, so `false`), and `.some(settings)` otherwise.
    static func runHasNativeShell(
        pendingAllowNativeBashTool: Bool?,
        sessionProfile: AgentSessionProfile,
        liveControllerLaunchSettings: ControllerLaunchSettings??
    ) -> Bool {
        guard launchKeepsNativeBash(allowNativeBashTool: pendingAllowNativeBashTool, sessionProfile: sessionProfile) else {
            return false
        }
        switch liveControllerLaunchSettings {
        case .none:
            return true
        case .some(.none):
            return false
        case let .some(.some(settings)):
            return launchKeepsNativeBash(
                allowNativeBashTool: settings.allowNativeBashTool,
                sessionProfile: settings.sessionProfile
            )
        }
    }

    /// Per-run `code_mode` eligibility for this Claude launch, captured once beside
    /// `runHasNativeShell(for:)` and immutable for the run. Only an official Claude Code
    /// (`.claudeCode`, standard runtime variant) Standard-profile launch whose model resolves
    /// through the existing Claude model authority (a static alias/default/enum case, or a
    /// launch-valid dynamic family point release), with the RepoPrompt tools setting at
    /// `direct + code_mode`, is `.directTools`; everything else — compatible backends, Knowledge,
    /// MCP-safe external defaults, unresolved/custom models, unknown live launch settings — is
    /// `.native`.
    package func codeModeEligibility(for session: AgentTabSession) -> MCPCodeModeEligibility {
        let liveLaunchSettings: ControllerLaunchSettings?? = session.claudeController == nil
            ? .none
            : .some(controllerLaunchSettingsByTabID[session.tabID])
        let defaults = viewModel?.providerBindingService.preferences.defaults ?? .standard
        return Self.codeModeEligibility(
            toolsMode: ClaudeAgentToolPreferences.repoPromptToolsMode(defaults: defaults),
            agentKind: session.selectedAgent,
            sessionProfile: session.profile,
            permissionProfile: session.permissionProfile,
            selectedModelRaw: session.selectedModelRaw,
            liveControllerLaunchSettings: liveLaunchSettings
        )
    }

    /// The RepoPrompt tools mode recorded in a launch's settings, so a change recycles a live
    /// controller before the next run (Claude reads `tools/list` once, at connect). Only
    /// `.directCodeMode` is recorded; `nil` means native, or a launch that can never be
    /// `code_mode` eligible, so the toggle never recycles those.
    private func launchRepoPromptToolsMode(for session: AgentTabSession) -> RepoPromptToolsMode? {
        guard session.selectedAgent == .claudeCode, session.profile == .standard else { return nil }
        let defaults = viewModel?.providerBindingService.preferences.defaults ?? .standard
        let mode = ClaudeAgentToolPreferences.repoPromptToolsMode(defaults: defaults)
        return mode == .directCodeMode ? mode : nil
    }

    /// Pure decision behind `codeModeEligibility(for:)`. `liveControllerLaunchSettings` follows
    /// the `runHasNativeShell` convention: `nil` when no controller is live, `.some(nil)` when a
    /// live controller has no recorded launch settings (unknown, so `.native`).
    static func codeModeEligibility(
        toolsMode: RepoPromptToolsMode,
        agentKind: AgentProviderKind,
        sessionProfile: AgentSessionProfile,
        permissionProfile: AgentProviderPermissionProfile,
        selectedModelRaw: String,
        liveControllerLaunchSettings: ControllerLaunchSettings??
    ) -> MCPCodeModeEligibility {
        guard toolsMode == .directCodeMode,
              agentKind == .claudeCode,
              sessionProfile == .standard,
              permissionProfile != .mcpSafeDefaults,
              AgentModel.resolvedModel(forRaw: selectedModelRaw, agentKind: .claudeCode) != nil
              || ClaudeCompatibleModelCatalogAdapter.isSupportedClaudeCodePointRelease(rawModel: selectedModelRaw)
        else {
            return .native
        }
        switch liveControllerLaunchSettings {
        case .none:
            return .directTools
        case .some(.none):
            return .native
        case let .some(.some(settings)):
            guard settings.runtimeVariant == .standard, settings.sessionProfile == .standard else {
                return .native
            }
            return .directTools
        }
    }

    /// Whether a launch with these settings has Bash enabled by RepoPrompt's preference and absent
    /// from the `--disallowedTools` list `makeDefaultController` passes.
    private static func launchKeepsNativeBash(
        allowNativeBashTool: Bool?,
        sessionProfile: AgentSessionProfile
    ) -> Bool {
        guard allowNativeBashTool == true, sessionProfile == .standard else { return false }
        return !ClaudeCodeIntegrationConfiguration.disallowedTools(
            for: .agentRun,
            allowNativeBashTool: true,
            sessionProfile: sessionProfile
        ).contains("Bash")
    }

    private func effectiveClaudeRuntimePermission(
        for session: AgentTabSession
    ) -> ClaudeControllerLaunchPolicy {
        guard let providerBindingService = viewModel?.providerBindingService else {
            return ClaudeControllerLaunchPolicy(
                permissionMode: session.permissionProfile.claudePermissionMode,
                allowNativeBashTool: session.permissionProfile == .mcpSafeDefaults ? false : nil,
                mcpStrictMode: session.permissionProfile == .mcpSafeDefaults ? true : nil
            )
        }
        let permissionMode = providerBindingService.runtimePermission(
            for: session.selectedAgent,
            profile: session.permissionProfile
        ).claudePermissionMode
        let preferences = providerBindingService.preferences
        return ClaudeControllerLaunchPolicy.resolve(
            permissionMode: permissionMode,
            profile: session.permissionProfile,
            defaults: preferences.defaults,
            securePermissions: preferences.securePermissions
        )
    }

    private func effectiveClaudePermissionResolution(
        for session: AgentTabSession,
        selectedModelRaw: String,
        runtimePermission: ClaudeControllerLaunchPolicy? = nil
    ) -> ClaudeAgentToolPreferences.PermissionModeResolution {
        ClaudeAgentToolPreferences.resolvePermissionMode(
            requestedMode: (runtimePermission ?? effectiveClaudeRuntimePermission(for: session)).permissionMode
                ?? session.permissionProfile.claudePermissionMode,
            agentKind: session.selectedAgent,
            selectedModelRaw: selectedModelRaw
        )
    }

    private func effectiveClaudeModel(for session: AgentTabSession) -> String? {
        effectiveClaudeModel(selectedModelRaw: session.selectedModelRaw)
    }

    private func effectiveClaudeModel(selectedModelRaw: String) -> String? {
        let selectedRaw = selectedModelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedRaw.isEmpty, selectedRaw != AgentModel.defaultModel.rawValue else {
            return nil
        }
        return selectedRaw
    }

    private func currentClaudeEffortLevel(for session: AgentTabSession) -> ClaudeCodeEffortLevel {
        viewModel?.providerBindingService.claudeEffortLevel(
            forModelRaw: session.selectedModelRaw,
            agentKind: session.selectedAgent
        ) ?? ClaudeAgentToolPreferences.effortLevel(
            forModelRaw: session.selectedModelRaw,
            agentKind: session.selectedAgent
        )
    }

    private func agentModeInstructionInjection(for session: AgentTabSession) -> String {
        SystemPromptService.agentModePrompt(
            agentKind: session.selectedAgent,
            taskLabelKind: session.mcpControlContext?.taskLabelKind,
            codeMapsDisabled: globalCodeMapsDisabled(),
            sessionProfile: session.profile,
            delegationAudience: (viewModel?.mcpDelegationRunToolPolicy(for: session) ?? .leaf).promptAudience
        )
    }

    private func agentModeSystemPromptOverride(for session: AgentTabSession) -> String? {
        ClaudeAgentToolPreferences.agentModePromptDelivery().nativeSystemPromptOverride(
            instructions: agentModeInstructionInjection(for: session)
        )
    }

    private func providerBoundUserMessage(_ outboundText: String, instructions: String) -> String {
        ClaudeCompatiblePluginBridge.providerBoundUserMessage(
            outboundText,
            instructions: instructions,
            delivery: ClaudeAgentToolPreferences.agentModePromptDelivery()
        )
    }
}
