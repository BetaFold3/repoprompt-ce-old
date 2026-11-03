import Foundation

/// Host surface shared by the agent coordinators for session UI refresh, persistence, and
/// run-state publication.
@MainActor
package protocol AgentSessionHost: AnyObject {
    func requestUIRefresh(
        tabID: UUID,
        urgent: Bool,
        scope: AgentUIRefreshScope
    )
    func scheduleSave(for tabID: UUID)
    func setAgentRunActive(_ tabID: UUID, isActive: Bool)
    func mcpDelegationRunToolPolicy(for session: AgentTabSession) -> AgentDelegationPolicy.RunToolPolicy
}

/// Mirrors the defaults of `AgentModeViewModel.requestUIRefresh` (`urgent: false`, `scope: .full`).
@MainActor
extension AgentSessionHost {
    func requestUIRefresh(tabID: UUID) {
        requestUIRefresh(tabID: tabID, urgent: false, scope: .full)
    }

    func requestUIRefresh(tabID: UUID, urgent: Bool) {
        requestUIRefresh(tabID: tabID, urgent: urgent, scope: .full)
    }

    func requestUIRefresh(tabID: UUID, scope: AgentUIRefreshScope) {
        requestUIRefresh(tabID: tabID, urgent: false, scope: scope)
    }
}

/// Host surface used by `CodexAgentModeCoordinator`.
@MainActor
package protocol CodexAgentModeCoordinatorHost: AgentSessionHost {
    var selectedAgent: AgentProviderKind { get }
    var activeSession: AgentTabSession? { get }
    var currentTabID: UUID? { get }
    var codexDynamicModels: [CodexAppServerClient.RemoteModel] { get }
    func updateCodexDynamicModels(_ models: [CodexAppServerClient.RemoteModel])
    func applyCodexSelectionToBindings(modelRaw: String, reasoningEffortRaw: String?)
    func reconcileInteractiveRunState(_ session: AgentTabSession)
    func publishMCPStateChange(for session: AgentTabSession)
    func signalCodexInstructionDelivered(for session: AgentTabSession) async
    func restoreCodexFallbackDraft(tabID: UUID, text: String, message: String)
    func recordMCPInteractionResolution(
        for session: AgentTabSession,
        interactionID: UUID,
        fallbackResolvedBy: String
    )
    func bindPendingOracleReviewContext(tabID: UUID, runID: UUID)
    func canBuildOrPublishActiveTranscriptBindings(for session: AgentTabSession) -> Bool
    func requestAssistantPresentationRefresh(
        session: AgentTabSession,
        sourceItemsRevision: Int,
        flushGeneration: UInt64
    )
    func codexThreadDisplayName(for tabID: UUID) -> String
    func scheduleSaveForCommandOutput(tabID: UUID, minInterval: TimeInterval)
    func ensureMCPServerEnabledForThreadStart() async
    func hasLiveRunRouteInCurrentMCPServer(_ runID: UUID) -> Bool
    func applyCodexNativeContextUsage(_ usage: AgentContextUsage, session: AgentTabSession)
    func refreshCodexContextUsageSnapshot(for session: AgentTabSession)
    func clearContextUsageSnapshot(for session: AgentTabSession)
    func markAttachmentsConsumed(for session: AgentTabSession, reservationID: UUID?)
    func stageConsumedAttachmentFilesForDeferredCleanup(_ attachments: [AgentImageAttachment], session: AgentTabSession)
    func finalizeAttachmentsForTurn(
        for session: AgentTabSession,
        reservationID: UUID?,
        disposition: AgentAttachmentTurnDisposition
    )
}

/// Mirrors the default of `AgentModeViewModel.recordMCPInteractionResolution` (`fallbackResolvedBy: "user"`).
@MainActor
extension CodexAgentModeCoordinatorHost {
    func recordMCPInteractionResolution(
        for session: AgentTabSession,
        interactionID: UUID
    ) {
        recordMCPInteractionResolution(
            for: session,
            interactionID: interactionID,
            fallbackResolvedBy: "user"
        )
    }
}

/// Immutable identity of one committed durable dispatch a history baseline binds to (Phase 4).
package struct AgentDispatchBaselineIdentity: Equatable {
    /// Existing durable dispatch identity (the first delivery attempt ID).
    package let dispatchID: UUID
    package let runAttemptID: UUID?
    /// Ordered local user items of the dispatch's constituents.
    package let userItemIDs: [UUID]
    /// Whether `userItemIDs` is the dispatch's complete constituent list: every constituent named
    /// its user item, none was dropped, the list is nonempty and duplicate-free. Only a complete
    /// identity can carry an outbound user-message claim (baseline capture itself is unchanged).
    package let hasCompleteUserItems: Bool

    package init(dispatchID: UUID, runAttemptID: UUID?, userItemIDs: [UUID], hasCompleteUserItems: Bool = false) {
        self.dispatchID = dispatchID
        self.runAttemptID = runAttemptID
        self.userItemIDs = userItemIDs
        self.hasCompleteUserItems = hasCompleteUserItems
    }
}

/// Whether the pre-byte history baseline refused one Claude write (main-actor box shared with
/// the controller's write-admission closure).
@MainActor
final class ClaudeDispatchBaselineRefusal {
    var refused = false
}

/// Host surface used by `ClaudeAgentModeCoordinator`.
@MainActor
package protocol ClaudeAgentModeCoordinatorHost: AgentSessionHost {
    var sessions: [UUID: AgentTabSession] { get }
    var providerBindingService: AgentModeProviderBindingService { get }
    func provisionalClaudeContextWindowKey(for session: AgentTabSession) -> ClaudeProvisionalContextWindowResolver.Key?
    func syncSpawnResolvedClaudeConfiguredContextWindow(
        _ value: Int?,
        launchKey: ClaudeProvisionalContextWindowResolver.Key,
        for session: AgentTabSession
    )
    func stageClaudeResumeRecoveryHandoffIfNeeded(
        for session: AgentTabSession,
        ifStillOwned: @escaping @MainActor () -> Bool,
        beforeCommit: (@MainActor () async -> Void)?
    ) async -> Bool
    /// Prepends the pending-handoff payload when it is neither staged nor held, reporting the
    /// exact stage this call created.
    func stagePendingHandoffIfNeeded(
        _ text: String,
        session: AgentTabSession
    ) -> AgentStagedProviderText
    /// Durable form: stages the payload and returns its exact snapshot (payload ID saved first),
    /// for `AgentProviderHandoff.notePendingHandoff` before the dispatch commit.
    func stagePendingHandoffForDurableDispatch(
        _ text: String,
        session: AgentTabSession
    ) async -> AgentPendingHandoffDispatchStaging
    @discardableResult
    func updatePermissionBindingState(from session: AgentTabSession, syncUI: Bool) -> Bool
    /// Lossless restart Phase 4: inside the managed-transport write admission, immediately before
    /// a Claude dispatch's user bytes, capture and commit that dispatch's pre-send history baseline.
    /// `.denied` = the enabled baseline could not be persisted (zero bytes are sent). With history
    /// reconciliation unqualified (production) it admits without any read or write. The admitted
    /// UUID is `outboundUserMessage.uuid` only when THIS call newly committed a captured baseline
    /// carrying that claim (complete canonical constituents); otherwise it is omitted.
    func admitClaudeDispatchBaseline(
        _ identity: AgentDispatchBaselineIdentity?,
        outboundUserMessage: AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage?,
        session: AgentTabSession
    ) async -> AgentRuntimeWriteAdmission
}

/// Mirrors the default of `AgentModeViewModel.updatePermissionBindingState` (`syncUI: true`).
@MainActor
extension ClaudeAgentModeCoordinatorHost {
    /// Hosts without recovery capture nothing and admit the ordinary send.
    package func admitClaudeDispatchBaseline(
        _: AgentDispatchBaselineIdentity?,
        outboundUserMessage _: AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage?,
        session _: AgentTabSession
    ) async -> AgentRuntimeWriteAdmission {
        .admittedWithoutIdentity
    }

    @discardableResult
    func updatePermissionBindingState(from session: AgentTabSession) -> Bool {
        updatePermissionBindingState(from: session, syncUI: true)
    }
}

@MainActor
package protocol AgentModeRunInteractionStateObserving: AnyObject {
    func agentModeViewModel(
        _ viewModel: any AgentSessionHost,
        didChangeRunInteractionStateFor session: AgentTabSession,
        reason: AgentRunInteractionStateChangeReason
    )
}
