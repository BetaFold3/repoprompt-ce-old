import Foundation

@MainActor
package final class AgentModeRunService {
    package struct Dependencies {
        let windowID: Int
        let headlessProviderFactory: AgentHeadlessProviderFactory
        let acpProviderFactory: AgentACPProviderFactory
        let acpControllerFactory: AgentACPControllerFactory
        let connectionPolicyInstaller: AgentConnectionPolicyInstaller
        let expectedPIDPolicyArmer: (MCPBootstrapLeaseSpec) async -> Bool
        let mcpServerEnabler: AgentMCPServerEnabler
        let workspacePathProvider: (AgentTabSession) throws -> String?
        let codexCoordinator: CodexAgentModeCoordinator
        let claudeCoordinator: ClaudeAgentModeCoordinator
        let shouldManageCodexTooling: Bool
        let providerRuntimePermissionResolver: (_ agent: AgentProviderKind, _ profile: AgentProviderPermissionProfile) -> AgentProviderRuntimePermissionBinding
        /// Bounded-delegation run policy (advertisement flag, leaf restrictions) for a session's
        /// current role and lineage, resolved when the run's MCP lease is prepared.
        let delegationRunToolPolicyResolver: (AgentTabSession) -> AgentDelegationPolicy.RunToolPolicy
        /// Promotes an immutable launch review snapshot to the exact process run before its MCP
        /// bootstrap lease can expose nested tools.
        let bindPendingOracleReviewContext: (_ tabID: UUID, _ runID: UUID) -> Void
        let cancelMCPToolsForRun: (_ runID: UUID, _ reason: String) -> Void
        /// Waits until the given runID has zero active MCP tool executions.
        /// Throws `CancellationError` if the calling Task is cancelled.
        let awaitNoActiveMCPTools: (_ runID: UUID) async throws -> Void
        /// Returns whether the parent run is currently blocked in child `agent_run.wait` scopes.
        let activeAgentRunWaitQuery: (_ runID: UUID) -> Bool
        /// Bounded wait for child `agent_run.wait` scopes to drain before Claude native interrupt.
        let childAgentRunWaitDrainTimeoutSeconds: TimeInterval
        #if DEBUG
            package var ompQualificationAuthorizer: (
                OhMyPiAgentModeSmokeGate.StartTransaction,
                UUID
            ) -> OhMyPiAgentModeSmokeGate.ProviderStartAuthorizationDecision = { _, _ in
                .refused(reason: "omp_qualification_authorizer_unconfigured")
            }

            package var ompQualificationActiveWorkspaceID: () -> UUID? = { nil }
            var ompQualificationInvocationContext: (AgentTabSession) -> OhMyPiAgentModeSmokeGate.StartContext? = { _ in
                OhMyPiAgentModeSmokeGate.invocationStartContext
            }

            var testBeforeOMPQualificationProviderAuthorization: () -> Void = {}
            var testOMPQualificationProviderBootstrapEntry: () -> Void = {}
            var ompQualificationStartupProbes = ACPIntegratedAgentModeRunner.OMPQualificationStartupProbes()
            var testOMPQualificationLeaseCreated: (MCPBootstrapLease) -> Void = { _ in }
        #endif

        #if DEBUG
            package init(
                windowID: Int,
                headlessProviderFactory: @escaping AgentHeadlessProviderFactory,
                acpProviderFactory: @escaping AgentACPProviderFactory,
                acpControllerFactory: @escaping AgentACPControllerFactory,
                connectionPolicyInstaller: @escaping AgentConnectionPolicyInstaller,
                expectedPIDPolicyArmer: @escaping (MCPBootstrapLeaseSpec) async -> Bool,
                mcpServerEnabler: @escaping AgentMCPServerEnabler,
                workspacePathProvider: @escaping (AgentTabSession) throws -> String?,
                codexCoordinator: CodexAgentModeCoordinator,
                claudeCoordinator: ClaudeAgentModeCoordinator,
                shouldManageCodexTooling: Bool,
                providerRuntimePermissionResolver: @escaping (_ agent: AgentProviderKind, _ profile: AgentProviderPermissionProfile) -> AgentProviderRuntimePermissionBinding,
                delegationRunToolPolicyResolver: @escaping (AgentTabSession) -> AgentDelegationPolicy.RunToolPolicy,
                bindPendingOracleReviewContext: @escaping (_ tabID: UUID, _ runID: UUID) -> Void,
                cancelMCPToolsForRun: @escaping (_ runID: UUID, _ reason: String) -> Void,
                awaitNoActiveMCPTools: @escaping (_ runID: UUID) async throws -> Void,
                activeAgentRunWaitQuery: @escaping (_ runID: UUID) -> Bool,
                childAgentRunWaitDrainTimeoutSeconds: TimeInterval,
                ompQualificationAuthorizer: @escaping (
                    OhMyPiAgentModeSmokeGate.StartTransaction,
                    UUID
                ) -> OhMyPiAgentModeSmokeGate.ProviderStartAuthorizationDecision = { _, _ in
                    .refused(reason: "omp_qualification_authorizer_unconfigured")
                },
                ompQualificationActiveWorkspaceID: @escaping () -> UUID? = { nil },
                ompQualificationInvocationContext: @escaping (AgentTabSession) -> OhMyPiAgentModeSmokeGate.StartContext? = { _ in
                    OhMyPiAgentModeSmokeGate.invocationStartContext
                },
                testBeforeOMPQualificationProviderAuthorization: @escaping () -> Void = {},
                testOMPQualificationProviderBootstrapEntry: @escaping () -> Void = {},
                ompQualificationStartupProbes: ACPIntegratedAgentModeRunner.OMPQualificationStartupProbes = ACPIntegratedAgentModeRunner.OMPQualificationStartupProbes(),
                testOMPQualificationLeaseCreated: @escaping (MCPBootstrapLease) -> Void = { _ in }
            ) {
                self.windowID = windowID
                self.headlessProviderFactory = headlessProviderFactory
                self.acpProviderFactory = acpProviderFactory
                self.acpControllerFactory = acpControllerFactory
                self.connectionPolicyInstaller = connectionPolicyInstaller
                self.expectedPIDPolicyArmer = expectedPIDPolicyArmer
                self.mcpServerEnabler = mcpServerEnabler
                self.workspacePathProvider = workspacePathProvider
                self.codexCoordinator = codexCoordinator
                self.claudeCoordinator = claudeCoordinator
                self.shouldManageCodexTooling = shouldManageCodexTooling
                self.providerRuntimePermissionResolver = providerRuntimePermissionResolver
                self.delegationRunToolPolicyResolver = delegationRunToolPolicyResolver
                self.bindPendingOracleReviewContext = bindPendingOracleReviewContext
                self.cancelMCPToolsForRun = cancelMCPToolsForRun
                self.awaitNoActiveMCPTools = awaitNoActiveMCPTools
                self.activeAgentRunWaitQuery = activeAgentRunWaitQuery
                self.childAgentRunWaitDrainTimeoutSeconds = childAgentRunWaitDrainTimeoutSeconds
                self.ompQualificationAuthorizer = ompQualificationAuthorizer
                self.ompQualificationActiveWorkspaceID = ompQualificationActiveWorkspaceID
                self.ompQualificationInvocationContext = ompQualificationInvocationContext
                self.testBeforeOMPQualificationProviderAuthorization = testBeforeOMPQualificationProviderAuthorization
                self.testOMPQualificationProviderBootstrapEntry = testOMPQualificationProviderBootstrapEntry
                self.ompQualificationStartupProbes = ompQualificationStartupProbes
                self.testOMPQualificationLeaseCreated = testOMPQualificationLeaseCreated
            }
        #else
            package init(
                windowID: Int,
                headlessProviderFactory: @escaping AgentHeadlessProviderFactory,
                acpProviderFactory: @escaping AgentACPProviderFactory,
                acpControllerFactory: @escaping AgentACPControllerFactory,
                connectionPolicyInstaller: @escaping AgentConnectionPolicyInstaller,
                expectedPIDPolicyArmer: @escaping (MCPBootstrapLeaseSpec) async -> Bool,
                mcpServerEnabler: @escaping AgentMCPServerEnabler,
                workspacePathProvider: @escaping (AgentTabSession) throws -> String?,
                codexCoordinator: CodexAgentModeCoordinator,
                claudeCoordinator: ClaudeAgentModeCoordinator,
                shouldManageCodexTooling: Bool,
                providerRuntimePermissionResolver: @escaping (_ agent: AgentProviderKind, _ profile: AgentProviderPermissionProfile) -> AgentProviderRuntimePermissionBinding,
                delegationRunToolPolicyResolver: @escaping (AgentTabSession) -> AgentDelegationPolicy.RunToolPolicy,
                bindPendingOracleReviewContext: @escaping (_ tabID: UUID, _ runID: UUID) -> Void,
                cancelMCPToolsForRun: @escaping (_ runID: UUID, _ reason: String) -> Void,
                awaitNoActiveMCPTools: @escaping (_ runID: UUID) async throws -> Void,
                activeAgentRunWaitQuery: @escaping (_ runID: UUID) -> Bool,
                childAgentRunWaitDrainTimeoutSeconds: TimeInterval
            ) {
                self.windowID = windowID
                self.headlessProviderFactory = headlessProviderFactory
                self.acpProviderFactory = acpProviderFactory
                self.acpControllerFactory = acpControllerFactory
                self.connectionPolicyInstaller = connectionPolicyInstaller
                self.expectedPIDPolicyArmer = expectedPIDPolicyArmer
                self.mcpServerEnabler = mcpServerEnabler
                self.workspacePathProvider = workspacePathProvider
                self.codexCoordinator = codexCoordinator
                self.claudeCoordinator = claudeCoordinator
                self.shouldManageCodexTooling = shouldManageCodexTooling
                self.providerRuntimePermissionResolver = providerRuntimePermissionResolver
                self.delegationRunToolPolicyResolver = delegationRunToolPolicyResolver
                self.bindPendingOracleReviewContext = bindPendingOracleReviewContext
                self.cancelMCPToolsForRun = cancelMCPToolsForRun
                self.awaitNoActiveMCPTools = awaitNoActiveMCPTools
                self.activeAgentRunWaitQuery = activeAgentRunWaitQuery
                self.childAgentRunWaitDrainTimeoutSeconds = childAgentRunWaitDrainTimeoutSeconds
            }
        #endif
    }

    package enum CancellationIntent {
        case userStop
        case executionLocationChange
    }

    package enum CancellationCompletion: Equatable {
        /// Return after canonical terminal publication and synchronous provider detachment.
        case terminalPublished
        /// Also wait for the exactly-once attempt/provider teardown closure to return.
        case terminalTeardownCompleted
    }

    /// Strategy for restoring draft text back to the composer.
    package enum DraftRestorationStrategy: Equatable {
        /// Only restore if the composer is currently empty.
        case replaceIfEmpty
        /// Always prepend the restored text, even if the user has started typing.
        case prependAlways
    }

    package struct Hooks {
        let estimateRuntimeTokens: (String) -> Int
        let addUserInputTokensToActiveNonCodexTurn: (Int, AgentTabSession) -> Void
        let startNonCodexTurnAccountingIfNeeded: (AgentTabSession, String) -> Void
        let reserveAttachmentsForTurn: ([AgentImageAttachment], AgentTabSession) -> UUID?
        let markAttachmentsConsumed: (AgentTabSession, UUID?) -> Void
        let stageConsumedAttachmentFilesForDeferredCleanup: ([AgentImageAttachment], AgentTabSession) -> Void
        let consumeDeferredAttachmentCleanup: (AgentTabSession, Bool) -> Void
        let finalizeAttachmentsForTurn: (
            AgentTabSession,
            UUID?,
            [AgentImageAttachment],
            AgentAttachmentTurnDisposition
        ) -> Void
        let finalizeAbandonedAttachmentsForTurn: ([AgentImageAttachment]) -> Void
        let setAgentRunActive: (UUID, Bool) -> Void
        let updateBindings: (AgentTabSession) -> Void
        let requestUIRefresh: (UUID, Bool) -> Void
        let scheduleSave: (UUID) -> Void
        let notifyAgentTurnComplete: (AgentTabSession) -> Void
        let handleHeadlessStreamResult: (AIStreamResult, AgentTabSession, UUID, UUID) async -> Void
        let buildHeadlessAgentMessage: (AgentTabSession, String, UUID, [AgentImageAttachment]) -> AgentMessage
        let finalizeStreamingItems: (AgentTabSession) -> Void
        let finalizePendingToolCalls: (AgentTabSession, AgentSessionRunState) -> Void
        let finalizePendingToolCallsWithUpperBound: (AgentTabSession, AgentSessionRunState, Int?) -> Void
        let finalizeNonCodexTurnUsage: (AgentTabSession, Int?, Int?, Int?) -> Void
        let cancelPendingQuestion: (AgentTabSession) -> Void
        let cancelPendingApproval: (AgentTabSession) -> Void
        let cancelPendingApplyEditsReview: (AgentTabSession, String) -> Void
        let cancelPendingWorktreeMergeReview: (AgentTabSession, String) -> Void
        let flushPendingAssistantDelta: (AgentTabSession) -> Void
        let clearPendingAssistantDelta: (AgentTabSession) -> Void
        let prepareTerminalPublication: (AgentTabSession) -> Void
        let makeTerminalPublicationEnvelope: (
            AgentTabSession,
            AgentRunOwnership,
            AgentSessionRunState,
            UUID?
        ) -> AgentRunTerminalPublicationEnvelope?
        let publishTerminalCommit: (
            AgentTabSession,
            AgentRunTerminalCommitRevision,
            AgentRunEpochTransitionKind?
        ) async -> AgentRunTerminalPublicationResult
        /// Attention notifications only: observes that a generic follow-up start returned (whether it
        /// started, refused, or failed). Synchronous, never throws, and claims nothing about the outcome.
        package typealias FollowUpStartObservation = @MainActor () -> Void
        /// Starts a follow-up run. A non-nil `afterStart` is invoked once, after the start returns.
        let startFollowUpRun: (_ tabID: UUID, _ text: String, _ afterStart: FollowUpStartObservation?) -> Void
        /// Restore queued steering draft text back to the composer.
        let restoreDraftText: (_ tabID: UUID, _ text: String, _ message: String, _ strategy: DraftRestorationStrategy) -> Void
        /// Augment queued steering text with skill context, tagged files, and attachment rendering before submit.
        let augmentUserMessageForProviderSend: (
            _ text: String,
            _ attachments: [AgentImageAttachment],
            _ taggedFileAttachments: [AgentTaggedFileAttachment],
            _ session: AgentTabSession?
        ) async -> String
        /// Stages a transcript handoff for fresh-session resume recovery.
        let stageResumeRecoveryHandoffIfNeeded: (_ session: AgentTabSession) async -> Void
        /// Prepends a staged handoff payload to provider-facing text.
        let prependPendingHandoffIfNeeded: (_ text: String, _ session: AgentTabSession) -> String
        /// Records whether a staged handoff payload was accepted by the provider send attempt.
        let recordPendingHandoffSendOutcome: (_ session: AgentTabSession, _ didSend: Bool) -> Void
        /// Wakes MCP waiters once a steering instruction has actually been delivered to the provider.
        let signalMCPInstructionDelivered: (_ session: AgentTabSession) async -> Void
        /// Commits or rolls back exactly the delegated child-question notices staged into this
        /// turn's first input (`stageID` from `AgentModeViewModel.startAgentRun`). Runners call it at
        /// the actual provider submission outcome of the input that carried them (never at a
        /// queued fallback or optimistic pre-dispatch point); a nil or superseded stage is a no-op.
        var recordDelegatedQuestionNoticeSendOutcome: (
            _ session: AgentTabSession,
            _ stageID: UUID?,
            _ didSend: Bool
        ) -> Void = { _, _, _ in }
        /// Attention notifications only (App/Notifications): reads the completed attempt and its
        /// final assistant text at terminal commit. Never mutates run state; nil skips the event.
        var captureAttentionTurnCompletion: (
            _ session: AgentTabSession,
            _ revision: AgentRunTerminalCommitRevision
        ) -> AttentionNotificationCapture? = { _, _ in nil }
        /// Attention notifications only: called once per accepted commit that produced a capture,
        /// after successor selection settled. `providerSuccessorDeclined` is true only when the
        /// selected provider successor declined after an accepted publication;
        /// `genericFollowUpScheduled` is true only when this commit actually hands a queued follow-up
        /// to `startFollowUpRun`. A returned observation is passed to that start. Must not await or
        /// mutate run state.
        var settleAttentionTurnCompletion: (
            _ session: AgentTabSession,
            _ revision: AgentRunTerminalCommitRevision,
            _ capture: AttentionNotificationCapture,
            _ providerSuccessorDeclined: Bool,
            _ genericFollowUpScheduled: Bool
        ) -> FollowUpStartObservation? = { _, _, _, _, _ in nil }
        /// Attention notifications only: registers one ACP-steering follow-up start and returns the
        /// observation passed to it. Must not await or mutate run state.
        var beginAttentionFollowUpObservation: (
            _ session: AgentTabSession
        ) -> FollowUpStartObservation? = { _ in nil }
        /// Attention notifications only: ACP steering handoff work progressed (a flush finished).
        /// Must not await or mutate run state.
        var attentionCompletionProgress: (_ session: AgentTabSession) -> Void = { _ in }
        /// Native-runtime output received while no run is consuming (for example a Claude
        /// continuation after a background task finished). Appends transcript rows immediately,
        /// without run-attempt ownership and without mutating run state. `sourceID` identifies the
        /// event stream (one provider launch) that carried the result.
        var handleBackgroundNativeStreamResult: (
            _ result: AIStreamResult,
            _ sourceID: UUID,
            _ session: AgentTabSession
        ) async -> Void = { _, _, _ in }
        /// A run took over the event stream `sourceID`: that stream's current background message
        /// ends, so later between-run output of the stream starts a new message.
        var endBackgroundNativeMessage: (
            _ sourceID: UUID,
            _ session: AgentTabSession
        ) -> Void = { _, _ in }

        package init(
            estimateRuntimeTokens: @escaping (String) -> Int,
            addUserInputTokensToActiveNonCodexTurn: @escaping (Int, AgentTabSession) -> Void,
            startNonCodexTurnAccountingIfNeeded: @escaping (AgentTabSession, String) -> Void,
            reserveAttachmentsForTurn: @escaping ([AgentImageAttachment], AgentTabSession) -> UUID?,
            markAttachmentsConsumed: @escaping (AgentTabSession, UUID?) -> Void,
            stageConsumedAttachmentFilesForDeferredCleanup: @escaping ([AgentImageAttachment], AgentTabSession) -> Void,
            consumeDeferredAttachmentCleanup: @escaping (AgentTabSession, Bool) -> Void,
            finalizeAttachmentsForTurn: @escaping (
                AgentTabSession,
                UUID?,
                [AgentImageAttachment],
                AgentAttachmentTurnDisposition
            ) -> Void,
            finalizeAbandonedAttachmentsForTurn: @escaping ([AgentImageAttachment]) -> Void,
            setAgentRunActive: @escaping (UUID, Bool) -> Void,
            updateBindings: @escaping (AgentTabSession) -> Void,
            requestUIRefresh: @escaping (UUID, Bool) -> Void,
            scheduleSave: @escaping (UUID) -> Void,
            notifyAgentTurnComplete: @escaping (AgentTabSession) -> Void,
            handleHeadlessStreamResult: @escaping (AIStreamResult, AgentTabSession, UUID, UUID) async -> Void,
            buildHeadlessAgentMessage: @escaping (AgentTabSession, String, UUID, [AgentImageAttachment]) -> AgentMessage,
            finalizeStreamingItems: @escaping (AgentTabSession) -> Void,
            finalizePendingToolCalls: @escaping (AgentTabSession, AgentSessionRunState) -> Void,
            finalizePendingToolCallsWithUpperBound: @escaping (AgentTabSession, AgentSessionRunState, Int?) -> Void,
            finalizeNonCodexTurnUsage: @escaping (AgentTabSession, Int?, Int?, Int?) -> Void,
            cancelPendingQuestion: @escaping (AgentTabSession) -> Void,
            cancelPendingApproval: @escaping (AgentTabSession) -> Void,
            cancelPendingApplyEditsReview: @escaping (AgentTabSession, String) -> Void,
            cancelPendingWorktreeMergeReview: @escaping (AgentTabSession, String) -> Void,
            flushPendingAssistantDelta: @escaping (AgentTabSession) -> Void,
            clearPendingAssistantDelta: @escaping (AgentTabSession) -> Void,
            prepareTerminalPublication: @escaping (AgentTabSession) -> Void,
            makeTerminalPublicationEnvelope: @escaping (
                AgentTabSession,
                AgentRunOwnership,
                AgentSessionRunState,
                UUID?
            ) -> AgentRunTerminalPublicationEnvelope?,
            publishTerminalCommit: @escaping (
                AgentTabSession,
                AgentRunTerminalCommitRevision,
                AgentRunEpochTransitionKind?
            ) async -> AgentRunTerminalPublicationResult,
            startFollowUpRun: @escaping (_ tabID: UUID, _ text: String, _ afterStart: FollowUpStartObservation?) -> Void,
            restoreDraftText: @escaping (_ tabID: UUID, _ text: String, _ message: String, _ strategy: DraftRestorationStrategy) -> Void,
            augmentUserMessageForProviderSend: @escaping (
                _ text: String,
                _ attachments: [AgentImageAttachment],
                _ taggedFileAttachments: [AgentTaggedFileAttachment],
                _ session: AgentTabSession?
            ) async -> String,
            stageResumeRecoveryHandoffIfNeeded: @escaping (_ session: AgentTabSession) async -> Void,
            prependPendingHandoffIfNeeded: @escaping (_ text: String, _ session: AgentTabSession) -> String,
            recordPendingHandoffSendOutcome: @escaping (_ session: AgentTabSession, _ didSend: Bool) -> Void,
            signalMCPInstructionDelivered: @escaping (_ session: AgentTabSession) async -> Void,
            recordDelegatedQuestionNoticeSendOutcome: @escaping (
                _ session: AgentTabSession,
                _ stageID: UUID?,
                _ didSend: Bool
            ) -> Void = { _, _, _ in },
            captureAttentionTurnCompletion: @escaping (
                _ session: AgentTabSession,
                _ revision: AgentRunTerminalCommitRevision
            ) -> AttentionNotificationCapture? = { _, _ in nil },
            settleAttentionTurnCompletion: @escaping (
                _ session: AgentTabSession,
                _ revision: AgentRunTerminalCommitRevision,
                _ capture: AttentionNotificationCapture,
                _ providerSuccessorDeclined: Bool,
                _ genericFollowUpScheduled: Bool
            ) -> FollowUpStartObservation? = { _, _, _, _, _ in nil },
            beginAttentionFollowUpObservation: @escaping (
                _ session: AgentTabSession
            ) -> FollowUpStartObservation? = { _ in nil },
            attentionCompletionProgress: @escaping (_ session: AgentTabSession) -> Void = { _ in },
            handleBackgroundNativeStreamResult: @escaping (
                _ result: AIStreamResult,
                _ sourceID: UUID,
                _ session: AgentTabSession
            ) async -> Void = { _, _, _ in },
            endBackgroundNativeMessage: @escaping (
                _ sourceID: UUID,
                _ session: AgentTabSession
            ) -> Void = { _, _ in }
        ) {
            self.estimateRuntimeTokens = estimateRuntimeTokens
            self.addUserInputTokensToActiveNonCodexTurn = addUserInputTokensToActiveNonCodexTurn
            self.startNonCodexTurnAccountingIfNeeded = startNonCodexTurnAccountingIfNeeded
            self.reserveAttachmentsForTurn = reserveAttachmentsForTurn
            self.markAttachmentsConsumed = markAttachmentsConsumed
            self.stageConsumedAttachmentFilesForDeferredCleanup = stageConsumedAttachmentFilesForDeferredCleanup
            self.consumeDeferredAttachmentCleanup = consumeDeferredAttachmentCleanup
            self.finalizeAttachmentsForTurn = finalizeAttachmentsForTurn
            self.finalizeAbandonedAttachmentsForTurn = finalizeAbandonedAttachmentsForTurn
            self.setAgentRunActive = setAgentRunActive
            self.updateBindings = updateBindings
            self.requestUIRefresh = requestUIRefresh
            self.scheduleSave = scheduleSave
            self.notifyAgentTurnComplete = notifyAgentTurnComplete
            self.handleHeadlessStreamResult = handleHeadlessStreamResult
            self.buildHeadlessAgentMessage = buildHeadlessAgentMessage
            self.finalizeStreamingItems = finalizeStreamingItems
            self.finalizePendingToolCalls = finalizePendingToolCalls
            self.finalizePendingToolCallsWithUpperBound = finalizePendingToolCallsWithUpperBound
            self.finalizeNonCodexTurnUsage = finalizeNonCodexTurnUsage
            self.cancelPendingQuestion = cancelPendingQuestion
            self.cancelPendingApproval = cancelPendingApproval
            self.cancelPendingApplyEditsReview = cancelPendingApplyEditsReview
            self.cancelPendingWorktreeMergeReview = cancelPendingWorktreeMergeReview
            self.flushPendingAssistantDelta = flushPendingAssistantDelta
            self.clearPendingAssistantDelta = clearPendingAssistantDelta
            self.prepareTerminalPublication = prepareTerminalPublication
            self.makeTerminalPublicationEnvelope = makeTerminalPublicationEnvelope
            self.publishTerminalCommit = publishTerminalCommit
            self.startFollowUpRun = startFollowUpRun
            self.restoreDraftText = restoreDraftText
            self.augmentUserMessageForProviderSend = augmentUserMessageForProviderSend
            self.stageResumeRecoveryHandoffIfNeeded = stageResumeRecoveryHandoffIfNeeded
            self.prependPendingHandoffIfNeeded = prependPendingHandoffIfNeeded
            self.recordPendingHandoffSendOutcome = recordPendingHandoffSendOutcome
            self.signalMCPInstructionDelivered = signalMCPInstructionDelivered
            self.recordDelegatedQuestionNoticeSendOutcome = recordDelegatedQuestionNoticeSendOutcome
            self.captureAttentionTurnCompletion = captureAttentionTurnCompletion
            self.settleAttentionTurnCompletion = settleAttentionTurnCompletion
            self.beginAttentionFollowUpObservation = beginAttentionFollowUpObservation
            self.attentionCompletionProgress = attentionCompletionProgress
            self.handleBackgroundNativeStreamResult = handleBackgroundNativeStreamResult
            self.endBackgroundNativeMessage = endBackgroundNativeMessage
        }
    }

    private let dependencies: Dependencies
    private let hooks: Hooks
    private let runCoordinator: AgentRunCoordinator

    #if DEBUG
        func test_acpRunner() -> ACPIntegratedAgentModeRunner {
            acpRunner
        }

        package func test_terminalCommitBarrier() -> AgentRunTerminalCommitBarrier {
            terminalCommitBarrier
        }

        package func test_attachmentFinalizationHook() -> (
            AgentTabSession,
            UUID?,
            [AgentImageAttachment],
            AgentAttachmentTurnDisposition
        ) -> Void {
            hooks.finalizeAttachmentsForTurn
        }
    #endif
    private let headlessRunner: HeadlessAgentModeRunner
    private let codexRunner: CodexIntegratedAgentModeRunner
    private let claudeRunner: ClaudeIntegratedAgentModeRunner
    private let acpRunner: ACPIntegratedAgentModeRunner
    private let terminalCommitBarrier: AgentRunTerminalCommitBarrier

    private static let enableSteeringDebugLogging = false

    private func steeringDebugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
            guard Self.enableSteeringDebugLogging else { return }
            print(message())
        #endif
    }

    package init(
        dependencies: Dependencies,
        hooks: Hooks,
        toolTrackingHooks: AgentToolTrackingHooks,
        runCoordinator: AgentRunCoordinator
    ) {
        self.dependencies = dependencies
        self.hooks = hooks
        self.runCoordinator = runCoordinator
        let terminalCommitBarrier = AgentRunTerminalCommitBarrier(hooks: hooks)
        self.terminalCommitBarrier = terminalCommitBarrier
        dependencies.codexCoordinator.installTerminalCommitBarrier(terminalCommitBarrier)
        headlessRunner = HeadlessAgentModeRunner(
            headlessProviderFactory: dependencies.headlessProviderFactory,
            hooks: hooks,
            terminalCommitBarrier: terminalCommitBarrier
        )
        codexRunner = CodexIntegratedAgentModeRunner(
            mcpServerEnabler: dependencies.mcpServerEnabler,
            codexCoordinator: dependencies.codexCoordinator,
            hooks: hooks
        )
        claudeRunner = ClaudeIntegratedAgentModeRunner(
            claudeCoordinator: dependencies.claudeCoordinator,
            hooks: hooks,
            terminalCommitBarrier: terminalCommitBarrier
        )
        acpRunner = ACPIntegratedAgentModeRunner(
            hooks: hooks,
            terminalCommitBarrier: terminalCommitBarrier,
            toolTrackingHooks: toolTrackingHooks,
            mcpHost: runCoordinator.mcpHost,
            providerFactory: dependencies.acpProviderFactory,
            controllerFactory: dependencies.acpControllerFactory
        )
        #if DEBUG
            acpRunner.installOMPQualificationStartupProbes(dependencies.ompQualificationStartupProbes)
        #endif
    }

    /// Reason carried by the `.stale` outcome when `providerHandoffAuthorization` revokes a start
    /// immediately before the provider runner would be invoked. No run state is mutated.
    package static let providerHandoffRevokedReason = "scheduled_provider_handoff_revoked"

    @discardableResult
    package func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        codexFallbackContext: AgentTabSession.CodexFallbackSubmissionContext? = nil,
        providerHandoffAuthorization: (@MainActor () -> Bool)? = nil,
        delegatedQuestionStageID: UUID? = nil
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome? {
        assert(session.tabID == tabID, "AgentModeRunService.startRun requires the originating tab ID to match the TabSession tab ID")
        let selectedAgent = session.selectedAgent
        #if DEBUG
            let ompQualificationStartContext = session.ompQualificationStartContext
            let invocationOMPQualificationStartContext = dependencies.ompQualificationInvocationContext(session)
            var ompQualificationBoundaryHandedOff = false
            defer {
                if selectedAgent == .ohMyPi, !ompQualificationBoundaryHandedOff {
                    invocationOMPQualificationStartContext?.authorizationReceipt.resolve(
                        .denied,
                        startupFailureReason: "provider_start_boundary_not_reached"
                    )
                }
            }
        #endif
        #if DEBUG
            if selectedAgent == .ohMyPi,
               ompQualificationStartContext != nil || invocationOMPQualificationStartContext != nil
            {
                if let invocationOMPQualificationStartContext,
                   session.mcpStartInvocationGenerationID != invocationOMPQualificationStartContext.generationID
                {
                    invocationOMPQualificationStartContext.authorizationReceipt.resolve(
                        .denied,
                        startupFailureReason: "start_invocation_generation_mismatch"
                    )
                    return nil
                }
                guard let ompQualificationStartContext,
                      let invocationOMPQualificationStartContext
                else {
                    let message = "Oh My Pi qualification state is incomplete or is not bound to this session and workspace."
                    await failBeforeProviderStartup(session: session, message: message)
                    return nil
                }
                guard ompQualificationStartContext === invocationOMPQualificationStartContext else {
                    invocationOMPQualificationStartContext.authorizationReceipt.resolve(
                        .denied,
                        startupFailureReason: "qualification_context_identity_mismatch"
                    )
                    return nil
                }
                guard session.mcpControlContext?.sessionID == ompQualificationStartContext.transaction.sessionID,
                      dependencies.ompQualificationActiveWorkspaceID() == ompQualificationStartContext.expectedWorkspaceID
                else {
                    let message = "Oh My Pi qualification state is incomplete or is not bound to this session and workspace."
                    await failBeforeProviderStartup(session: session, message: message)
                    return nil
                }
            }
        #endif
        if session.profile == .knowledge,
           !KnowledgeSessionPolicy.supportedProviders.contains(selectedAgent)
        {
            let message = "Knowledge sessions currently support Claude Code and Codex only."
            await failBeforeProviderStartup(session: session, message: message)
            return selectedAgent == .codexExec ? .failed(message: message) : nil
        }
        let selectedModelString = session.selectedModelRaw == AgentModel.defaultModel.rawValue
            ? nil
            : session.selectedModelRaw
        let runtimePermission = dependencies.providerRuntimePermissionResolver(selectedAgent, session.permissionProfile)
        let workspacePath: String?
        do {
            workspacePath = try dependencies.workspacePathProvider(session)
        } catch {
            let message = Self.providerStartupFailureMessage(for: error)
            await failBeforeProviderStartup(session: session, message: message)
            return selectedAgent == .codexExec ? .failed(message: message) : nil
        }

        // Final authorization immediately before any provider runner is invoked: every
        // asynchronous preparation above has completed and no run state has been mutated yet.
        if let providerHandoffAuthorization, !providerHandoffAuthorization() {
            return .stale(reason: Self.providerHandoffRevokedReason)
        }

        if selectedAgent == .codexExec {
            return await codexRunner.startRun(
                tabID: tabID,
                session: session,
                initialMessageForRun: initialMessageForRun,
                attachments: attachments,
                fallbackContext: codexFallbackContext,
                delegatedQuestionStageID: delegatedQuestionStageID
            )
        }

        let acpRunRequest: ACPRunRequest? = if selectedAgent.acpProviderID != nil {
            ACPRunRequest(
                agentKind: selectedAgent,
                modelString: selectedModelString,
                workspacePath: workspacePath,
                resumeSessionID: session.providerSessionID,
                attachments: attachments,
                taskLabelKind: session.mcpControlContext?.taskLabelKind,
                sessionModeID: runtimePermission.acpSessionModeID,
                additionalConfigOptionValues: Self.ohMyPiConfigAssignments(
                    agent: selectedAgent,
                    exactWireModelID: selectedModelString,
                    selections: session.ohMyPiThinkingSelections
                ),
                autoApproveAllToolPermissions: runtimePermission.autoApproveAllACPToolPermissions
            )
        } else {
            nil
        }

        let windowID = dependencies.windowID
        let mcpServerEnabler = dependencies.mcpServerEnabler
        let connectionPolicyInstaller = dependencies.connectionPolicyInstaller
        let expectedPIDPolicyArmer = dependencies.expectedPIDPolicyArmer
        let taskLabelKind = session.mcpControlContext?.taskLabelKind
        let delegationPolicy = dependencies.delegationRunToolPolicyResolver(session)
        let runHasNativeShell = resolveRunHasNativeShell(
            selectedAgent: selectedAgent,
            session: session,
            acpSessionModeID: acpRunRequest?.sessionModeID
        )
        let runCoordinator = runCoordinator
        let makeLease: (_ runID: UUID) -> MCPBootstrapLease = { runID in
            self.dependencies.bindPendingOracleReviewContext(tabID, runID)
            let leaseSpec = MCPBootstrapLeaseSpec.agentMode(
                tabID: tabID,
                runID: runID,
                gateID: UUID(),
                windowID: windowID,
                agent: selectedAgent,
                sessionProfile: session.profile,
                taskLabelKind: taskLabelKind,
                allowsAgentExternalControlTools: delegationPolicy.allowsAgentExternalControlTools,
                additionalRestrictedTools: delegationPolicy.additionalRestrictedTools,
                runHasNativeShell: runHasNativeShell
            )
            let lease = MCPBootstrapLease(
                spec: leaseSpec,
                runCoordinator: runCoordinator,
                mcpServerEnabler: mcpServerEnabler,
                policyInstaller: MCPBootstrapLease.agentModePolicyInstaller(connectionPolicyInstaller),
                expectedPIDPolicyArmer: expectedPIDPolicyArmer
            )
            #if DEBUG
                self.dependencies.testOMPQualificationLeaseCreated(lease)
            #endif
            return lease
        }
        if selectedAgent.usesClaudeNativeRuntime {
            await claudeRunner.startRun(
                tabID: tabID,
                session: session,
                initialUserMessage: initialUserMessage,
                initialMessageForRun: initialMessageForRun,
                attachments: attachments,
                makeLease: makeLease,
                delegatedQuestionStageID: delegatedQuestionStageID
            )
            return nil
        }
        if let acpRunRequest {
            #if DEBUG
                let ompQualificationActiveWorkspaceID = dependencies.ompQualificationActiveWorkspaceID
                let ompQualificationAuthorizer = dependencies.ompQualificationAuthorizer
                let testBeforeOMPQualificationProviderAuthorization = dependencies.testBeforeOMPQualificationProviderAuthorization
                let providerStartBootstrapObserver = dependencies.testOMPQualificationProviderBootstrapEntry
                var providerStartAuthorizationFailureReason: String?
                let providerStartAuthorizer: (UUID) -> Bool = { [weak session] runID in
                    guard selectedAgent == .ohMyPi else { return true }
                    if ompQualificationStartContext == nil, invocationOMPQualificationStartContext == nil {
                        return true
                    }
                    testBeforeOMPQualificationProviderAuthorization()
                    guard let session,
                          let ompQualificationStartContext,
                          let invocationOMPQualificationStartContext,
                          session.mcpStartInvocationGenerationID == invocationOMPQualificationStartContext.generationID,
                          session.ompQualificationStartContext === invocationOMPQualificationStartContext,
                          ompQualificationStartContext === invocationOMPQualificationStartContext,
                          session.mcpControlContext?.sessionID == ompQualificationStartContext.transaction.sessionID,
                          ompQualificationActiveWorkspaceID() == ompQualificationStartContext.expectedWorkspaceID,
                          ompQualificationStartContext.authorizationReceipt.authorizationStillPermitted
                    else {
                        ompQualificationStartContext?.authorizationReceipt.resolve(
                            .denied,
                            startupFailureReason: "qualification_authorizer_precondition_failed"
                        )
                        return false
                    }
                    let decision = ompQualificationAuthorizer(ompQualificationStartContext.transaction, runID)
                    providerStartAuthorizationFailureReason = decision.refusalReason
                    return decision.isAuthorized
                }
                let providerStartBoundaryReporter: (
                    _ runID: UUID?,
                    _ activeAgentSessionID: UUID?,
                    _ runAttemptID: UUID?,
                    _ authorized: Bool,
                    _ startupFailureReason: String?
                ) -> Bool = { runID, activeAgentSessionID, runAttemptID, authorized, startupFailureReason in
                    guard selectedAgent == .ohMyPi else { return true }
                    if ompQualificationStartContext == nil, invocationOMPQualificationStartContext == nil {
                        return true
                    }
                    guard let context = ompQualificationStartContext,
                          invocationOMPQualificationStartContext != nil
                    else { return false }
                    let proposedOutcome: OhMyPiAgentModeSmokeGate.StartAuthorizationReceipt.Outcome = if authorized, let runID {
                        .authorized(.init(
                            runID: runID,
                            activeAgentSessionID: activeAgentSessionID,
                            runAttemptID: runAttemptID
                        ))
                    } else {
                        .denied
                    }
                    let effectiveStartupFailureReason = if authorized {
                        startupFailureReason
                    } else {
                        startupFailureReason
                            ?? providerStartAuthorizationFailureReason
                            ?? "provider_boundary_failure_unspecified"
                    }
                    return context.authorizationReceipt.resolve(
                        proposedOutcome,
                        startupFailureReason: effectiveStartupFailureReason
                    ) == proposedOutcome
                }
            #else
                let providerStartAuthorizer: (UUID) -> Bool = { _ in true }
                let providerStartBoundaryReporter: (UUID?, UUID?, UUID?, Bool, String?) -> Bool = { _, _, _, _, _ in true }
                let providerStartBootstrapObserver: () -> Void = {}
            #endif
            #if DEBUG
                if selectedAgent == .ohMyPi {
                    ompQualificationBoundaryHandedOff = true
                }
            #endif
            await acpRunner.startRun(
                tabID: tabID,
                session: session,
                initialUserMessage: initialUserMessage,
                initialMessageForRun: initialMessageForRun,
                attachments: attachments,
                runRequest: acpRunRequest,
                makeLease: makeLease,
                providerStartAuthorizer: providerStartAuthorizer,
                providerStartBoundaryReporter: providerStartBoundaryReporter,
                providerStartBootstrapObserver: providerStartBootstrapObserver,
                delegatedQuestionStageID: delegatedQuestionStageID
            )
            return nil
        }
        await headlessRunner.startRun(
            tabID: tabID,
            session: session,
            initialUserMessage: initialUserMessage,
            initialMessageForRun: initialMessageForRun,
            attachments: attachments,
            makeLease: makeLease,
            delegatedQuestionStageID: delegatedQuestionStageID
        )
        return nil
    }

    /// Attempts to submit a prompt into an already-active ACP session.
    @discardableResult
    func submitActiveACPPromptIfSupported(
        session: AgentTabSession,
        messageForRun: String,
        attachments: [AgentImageAttachment],
        targetRunID: UUID?,
        targetRunAttemptID: UUID?,
        targetController: ACPAgentSessionController
    ) async -> Bool {
        let selectedAgent = session.selectedAgent
        let selectedModelString = session.selectedModelRaw == AgentModel.defaultModel.rawValue
            ? nil
            : session.selectedModelRaw
        let runtimePermission = dependencies.providerRuntimePermissionResolver(selectedAgent, session.permissionProfile)
        guard selectedAgent.acpProviderID != nil,
              session.runState == .running,
              attachments.isEmpty,
              session.runID == targetRunID,
              session.activeRunAttemptID == targetRunAttemptID,
              session.acpController === targetController
        else {
            steeringDebugLog("[AgentRunSteeringWake] ACP active submit guard rejected agent=\(selectedAgent.rawValue) state=\(session.runState.rawValue) attachments=\(attachments.count) runID=\(String(describing: session.runID)) targetRunID=\(String(describing: targetRunID)) attempt=\(String(describing: session.activeRunAttemptID)) targetAttempt=\(String(describing: targetRunAttemptID)) hasController=\(session.acpController != nil) controllerMatches=\(session.acpController === targetController)")
            return false
        }
        let workspacePath: String?
        do {
            workspacePath = try dependencies.workspacePathProvider(session)
        } catch {
            let message = Self.providerStartupFailureMessage(for: error)
            await failBeforeProviderStartup(session: session, message: message)
            return false
        }
        let runRequest = ACPRunRequest(
            agentKind: selectedAgent,
            modelString: selectedModelString,
            workspacePath: workspacePath,
            resumeSessionID: session.providerSessionID,
            attachments: attachments,
            taskLabelKind: session.mcpControlContext?.taskLabelKind,
            sessionModeID: runtimePermission.acpSessionModeID,
            additionalConfigOptionValues: Self.ohMyPiConfigAssignments(
                agent: selectedAgent,
                exactWireModelID: selectedModelString,
                selections: session.ohMyPiThinkingSelections
            ),
            autoApproveAllToolPermissions: runtimePermission.autoApproveAllACPToolPermissions
        )
        let sent = await acpRunner.submitActivePrompt(
            session: session,
            messageForRun: messageForRun,
            attachments: attachments,
            runRequest: runRequest,
            targetRunID: targetRunID,
            targetRunAttemptID: targetRunAttemptID,
            targetController: targetController
        )
        steeringDebugLog("[AgentRunSteeringWake] ACP active submit runner returned sent=\(sent) agent=\(selectedAgent.rawValue) model=\(selectedModelString ?? "default") runID=\(String(describing: targetRunID)) attempt=\(String(describing: targetRunAttemptID))")
        return sent
    }

    /// Native-shell signal for the run's MCP lease, computed from the effective launch settings.
    /// Claude reads the coordinator's effective Bash launch policy; OpenCode reads the requested
    /// managed session mode. Every other provider, and any unknown value, reports `false` so the
    /// RepoPrompt `git` tool stays visible. Codex computes its own value in its coordinator.
    private func resolveRunHasNativeShell(
        selectedAgent: AgentProviderKind,
        session: AgentTabSession,
        acpSessionModeID: String?
    ) -> Bool {
        guard session.profile == .standard else { return false }
        if selectedAgent.usesClaudeNativeRuntime {
            return dependencies.claudeCoordinator.runHasNativeShell(for: session)
        }
        if selectedAgent == .openCode {
            return OpenCodeAgentConfig.sessionModeHasNativeShell(acpSessionModeID)
        }
        return false
    }

    @discardableResult
    package func submitQueuedACPSteeringIfSupported(session: AgentTabSession) async -> Bool {
        guard session.selectedAgent.acpProviderID != nil,
              session.runState == .running
        else {
            return false
        }

        // If a flush task is already draining the queue, just return — it will
        // pick up the newly appended instruction on its next loop iteration.
        guard session.acpSteeringFlushTask == nil else {
            steeringDebugLog("[AgentRunSteeringWake] ACP flush already active tab=\(session.tabID) queue=\(session.pendingACPSteeringInstructions.count)")
            return true
        }
        guard !session.pendingACPSteeringInstructions.isEmpty else { return false }

        guard let runID = session.runID,
              let runAttemptID = session.activeRunAttemptID,
              let controller = session.acpController else { return false }

        let tabID = session.tabID
        steeringDebugLog("[AgentRunSteeringWake] ACP flush start tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) queue=\(session.pendingACPSteeringInstructions.count)")
        session.acpSteeringFlushTask = Task { [weak self, weak session, controller] in
            guard let self, let session else { return }
            defer {
                session.acpSteeringFlushTask = nil
                if session.runState == .running,
                   session.selectedAgent.acpProviderID != nil,
                   !session.pendingACPSteeringInstructions.isEmpty
                {
                    Task { @MainActor [weak self, weak session] in
                        guard let self, let session else { return }
                        _ = await self.submitQueuedACPSteeringIfSupported(session: session)
                    }
                }
                hooks.attentionCompletionProgress(session)
            }

            while true {
                guard isCurrentACPSteeringAttempt(session: session, runID: runID, runAttemptID: runAttemptID, controller: controller) else {
                    requeueQueuedACPSteeringAsFollowUp(
                        tabID: tabID,
                        session: session,
                        matching: { $0.targetRunID == runID && $0.targetRunAttemptID == runAttemptID },
                        reason: "stale ACP steering attempt before MCP idle wait"
                    )
                    return
                }
                guard !session.pendingACPSteeringInstructions.isEmpty else { return }

                if let first = session.pendingACPSteeringInstructions.first,
                   first.targetRunID != runID || first.targetRunAttemptID != runAttemptID
                {
                    requeueLeadingACPSteeringAsFollowUp(
                        tabID: tabID,
                        session: session,
                        while: { $0.targetRunID != runID || $0.targetRunAttemptID != runAttemptID },
                        reason: "queued ACP steering target no longer matches active run"
                    )
                    continue
                }

                // Protect the current turn before the MCP idle wait. ACP providers can
                // complete the original prompt while we are waiting for RepoPrompt tools
                // to drain; that terminal must be treated as superseded once steering has
                // been accepted into the serialized ACP queue, otherwise the run finalizes
                // before we can send the interrupt+prompt.
                let supersedingBaseline = session.pendingSupersedingTurnCompletions
                session.pendingSupersedingTurnCompletions += 1
                let releaseSupersedingProtectionIfUnused = {
                    if session.pendingSupersedingTurnCompletions > supersedingBaseline {
                        session.pendingSupersedingTurnCompletions -= 1
                    }
                }

                // Wait for all active MCP tool executions to finish before interrupting.
                steeringDebugLog("[AgentRunSteeringWake] ACP flush waiting MCP idle tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) queue=\(session.pendingACPSteeringInstructions.count)")
                do {
                    try await dependencies.awaitNoActiveMCPTools(runID)
                    steeringDebugLog("[AgentRunSteeringWake] ACP flush MCP idle returned tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) queue=\(session.pendingACPSteeringInstructions.count)")
                } catch {
                    releaseSupersedingProtectionIfUnused()
                    steeringDebugLog("[AgentRunSteeringWake] ACP flush MCP idle cancelled tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) error=\(error)")
                    requeueAllQueuedACPSteeringAsFollowUp(
                        tabID: tabID,
                        session: session,
                        reason: "ACP steering MCP idle wait was cancelled"
                    )
                    return
                }

                guard isCurrentACPSteeringAttempt(session: session, runID: runID, runAttemptID: runAttemptID, controller: controller),
                      !session.pendingACPSteeringInstructions.isEmpty
                else {
                    releaseSupersedingProtectionIfUnused()
                    requeueQueuedACPSteeringAsFollowUp(
                        tabID: tabID,
                        session: session,
                        matching: { $0.targetRunID == runID && $0.targetRunAttemptID == runAttemptID },
                        reason: "stale ACP steering attempt after MCP idle wait"
                    )
                    return
                }

                let steeringBatch = Array(session.pendingACPSteeringInstructions.prefix(while: {
                    $0.targetRunID == runID && $0.targetRunAttemptID == runAttemptID
                }))
                guard !steeringBatch.isEmpty else { continue }
                session.pendingACPSteeringInstructions.removeFirst(steeringBatch.count)

                let providerTextForSend = coalescedACPProviderText(for: steeringBatch)
                var dequeuedUserInputTokens: [Int] = []
                for _ in steeringBatch {
                    guard !session.pendingNonCodexUserInputTokenQueue.isEmpty else { break }
                    dequeuedUserInputTokens.append(session.pendingNonCodexUserInputTokenQueue.removeFirst())
                }
                let steeringUserInputTokens = dequeuedUserInputTokens.count == steeringBatch.count
                    ? dequeuedUserInputTokens.reduce(0, +)
                    : hooks.estimateRuntimeTokens(providerTextForSend)
                hooks.addUserInputTokensToActiveNonCodexTurn(steeringUserInputTokens, session)

                let augmentedSteeringText = await hooks.augmentUserMessageForProviderSend(
                    providerTextForSend,
                    steeringBatch.flatMap(\.attachments),
                    steeringBatch.flatMap(\.taggedFileAttachments),
                    session
                )
                let sent = await submitActiveACPPromptIfSupported(
                    session: session,
                    messageForRun: augmentedSteeringText,
                    attachments: steeringBatch.flatMap(\.attachments),
                    targetRunID: runID,
                    targetRunAttemptID: runAttemptID,
                    targetController: controller
                )
                hooks.recordPendingHandoffSendOutcome(session, sent)
                if sent {
                    await hooks.signalMCPInstructionDelivered(session)
                }
                if !sent {
                    releaseSupersedingProtectionIfUnused()
                    session.pendingACPSteeringInstructions.insert(contentsOf: steeringBatch, at: 0)
                    if !dequeuedUserInputTokens.isEmpty {
                        session.pendingNonCodexUserInputTokenQueue.insert(contentsOf: dequeuedUserInputTokens, at: 0)
                    }
                    requeueAllQueuedACPSteeringAsFollowUp(
                        tabID: tabID,
                        session: session,
                        reason: "ACP interrupt+prompt send returned false"
                    )
                    return
                }
            }
        }

        return true
    }

    package static func ohMyPiConfigAssignments(
        agent: AgentProviderKind,
        exactWireModelID: String?,
        selections: OhMyPiThinkingSelections
    ) -> [ACPConfigOptionAssignment] {
        guard agent == .ohMyPi,
              let rawModelID = exactWireModelID,
              let canonicalModelID = OhMyPiCanonicalModelIdentity.exactWireID(for: rawModelID),
              OhMyPiThinkingExecutionEligibility.allowsAssignment(for: canonicalModelID),
              let assignment = selections.assignment(for: canonicalModelID)
        else {
            return []
        }
        return [assignment]
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

    private func failBeforeProviderStartup(session: AgentTabSession, message: String) async {
        let ownership = session.activeRunOwnership ?? session.beginRunAttempt(source: "runService.startupFailure")
        hooks.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: session.runID,
            terminalState: .failed,
            source: "runService.startupFailure",
            errorText: message,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: session.selectedAgent != .codexExec,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            prepareProviderState: {
                session.provider = nil
                return nil
            }
        ))
    }

    private func isCurrentACPSteeringAttempt(
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController
    ) -> Bool {
        session.runState == .running
            && session.selectedAgent.acpProviderID != nil
            && session.runID == runID
            && session.activeRunAttemptID == runAttemptID
            && session.acpController === controller
    }

    private func requeueQueuedACPSteeringAsFollowUp(
        tabID: UUID,
        session: AgentTabSession,
        matching shouldRequeue: (AgentTabSession.ACPSteeringInstruction) -> Bool,
        reason: String
    ) {
        let instructions = session.pendingACPSteeringInstructions.filter(shouldRequeue)
        guard !instructions.isEmpty else { return }
        session.pendingACPSteeringInstructions.removeAll(where: shouldRequeue)
        requeueACPSteeringAsFollowUp(instructions, tabID: tabID, session: session, reason: reason)
    }

    private func requeueLeadingACPSteeringAsFollowUp(
        tabID: UUID,
        session: AgentTabSession,
        while shouldRequeue: (AgentTabSession.ACPSteeringInstruction) -> Bool,
        reason: String
    ) {
        let instructions = Array(session.pendingACPSteeringInstructions.prefix(while: shouldRequeue))
        guard !instructions.isEmpty else { return }
        session.pendingACPSteeringInstructions.removeFirst(instructions.count)
        requeueACPSteeringAsFollowUp(instructions, tabID: tabID, session: session, reason: reason)
    }

    private func requeueAllQueuedACPSteeringAsFollowUp(
        tabID: UUID,
        session: AgentTabSession,
        reason: String
    ) {
        let instructions = session.pendingACPSteeringInstructions
        guard !instructions.isEmpty else { return }
        session.pendingACPSteeringInstructions.removeAll()
        requeueACPSteeringAsFollowUp(instructions, tabID: tabID, session: session, reason: reason)
    }

    private func coalescedACPProviderText(
        for instructions: [AgentTabSession.ACPSteeringInstruction]
    ) -> String {
        let steeringTexts = instructions
            .map { $0.providerText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !steeringTexts.isEmpty else { return "" }

        var seenInterruptedTexts = Set<String>()
        let steeringTextSet = Set(steeringTexts)
        let interruptedTexts = instructions.compactMap { instruction -> String? in
            guard let text = instruction.interruptedPromptProviderText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  !steeringTextSet.contains(text),
                  seenInterruptedTexts.insert(text).inserted
            else {
                return nil
            }
            return text
        }

        guard !interruptedTexts.isEmpty || steeringTexts.count > 1 else {
            return steeringTexts[0]
        }

        let interruptedSection = interruptedTexts.isEmpty ? "" : """
        <interrupted_user_messages>
        \(interruptedTexts.enumerated().map { index, text in
            "<message index=\"\(index + 1)\">\n\(text)\n</message>"
        }.joined(separator: "\n"))
        </interrupted_user_messages>

        """
        let steeringSection = """
        <steering_messages>
        \(steeringTexts.enumerated().map { index, text in
            "<message index=\"\(index + 1)\">\n\(text)\n</message>"
        }.joined(separator: "\n"))
        </steering_messages>
        """

        return """
        \(interruptedSection)\(steeringSection)

        The active ACP prompt was cancelled so this steering could be delivered. Treat the interrupted user messages, if any, followed by the steering messages above as the latest user messages in chronological order.
        """
    }

    private func requeueACPSteeringAsFollowUp(
        _ instructions: [AgentTabSession.ACPSteeringInstruction],
        tabID: UUID,
        session: AgentTabSession,
        reason: String
    ) {
        var providerTexts = [coalescedACPProviderText(for: instructions)]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !providerTexts.isEmpty else { return }
        if session.runState == .completed, session.acpController != nil {
            let first = providerTexts.removeFirst()
            if !providerTexts.isEmpty {
                session.pendingInstructions.insert(contentsOf: providerTexts, at: 0)
            }
            session.mcpFollowUpRunPending = true
            hooks.startFollowUpRun(tabID, first, hooks.beginAttentionFollowUpObservation(session))
            return
        }
        session.pendingInstructions.insert(contentsOf: providerTexts, at: 0)
        session.isDirty = true
        hooks.updateBindings(session)
        hooks.scheduleSave(tabID)
    }

    /// Claims superseding protection for the currently outstanding Claude turn when
    /// a steering instruction has been accepted into the live queue. The claim is
    /// scoped to unprotected expected turn IDs rather than queued-message count so
    /// coalesced/stacked steering does not over-increment.
    package func protectCurrentClaudeTurnForAcceptedSteeringIfNeeded(
        session: AgentTabSession,
        steeringID: UUID
    ) {
        guard session.selectedAgent.usesClaudeNativeRuntime,
              session.runState == .running,
              let runID = session.runID,
              let runAttemptID = session.activeRunAttemptID,
              let steeringIndex = session.pendingClaudeSteeringInstructions.firstIndex(where: { $0.id == steeringID })
        else {
            return
        }
        let steering = session.pendingClaudeSteeringInstructions[steeringIndex]
        guard steering.targetRunID == runID,
              steering.targetRunAttemptID == runAttemptID
        else {
            return
        }

        let claimableTurnIDs = session.claudeExpectedTurnIDs.subtracting(session.claudeSupersedingProtectedTurnIDs)
        guard !claimableTurnIDs.isEmpty else { return }

        session.claudeSupersedingProtectedTurnIDs.formUnion(claimableTurnIDs)
        session.pendingClaudeSteeringInstructions[steeringIndex].supersedingProtectedTurnIDs.formUnion(claimableTurnIDs)
        session.pendingSupersedingTurnCompletions += claimableTurnIDs.count
    }

    private func releaseUnconsumedClaudeSupersedingProtection(
        for instructions: [AgentTabSession.ClaudeSteeringInstruction],
        session: AgentTabSession
    ) {
        let protectedTurnIDs = Set(instructions.flatMap(\.supersedingProtectedTurnIDs))
        guard !protectedTurnIDs.isEmpty else { return }

        let unconsumedTurnIDs = protectedTurnIDs
            .intersection(session.claudeExpectedTurnIDs)
            .intersection(session.claudeSupersedingProtectedTurnIDs)
        guard !unconsumedTurnIDs.isEmpty else { return }

        session.claudeSupersedingProtectedTurnIDs.subtract(unconsumedTurnIDs)
        session.pendingSupersedingTurnCompletions = max(
            0,
            session.pendingSupersedingTurnCompletions - unconsumedTurnIDs.count
        )
    }

    private func awaitClaudeChildAgentRunWaitScopesDrained(
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        timeoutSeconds: TimeInterval? = nil
    ) async -> Bool {
        let timeoutSeconds = timeoutSeconds ?? dependencies.childAgentRunWaitDrainTimeoutSeconds
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeoutSeconds * 1000)))
        while dependencies.activeAgentRunWaitQuery(runID) {
            guard isCurrentClaudeSteeringAttempt(session: session, runID: runID, runAttemptID: runAttemptID) else {
                return false
            }
            guard ContinuousClock.now < deadline else {
                steeringDebugLog("[AgentRunSteeringWake] Claude flush child agent_run wait drain timed out tab=\(session.tabID) runID=\(runID) attempt=\(runAttemptID)")
                return false
            }
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return false
            }
        }
        await Task.yield()
        return true
    }

    @discardableResult
    package func submitQueuedClaudeSteeringIfSupported(session: AgentTabSession) async -> Bool {
        guard session.selectedAgent.usesClaudeNativeRuntime,
              session.runState == .running
        else {
            return false
        }

        // If a flush task is already draining the queue, just return — it will
        // pick up the newly appended instruction on its next loop iteration.
        guard session.claudeSteeringFlushTask == nil else {
            steeringDebugLog("[AgentRunSteeringWake] Claude flush already active tab=\(session.tabID) queue=\(session.pendingClaudeSteeringInstructions.count)")
            return true
        }

        guard !session.pendingClaudeSteeringInstructions.isEmpty else { return false }

        guard let runID = session.runID,
              let runAttemptID = session.activeRunAttemptID else { return false }

        if let firstQueuedSteeringID = session.pendingClaudeSteeringInstructions.first?.id {
            protectCurrentClaudeTurnForAcceptedSteeringIfNeeded(
                session: session,
                steeringID: firstQueuedSteeringID
            )
        }

        let tabID = session.tabID
        steeringDebugLog("[AgentRunSteeringWake] Claude flush start tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) queue=\(session.pendingClaudeSteeringInstructions.count)")
        session.claudeSteeringFlushTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            defer {
                session.claudeSteeringFlushTask = nil
                if session.runState == .running,
                   session.selectedAgent.usesClaudeNativeRuntime,
                   !session.pendingClaudeSteeringInstructions.isEmpty
                {
                    Task { @MainActor [weak self, weak session] in
                        guard let self, let session else { return }
                        _ = await self.submitQueuedClaudeSteeringIfSupported(session: session)
                    }
                }
            }

            while true {
                guard isCurrentClaudeSteeringAttempt(session: session, runID: runID, runAttemptID: runAttemptID) else {
                    restoreQueuedClaudeSteeringDrafts(
                        tabID: tabID,
                        session: session,
                        strategy: .prependAlways,
                        matching: { $0.targetRunID == runID && $0.targetRunAttemptID == runAttemptID }
                    )
                    return
                }
                guard !session.pendingClaudeSteeringInstructions.isEmpty else { return }

                if let first = session.pendingClaudeSteeringInstructions.first,
                   first.targetRunID != runID || first.targetRunAttemptID != runAttemptID
                {
                    restoreLeadingQueuedClaudeSteeringDrafts(
                        tabID: tabID,
                        session: session,
                        strategy: .prependAlways,
                        while: { $0.targetRunID != runID || $0.targetRunAttemptID != runAttemptID }
                    )
                    continue
                }

                if let firstQueuedSteeringID = session.pendingClaudeSteeringInstructions.first?.id {
                    protectCurrentClaudeTurnForAcceptedSteeringIfNeeded(
                        session: session,
                        steeringID: firstQueuedSteeringID
                    )
                }

                // Wait for all active MCP tool executions to finish before interrupting.
                steeringDebugLog("[AgentRunSteeringWake] Claude flush waiting MCP idle tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) queue=\(session.pendingClaudeSteeringInstructions.count)")
                do {
                    try await dependencies.awaitNoActiveMCPTools(runID)
                    steeringDebugLog("[AgentRunSteeringWake] Claude flush MCP idle returned tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) queue=\(session.pendingClaudeSteeringInstructions.count)")
                } catch {
                    steeringDebugLog("[AgentRunSteeringWake] Claude flush MCP idle cancelled tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) error=\(error)")
                    // Task cancelled (user cancelled the run) — restore all remaining drafts.
                    restoreAllQueuedClaudeSteeringDrafts(tabID: tabID, session: session, strategy: .prependAlways)
                    return
                }

                // `agent_run` / `agent_explore` control tools are intentionally excluded from
                // ordinary active MCP tool tracking. Before a Claude native interrupt, also
                // wait briefly for parent-owned child-agent wait scopes to drain after the
                // upstream steering wake has had a chance to return `interrupted_by_steering`.
                guard await awaitClaudeChildAgentRunWaitScopesDrained(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID
                ) else {
                    restoreQueuedClaudeSteeringDrafts(
                        tabID: tabID,
                        session: session,
                        strategy: .prependAlways,
                        matching: { $0.targetRunID == runID && $0.targetRunAttemptID == runAttemptID }
                    )
                    return
                }

                // Claude Code handles steering as interrupt + queue/send follow-up prompt.
                // Keep the local MCP-idle and child-agent wait-scope gates above, but do not
                // block the queue on a stream-derived provider tool_result ack parity signal here.

                // Re-check state after waiting — run may have been cancelled during the wait
                guard isCurrentClaudeSteeringAttempt(session: session, runID: runID, runAttemptID: runAttemptID),
                      !session.pendingClaudeSteeringInstructions.isEmpty
                else {
                    restoreQueuedClaudeSteeringDrafts(
                        tabID: tabID,
                        session: session,
                        strategy: .prependAlways,
                        matching: { $0.targetRunID == runID && $0.targetRunAttemptID == runAttemptID }
                    )
                    return
                }

                let steering = session.pendingClaudeSteeringInstructions.removeFirst()
                steeringDebugLog("[AgentRunSteeringWake] Claude flush dequeued steering id=\(steering.id) tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) remaining=\(session.pendingClaudeSteeringInstructions.count)")
                let dequeuedUserInputTokens: Int? = {
                    guard !session.pendingNonCodexUserInputTokenQueue.isEmpty else { return nil }
                    return session.pendingNonCodexUserInputTokenQueue.removeFirst()
                }()

                let augmentedSteeringText = await hooks.augmentUserMessageForProviderSend(
                    steering.providerText,
                    steering.attachments,
                    steering.taggedFileAttachments,
                    session
                )
                steeringDebugLog("[AgentRunSteeringWake] Claude flush sending native interrupt id=\(steering.id) tab=\(tabID) runID=\(runID) attempt=\(runAttemptID)")
                let sent = await dependencies.claudeCoordinator.sendClaudeNativeMessage(
                    session: session,
                    text: augmentedSteeringText,
                    attachments: []
                )
                steeringDebugLog("[AgentRunSteeringWake] Claude flush send completed id=\(steering.id) tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) sent=\(sent)")
                hooks.recordPendingHandoffSendOutcome(session, sent)
                if sent {
                    await hooks.signalMCPInstructionDelivered(session)
                }
                if !sent {
                    // Re-insert the failed instruction so it's included in the restore
                    session.pendingClaudeSteeringInstructions.insert(steering, at: 0)
                    if let dequeuedUserInputTokens {
                        session.pendingNonCodexUserInputTokenQueue.insert(dequeuedUserInputTokens, at: 0)
                    }
                    // Restore ALL remaining queued drafts (including the one that failed)
                    restoreAllQueuedClaudeSteeringDrafts(tabID: tabID, session: session, strategy: .prependAlways)
                    await cancelClaudeRunStrandedBySteeringFailureIfNeeded(
                        tabID: tabID,
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID
                    )
                    return
                }
            }
        }

        return true
    }

    /// A failed steering dispatch normally leaves the interrupted turn outstanding, so its
    /// now-unprotected completion ends the run. If the runner already consumed that
    /// completion as protected (for example after interrupted-turn settlement), no event
    /// will ever arrive and the attempt would stay live with nothing in flight. Finish only
    /// that still-current, uncommitted attempt:
    /// - still running (dispatch deferred or abandoned without a send error): cancel it,
    ///   matching an aborted steer;
    /// - raw `.failed` from the coordinator's send failure (it records the error and run
    ///   state but owns no terminal commit): commit that failure through the terminal barrier
    ///   so the attempt ends, publishes once, and its runner drains.
    /// This runs inside the flush task, so it detaches the task first and never cancels or
    /// awaits itself.
    private func cancelClaudeRunStrandedBySteeringFailureIfNeeded(
        tabID: UUID,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async {
        guard session.selectedAgent.usesClaudeNativeRuntime,
              session.runID == runID,
              let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID,
              session.lastTerminalCommitRevision?.ownership != ownership,
              !session.terminalCommitInProgress,
              session.claudeExpectedTurnIDs.isEmpty
        else {
            return
        }
        switch session.runState {
        case .running:
            steeringDebugLog("[AgentRunSteeringWake] Claude flush cancelling stranded run tab=\(tabID) runID=\(runID) attempt=\(runAttemptID)")
            session.claudeSteeringFlushTask = nil
            await cancelRun(tabID: tabID, session: session)
        case .failed:
            steeringDebugLog("[AgentRunSteeringWake] Claude flush committing stranded send failure tab=\(tabID) runID=\(runID) attempt=\(runAttemptID)")
            session.claudeSteeringFlushTask = nil
            let runnerTask = session.agentTask
            // The coordinator already appended the diagnosable send error; commit the
            // failure without duplicating it.
            await terminalCommitBarrier.commit(.init(
                session: session,
                ownership: ownership,
                expectedRunID: runID,
                terminalState: .failed,
                source: "runService.claudeSteeringSendFailure",
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: true,
                supportsFollowUp: false,
                notifyTurnComplete: false,
                providerDrainGeneration: session.providerTerminalDrainGeneration,
                prepareProviderState: {
                    session.pendingSupersedingTurnCompletions = 0
                    session.claudeSupersedingProtectedTurnIDs.removeAll()
                    session.claudeExpectedTurnIDs.removeAll()
                    return nil
                }
            ))
            // The runner is parked on an event stream that will never yield for this
            // attempt; cancelling ends its loop, and its own finalize is a duplicate commit.
            runnerTask?.cancel()
        default:
            return
        }
    }

    private func isCurrentClaudeSteeringAttempt(
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID
    ) -> Bool {
        session.runState == .running
            && session.selectedAgent.usesClaudeNativeRuntime
            && session.runID == runID
            && session.activeRunAttemptID == runAttemptID
    }

    /// Concatenates queued Claude steering draft texts and restores them to the composer.
    private func restoreQueuedClaudeSteeringDrafts(
        tabID: UUID,
        session: AgentTabSession,
        strategy: DraftRestorationStrategy,
        matching shouldRestore: (AgentTabSession.ClaudeSteeringInstruction) -> Bool
    ) {
        let instructions = session.pendingClaudeSteeringInstructions.filter(shouldRestore)
        let drafts = instructions
            .map(\.draftText)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        releaseUnconsumedClaudeSupersedingProtection(for: instructions, session: session)
        session.pendingClaudeSteeringInstructions.removeAll(where: shouldRestore)
        restoreClaudeSteeringDrafts(drafts, tabID: tabID, strategy: strategy)
    }

    /// Restores only the leading stale instructions so newer queued work remains eligible for a new flush task.
    private func restoreLeadingQueuedClaudeSteeringDrafts(
        tabID: UUID,
        session: AgentTabSession,
        strategy: DraftRestorationStrategy,
        while shouldRestore: (AgentTabSession.ClaudeSteeringInstruction) -> Bool
    ) {
        let instructions = Array(session.pendingClaudeSteeringInstructions.prefix(while: shouldRestore))
        guard !instructions.isEmpty else { return }
        session.pendingClaudeSteeringInstructions.removeFirst(instructions.count)
        let drafts = instructions
            .map(\.draftText)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        releaseUnconsumedClaudeSupersedingProtection(for: instructions, session: session)
        restoreClaudeSteeringDrafts(drafts, tabID: tabID, strategy: strategy)
    }

    private func restoreClaudeSteeringDrafts(
        _ drafts: [String],
        tabID: UUID,
        strategy: DraftRestorationStrategy
    ) {
        guard !drafts.isEmpty else { return }
        let combined = drafts.joined(separator: "\n")
        hooks.restoreDraftText(tabID, combined, "Restored queued steering messages", strategy)
    }

    private func restoreAllQueuedDraftsForExecutionLocationChange(
        tabID: UUID,
        session: AgentTabSession,
        strategy: DraftRestorationStrategy
    ) {
        let drafts = (
            session.pendingClaudeSteeringInstructions.map(\.draftText)
                + session.pendingACPSteeringInstructions.map(\.draftText)
                + session.pendingInstructions
        )
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        guard !drafts.isEmpty else { return }
        hooks.restoreDraftText(tabID, drafts.joined(separator: "\n"), "Restored queued messages after changing execution location", strategy)
    }

    /// Concatenates all queued Claude steering draft texts and restores them to the composer.
    private func restoreAllQueuedClaudeSteeringDrafts(
        tabID: UUID,
        session: AgentTabSession,
        strategy: DraftRestorationStrategy
    ) {
        restoreQueuedClaudeSteeringDrafts(
            tabID: tabID,
            session: session,
            strategy: strategy,
            matching: { _ in true }
        )
    }

    package func cancelRun(
        tabID: UUID,
        session: AgentTabSession,
        intent: CancellationIntent = .userStop,
        completion: CancellationCompletion = .terminalPublished
    ) async {
        if session.runState.isTerminalForCommit,
           let revision = session.lastTerminalCommitRevision
        {
            await terminalCommitBarrier.awaitTerminalPublication(
                for: revision.ownership,
                session: session
            )
            if completion == .terminalTeardownCompleted {
                await terminalCommitBarrier.awaitTerminalTeardown(
                    for: revision.ownership,
                    session: session
                )
            }
            return
        }
        hooks.cancelPendingQuestion(session)
        hooks.cancelPendingApproval(session)
        hooks.cancelPendingApplyEditsReview(session, "Run cancelled")
        hooks.cancelPendingWorktreeMergeReview(session, "Run cancelled")

        // Cancel steering flush tasks first so they don't race with cleanup.
        session.claudeSteeringFlushTask?.cancel()
        session.claudeSteeringFlushTask = nil
        session.acpSteeringFlushTask?.cancel()
        session.acpSteeringFlushTask = nil

        // Ordinary stop keeps existing behavior. A cwd-changing cancellation
        // restores every queued, undelivered draft once without replaying the
        // already-delivered active prompt.
        switch intent {
        case .userStop:
            restoreAllQueuedClaudeSteeringDrafts(tabID: tabID, session: session, strategy: .prependAlways)
        case .executionLocationChange:
            restoreAllQueuedDraftsForExecutionLocationChange(tabID: tabID, session: session, strategy: .prependAlways)
        }

        let hadPendingTokenQueue = !session.pendingNonCodexUserInputTokenQueue.isEmpty
        let hadActiveTurnAccumulator = session.activeNonCodexTurnTokenAccumulator != nil
        let hadPendingInstructions = !session.pendingInstructions.isEmpty
            || !session.pendingClaudeSteeringInstructions.isEmpty
            || !session.pendingACPSteeringInstructions.isEmpty
        session.pendingNonCodexUserInputTokenQueue.removeAll()
        session.activeNonCodexTurnTokenAccumulator = nil
        session.pendingInstructions.removeAll()
        session.pendingClaudeSteeringInstructions.removeAll()
        session.pendingACPSteeringInstructions.removeAll()
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        session.claudeExpectedTurnIDs.removeAll()
        if hadPendingTokenQueue || hadActiveTurnAccumulator || hadPendingInstructions {
            session.isDirty = true
        }

        // Cancel all active MCP tool executions for this run (all providers) before stopping providers.
        cancelToolsBeforeStoppingProvider(
            session: session,
            reason: intent == .executionLocationChange ? "execution_location_change" : "user_stop"
        )

        let ownership = session.activeRunOwnership ?? session.beginRunAttempt(source: "runService.cancel")
        let expectedRunID = session.runID
        let provider = session.provider
        let acpController = session.acpController
        let hasAttemptTerminalResources = session.runAttemptTerminalResources?.ownership == ownership
        #if DEBUG
            var shouldJoinOMPQualificationStartupTeardown = false
            if completion == .terminalPublished,
               session.selectedAgent == .ohMyPi,
               hasAttemptTerminalResources,
               let startupLease = session.ompQualificationStartupLease
            {
                let startupLeaseWasReleased = await startupLease.debugCleanupSnapshot().hasReleased
                shouldJoinOMPQualificationStartupTeardown = !startupLeaseWasReleased
            }
            let effectiveCompletion: CancellationCompletion = shouldJoinOMPQualificationStartupTeardown
                ? .terminalTeardownCompleted
                : completion
        #else
            let effectiveCompletion = completion
        #endif
        let codexCancellationTarget = session.selectedAgent == .codexExec
            ? dependencies.codexCoordinator.captureCodexCancellationTarget(
                session,
                expectedRunID: expectedRunID
            )
            : nil
        session.agentTask?.cancel()

        if session.selectedAgent == .codexExec {
            dependencies.codexCoordinator.drainCodexTerminalBuffersForCancellation(session)
        }

        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: expectedRunID,
            terminalState: .cancelled,
            source: "runService.cancel",
            completion: effectiveCompletion,
            attachmentDisposition: session.selectedAgent == .codexExec ? .restoreToPending : .deleteFiles,
            finalizeNonCodexUsage: session.selectedAgent != .codexExec,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            providerDrainGeneration: session.providerTerminalDrainGeneration,
            providerBuffersAreDrained: { [dependencies] in
                session.selectedAgent != .codexExec
                    || dependencies.codexCoordinator.codexTerminalBuffersAreDrained(session)
            },
            prepareProviderState: { [dependencies] in
                if session.selectedAgent == .codexExec {
                    return dependencies.codexCoordinator.prepareCodexCancellationTeardown(
                        session,
                        expectedRunID: expectedRunID,
                        capturedTarget: codexCancellationTarget
                    )
                }
                if session.selectedAgent.usesClaudeNativeRuntime {
                    let oldController = dependencies.claudeCoordinator.prepareClaudeCancelSync(session)
                    session.provider = nil
                    return {
                        dependencies.claudeCoordinator.beginClaudeResumeTransferIfNeeded(
                            for: session,
                            oldController: oldController
                        )
                        await dependencies.claudeCoordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)
                    }
                }
                if let acpController {
                    if session.acpController === acpController {
                        session.acpController = nil
                    }
                    AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                    session.provider = nil
                    return {
                        await acpController.cancelPrompt()
                        await acpController.shutdown()
                    }
                }
                session.provider = nil
                session.runID = nil
                guard let provider, !hasAttemptTerminalResources else { return nil }
                return { await provider.dispose() }
            }
        ))
        if completion == .terminalTeardownCompleted {
            await terminalCommitBarrier.awaitTerminalTeardown(
                for: ownership,
                session: session
            )
        }
    }

    private func cancelToolsBeforeStoppingProvider(
        session: AgentTabSession,
        reason: String
    ) {
        guard let runID = session.runID else { return }
        dependencies.cancelMCPToolsForRun(runID, reason)
    }

    // MARK: - Provider Tool Stream Event Routing

    /// Routes a provider-stream tool event to the appropriate provider handler.
    /// Returns `true` when the event was consumed or suppressed, signaling
    /// `handleStreamResult` to skip its default tool processing.
    @discardableResult
    package func handleProviderToolStreamEvent(
        _ result: AIStreamResult,
        session: AgentTabSession
    ) -> Bool {
        guard let event = AgentToolStreamEvent.from(result) else { return false }
        let agent = session.selectedAgent
        if agent.acpProviderID != nil {
            return acpRunner.handleToolStreamEvent(event, session: session)
        }
        if agent.usesClaudeNativeRuntime {
            return dependencies.claudeCoordinator.handleToolStreamEvent(event, session: session)
        }
        return false
    }
}
