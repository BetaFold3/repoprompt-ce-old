import Foundation
import MCP

@MainActor
package final class ACPIntegratedAgentModeRunner {
    private static let ohMyPiAuthorizationFailureText =
        "Oh My Pi provider start authorization was denied."

    private struct ConsumeEventsOutcome {
        let terminalState: AgentSessionRunState
        let errorText: String?
    }

    private enum MCPBootstrapLeaseDisposition {
        case none
        case clearPolicyAfterSuccessfulRouting
        case failAndRelease
        case failAndCleanup
        case cancelAndCleanup
        case cleanupDeferredRouting

        init(terminalState: AgentSessionRunState, agentKind: AgentProviderKind) {
            switch terminalState {
            case .failed:
                self = agentKind.requiresPrePromptAgentModeMCPRouting ? .failAndRelease : .failAndCleanup
            case .cancelled:
                self = .cancelAndCleanup
            case .completed:
                self = agentKind.requiresPrePromptAgentModeMCPRouting
                    ? .clearPolicyAfterSuccessfulRouting
                    : .cleanupDeferredRouting
            default:
                self = .none
            }
        }

        func apply(to lease: MCPBootstrapLease?) async {
            switch self {
            case .none:
                break
            case .clearPolicyAfterSuccessfulRouting:
                await lease?.clearPolicyAfterSuccessfulRouting()
            case .failAndRelease:
                await lease?.failAndRelease()
            case .failAndCleanup:
                await lease?.failAndCleanup()
            case .cancelAndCleanup:
                await lease?.cancelAndCleanup()
            case .cleanupDeferredRouting:
                await lease?.cleanupDeferredRouting()
            }
        }
    }

    private final class WeakTabSession {
        weak var value: AgentTabSession?

        init(_ value: AgentTabSession) {
            self.value = value
        }
    }

    private final class StartupTeardownClaim: @unchecked Sendable {
        private let lock = NSLock()
        private var teardownTask: Task<Void, Never>?
        private var promptStarted = false

        func markPromptStartedIfUnclaimed() -> Bool {
            lock.withLock {
                guard teardownTask == nil else { return false }
                promptStarted = true
                return true
            }
        }

        @discardableResult
        func claim(
            onlyBeforePrompt: Bool = false,
            operation: @escaping @Sendable () async -> Void
        ) -> Task<Void, Never>? {
            lock.withLock {
                if let teardownTask { return teardownTask }
                if onlyBeforePrompt, promptStarted { return nil }
                let task = Task { await operation() }
                teardownTask = task
                return task
            }
        }

        var task: Task<Void, Never>? {
            lock.withLock { teardownTask }
        }
    }

    private let hooks: AgentModeRunService.Hooks
    private let terminalCommitBarrier: AgentRunTerminalCommitBarrier
    private let toolTrackingHooks: AgentToolTrackingHooks
    private let mcpHost: any AgentMCPHosting
    private let providerFactory: AgentACPProviderFactory
    private let controllerFactory: AgentACPControllerFactory
    private var toolTrackingByTabID: [UUID: AgentToolTrackingController] = [:]
    private var toolTrackingRunIDByTabID: [UUID: UUID] = [:]
    private var acpProviderInvocationByTrackerInvocationIDByTabID: [UUID: [UUID: UUID]] = [:]
    private var acpProviderPlaceholderInvocationIDsByTabID: [UUID: Set<UUID>] = [:]

    private struct PendingOMPProviderFailure {
        let toolCallID: UUID?
        let title: String
        let rawInput: String?
    }

    private static let maxPendingOMPProviderFailures = 64
    private static let ompUncorrelatedFailureJSON =
        #"{"note":"Reported failed by Oh My Pi; not correlated with any RepoPrompt MCP-tracked call."}"#
    private var trackerErrorCreditsByTabID: [UUID: Int] = [:]
    private var pendingOMPProviderFailuresByTabID: [UUID: [PendingOMPProviderFailure]] = [:]
    /// Run-scoped terminal IDs, including failures consumed by a tracker credit.
    private var seenOMPProviderFailureIDsByTabID: [UUID: Set<UUID>] = [:]
    #if DEBUG
        package struct OMPQualificationStartupProbes {
            var beforeAgentTaskEntry: () async -> Void = {}
            var duringExpectedMCPRunIDSet: (() async -> Void)?
            var beforeAuthorizationLivenessCheck: () async -> Void = {}
            var afterProviderBootstrap: () async -> Void = {}
            var afterProviderInitializationCompleted: () async -> Void = {}
            var beforePromptStartClaim: () async -> Void = {}
            var beforeGenericStartupFailureTeardown: () async -> Void = {}
            var toolTrackingStopped: (UUID) -> Void = { _ in }
        }

        private var ompQualificationStartupProbes = OMPQualificationStartupProbes()

        func installOMPQualificationStartupProbes(_ probes: OMPQualificationStartupProbes) {
            ompQualificationStartupProbes = probes
        }
    #endif

    private func log(_ message: String, runID: UUID) {
        guard AgentRuntimeProviderService.enableDebugLogging else { return }
        print("[ACP-Runner] run=\(runID) \(message)")
    }

    private func displayText(for error: Error) -> String {
        Self.displayText(for: error)
    }

    private static func displayText(for error: Error) -> String {
        if let providerError = error as? AIProviderError {
            switch providerError {
            case .missingOllamaURL:
                return "Missing Ollama URL."
            case .missingAzureConfiguration:
                return "Missing Azure OpenAI configuration."
            case .missingAPIKey:
                return "Missing API key."
            case .missingURL:
                return "Missing provider URL."
            case .providerNotConfigured:
                return "Provider is not configured."
            case .invalidModel:
                return "Invalid model."
            case .invalidSystemPrompt:
                return "Invalid system prompt."
            case .messageCreationFailed:
                return "Failed to create provider message."
            case let .invalidResponse(detail), let .invalidConfiguration(detail):
                return detail
            case let .apiError(source), let .unknown(source):
                return source.map(displayText) ?? String(describing: providerError)
            }
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty
        {
            return description
        }
        let nsError = error as NSError
        if nsError.domain != NSCocoaErrorDomain || nsError.code != 0 {
            let description = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty, description != "The operation couldn’t be completed." {
                return description
            }
        }
        return String(describing: error)
    }

    init(
        hooks: AgentModeRunService.Hooks,
        terminalCommitBarrier: AgentRunTerminalCommitBarrier,
        toolTrackingHooks: AgentToolTrackingHooks,
        mcpHost: any AgentMCPHosting,
        providerFactory: @escaping AgentACPProviderFactory,
        controllerFactory: @escaping AgentACPControllerFactory
    ) {
        self.hooks = hooks
        self.terminalCommitBarrier = terminalCommitBarrier
        self.toolTrackingHooks = toolTrackingHooks
        self.mcpHost = mcpHost
        self.providerFactory = providerFactory
        self.controllerFactory = controllerFactory
    }

    func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        handoff: AgentProviderHandoff,
        runRequest: ACPRunRequest,
        makeLease: @escaping (_ runID: UUID) -> MCPBootstrapLease,
        providerStartAuthorizer: @escaping (_ runID: UUID) -> Bool,
        providerStartBoundaryReporter: @escaping (
            _ runID: UUID?,
            _ activeAgentSessionID: UUID?,
            _ runAttemptID: UUID?,
            _ authorized: Bool,
            _ startupFailureReason: String?
        ) -> Bool,
        providerStartBootstrapObserver: @escaping () -> Void
    ) async {
        #if DEBUG
            var providerBoundaryResponsibilityTransferred = false
            var providerBoundaryFailureReason: String? = "provider_start_abandoned_before_authorization"
            defer {
                if !providerBoundaryResponsibilityTransferred {
                    _ = providerStartBoundaryReporter(nil, nil, nil, false, providerBoundaryFailureReason)
                }
            }
        #endif
        // A run task owns the handoff once created; every earlier exit never reached the provider.
        // Settling the handoff also settles the staged input it carries (`carriedStagedInput`).
        var runTaskOwnsHandoff = false
        defer {
            if !runTaskOwnsHandoff {
                handoff.settleRunInputScope()
            }
        }
        let attachmentReservationID = hooks.reserveAttachmentsForTurn(attachments, session)

        if initialMessageForRun != initialUserMessage,
           !session.pendingNonCodexUserInputTokenQueue.isEmpty
        {
            session.pendingNonCodexUserInputTokenQueue[0] = hooks.estimateRuntimeTokens(initialMessageForRun)
        }
        hooks.startNonCodexTurnAccountingIfNeeded(session, initialMessageForRun)
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()

        let ownership = session.beginRunAttempt(source: "acp", inputUserItemID: handoff.attributedUserItemID)
        let runAttemptID = ownership.attemptID
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        session.runState = .running
        hooks.setAgentRunActive(tabID, true)
        setRunningStatus(initialTransportStatusText(for: runRequest.agentKind), source: .transport, session: session, urgent: true)

        if let existingController = session.acpController {
            let isCompatible = await existingController.isCompatibleWith(request: runRequest)
            guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID) else { return }
            let hasReusableSession = isCompatible ? await existingController.hasReusableSession : false
            guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID) else { return }
            if isCompatible,
               hasReusableSession,
               let runID = AgentModeProcessRunIdentity.existingProcessRunID(for: session)
            {
                guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID) else { return }
                guard providerStartAuthorizer(runID) else {
                    #if DEBUG
                        _ = providerStartBoundaryReporter(runID, session.activeAgentSessionID, runAttemptID, false, nil)
                    #endif
                    await failBeforeProviderSend(
                        tabID: tabID,
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        attachmentReservationID: attachmentReservationID,
                        errorText: Self.ohMyPiAuthorizationFailureText
                    )
                    return
                }
                #if DEBUG
                    guard providerStartBoundaryReporter(
                        runID,
                        session.activeAgentSessionID,
                        runAttemptID,
                        true,
                        nil
                    ) else {
                        await failBeforeProviderSend(
                            tabID: tabID,
                            session: session,
                            runID: runID,
                            runAttemptID: runAttemptID,
                            attachmentReservationID: attachmentReservationID,
                            errorText: Self.ohMyPiAuthorizationFailureText
                        )
                        return
                    }
                #endif
                let deferredLease = runRequest.agentKind.requiresPrePromptAgentModeMCPRouting
                    ? nil
                    : makeLease(runID)
                session.installRunAttemptTerminalResources(ownership: ownership) { [weak self] terminalState in
                    let trackerTeardown = self?.prepareToolTrackingTeardown(for: session, matchingRunID: runID)
                    return {
                        await trackerTeardown?()
                        await MCPBootstrapLeaseDisposition(
                            terminalState: terminalState,
                            agentKind: runRequest.agentKind
                        ).apply(to: deferredLease)
                    }
                }
                // R6: the reused process serves this run attempt (its existing process run).
                let attemptRunRequest = runRequest.withRuntimeSession(session.runtimeSessionScope)
                runTaskOwnsHandoff = true
                session.agentTask = Task { [weak self, weak session] in
                    defer { handoff.settleRunInputScope() }
                    guard let self, let session else { return }
                    if let clientNameHint = runRequest.agentKind.mcpClientNameHint {
                        await startToolTracking(for: session, runID: runID, clientNameHint: clientNameHint)
                    }
                    await withTaskCancellationHandler {
                        await self.continueRun(
                            tabID: tabID,
                            session: session,
                            runID: runID,
                            runAttemptID: runAttemptID,
                            initialMessageForRun: initialMessageForRun,
                            attachments: attachments,
                            handoff: handoff,
                            controller: existingController,
                            runRequest: attemptRunRequest,
                            deferredLease: deferredLease,
                            attachmentReservationID: attachmentReservationID
                        )
                    } onCancel: {}
                }
                return
            }

            session.acpController = nil
            AgentModeProcessRunIdentity.clearProcessRunID(for: session)
            await existingController.shutdown()
            guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID) else { return }
        }
        let runID = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID) else { return }
        // R6: the launch and every write of this attempt carry its lifecycle, attempt and process run.
        let freshRunRequest = runRequest.withRuntimeSession(session.runtimeSessionScope)
        let lease = makeLease(runID)

        guard let provider = providerFactory(runRequest.agentKind, runRequest.modelString) else {
            #if DEBUG
                providerBoundaryFailureReason = "acp_provider_unavailable"
            #endif
            await failBeforeProviderSend(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: "No ACP provider is registered for \(runRequest.agentKind.displayName)."
            )
            return
        }
        let support: ACPSupportResult
        do {
            support = try await provider.support(for: freshRunRequest)
        } catch is CancellationError {
            #if DEBUG
                providerBoundaryFailureReason = "acp_support_preflight_cancelled"
            #endif
            await cancelBeforeProviderSend(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID
            )
            return
        } catch {
            #if DEBUG
                providerBoundaryFailureReason = "acp_support_preflight_failed"
            #endif
            await failBeforeProviderSend(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: "ACP support preflight failed: \(error.localizedDescription)"
            )
            return
        }
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID) else { return }
        guard support == .supported else {
            #if DEBUG
                providerBoundaryFailureReason = "acp_support_unsupported"
            #endif
            await failBeforeProviderSend(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: support.reason ?? "\(runRequest.agentKind.displayName) ACP is not available."
            )
            return
        }
        let controller: ACPAgentSessionController
        do {
            controller = try controllerFactory(provider, freshRunRequest)
        } catch {
            let errorText = displayText(for: error)
            #if DEBUG
                providerBoundaryFailureReason = "acp_controller_initialization_failed"
            #endif
            await failBeforeProviderSend(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: "ACP controller init failed: \(errorText)"
            )
            return
        }

        if controller.joinsRetirementBeforeSuccessor {
            // R6: a retired registered runtime of this tab (any provider, for example a Codex or
            // Claude controller retired by a provider switch) finishes its cleanup before this
            // launch reserves; the currency and cancellation checks below then apply.
            await session.joinRuntimeRetirements()
        }
        #if DEBUG
            await controller.setExpectedMCPRunID(
                runID,
                testDuringSet: runRequest.agentKind == .ohMyPi
                    ? ompQualificationStartupProbes.duringExpectedMCPRunIDSet
                    : nil
            )
        #else
            await controller.setExpectedMCPRunID(runID)
        #endif
        let ownsUnpublishedControllerSlot = session.acpController == nil || session.acpController === controller
        let ownsCurrentAttempt = isStartupStillCurrent(
            session: session,
            runID: runID,
            runAttemptID: runAttemptID
        ) && ownsUnpublishedControllerSlot
        guard !Task.isCancelled, ownsCurrentAttempt else {
            await finalizeUnpublishedControllerStartup(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                lease: lease,
                attachments: attachments,
                attachmentReservationID: attachmentReservationID,
                ownsCurrentAttempt: ownsCurrentAttempt,
                providerStartBoundaryReporter: providerStartBoundaryReporter
            )
            return
        }
        session.acpController = controller
        #if DEBUG
            if runRequest.agentKind == .ohMyPi {
                session.ompQualificationStartupLease = lease
            }
        #endif
        session.installRunAttemptTerminalResources(ownership: ownership) { [weak self, weak session] terminalState in
            let trackerTeardown = session.flatMap { self?.prepareToolTrackingTeardown(for: $0, matchingRunID: runID) }
            return {
                await trackerTeardown?()
                await MCPBootstrapLeaseDisposition(
                    terminalState: terminalState,
                    agentKind: runRequest.agentKind
                ).apply(to: lease)
                #if DEBUG
                    if session?.ompQualificationStartupLease === lease {
                        session?.ompQualificationStartupLease = nil
                    }
                #endif
            }
        }
        #if DEBUG
            providerBoundaryResponsibilityTransferred = true
        #endif
        let weakSession = WeakTabSession(session)
        #if DEBUG
            let beforeAgentTaskEntry = ompQualificationStartupProbes.beforeAgentTaskEntry
        #endif
        let terminalCommitBarrier = terminalCommitBarrier
        let hooks = hooks
        let startupTeardownClaim = StartupTeardownClaim()
        runTaskOwnsHandoff = true
        session.agentTask = Task { [weak self] in
            defer { handoff.settleRunInputScope() }
            #if DEBUG
                if runRequest.agentKind == .ohMyPi {
                    await beforeAgentTaskEntry()
                }
            #endif
            guard let self else {
                #if DEBUG
                    _ = providerStartBoundaryReporter(
                        runID,
                        nil,
                        runAttemptID,
                        false,
                        "runner_released_before_authorization"
                    )
                #endif
                if let session = weakSession.value,
                   let currentOwnership = session.activeRunOwnership,
                   currentOwnership.attemptID == runAttemptID,
                   session.runID == runID,
                   session.acpController == nil || session.acpController === controller
                {
                    handoff.settleRunInputScope()
                    await terminalCommitBarrier.commit(.init(
                        session: session,
                        ownership: currentOwnership,
                        expectedRunID: runID,
                        terminalState: .failed,
                        source: "acp.runnerReleasedBeforeTaskEntry",
                        cause: .ordinary,
                        completion: .terminalTeardownCompleted,
                        errorText: Self.ohMyPiAuthorizationFailureText,
                        attachmentReservationID: attachmentReservationID,
                        attachmentDisposition: .deleteFiles,
                        finalizeNonCodexUsage: true,
                        supportsFollowUp: false,
                        notifyTurnComplete: false,
                        prepareProviderState: {
                            if session.acpController === controller {
                                session.acpController = nil
                            }
                            AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                            return { await controller.shutdown() }
                        }
                    ))
                } else {
                    hooks.finalizeAbandonedAttachmentsForTurn(attachments)
                    await lease.failAndCleanup()
                    await controller.shutdown()
                }
                return
            }
            if let clientNameHint = runRequest.agentKind.mcpClientNameHint {
                if let session = weakSession.value {
                    await startToolTracking(for: session, runID: runID, clientNameHint: clientNameHint)
                }
            }
            await withTaskCancellationHandler {
                await self.startFreshRun(
                    tabID: tabID,
                    session: weakSession,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    initialMessageForRun: initialMessageForRun,
                    attachments: attachments,
                    handoff: handoff,
                    controller: controller,
                    runRequest: freshRunRequest,
                    lease: lease,
                    providerStartAuthorizer: providerStartAuthorizer,
                    providerStartBoundaryReporter: providerStartBoundaryReporter,
                    providerStartBootstrapObserver: providerStartBootstrapObserver,
                    attachmentReservationID: attachmentReservationID,
                    startupTeardownClaim: startupTeardownClaim
                )
            } onCancel: { [weak self] in
                guard freshRunRequest.agentKind == .ohMyPi else { return }
                // OMP bootstrap may not promptly cooperate with cancellation. The same
                // one-shot task is joined below and claimed by in-body cancellation paths.
                _ = startupTeardownClaim.claim(onlyBeforePrompt: true) { @MainActor [weak self] in
                    guard let self else { return }
                    await finalizeStartupDisposition(
                        tabID: tabID,
                        session: weakSession,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        lease: lease,
                        attachments: attachments,
                        attachmentReservationID: attachmentReservationID,
                        controller: controller,
                        runRequest: freshRunRequest,
                        terminalState: .cancelled,
                        errorText: nil
                    )
                }
            }
            await startupTeardownClaim.task?.value
        }
    }

    /// Submits steering into the active ACP prompt. `handoff` carries the committed dispatch of
    /// every steering constituent (in order): every return before the `session/prompt` call
    /// reports no handoff; a throw without the documented write callback reports no handoff; a
    /// throw after it stays delivery-unknown; the provider's `session/prompt` response is
    /// acceptance.
    func submitActivePrompt(
        session: AgentTabSession,
        messageForRun: String,
        attachments: [AgentImageAttachment],
        runRequest: ACPRunRequest,
        targetRunID: UUID?,
        targetRunAttemptID: UUID?,
        targetController: ACPAgentSessionController,
        handoff: AgentProviderHandoff
    ) async -> Bool {
        defer {
            if !handoff.handoffStarted {
                handoff.noteNoHandoff()
            }
        }
        guard runRequest.agentKind == session.selectedAgent,
              runRequest.agentKind.acpProviderID != nil,
              session.runState == .running,
              let controller = session.acpController,
              controller === targetController,
              let runID = session.runID,
              runID == targetRunID,
              let runAttemptID = session.activeRunAttemptID,
              runAttemptID == targetRunAttemptID
        else {
            let diagnosticRunID = session.runID ?? targetRunID ?? UUID()
            log("active prompt preflight rejected selected=\(session.selectedAgent.rawValue) request=\(runRequest.agentKind.rawValue) state=\(session.runState.rawValue) runID=\(String(describing: session.runID)) targetRunID=\(String(describing: targetRunID)) attempt=\(String(describing: session.activeRunAttemptID)) targetAttempt=\(String(describing: targetRunAttemptID)) hasController=\(session.acpController != nil) controllerMatches=\(session.acpController === targetController)", runID: diagnosticRunID)
            return false
        }
        guard await controller.isCompatibleWith(request: runRequest) else {
            log("active prompt preflight rejected incompatible ACP request model=\(runRequest.modelString ?? "default") workspace=\(runRequest.workspacePath ?? "nil")", runID: runID)
            return false
        }
        guard session.runState == .running,
              session.runID == runID,
              session.activeRunAttemptID == runAttemptID,
              session.acpController === controller
        else {
            log("active prompt preflight became stale after compatibility check state=\(session.runState.rawValue) runID=\(String(describing: session.runID)) attempt=\(String(describing: session.activeRunAttemptID))", runID: runID)
            return false
        }

        setRunningStatus("Thinking…", source: .transport, session: session, urgent: true)
        // Active steering must not reconfigure ACP session mode/model. Agent-mode UI
        // locks provider selection while a run is active, and reapplying Cursor/OpenCode
        // dynamic model aliases (notably Cursor `auto`) can fail before session/cancel.

        setRunningStatus("Interrupting…", source: .transport, session: session, urgent: true)
        log("active steering interrupt begin attempt=\(runAttemptID)", runID: runID)
        do {
            try await controller.interruptActivePromptForSteering()
            log("active steering interrupt settled attempt=\(runAttemptID)", runID: runID)
        } catch {
            let normalized = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalized)
            log("active steering interrupt failed attempt=\(runAttemptID) raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            return false
        }

        guard session.runState == .running,
              session.runID == runID,
              session.activeRunAttemptID == runAttemptID,
              session.acpController === controller
        else {
            log("active steering became stale after interrupt state=\(session.runState.rawValue) currentRunID=\(String(describing: session.runID)) currentAttempt=\(String(describing: session.activeRunAttemptID))", runID: runID)
            return false
        }

        let agentMessage = hooks.buildHeadlessAgentMessage(
            session,
            messageForRun,
            runID,
            attachments
        )

        let promptWrite = ACPPromptWriteObservation()
        do {
            log("active steering session/prompt begin attempt=\(runAttemptID)", runID: runID)
            guard handoff.enterProviderBoundary(in: session) else { return false }
            try await controller.prompt(
                agentMessage,
                request: runRequest,
                onSubmitted: promptWrite.onSubmitted,
                onFailure: promptWrite.onFailure
            )
            // The provider answered `session/prompt`: affirmative acceptance, recorded first.
            handoff.noteAccepted()
            log("active steering session/prompt completed attempt=\(runAttemptID)", runID: runID)
            #if DEBUG
                if let hold = ACPActiveSteeringPromptTestHook.afterPromptReturned {
                    await hold()
                }
            #endif
            let identity = await controller.currentProviderSessionIdentity()
            applyProviderSessionIdentity(identity, session: session)
            // A successful prompt return means the steering prompt was delivered and
            // completed at the ACP layer. The event consumer may already have handled
            // the terminal and finalized the run, so do not require the original
            // activeRunAttemptID to still be present here.
            return true
        } catch {
            if promptWrite.wasWritten {
                Self.noteWrittenPromptFailure(handoff, promptWrite: promptWrite)
            } else {
                // Documented boundary: building or writing the request failed; never written.
                handoff.noteProvenNotWritten(message: String(describing: error))
            }
            let identity = await controller.refreshProviderSessionIdentityAfterPromptInterruption()
            applyProviderSessionIdentity(identity, session: session)
            let normalized = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalized)
            log("active steering session/prompt failed attempt=\(runAttemptID) raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            return false
        }
    }

    /// A written `session/prompt` threw. O49: when the agent had started that prompt's turn (it
    /// streamed content or reasoning for it) and RepoPrompt's own Stop or steer sent
    /// `session/cancel` (or its own Stop, window close or quit was requested before the run task
    /// was cancelled), the prompt was received: accepted. The evidence is that prompt's own,
    /// reported through its `onFailure`, and never when another prompt overlapped it. Any other
    /// written failure stays delivery-unknown.
    private static func noteWrittenPromptFailure(
        _ handoff: AgentProviderHandoff,
        promptWrite: ACPPromptWriteObservation
    ) {
        if promptWrite.failedAfterAgentReceipt {
            handoff.noteAccepted()
        } else {
            handoff.noteDeliveryUnknown()
        }
    }

    private func isStartupStillCurrent(
        session: AgentTabSession,
        runID: UUID? = nil,
        runAttemptID: UUID
    ) -> Bool {
        guard session.activeRunAttemptID == runAttemptID,
              session.runState.isActive
        else {
            return false
        }
        if let runID {
            return session.runID == runID
        }
        return true
    }

    private func finalizeUnpublishedControllerStartup(
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController,
        lease: MCPBootstrapLease,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        ownsCurrentAttempt: Bool,
        providerStartBoundaryReporter: (
            _ runID: UUID?,
            _ activeAgentSessionID: UUID?,
            _ runAttemptID: UUID?,
            _ authorized: Bool,
            _ startupFailureReason: String?
        ) -> Bool
    ) async {
        #if DEBUG
            _ = providerStartBoundaryReporter(
                runID,
                session.activeAgentSessionID,
                runAttemptID,
                false,
                "startup_invalid_before_authorization"
            )
        #endif
        if ownsCurrentAttempt {
            await cancelBeforeProviderSend(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID
            )
        } else {
            hooks.finalizeAttachmentsForTurn(
                session,
                attachmentReservationID,
                attachments,
                .deleteFiles
            )
        }
        await lease.cancelAndCleanup()
        await controller.shutdown()
    }

    private func failBeforeProviderSend(
        tabID _: UUID,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        attachmentReservationID: UUID?,
        errorText: String
    ) async {
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID),
              let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else { return }
        // The staged input is released by the owning scope's handoff settlement (never handed off).
        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: runID,
            terminalState: .failed,
            source: "acp.startupFailure",
            cause: .ordinary,
            errorText: errorText,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            prepareProviderState: {
                session.acpController = nil
                AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                return nil
            }
        ))
    }

    private func cancelBeforeProviderSend(
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        attachmentReservationID: UUID?
    ) async {
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID),
              let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else { return }
        // The staged input is released by the owning scope's handoff settlement (never handed off).
        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: runID,
            terminalState: .cancelled,
            source: "acp.startupCancelled",
            cause: .ordinary,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            prepareProviderState: {
                session.acpController = nil
                AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                return nil
            }
        ))
    }

    private struct StartupBoundarySnapshot {
        let activeAgentSessionID: UUID?
    }

    private enum StartupBoundaryStage: Equatable {
        case beforeAuthorization
        case beforeBootstrap
        case afterBootstrap
        case afterProviderInitializationCompleted

        var reportsProviderInitializationCancellation: Bool {
            self != .afterProviderInitializationCompleted
        }

        var reportsProviderBoundaryFailure: Bool {
            self == .beforeBootstrap
        }
    }

    private enum StartupBoundaryOutcome {
        case current(StartupBoundarySnapshot)
        case cancelled(StartupBoundaryStage)
    }

    private func revalidateStartupBoundary(
        _ stage: StartupBoundaryStage,
        session: WeakTabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController
    ) -> StartupBoundaryOutcome {
        guard let snapshot = startupBoundarySnapshot(
            session: session,
            runID: runID,
            runAttemptID: runAttemptID,
            controller: controller
        ) else {
            return .cancelled(stage)
        }
        return .current(snapshot)
    }

    private func reportInvalidStartupBoundaryIfNeeded(
        _ stage: StartupBoundaryStage,
        runID: UUID,
        runAttemptID: UUID,
        providerStartBoundaryReporter: (
            _ runID: UUID?,
            _ activeAgentSessionID: UUID?,
            _ runAttemptID: UUID?,
            _ authorized: Bool,
            _ startupFailureReason: String?
        ) -> Bool
    ) -> Bool {
        #if DEBUG
            guard stage.reportsProviderBoundaryFailure else { return false }
            _ = providerStartBoundaryReporter(
                runID,
                nil,
                runAttemptID,
                false,
                "startup_boundary_invalid_before_bootstrap"
            )
            return true
        #else
            return false
        #endif
    }

    private func finalizeInvalidStartupBoundary(
        _ stage: StartupBoundaryStage,
        tabID: UUID,
        session: WeakTabSession,
        runID: UUID,
        runAttemptID: UUID,
        providerName: String,
        lease: MCPBootstrapLease,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        startupTeardownClaim: StartupTeardownClaim
    ) async {
        if stage.reportsProviderInitializationCancellation {
            await lease.providerInitializationCompleted(provider: providerName, outcome: "cancelled")
        }
        await finalizeStartupBoundaryCancellation(
            tabID: tabID,
            session: session,
            runID: runID,
            runAttemptID: runAttemptID,
            lease: lease,
            attachments: attachments,
            attachmentReservationID: attachmentReservationID,
            controller: controller,
            runRequest: runRequest,
            startupTeardownClaim: startupTeardownClaim
        )
    }

    private func startupBoundarySnapshot(
        session: WeakTabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController
    ) -> StartupBoundarySnapshot? {
        guard !Task.isCancelled,
              let session = session.value,
              isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID),
              session.acpController === controller
        else {
            return nil
        }
        return StartupBoundarySnapshot(activeAgentSessionID: session.activeAgentSessionID)
    }

    private func finalizeAfterSessionLoss(
        tabID: UUID,
        session: WeakTabSession,
        runID: UUID,
        lease: MCPBootstrapLease,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        terminalState: AgentSessionRunState
    ) async {
        await teardownToolTrackingAfterSessionLoss(
            tabID: tabID,
            runID: runID,
            session: session.value
        )
        if let liveSession = session.value {
            hooks.finalizeAttachmentsForTurn(
                liveSession,
                attachmentReservationID,
                attachments,
                .deleteFiles
            )
        } else {
            hooks.finalizeAbandonedAttachmentsForTurn(attachments)
        }
        await MCPBootstrapLeaseDisposition(
            terminalState: terminalState,
            agentKind: runRequest.agentKind
        ).apply(to: lease)
        await controller.shutdown()
    }

    private func finalizeClaimedStartupDisposition(
        tabID: UUID,
        session: WeakTabSession,
        runID: UUID,
        runAttemptID: UUID,
        lease: MCPBootstrapLease,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        terminalState: AgentSessionRunState,
        errorText: String?,
        startupTeardownClaim: StartupTeardownClaim
    ) async {
        let task = startupTeardownClaim.claim { @MainActor [weak self] in
            guard let self else { return }
            await finalizeStartupDisposition(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                lease: lease,
                attachments: attachments,
                attachmentReservationID: attachmentReservationID,
                controller: controller,
                runRequest: runRequest,
                terminalState: terminalState,
                errorText: errorText
            )
        }
        await task?.value
    }

    private func finalizeStartupBoundaryCancellation(
        tabID: UUID,
        session: WeakTabSession,
        runID: UUID,
        runAttemptID: UUID,
        lease: MCPBootstrapLease,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        startupTeardownClaim: StartupTeardownClaim
    ) async {
        await finalizeClaimedStartupDisposition(
            tabID: tabID,
            session: session,
            runID: runID,
            runAttemptID: runAttemptID,
            lease: lease,
            attachments: attachments,
            attachmentReservationID: attachmentReservationID,
            controller: controller,
            runRequest: runRequest,
            terminalState: .cancelled,
            errorText: nil,
            startupTeardownClaim: startupTeardownClaim
        )
    }

    private func finalizeStartupDisposition(
        tabID: UUID,
        session: WeakTabSession,
        runID: UUID,
        runAttemptID: UUID,
        lease: MCPBootstrapLease,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        terminalState: AgentSessionRunState,
        errorText: String?
    ) async {
        if let liveSession = session.value,
           isStartupStillCurrent(session: liveSession, runID: runID, runAttemptID: runAttemptID),
           liveSession.acpController == nil || liveSession.acpController === controller
        {
            await finalize(
                session: liveSession,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: terminalState,
                errorText: errorText,
                notifyTurnComplete: false,
                shouldShutdownController: true,
                completion: .terminalTeardownCompleted
            )
            return
        }
        await finalizeAfterSessionLoss(
            tabID: tabID,
            session: session,
            runID: runID,
            lease: lease,
            attachments: attachments,
            attachmentReservationID: attachmentReservationID,
            controller: controller,
            runRequest: runRequest,
            terminalState: terminalState
        )
    }

    private func finalizeAcquireFailureAfterSessionLoss(
        tabID: UUID,
        runID: UUID,
        attachments: [AgentImageAttachment],
        controller: ACPAgentSessionController
    ) async {
        await teardownToolTrackingAfterSessionLoss(tabID: tabID, runID: runID)
        hooks.finalizeAbandonedAttachmentsForTurn(attachments)
        await controller.shutdown()
    }

    private func startFreshRun(
        tabID: UUID,
        session: WeakTabSession,
        runID: UUID,
        runAttemptID: UUID,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        handoff: AgentProviderHandoff,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        lease: MCPBootstrapLease,
        providerStartAuthorizer: (_ runID: UUID) -> Bool,
        providerStartBoundaryReporter: (
            _ runID: UUID?,
            _ activeAgentSessionID: UUID?,
            _ runAttemptID: UUID?,
            _ authorized: Bool,
            _ startupFailureReason: String?
        ) -> Bool,
        providerStartBootstrapObserver: () -> Void,
        attachmentReservationID: UUID?,
        startupTeardownClaim: StartupTeardownClaim
    ) async {
        #if DEBUG
            var providerBoundaryReported = false
            var providerBoundaryFailureReason = "fresh_start_abandoned_before_authorization"
            defer {
                if !providerBoundaryReported {
                    _ = providerStartBoundaryReporter(
                        runID,
                        nil,
                        runAttemptID,
                        false,
                        providerBoundaryFailureReason
                    )
                }
            }
        #endif
        let modelDescription = runRequest.modelString ?? "default"
        let resumeDescription = runRequest.resumeSessionID ?? "nil"
        let workspaceDescription = runRequest.workspacePath ?? "nil"
        log("fresh start begin model=\(modelDescription) resume=\(resumeDescription) workspace=\(workspaceDescription)", runID: runID)
        let acquired = await lease.acquire()
        guard acquired else {
            #if DEBUG
                providerBoundaryFailureReason = "bootstrap_lease_acquisition_failed"
            #endif
            log("lease acquire failed", runID: runID)
            let teardown = startupTeardownClaim.claim { @MainActor [self] in
                if let liveSession = session.value {
                    await handleAcquireFailure(
                        tabID: tabID,
                        session: liveSession,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        controller: controller,
                        lease: lease,
                        attachmentReservationID: attachmentReservationID
                    )
                } else {
                    // acquire() owns its failure cleanup. This branch must not apply a second
                    // generic lease disposition that could be mistaken for gate ownership.
                    await finalizeAcquireFailureAfterSessionLoss(
                        tabID: tabID,
                        runID: runID,
                        attachments: attachments,
                        controller: controller
                    )
                }
            }
            await teardown?.value
            return
        }

        var providerInitializationCompleted = false
        do {
            let providerName = runRequest.agentKind.rawValue
            await lease.providerInitializationStarted(provider: providerName)
            #if DEBUG
                if runRequest.agentKind == .ohMyPi {
                    await ompQualificationStartupProbes.beforeAuthorizationLivenessCheck()
                }
            #endif
            if case let .cancelled(stage) = revalidateStartupBoundary(
                .beforeAuthorization,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller
            ) {
                let reportedProviderBoundaryFailure = reportInvalidStartupBoundaryIfNeeded(
                    stage,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerStartBoundaryReporter: providerStartBoundaryReporter
                )
                #if DEBUG
                    providerBoundaryReported = providerBoundaryReported || reportedProviderBoundaryFailure
                #else
                    _ = reportedProviderBoundaryFailure
                #endif
                await finalizeInvalidStartupBoundary(
                    stage,
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerName: providerName,
                    lease: lease,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    controller: controller,
                    runRequest: runRequest,
                    startupTeardownClaim: startupTeardownClaim
                )
                return
            }
            guard providerStartAuthorizer(runID) else {
                #if DEBUG
                    providerBoundaryReported = true
                    _ = providerStartBoundaryReporter(runID, session.value?.activeAgentSessionID, runAttemptID, false, nil)
                #endif
                await lease.providerInitializationCompleted(provider: providerName, outcome: "failed")
                await finalizeClaimedStartupDisposition(
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    lease: lease,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    controller: controller,
                    runRequest: runRequest,
                    terminalState: .failed,
                    errorText: Self.ohMyPiAuthorizationFailureText,
                    startupTeardownClaim: startupTeardownClaim
                )
                return
            }
            let boundarySnapshot: StartupBoundarySnapshot
            switch revalidateStartupBoundary(
                .beforeBootstrap,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller
            ) {
            case let .current(snapshot):
                boundarySnapshot = snapshot
            case let .cancelled(stage):
                let reportedProviderBoundaryFailure = reportInvalidStartupBoundaryIfNeeded(
                    stage,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerStartBoundaryReporter: providerStartBoundaryReporter
                )
                #if DEBUG
                    providerBoundaryReported = providerBoundaryReported || reportedProviderBoundaryFailure
                #else
                    _ = reportedProviderBoundaryFailure
                #endif
                await finalizeInvalidStartupBoundary(
                    stage,
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerName: providerName,
                    lease: lease,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    controller: controller,
                    runRequest: runRequest,
                    startupTeardownClaim: startupTeardownClaim
                )
                return
            }
            log("bootstrap begin", runID: runID)
            #if DEBUG
                providerBoundaryReported = true
                guard providerStartBoundaryReporter(
                    runID,
                    boundarySnapshot.activeAgentSessionID,
                    runAttemptID,
                    true,
                    nil
                ) else {
                    await lease.providerInitializationCompleted(provider: providerName, outcome: "failed")
                    await finalizeClaimedStartupDisposition(
                        tabID: tabID,
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        lease: lease,
                        attachments: attachments,
                        attachmentReservationID: attachmentReservationID,
                        controller: controller,
                        runRequest: runRequest,
                        terminalState: .failed,
                        errorText: Self.ohMyPiAuthorizationFailureText,
                        startupTeardownClaim: startupTeardownClaim
                    )
                    return
                }
                providerStartBootstrapObserver()
            #endif
            let bootstrap = try await controller.bootstrap()
            #if DEBUG
                if runRequest.agentKind == .ohMyPi {
                    await ompQualificationStartupProbes.afterProviderBootstrap()
                }
            #endif
            if case let .cancelled(stage) = revalidateStartupBoundary(
                .afterBootstrap,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller
            ) {
                let reportedProviderBoundaryFailure = reportInvalidStartupBoundaryIfNeeded(
                    stage,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerStartBoundaryReporter: providerStartBoundaryReporter
                )
                #if DEBUG
                    providerBoundaryReported = providerBoundaryReported || reportedProviderBoundaryFailure
                #else
                    _ = reportedProviderBoundaryFailure
                #endif
                await finalizeInvalidStartupBoundary(
                    stage,
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerName: providerName,
                    lease: lease,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    controller: controller,
                    runRequest: runRequest,
                    startupTeardownClaim: startupTeardownClaim
                )
                return
            }
            providerInitializationCompleted = true
            await lease.providerInitializationCompleted(provider: providerName, outcome: "ready")
            #if DEBUG
                if runRequest.agentKind == .ohMyPi {
                    await ompQualificationStartupProbes.afterProviderInitializationCompleted()
                }
            #endif
            if case let .cancelled(stage) = revalidateStartupBoundary(
                .afterProviderInitializationCompleted,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller
            ) {
                let reportedProviderBoundaryFailure = reportInvalidStartupBoundaryIfNeeded(
                    stage,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerStartBoundaryReporter: providerStartBoundaryReporter
                )
                #if DEBUG
                    providerBoundaryReported = providerBoundaryReported || reportedProviderBoundaryFailure
                #else
                    _ = reportedProviderBoundaryFailure
                #endif
                await finalizeInvalidStartupBoundary(
                    stage,
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    providerName: providerName,
                    lease: lease,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    controller: controller,
                    runRequest: runRequest,
                    startupTeardownClaim: startupTeardownClaim
                )
                return
            }
            log("bootstrap completed sessionID=\(bootstrap.sessionID)", runID: runID)
            guard let session = session.value else {
                await finalizeStartupBoundaryCancellation(
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    lease: lease,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    controller: controller,
                    runRequest: runRequest,
                    startupTeardownClaim: startupTeardownClaim
                )
                return
            }
            var initialMessageForPromptTurn = initialMessageForRun
            if bootstrap.didFallbackToNewSessionAfterLoadFailure {
                await hooks.stageResumeRecoveryHandoffIfNeeded(session)
                if handoff.isDurable {
                    // Adopted plan §5: this input's dispatch commit is deferred to `runPromptTurn`,
                    // so the recovery handoff this fallback created is staged now and its exact
                    // snapshot is attached to the still-queued carrier at that commit. If it cannot
                    // be staged durably the send is blocked with its input saved — never sent to
                    // the fresh session without its history.
                    switch await hooks.stagePendingHandoffForDurableDispatch(initialMessageForRun, session) {
                    case .none:
                        break
                    case let .staged(staged, snapshot):
                        initialMessageForPromptTurn = staged.text
                        handoff.carryStagedInput(AgentCarriedStagedInput(pendingHandoffStage: staged.pendingHandoffStage))
                        handoff.notePendingHandoff(snapshot)
                    case .failed:
                        handoff.blockBeforeHandoff(.pendingHandoffNotSaved)
                        await finalize(
                            session: session,
                            runID: runID,
                            runAttemptID: runAttemptID,
                            controller: controller,
                            attachmentReservationID: attachmentReservationID,
                            terminalState: .failed,
                            errorText: AgentProviderHandoff.CommitFailure.pendingHandoffNotSaved.userText,
                            notifyTurnComplete: false,
                            shouldShutdownController: false
                        )
                        return
                    }
                } else {
                    let staged = hooks.prependPendingHandoffIfNeeded(initialMessageForRun, session)
                    initialMessageForPromptTurn = staged.text
                    // The recovery handoff now rides on this prompt: its handoff settles that stage.
                    handoff.carryStagedInput(AgentCarriedStagedInput(pendingHandoffStage: staged.pendingHandoffStage))
                }
            }
            applyProviderSessionIdentity(
                bootstrap.providerSessionIdentity,
                invalidatedResumeSessionID: bootstrap.invalidatedResumeSessionID,
                session: session
            )
            _ = syncACPSelectedModelFromRegistryIfNeeded(agentKind: runRequest.agentKind, session: session)
            session.isDirty = true
            hooks.scheduleSave(session.tabID)
            hooks.updateBindings(session)

            try await applyExplicitSelectedModelIfNeeded(runRequest, controller: controller, runID: runID)
            await controller.setAutoApproveAllToolPermissions(runRequest.autoApproveAllToolPermissions)
            try await applyRequestedSessionModeIfNeeded(
                runRequest.sessionModeID,
                runtimeOwner: runRequest.runtimeSession,
                controller: controller,
                runID: runID
            )
            setRunningStatus(waitingForConnectionStatusText(for: runRequest.agentKind), source: .transport, session: session, urgent: true)

            if runRequest.agentKind.requiresPrePromptAgentModeMCPRouting {
                let routed = await lease.releaseWhenRouted()
                log("releaseWhenRouted routed=\(routed)", runID: runID)
                guard routed else {
                    await finalize(
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        controller: controller,
                        attachmentReservationID: attachmentReservationID,
                        terminalState: .failed,
                        errorText: "RepoPrompt MCP routing did not complete before \(runRequest.agentKind.displayName) ACP prompt submission.",
                        notifyTurnComplete: false,
                        shouldShutdownController: true
                    )
                    return
                }
            } else {
                await lease.releaseGateForDeferredRouting()
                log("deferred MCP routing until ACP prompt", runID: runID)
            }

            #if DEBUG
                if runRequest.agentKind == .ohMyPi {
                    await ompQualificationStartupProbes.beforePromptStartClaim()
                }
            #endif
            guard startupTeardownClaim.markPromptStartedIfUnclaimed() else {
                await startupTeardownClaim.task?.value
                return
            }
            await runPromptTurn(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                initialMessageForRun: initialMessageForPromptTurn,
                attachments: attachments,
                handoff: handoff,
                controller: controller,
                runRequest: runRequest,
                attachmentReservationID: attachmentReservationID
            )
        } catch is CancellationError {
            if !providerInitializationCompleted {
                await lease.providerInitializationCompleted(provider: runRequest.agentKind.rawValue, outcome: "cancelled")
            }
            log("fresh start cancelled", runID: runID)
            await finalizeStartupBoundaryCancellation(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                lease: lease,
                attachments: attachments,
                attachmentReservationID: attachmentReservationID,
                controller: controller,
                runRequest: runRequest,
                startupTeardownClaim: startupTeardownClaim
            )
        } catch {
            if !providerInitializationCompleted {
                await lease.providerInitializationCompleted(provider: runRequest.agentKind.rawValue, outcome: "failed")
            }
            let normalized = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalized)
            log("fresh start failed raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            #if DEBUG
                if runRequest.agentKind == .ohMyPi {
                    await ompQualificationStartupProbes.beforeGenericStartupFailureTeardown()
                }
            #endif
            let teardown = startupTeardownClaim.claim { @MainActor [weak self] in
                guard let self else { return }
                await finalizeStartupDisposition(
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    lease: lease,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    controller: controller,
                    runRequest: runRequest,
                    terminalState: .failed,
                    errorText: normalizedText
                )
            }
            await teardown?.value
        }
    }

    private func continueRun(
        tabID: UUID,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        handoff: AgentProviderHandoff,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        deferredLease: MCPBootstrapLease?,
        attachmentReservationID: UUID?
    ) async {
        do {
            guard await controller.hasReusableSession else {
                await finalize(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    controller: controller,
                    attachmentReservationID: attachmentReservationID,
                    terminalState: .failed,
                    errorText: "\(runRequest.agentKind.displayName) ACP session is no longer reusable.",
                    notifyTurnComplete: false,
                    shouldShutdownController: true
                )
                return
            }

            let prepared = await controller.prepareForNextTurn()
            guard prepared else {
                await finalize(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    controller: controller,
                    attachmentReservationID: attachmentReservationID,
                    terminalState: .failed,
                    errorText: "\(runRequest.agentKind.displayName) ACP session is no longer reusable.",
                    notifyTurnComplete: false,
                    shouldShutdownController: true
                )
                return
            }

            try await applyExplicitSelectedModelIfNeeded(runRequest, controller: controller, runID: runID)
            await controller.setAutoApproveAllToolPermissions(runRequest.autoApproveAllToolPermissions)
            try await applyRequestedSessionModeIfNeeded(
                runRequest.sessionModeID,
                runtimeOwner: runRequest.runtimeSession,
                controller: controller,
                runID: runID
            )

            if let deferredLease {
                let acquired = await deferredLease.acquire()
                guard acquired else {
                    await finalize(
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        controller: controller,
                        attachmentReservationID: attachmentReservationID,
                        terminalState: .failed,
                        errorText: "RepoPrompt MCP routing policy could not be prepared before \(runRequest.agentKind.displayName) ACP prompt submission.",
                        notifyTurnComplete: false,
                        shouldShutdownController: true
                    )
                    return
                }
                await deferredLease.releaseGateForDeferredRouting()
                log("deferred MCP routing until ACP follow-up prompt", runID: runID)
            }

            await runPromptTurn(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                initialMessageForRun: initialMessageForRun,
                attachments: attachments,
                handoff: handoff,
                controller: controller,
                runRequest: runRequest,
                attachmentReservationID: attachmentReservationID
            )
        } catch is CancellationError {
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .cancelled,
                errorText: nil,
                notifyTurnComplete: false,
                shouldShutdownController: true
            )
        } catch {
            let normalized = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalized)
            log("continue failed raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .failed,
                errorText: normalizedText,
                notifyTurnComplete: false,
                shouldShutdownController: true
            )
        }
    }

    private func runPromptTurn(
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        handoff: AgentProviderHandoff,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        attachmentReservationID: UUID?
    ) async {
        // Attach the input's delivery attempts to this run attempt before the provider is
        // invoked, then require the exact attempt and controller to still own the session.
        guard let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID,
              session.runID == runID,
              session.acpController === controller,
              !Task.isCancelled
        else {
            handoff.noteNoHandoff()
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .cancelled,
                errorText: nil,
                notifyTurnComplete: false,
                shouldShutdownController: true
            )
            return
        }
        if case let .failure(failure) = await handoff.attachRunAttempt(
            ownership: ownership,
            processRunID: runID,
            session: session
        ) {
            AgentDeliveryRecordDiagnostics.runAttemptNotRecorded(route: .acp, runAttemptID: runAttemptID, failure: failure)
            handoff.noteNoHandoff(message: AgentProviderHandoff.deliveryNotRecordedText(failure))
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .failed,
                errorText: AgentRecoveryAdmissionFailure.deliveryNotRecordedText(),
                notifyTurnComplete: false,
                shouldShutdownController: false
            )
            return
        }
        // Deferred dispatch commit (adopted plan §5), after the bootstrap and any fallback staging:
        // the noted pending-handoff snapshot is attached to the still-queued carrier first. If that
        // cannot be completed the send is blocked with its input saved; late payloads also block.
        var commitFailure: AgentProviderHandoff.CommitFailure?
        if case let .failure(failure) = await handoff.commitDispatch(session: session) {
            commitFailure = failure
        } else if handoff.pendingHandoffCreatedAfterCommit(in: session) {
            commitFailure = .pendingHandoffAfterCommit
        }
        if let commitFailure {
            handoff.blockBeforeHandoff(commitFailure)
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .failed,
                errorText: commitFailure.userText,
                notifyTurnComplete: false,
                shouldShutdownController: false
            )
            return
        }
        guard session.activeRunAttemptID == runAttemptID,
              session.runID == runID,
              session.acpController === controller,
              !Task.isCancelled
        else {
            handoff.noteNoHandoff()
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .cancelled,
                errorText: nil,
                notifyTurnComplete: false,
                shouldShutdownController: true
            )
            return
        }
        log("prompt turn begin", runID: runID)
        setRunningStatus("Thinking…", source: .transport, session: session, urgent: true)
        let agentMessage = hooks.buildHeadlessAgentMessage(
            session,
            initialMessageForRun,
            runID,
            attachments
        )
        // Staged input in this prompt (pending handoff and delegated child-question notices) settles
        // only at the actual `session/prompt` write — not optimistically here, and not at turn end
        // (plan §6.2; ACP `onSubmitted` is the stage-delivery boundary, not acceptance).
        let stagedInputAcknowledgement = makeStagedInputPromptAcknowledgement(handoff: handoff)
        // `onSubmitted` proves only the `session/prompt` write; the provider's response proves
        // acceptance.
        let promptWrite = ACPPromptWriteObservation(forwarding: stagedInputAcknowledgement.onSubmitted)
        hooks.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
        hooks.markAttachmentsConsumed(session, attachmentReservationID)

        let events = await controller.events
        // Final synchronous ownership check (no await before the prompt write): a lane retired
        // or frozen for reset after the dispatch commit settles this attempt as never handed off.
        guard handoff.enterProviderBoundary(in: session) else {
            await stagedInputAcknowledgement.settle()
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .failed,
                errorText: AgentProviderHandoff.sessionChangedBeforeHandoffMessage,
                notifyTurnComplete: false,
                shouldShutdownController: true
            )
            return
        }
        let consumeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else {
                return ConsumeEventsOutcome(terminalState: .failed, errorText: "ACP event consumer deallocated.")
            }
            return await consumeEvents(
                events,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID
            )
        }

        do {
            log("controller.prompt begin", runID: runID)
            try await controller.prompt(
                agentMessage,
                request: runRequest,
                onSubmitted: promptWrite.onSubmitted,
                onFailure: promptWrite.onFailure
            )
            // The provider answered `session/prompt`: affirmative acceptance, recorded before any
            // reconciliation below.
            handoff.noteAccepted()
            await stagedInputAcknowledgement.settle()
            let identity = await controller.currentProviderSessionIdentity()
            applyProviderSessionIdentity(identity, session: session)
            log("controller.prompt returned; awaiting event consumer", runID: runID)
        } catch {
            if promptWrite.wasWritten {
                Self.noteWrittenPromptFailure(handoff, promptWrite: promptWrite)
            } else {
                // Documented boundary: building or writing the request failed; never written.
                handoff.noteProvenNotWritten(message: String(describing: error))
            }
            // Releases the staged input unless the prompt was actually written.
            await stagedInputAcknowledgement.settle()
            let identity = await controller.refreshProviderSessionIdentityAfterPromptInterruption()
            applyProviderSessionIdentity(identity, session: session)
            let normalizedError = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalizedError)
            log("controller.prompt failed raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            let outcome = await consumeTask.value
            let errorText = promptFailureErrorText(outcome: outcome, fallback: normalizedText)
            let failureCause = await Self.terminalCause(terminalState: .failed, controller: controller)
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .failed,
                errorText: errorText,
                notifyTurnComplete: false,
                shouldShutdownController: true,
                cause: failureCause
            )
            return
        }

        let outcome = await consumeTask.value
        let outcomeErrorDescription = outcome.errorText ?? "nil"
        log("event consumer completed state=\(outcome.terminalState.rawValue) error=\(outcomeErrorDescription)", runID: runID)
        let cause = await Self.terminalCause(terminalState: outcome.terminalState, controller: controller)
        await finalize(
            session: session,
            runID: runID,
            runAttemptID: runAttemptID,
            controller: controller,
            attachmentReservationID: attachmentReservationID,
            terminalState: outcome.terminalState,
            errorText: outcome.errorText,
            notifyTurnComplete: outcome.terminalState == .completed,
            shouldShutdownController: outcome.terminalState != .completed,
            cause: cause
        )
    }

    /// Review A F06: a failed run whose provider process exited while the controller was not
    /// closing it ended by provider-process loss; every other ending (provider-reported errors,
    /// our own shutdown, completion) stays ordinary. A lifecycle teardown still wins at the barrier.
    static func terminalCause(
        terminalState: AgentSessionRunState,
        controller: ACPAgentSessionController
    ) async -> AgentRunTerminalCause {
        guard terminalState == .failed else { return .ordinary }
        return await controller.providerProcessWasLost() ? .providerProcessLost : .ordinary
    }

    /// Settles the staged input `handoff` carries into one ACP prompt (plan §6.2): `onSubmitted`
    /// (passed to `ACPAgentSessionController.prompt`) fires at the actual `session/prompt` write
    /// and settles those exact stages as sent; `settle()` — awaited once the prompt returned or
    /// threw, before finalization — otherwise classifies them from the handoff's evidence (a
    /// prompt never written releases them) and joins the acknowledgement.
    private func makeStagedInputPromptAcknowledgement(
        handoff: AgentProviderHandoff
    ) -> (onSubmitted: (@Sendable () -> Void)?, settle: () async -> Void) {
        let (submissions, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let hooks = hooks
        let acknowledgement = Task { @MainActor in
            var submitted = false
            for await _ in submissions {
                submitted = true
                break
            }
            hooks.recordStagedInputSendOutcome(handoff: handoff, sent: submitted)
        }
        return (
            onSubmitted: {
                continuation.yield(())
                continuation.finish()
            },
            settle: {
                continuation.finish()
                await acknowledgement.value
            }
        )
    }

    private func applyProviderSessionIdentity(
        _ identity: ACPProviderSessionIdentity,
        invalidatedResumeSessionID: String? = nil,
        session: AgentTabSession
    ) {
        let providerSessionID = identity.loadSessionID ?? identity.runtimeSessionID
        var changed = false
        let invalidated = invalidatedResumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let invalidated,
           !invalidated.isEmpty,
           session.providerSessionID?.trimmingCharacters(in: .whitespacesAndNewlines) == invalidated,
           providerSessionID != invalidated
        {
            session.providerSessionID = nil
            changed = true
        }
        if session.providerSessionID != providerSessionID {
            session.providerSessionID = providerSessionID
            changed = true
        }
        guard changed else { return }
        session.isDirty = true
        hooks.scheduleSave(session.tabID)
        hooks.updateBindings(session)
    }

    /// `runtimeOwner`: the attempt request's owner-captured scope (R6), which the requested mode
    /// change is associated with before it is written.
    private func applyRequestedSessionModeIfNeeded(
        _ requestedMode: String?,
        runtimeOwner: AgentRuntimeSessionScope,
        controller: ACPAgentSessionController,
        runID: UUID
    ) async throws {
        if let requestedMode = requestedMode?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedMode.isEmpty {
            try await AgentRuntimeOperationOwner.$session.withValue(runtimeOwner) {
                try await controller.setSessionMode(requestedMode)
            }
        }
    }

    private func applyExplicitSelectedModelIfNeeded(
        _ runRequest: ACPRunRequest,
        controller: ACPAgentSessionController,
        runID: UUID
    ) async throws {
        guard runRequest.agentKind == .openCode || runRequest.agentKind == .cursor || runRequest.agentKind == .ohMyPi else { return }
        guard let model = runRequest.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return
        }
        if runRequest.agentKind == .cursor,
           let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor),
           !Self.cursorRegistryAllowsSelectedModel(model, snapshot: snapshot)
        {
            return
        }
        log("applying \(runRequest.agentKind.displayName) selected model=\(model)", runID: runID)
        if runRequest.agentKind == .ohMyPi {
            try await controller.setSessionSelection(
                model: model,
                additionalOptions: runRequest.additionalConfigOptionValues
            )
        } else {
            try await controller.setSessionModel(model)
        }
    }

    static func cursorRegistryAllowsSelectedModel(
        _ model: String,
        snapshot: ACPDiscoveredSessionModels?
    ) -> Bool {
        CursorModelRegistryGate.allows(model, in: snapshot)
    }

    private func promptFailureErrorText(
        outcome: ConsumeEventsOutcome,
        fallback: String
    ) -> String {
        let unexpectedStreamEnd = "ACP events stream ended unexpectedly."
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let outcomeError = outcome.errorText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !outcomeError.isEmpty,
              outcomeError != unexpectedStreamEnd
        else {
            return trimmedFallback.isEmpty ? unexpectedStreamEnd : trimmedFallback
        }
        return outcomeError
    }

    private func consumeEvents(
        _ events: AsyncStream<NormalizedAgentRuntimeEvent>,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async -> ConsumeEventsOutcome {
        if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
            session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
        }
        for await event in events {
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID
            else {
                return ConsumeEventsOutcome(terminalState: .cancelled, errorText: nil)
            }

            if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
            }
            switch event {
            case let .stream(result):
                await hooks.handleHeadlessStreamResult(result, session, runID, runAttemptID)
            case let .approvalRequested(request):
                session.pendingApproval = request
                session.runState = .waitingForApproval
                setRunningStatus(nil, source: nil, session: session, urgent: true)
            case let .approvalCancelled(requestID):
                if session.pendingApproval?.requestID == requestID {
                    session.pendingApproval = nil
                    if session.runState == .waitingForApproval {
                        session.runState = .running
                        setRunningStatus("Thinking…", source: .transport, session: session, urgent: true)
                    } else {
                        hooks.updateBindings(session)
                    }
                }
            case let .terminal(state, errorText):
                if session.pendingSupersedingTurnCompletions > 0 {
                    session.pendingSupersedingTurnCompletions -= 1
                    if session.runState.isActive {
                        session.runState = .running
                        setRunningStatus("Thinking…", source: .transport, session: session, urgent: true)
                    }
                    continue
                }
                return ConsumeEventsOutcome(terminalState: state, errorText: errorText)
            }
        }

        return ConsumeEventsOutcome(
            terminalState: .failed,
            errorText: "ACP events stream ended unexpectedly."
        )
    }

    private func handleAcquireFailure(
        tabID _: UUID,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController,
        lease _: MCPBootstrapLease,
        attachmentReservationID: UUID?
    ) async {
        guard let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else { return }
        // The staged input is released by the owning task's handoff settlement (never handed off).
        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: runID,
            terminalState: .cancelled,
            source: "acp.acquireFailure",
            cause: .ordinary,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            prepareProviderState: {
                if session.acpController === controller {
                    session.acpController = nil
                }
                AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                return { await controller.shutdown() }
            }
        ))
    }

    private func finalize(
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController?,
        attachmentReservationID: UUID?,
        terminalState: AgentSessionRunState,
        errorText: String?,
        notifyTurnComplete: Bool,
        shouldShutdownController: Bool,
        completion: AgentModeRunService.CancellationCompletion = .terminalPublished,
        cause: AgentRunTerminalCause = .ordinary
    ) async {
        let finalizeErrorDescription = errorText ?? "nil"
        log("finalize requested state=\(terminalState.rawValue) error=\(finalizeErrorDescription)", runID: runID)
        guard let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else {
            log("finalize ignored; session no longer owns run", runID: runID)
            return
        }
        if session.selectedAgent == .ohMyPi,
           toolTrackingRunIDByTabID[session.tabID] == runID
        {
            await toolTrackingByTabID[session.tabID]?.waitForPendingEventDeliveries()
            materializePendingOMPProviderFailures(for: session)
        }
        let supportsSessionResume = terminalState == .completed && controller != nil
        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: runID,
            terminalState: terminalState,
            source: "acp.finalize",
            cause: cause,
            completion: completion,
            errorText: errorText,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: supportsSessionResume,
            notifyTurnComplete: notifyTurnComplete,
            prepareProviderState: {
                session.pendingSupersedingTurnCompletions = 0
                if terminalState != .completed {
                    if let controller, session.acpController === controller {
                        session.acpController = nil
                    }
                    AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                } else if session.acpController == nil {
                    AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                }
                return {
                    if shouldShutdownController, let controller {
                        await controller.shutdown()
                    }
                }
            }
        ))
    }

    // MARK: - Tool Tracking (per-tab, using shared AgentToolTrackingController)

    private func startToolTracking(
        for session: AgentTabSession,
        runID: UUID,
        clientNameHint: String
    ) async {
        guard session.runID == runID, session.runState.isActive else { return }
        #if DEBUG
            print("[ACPAgentRunToolTracking] ACP startToolTracking session=\(session.activeAgentSessionID?.uuidString ?? "nil") tab=\(session.tabID.uuidString) agent=\(session.selectedAgent.rawValue) runID=\(runID.uuidString) clientHint=\(clientNameHint)")
        #endif
        resetACPToolCorrelation(for: session.tabID)
        toolTrackingRunIDByTabID[session.tabID] = runID
        let controller = toolTrackingByTabID[session.tabID] ?? {
            let c = AgentToolTrackingController(mcpHost: mcpHost)
            toolTrackingByTabID[session.tabID] = c
            return c
        }()
        await controller.startTracking(
            runID: runID,
            clientNameHint: clientNameHint,
            observationPolicy: session.selectedAgent == .ohMyPi
                ? .executionAndPreExecutionDenials
                : .executionOnly,
            onCalled: { [weak self, weak session] invocationID, toolName, args in
                guard let self, let session else { return }
                handleTrackerToolCall(invocationID: invocationID, toolName: toolName, args: args, session: session)
            },
            onCompleted: { [weak self, weak session] invocationID, toolName, args, resultJSON, isError in
                guard let self, let session else { return }
                handleTrackerToolResult(invocationID: invocationID, toolName: toolName, args: args, resultJSON: resultJSON, isError: isError, session: session)
            }
        )
    }

    private func prepareToolTrackingTeardown(
        for session: AgentTabSession,
        matchingRunID: UUID? = nil
    ) -> AgentRunAttemptTerminalResources.Teardown? {
        prepareToolTrackingTeardown(
            tabID: session.tabID,
            matchingRunID: matchingRunID,
            session: session
        )
    }

    private func prepareToolTrackingTeardown(
        tabID: UUID,
        matchingRunID: UUID? = nil,
        session: AgentTabSession? = nil
    ) -> AgentRunAttemptTerminalResources.Teardown? {
        if let matchingRunID, toolTrackingRunIDByTabID[tabID] != matchingRunID {
            return nil
        }
        let stoppedRunID = toolTrackingRunIDByTabID.removeValue(forKey: tabID)
        let pendingFailures = takePendingOMPProviderFailures(for: tabID)
        resetACPToolCorrelation(for: tabID)
        guard let controller = toolTrackingByTabID.removeValue(forKey: tabID) else { return nil }
        #if DEBUG
            let stoppedHook = ompQualificationStartupProbes.toolTrackingStopped
        #endif
        // State is detached synchronously above. A successor run can start while stopTracking
        // drains without inheriting credits, failures, seen terminal IDs, or ACP correlation.
        return { [weak self, session] in
            await controller.stopTracking()
            if let self, let session {
                materializeOMPProviderFailures(pendingFailures, for: session)
            }
            #if DEBUG
                if let stoppedRunID {
                    stoppedHook(stoppedRunID)
                }
            #endif
        }
    }

    private func teardownToolTrackingAfterSessionLoss(
        tabID: UUID,
        runID: UUID,
        session: AgentTabSession? = nil
    ) async {
        let teardown = prepareToolTrackingTeardown(
            tabID: tabID,
            matchingRunID: runID,
            session: session
        )
        await teardown?()
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
        guard session.runningStatusText != value || session.runningStatusSource != normalizedSource else {
            if urgent {
                hooks.updateBindings(session)
                hooks.requestUIRefresh(session.tabID, true)
            }
            return
        }
        session.runningStatusText = value
        session.runningStatusSource = normalizedSource
        hooks.updateBindings(session)
        hooks.requestUIRefresh(session.tabID, urgent)
    }

    private func initialTransportStatusText(for _: AgentProviderKind) -> String {
        "Preparing…"
    }

    private func waitingForConnectionStatusText(for _: AgentProviderKind) -> String {
        "Waiting for connection…"
    }

    // MARK: - Tracker Callbacks

    private func handleTrackerToolCall(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        session: AgentTabSession
    ) {
        guard AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return }
        guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }
        #if DEBUG
            if MCPIntegrationHelper.normalizedRepoPromptToolName(toolName) == "agent_run" {
                print("[ACPAgentRunToolTracking] ACP tracker call session=\(session.activeAgentSessionID?.uuidString ?? "nil") invocation=\(invocationID.uuidString) tool=\(toolName) itemCountBefore=\(session.items.count)")
            }
        #endif
        toolTrackingHooks.flushPendingAssistantDelta(session)
        toolTrackingHooks.endActiveAssistantSegment(session)
        toolTrackingHooks.endActiveReasoningSegment(session)
        let argsJSON = AgentToolTrackingController.encodeArgsToJSON(args)
        let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(toolName) ?? toolName
        if let index = correlatedToolCallItemIndex(
            in: session,
            storedToolName: storedToolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            allowNameOnlyFallback: false
        ) {
            var updated = session.items[index]
            let hadArgs = hasAccountableToolPayload(updated.toolArgsJSON)
            if let existingInvocationID = updated.toolInvocationID,
               existingInvocationID != invocationID
            {
                recordProviderInvocation(existingInvocationID, forTrackerInvocationID: invocationID, tabID: session.tabID)
                removeProviderPlaceholderInvocation(existingInvocationID, tabID: session.tabID)
            } else {
                updated.toolInvocationID = invocationID
            }
            updated.toolName = storedToolName
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            if updated.kind == .toolCall {
                updated.text = argsJSON ?? ""
            }
            if !hadArgs, hasAccountableToolPayload(argsJSON) {
                toolTrackingHooks.addToolInputTokens(argsJSON, session)
            }
            session.replaceItem(at: index, with: updated)
        } else if let index = correlatedToolResultItemIndex(
            in: session,
            storedToolName: storedToolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            allowNameOnlyFallback: false
        ) {
            var updated = session.items[index]
            let hadArgs = hasAccountableToolPayload(updated.toolArgsJSON)
            if let existingInvocationID = updated.toolInvocationID,
               existingInvocationID != invocationID
            {
                recordProviderInvocation(existingInvocationID, forTrackerInvocationID: invocationID, tabID: session.tabID)
                removeProviderPlaceholderInvocation(existingInvocationID, tabID: session.tabID)
            } else {
                updated.toolInvocationID = invocationID
            }
            updated.toolName = storedToolName
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            if !hadArgs, hasAccountableToolPayload(argsJSON) {
                toolTrackingHooks.addToolInputTokens(argsJSON, session)
            }
            session.replaceItem(at: index, with: updated)
        } else {
            if hasAccountableToolPayload(argsJSON) {
                toolTrackingHooks.addToolInputTokens(argsJSON, session)
            }
            let toolItem = AgentChatItem.toolCall(
                name: storedToolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(toolItem)
        }
        toolTrackingHooks.requestUIRefresh(session.tabID, false)
        toolTrackingHooks.scheduleSave(session.tabID)
    }

    private func handleTrackerToolResult(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        resultJSON: String,
        isError: Bool,
        session: AgentTabSession
    ) {
        if isError {
            recordOMPTrackerErrorCredit(for: session)
        }
        guard AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return }
        guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }
        #if DEBUG
            if MCPIntegrationHelper.normalizedRepoPromptToolName(toolName) == "agent_run" {
                print("[ACPAgentRunToolTracking] ACP tracker result session=\(session.activeAgentSessionID?.uuidString ?? "nil") invocation=\(invocationID.uuidString) tool=\(toolName) isError=\(isError) resultChars=\(resultJSON.count) itemCountBefore=\(session.items.count)")
            }
        #endif
        toolTrackingHooks.flushPendingAssistantDelta(session)
        toolTrackingHooks.endActiveAssistantSegment(session)
        toolTrackingHooks.endActiveReasoningSegment(session)
        let argsJSON = AgentToolTrackingController.encodeArgsToJSON(args)
        let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(toolName) ?? toolName
        let resolvedInvocationID = consumeProviderInvocation(forTrackerInvocationID: invocationID, tabID: session.tabID) ?? invocationID
        if let index = correlatedToolResultItemIndex(
            in: session,
            storedToolName: storedToolName,
            invocationID: resolvedInvocationID,
            argsJSON: argsJSON,
            allowNameOnlyFallback: true
        ) {
            var updated = session.items[index]
            let hadResult = hasNonEmptyPayload(updated.toolResultJSON)
            updated.kind = .toolResult
            if let existingInvocationID = updated.toolInvocationID,
               existingInvocationID != resolvedInvocationID
            {
                recordProviderInvocation(existingInvocationID, forTrackerInvocationID: invocationID, tabID: session.tabID)
            } else {
                updated.toolInvocationID = resolvedInvocationID
            }
            updated.toolName = storedToolName
            updated.toolResultJSON = resultJSON
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            updated.toolIsError = isError
            updated.text = resultJSON
            if !hadResult, hasNonEmptyPayload(resultJSON) {
                toolTrackingHooks.addToolOutputTokens(resultJSON, session)
            }
            session.replaceItem(at: index, with: updated)
        } else {
            if hasNonEmptyPayload(resultJSON) {
                toolTrackingHooks.addToolOutputTokens(resultJSON, session)
            }
            var toolResultItem = AgentChatItem.toolResult(
                name: storedToolName,
                invocationID: resolvedInvocationID,
                resultJSON: resultJSON,
                isError: isError,
                sequenceIndex: session.nextSequenceIndex
            )
            toolResultItem.toolArgsJSON = argsJSON
            session.appendItem(toolResultItem)
        }
        toolTrackingHooks.requestUIRefresh(session.tabID, false)
        toolTrackingHooks.scheduleSave(session.tabID)
    }

    private func indexedThenActiveTurnToolCandidates(
        indexedIndices: [Int],
        session: AgentTabSession,
        where predicate: (AgentChatItem) -> Bool
    ) -> (indices: [Int], inspectedItemCount: Int, usedFallbackScan: Bool) {
        let indexedMatches = indexedIndices.filter { predicate(session.items[$0]) }
        if !indexedMatches.isEmpty || !indexedIndices.isEmpty {
            return (indexedMatches, indexedIndices.count, false)
        }
        let fallback = session.activeTurnToolItemIndices(where: predicate)
        return (
            fallback.indices,
            indexedIndices.count + fallback.scannedItemCount,
            !fallback.indices.isEmpty
        )
    }

    private func correlatedToolCallItemIndex(
        in session: AgentTabSession,
        storedToolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        allowNameOnlyFallback: Bool
    ) -> Int? {
        var inspectedItemCount = 0
        if let invocationID {
            let candidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: session.indexedToolItemIndices(invocationID: invocationID),
                session: session,
                where: {
                    $0.kind == .toolCall
                        && $0.toolInvocationID == invocationID
                        && self.shouldUpdateExistingToolCall(
                            $0,
                            storedToolName: storedToolName,
                            argsJSON: argsJSON,
                            tabID: session.tabID
                        )
                }
            )
            inspectedItemCount += candidates.inspectedItemCount
            if let index = candidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: candidates.usedFallbackScan ? "invocation_id_active_turn_scan" : "invocation_id",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
        }
        if let argsJSON {
            let signature = toolInvocationSignature(toolName: storedToolName, argsJSON: argsJSON)
            let candidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: session.indexedToolItemIndices(
                    signature: signature,
                    pendingCallsOnly: true
                ),
                session: session,
                where: {
                    $0.kind == .toolCall
                        && self.toolInvocationSignature(toolName: $0.toolName, argsJSON: $0.toolArgsJSON) == signature
                }
            )
            inspectedItemCount += candidates.inspectedItemCount
            if let index = candidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: candidates.usedFallbackScan ? "signature_active_turn_scan" : "signature",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
        }
        if let argsJSON,
           hasAccountableToolPayload(argsJSON)
        {
            let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(storedToolName)
            let placeholderCandidates = session.activeTurnToolItemIndices(where: { item in
                item.kind == .toolCall
                    && self.isProviderPlaceholderInvocation(item.toolInvocationID, tabID: session.tabID)
                    && self.isPlaceholderToolArgs(item.toolArgsJSON)
                    && AgentTabSession.normalizedToolCorrelationName(item.toolName) == normalizedToolName
            })
            inspectedItemCount += placeholderCandidates.scannedItemCount
            if placeholderCandidates.indices.count == 1 {
                MCPToolObserverAttributionContext.record(
                    correlationPath: "placeholder_active_turn_scan",
                    scannedItemCount: inspectedItemCount
                )
                return placeholderCandidates.indices[0]
            }
        }
        if allowNameOnlyFallback {
            let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(storedToolName)
            let fallback = session.activeTurnToolItemIndices(where: {
                $0.kind == .toolCall
                    && AgentTabSession.normalizedToolCorrelationName($0.toolName) == normalizedToolName
            })
            inspectedItemCount += fallback.scannedItemCount
            MCPToolObserverAttributionContext.record(
                correlationPath: fallback.lastIndex == nil ? "none" : "name_active_turn_scan",
                scannedItemCount: inspectedItemCount
            )
            return fallback.lastIndex
        }
        MCPToolObserverAttributionContext.record(
            correlationPath: "none",
            scannedItemCount: inspectedItemCount
        )
        return nil
    }

    private func correlatedToolResultItemIndex(
        in session: AgentTabSession,
        storedToolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        allowNameOnlyFallback: Bool
    ) -> Int? {
        var inspectedItemCount = 0
        if let invocationID {
            let callCandidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: session.indexedToolItemIndices(invocationID: invocationID),
                session: session,
                where: {
                    $0.kind == .toolCall
                        && $0.toolInvocationID == invocationID
                        && self.shouldUpdateExistingToolCall(
                            $0,
                            storedToolName: storedToolName,
                            argsJSON: argsJSON,
                            tabID: session.tabID
                        )
                }
            )
            inspectedItemCount += callCandidates.inspectedItemCount
            if let index = callCandidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: callCandidates.usedFallbackScan
                        ? "invocation_id_call_active_turn_scan"
                        : "invocation_id_call",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
            let resultCandidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: session.indexedToolItemIndices(invocationID: invocationID),
                session: session,
                where: {
                    $0.kind == .toolResult
                        && $0.toolInvocationID == invocationID
                        && self.shouldUpdateExistingToolResult(
                            $0,
                            storedToolName: storedToolName,
                            argsJSON: argsJSON,
                            tabID: session.tabID
                        )
                }
            )
            inspectedItemCount += resultCandidates.inspectedItemCount
            if let index = resultCandidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: resultCandidates.usedFallbackScan
                        ? "invocation_id_result_active_turn_scan"
                        : "invocation_id_result",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
        }
        let signature = toolInvocationSignature(toolName: storedToolName, argsJSON: argsJSON)
        if argsJSON != nil {
            let signatureIndices = session.indexedToolItemIndices(signature: signature)
            let callCandidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: signatureIndices,
                session: session,
                where: {
                    $0.kind == .toolCall
                        && self.toolInvocationSignature(toolName: $0.toolName, argsJSON: $0.toolArgsJSON) == signature
                }
            )
            inspectedItemCount += callCandidates.inspectedItemCount
            if let index = callCandidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: callCandidates.usedFallbackScan
                        ? "signature_call_active_turn_scan"
                        : "signature_call",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
            let resultCandidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: signatureIndices,
                session: session,
                where: {
                    $0.kind == .toolResult
                        && self.toolInvocationSignature(toolName: $0.toolName, argsJSON: $0.toolArgsJSON) == signature
                }
            )
            inspectedItemCount += resultCandidates.inspectedItemCount
            if let index = resultCandidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: resultCandidates.usedFallbackScan
                        ? "signature_result_active_turn_scan"
                        : "signature_result",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
        }
        if allowNameOnlyFallback {
            let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(storedToolName)
            let fallback = session.activeTurnToolItemIndices(where: {
                $0.kind == .toolCall
                    && AgentTabSession.normalizedToolCorrelationName($0.toolName) == normalizedToolName
            })
            inspectedItemCount += fallback.scannedItemCount
            MCPToolObserverAttributionContext.record(
                correlationPath: fallback.lastIndex == nil ? "none" : "name_active_turn_scan",
                scannedItemCount: inspectedItemCount
            )
            return fallback.lastIndex
        }
        MCPToolObserverAttributionContext.record(
            correlationPath: "none",
            scannedItemCount: inspectedItemCount
        )
        return nil
    }

    private func shouldUpdateExistingToolCall(
        _ item: AgentChatItem,
        storedToolName: String,
        argsJSON: String?,
        tabID: UUID
    ) -> Bool {
        guard item.kind == .toolCall else { return false }
        return hasExactToolInvocationSignature(item, storedToolName: storedToolName, argsJSON: argsJSON)
            || hasSameNormalizedToolName(item.toolName, storedToolName)
            || isKnownProviderPlaceholder(item, tabID: tabID)
    }

    private func shouldUpdateExistingToolResult(
        _ item: AgentChatItem,
        storedToolName: String,
        argsJSON: String?,
        tabID: UUID
    ) -> Bool {
        guard item.kind == .toolResult else { return false }
        if hasExactToolInvocationSignature(item, storedToolName: storedToolName, argsJSON: argsJSON) {
            return true
        }
        switch AgentTranscriptToolNormalizer.status(for: item) {
        case .pending, .running:
            return hasSameNormalizedToolName(item.toolName, storedToolName)
                || isKnownProviderPlaceholder(item, tabID: tabID)
        case .success, .warning, .failed, .cancelled, .unknown:
            return false
        }
    }

    private func hasExactToolInvocationSignature(
        _ item: AgentChatItem,
        storedToolName: String,
        argsJSON: String?
    ) -> Bool {
        toolInvocationSignature(toolName: item.toolName, argsJSON: item.toolArgsJSON)
            == toolInvocationSignature(toolName: storedToolName, argsJSON: argsJSON)
    }

    private func hasSameNormalizedToolName(_ existingToolName: String?, _ incomingToolName: String) -> Bool {
        let existing = MCPIntegrationHelper.normalizedRepoPromptToolName(existingToolName ?? "")
        let incoming = MCPIntegrationHelper.normalizedRepoPromptToolName(incomingToolName)
        return !existing.isEmpty && existing == incoming
    }

    private func isKnownProviderPlaceholder(_ item: AgentChatItem, tabID: UUID) -> Bool {
        isProviderPlaceholderInvocation(item.toolInvocationID, tabID: tabID)
            && isPlaceholderToolArgs(item.toolArgsJSON)
    }

    private func recordProviderInvocation(_ providerInvocationID: UUID, forTrackerInvocationID trackerInvocationID: UUID, tabID: UUID) {
        var mappings = acpProviderInvocationByTrackerInvocationIDByTabID[tabID, default: [:]]
        mappings[trackerInvocationID] = providerInvocationID
        acpProviderInvocationByTrackerInvocationIDByTabID[tabID] = mappings
    }

    private func recordProviderPlaceholderInvocationIfNeeded(_ invocationID: UUID?, argsJSON: String?, tabID: UUID) {
        guard let invocationID, isPlaceholderToolArgs(argsJSON) else { return }
        var placeholders = acpProviderPlaceholderInvocationIDsByTabID[tabID, default: []]
        placeholders.insert(invocationID)
        acpProviderPlaceholderInvocationIDsByTabID[tabID] = placeholders
    }

    private func removeProviderPlaceholderInvocation(_ invocationID: UUID?, tabID: UUID) {
        guard let invocationID,
              var placeholders = acpProviderPlaceholderInvocationIDsByTabID[tabID] else { return }
        placeholders.remove(invocationID)
        acpProviderPlaceholderInvocationIDsByTabID[tabID] = placeholders.isEmpty ? nil : placeholders
    }

    private func isProviderPlaceholderInvocation(_ invocationID: UUID?, tabID: UUID) -> Bool {
        guard let invocationID else { return false }
        return acpProviderPlaceholderInvocationIDsByTabID[tabID]?.contains(invocationID) == true
    }

    private func consumeProviderInvocation(forTrackerInvocationID trackerInvocationID: UUID, tabID: UUID) -> UUID? {
        guard var mappings = acpProviderInvocationByTrackerInvocationIDByTabID[tabID] else { return nil }
        let providerInvocationID = mappings.removeValue(forKey: trackerInvocationID)
        acpProviderInvocationByTrackerInvocationIDByTabID[tabID] = mappings.isEmpty ? nil : mappings
        return providerInvocationID
    }

    private func isOMPToolTrackingActive(for session: AgentTabSession) -> Bool {
        guard session.selectedAgent == .ohMyPi, let runID = session.runID else { return false }
        return toolTrackingRunIDByTabID[session.tabID] == runID
    }

    private func recordOMPTrackerErrorCredit(for session: AgentTabSession) {
        guard isOMPToolTrackingActive(for: session) else { return }
        // Credits only apply to provider failures that arrive later. Consuming an earlier
        // unmatched failure would hide evidence from an unrelated denied/cancelled call.
        trackerErrorCreditsByTabID[session.tabID, default: 0] += 1
    }

    private func recordOMPProviderFailure(
        toolCallID: UUID?,
        title: String,
        rawInput: String?,
        session: AgentTabSession
    ) {
        let tabID = session.tabID
        if let toolCallID {
            guard seenOMPProviderFailureIDsByTabID[tabID, default: []].insert(toolCallID).inserted else {
                return
            }
        }
        if let credits = trackerErrorCreditsByTabID[tabID], credits > 0 {
            trackerErrorCreditsByTabID[tabID] = credits == 1 ? nil : credits - 1
            return
        }
        guard pendingOMPProviderFailuresByTabID[tabID, default: []].count
            < Self.maxPendingOMPProviderFailures else { return }
        pendingOMPProviderFailuresByTabID[tabID, default: []].append(.init(
            toolCallID: toolCallID,
            title: title,
            rawInput: rawInput
        ))
    }

    private func takePendingOMPProviderFailures(for tabID: UUID) -> [PendingOMPProviderFailure] {
        let pending = pendingOMPProviderFailuresByTabID.removeValue(forKey: tabID) ?? []
        trackerErrorCreditsByTabID[tabID] = nil
        return pending
    }

    private func materializePendingOMPProviderFailures(for session: AgentTabSession) {
        materializeOMPProviderFailures(
            takePendingOMPProviderFailures(for: session.tabID),
            for: session
        )
    }

    private func materializeOMPProviderFailures(
        _ pending: [PendingOMPProviderFailure],
        for session: AgentTabSession
    ) {
        guard !pending.isEmpty else { return }
        let tabID = session.tabID
        toolTrackingHooks.flushPendingAssistantDelta(session)
        toolTrackingHooks.endActiveAssistantSegment(session)
        toolTrackingHooks.endActiveReasoningSegment(session)
        for failure in pending {
            var item = AgentChatItem.toolResult(
                name: failure.title,
                invocationID: failure.toolCallID,
                resultJSON: Self.ompUncorrelatedFailureJSON,
                isError: true,
                sequenceIndex: session.nextSequenceIndex
            )
            item.toolArgsJSON = failure.rawInput
            session.appendItem(item)
        }
        toolTrackingHooks.requestUIRefresh(tabID, false)
        toolTrackingHooks.scheduleSave(tabID)
    }

    private func resetACPToolCorrelation(for tabID: UUID) {
        acpProviderInvocationByTrackerInvocationIDByTabID[tabID] = nil
        acpProviderPlaceholderInvocationIDsByTabID[tabID] = nil
        trackerErrorCreditsByTabID[tabID] = nil
        pendingOMPProviderFailuresByTabID[tabID] = nil
        seenOMPProviderFailureIDsByTabID[tabID] = nil
    }

    private func toolInvocationSignature(toolName: String?, argsJSON: String?) -> String {
        AgentTabSession.canonicalToolInvocationSignature(
            toolName: toolName,
            argsJSON: argsJSON
        )
    }

    private func hasNonEmptyPayload(_ payload: String?) -> Bool {
        payload?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func hasAccountableToolPayload(_ payload: String?) -> Bool {
        hasNonEmptyPayload(payload) && !isPlaceholderToolArgs(payload)
    }

    private func isPlaceholderToolArgs(_ payload: String?) -> Bool {
        guard let payload = payload?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
            return true
        }
        return canonicalizedJSON(payload) == "{}"
    }

    private func canonicalizedJSON(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard JSONSerialization.isValidJSONObject(object),
              let canonicalData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let canonical = String(data: canonicalData, encoding: .utf8)
        else {
            return raw
        }
        return canonical
    }

    #if DEBUG
        func testInstallOMPToolTrackingAuthority(
            session: AgentTabSession,
            runID: UUID
        ) {
            resetACPToolCorrelation(for: session.tabID)
            toolTrackingRunIDByTabID[session.tabID] = runID
        }

        func testMaterializePendingOMPProviderFailures(
            session: AgentTabSession
        ) {
            materializePendingOMPProviderFailures(for: session)
        }

        func testOMPTranscriptAuthorityState(
            tabID: UUID
        ) -> (credits: Int, pendingCount: Int, seenTerminalCount: Int, runID: UUID?) {
            (
                trackerErrorCreditsByTabID[tabID] ?? 0,
                pendingOMPProviderFailuresByTabID[tabID]?.count ?? 0,
                seenOMPProviderFailureIDsByTabID[tabID]?.count ?? 0,
                toolTrackingRunIDByTabID[tabID]
            )
        }

        func testPrepareToolTrackingTeardownState(
            session: AgentTabSession,
            matchingRunID: UUID
        ) {
            _ = prepareToolTrackingTeardown(for: session, matchingRunID: matchingRunID)
        }

        func testHandleTrackerToolCall(
            invocationID: UUID,
            toolName: String,
            args: [String: Value]?,
            session: AgentTabSession
        ) {
            handleTrackerToolCall(invocationID: invocationID, toolName: toolName, args: args, session: session)
        }

        func testHandleTrackerToolResult(
            invocationID: UUID,
            toolName: String,
            args: [String: Value]?,
            resultJSON: String,
            isError: Bool,
            session: AgentTabSession
        ) {
            handleTrackerToolResult(
                invocationID: invocationID,
                toolName: toolName,
                args: args,
                resultJSON: resultJSON,
                isError: isError,
                session: session
            )
        }

        func testSyncACPSelectedModelFromRegistryIfNeeded(
            agentKind: AgentProviderKind,
            session: AgentTabSession
        ) -> Bool {
            syncACPSelectedModelFromRegistryIfNeeded(agentKind: agentKind, session: session)
        }
    #endif

    // MARK: - Provider Stream Tool Event Handling

    private func syncACPSelectedModelFromRegistryIfNeeded(
        agentKind: AgentProviderKind,
        session: AgentTabSession
    ) -> Bool {
        guard let providerID = agentKind.acpProviderID,
              let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: providerID)
        else {
            return false
        }
        let selectedModelRaw = session.selectedModelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedIsDefault = selectedModelRaw.isEmpty
            || selectedModelRaw.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame
        let selectedOption = snapshot.option(matching: selectedModelRaw)
        let selectedIsPlaceholder = selectedIsDefault || selectedOption?.isPlaceholderDefault == true
        guard selectedIsPlaceholder else { return false }
        if let preferredModelRaw = snapshot.preferredModelRaw,
           session.selectedModelRaw.caseInsensitiveCompare(preferredModelRaw) != .orderedSame
        {
            session.selectedModelRaw = preferredModelRaw
            return true
        }
        if !snapshot.contains(rawModel: session.selectedModelRaw) {
            session.selectedModelRaw = AgentModelCatalog.defaultModelRaw(for: agentKind)
            return true
        }
        return false
    }

    @discardableResult
    func handleToolStreamEvent(
        _ event: AgentToolStreamEvent,
        session: AgentTabSession
    ) -> Bool {
        // For the exact managed OMP run, the MCP tracker is the transcript and token
        // authority. Provider titles are intentionally not inspected for identity.
        if isOMPToolTrackingActive(for: session) {
            if case let .toolResult(result) = event, result.isError == true {
                recordOMPProviderFailure(
                    toolCallID: result.invocationID,
                    title: result.toolName,
                    rawInput: result.argsJSON,
                    session: session
                )
            }
            return true
        }

        // ACP provider events carry the provider's tool invocation IDs, while the
        // MCP tracker sees RepoPrompt's internal invocation IDs. Render explicit
        // RepoPrompt tool cards here so AgentModeViewModel can remain provider-neutral.
        switch event {
        case let .toolCall(call):
            guard AgentToolTrackingSupport.isRepoPromptTool(call.toolName) else { return false }
            guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(call.toolName) else { return true }
            #if DEBUG
                if MCPIntegrationHelper.normalizedRepoPromptToolName(call.toolName) == "agent_run" {
                    print("[ACPAgentRunToolTracking] ACP provider tool_call session=\(session.activeAgentSessionID?.uuidString ?? "nil") invocation=\(call.invocationID?.uuidString ?? "nil") tool=\(call.toolName) argsChars=\(call.argsJSON?.count ?? 0) itemCountBefore=\(session.items.count)")
                }
            #endif
            toolTrackingHooks.flushPendingAssistantDelta(session)
            toolTrackingHooks.endActiveAssistantSegment(session)
            toolTrackingHooks.endActiveReasoningSegment(session)
            let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(call.toolName) ?? call.toolName
            if let index = correlatedToolCallItemIndex(
                in: session,
                storedToolName: storedToolName,
                invocationID: call.invocationID,
                argsJSON: call.argsJSON,
                allowNameOnlyFallback: false
            ) {
                var updated = session.items[index]
                let hadArgs = hasAccountableToolPayload(updated.toolArgsJSON)
                if let trackerInvocationID = updated.toolInvocationID,
                   let providerInvocationID = call.invocationID,
                   trackerInvocationID != providerInvocationID
                {
                    recordProviderInvocation(providerInvocationID, forTrackerInvocationID: trackerInvocationID, tabID: session.tabID)
                    updated.toolInvocationID = providerInvocationID
                } else {
                    updated.toolInvocationID = updated.toolInvocationID ?? call.invocationID
                }
                updated.toolName = storedToolName
                updated.toolArgsJSON = call.argsJSON ?? updated.toolArgsJSON
                if updated.kind == .toolCall {
                    updated.text = call.argsJSON ?? ""
                }
                if !hadArgs, hasAccountableToolPayload(call.argsJSON) {
                    toolTrackingHooks.addToolInputTokens(call.argsJSON, session)
                }
                session.replaceItem(at: index, with: updated)
            } else if let index = correlatedToolResultItemIndex(
                in: session,
                storedToolName: storedToolName,
                invocationID: call.invocationID,
                argsJSON: call.argsJSON,
                allowNameOnlyFallback: false
            ) {
                var updated = session.items[index]
                let hadArgs = hasAccountableToolPayload(updated.toolArgsJSON)
                if let trackerInvocationID = updated.toolInvocationID,
                   let providerInvocationID = call.invocationID,
                   trackerInvocationID != providerInvocationID
                {
                    recordProviderInvocation(providerInvocationID, forTrackerInvocationID: trackerInvocationID, tabID: session.tabID)
                    updated.toolInvocationID = providerInvocationID
                } else {
                    updated.toolInvocationID = updated.toolInvocationID ?? call.invocationID
                }
                updated.toolName = storedToolName
                updated.toolArgsJSON = call.argsJSON ?? updated.toolArgsJSON
                if !hadArgs, hasAccountableToolPayload(call.argsJSON) {
                    toolTrackingHooks.addToolInputTokens(call.argsJSON, session)
                }
                session.replaceItem(at: index, with: updated)
            } else {
                if hasAccountableToolPayload(call.argsJSON) {
                    toolTrackingHooks.addToolInputTokens(call.argsJSON, session)
                }
                let toolItem = AgentChatItem.toolCall(
                    name: storedToolName,
                    invocationID: call.invocationID,
                    argsJSON: call.argsJSON,
                    sequenceIndex: session.nextSequenceIndex
                )
                session.appendItem(toolItem)
                recordProviderPlaceholderInvocationIfNeeded(call.invocationID, argsJSON: call.argsJSON, tabID: session.tabID)
            }
            toolTrackingHooks.requestUIRefresh(session.tabID, false)
            toolTrackingHooks.scheduleSave(session.tabID)
            return true

        case let .toolResult(result):
            guard AgentToolTrackingSupport.isRepoPromptTool(result.toolName) else { return false }
            guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(result.toolName) else { return true }
            #if DEBUG
                if MCPIntegrationHelper.normalizedRepoPromptToolName(result.toolName) == "agent_run" {
                    print("[ACPAgentRunToolTracking] ACP provider tool_result session=\(session.activeAgentSessionID?.uuidString ?? "nil") invocation=\(result.invocationID?.uuidString ?? "nil") tool=\(result.toolName) isError=\(result.isError) resultChars=\(result.resultJSON.count) itemCountBefore=\(session.items.count)")
                }
            #endif
            toolTrackingHooks.flushPendingAssistantDelta(session)
            toolTrackingHooks.endActiveAssistantSegment(session)
            toolTrackingHooks.endActiveReasoningSegment(session)
            removeProviderPlaceholderInvocation(result.invocationID, tabID: session.tabID)
            let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(result.toolName) ?? result.toolName
            if let index = correlatedToolResultItemIndex(
                in: session,
                storedToolName: storedToolName,
                invocationID: result.invocationID,
                argsJSON: result.argsJSON,
                allowNameOnlyFallback: true
            ) {
                var updated = session.items[index]
                let hadResult = hasNonEmptyPayload(updated.toolResultJSON)
                updated.kind = .toolResult
                updated.toolName = storedToolName
                updated.toolInvocationID = updated.toolInvocationID ?? result.invocationID
                updated.toolResultJSON = result.resultJSON
                updated.toolArgsJSON = result.argsJSON ?? updated.toolArgsJSON
                updated.toolIsError = result.isError
                updated.text = result.resultJSON
                if !hadResult, hasNonEmptyPayload(result.resultJSON) {
                    toolTrackingHooks.addToolOutputTokens(result.resultJSON, session)
                }
                session.replaceItem(at: index, with: updated)
            } else {
                if hasNonEmptyPayload(result.resultJSON) {
                    toolTrackingHooks.addToolOutputTokens(result.resultJSON, session)
                }
                var toolResultItem = AgentChatItem.toolResult(
                    name: storedToolName,
                    invocationID: result.invocationID,
                    resultJSON: result.resultJSON,
                    isError: result.isError,
                    sequenceIndex: session.nextSequenceIndex
                )
                toolResultItem.toolArgsJSON = result.argsJSON
                session.appendItem(toolResultItem)
            }
            toolTrackingHooks.requestUIRefresh(session.tabID, false)
            toolTrackingHooks.scheduleSave(session.tabID)
            return true

        case let .legacyEvent(legacy):
            guard AgentToolTrackingSupport.isRepoPromptTool(legacy.toolName) else { return false }
            guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(legacy.toolName) else { return true }
            toolTrackingHooks.flushPendingAssistantDelta(session)
            toolTrackingHooks.endActiveAssistantSegment(session)
            toolTrackingHooks.endActiveReasoningSegment(session)
            let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(legacy.toolName) ?? legacy.toolName
            let toolItem = AgentChatItem.toolCall(
                name: storedToolName,
                argsJSON: nil,
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(toolItem)
            toolTrackingHooks.requestUIRefresh(session.tabID, false)
            toolTrackingHooks.scheduleSave(session.tabID)
            return true
        }
    }
}

#if DEBUG
    /// Test-only, task-local hold at the existing await after an active ACP steering prompt
    /// returned (before the flush continues). Nil — the default — is a no-op.
    enum ACPActiveSteeringPromptTestHook {
        @TaskLocal static var afterPromptReturned: (@MainActor @Sendable () async -> Void)?
    }
#endif
