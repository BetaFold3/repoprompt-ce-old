import Combine
import Foundation
import RepoPromptShared
import RepoPromptWorkspace

/// A resend selector carries either a picked target (`windowID`, with an optional `workspaceID` guard
/// and `workspaceName` nil) or a name-only selector (`workspaceName`, with IDs nil), never both.
/// The gateway ANDs ID and name matching, so a mixed selector can match zero windows.
package struct AgentRemoteResendPayload {
    package let providerText: String
    package let wasStart: Bool
    package let modelSelectionRaw: String?
    package let sessionName: String?
    package let workspaceName: String?
    package let windowID: Int?
    package let workspaceID: String?

    package init(
        providerText: String,
        wasStart: Bool,
        modelSelectionRaw: String?,
        sessionName: String?,
        workspaceName: String?,
        windowID: Int? = nil,
        workspaceID: String? = nil
    ) {
        self.providerText = providerText
        self.wasStart = wasStart
        self.modelSelectionRaw = modelSelectionRaw
        self.sessionName = sessionName
        self.workspaceName = workspaceName
        self.windowID = windowID
        self.workspaceID = workspaceID
    }
}

/// Per-tab session state for agent mode
@MainActor
package final class AgentTabSession: ObservableObject {
    package let tabID: UUID
    private var suppressSourceItemsChanged = false

    /// Canonical runtime source-item suffix. Coordinators and tests mutate this list,
    /// but it only retains the mutable full-detail working turns; older compacted
    /// history lives in `transcript` and should not be rehydrated back into this array.
    @Published package var items: [AgentChatItem] = [] {
        didSet {
            guard !suppressSourceItemsChanged else { return }
            repairStoredSourceItemsIfNeeded(diagnosticContext: "items.didSet")
            rebuildSourceItemDerivedState()
            onSourceItemsChanged?(self, .structural, .itemsDidSet)
        }
    }

    package var transcript: AgentTranscript = .empty {
        didSet {
            guard rawInputSanitizeEvidence != nil,
                  !Self.transcriptActivitiesMatch(oldValue, transcript)
            else {
                return
            }
            rawInputSanitizeEvidence = nil
        }
    }

    /// When non-nil, the exact pre-sanitize input and per-activity processing flags of the
    /// build whose sanitized activities are installed in `transcript`. It makes no claim about
    /// current source items or maps. Any write that changes `transcript`'s activities or
    /// structure drops it. Retention that changes source items keeps it while a run is active
    /// (the next build reuses its unchanged activities) and drops it otherwise, so an idle
    /// session does not pin pre-retention raw payloads; the next full import re-seeds it.
    /// Session-local, never persisted.
    package var rawInputSanitizeEvidence: AgentSanitizeRawInputEvidence?
    #if DEBUG
        /// Test seam: derive this session's transcript without incremental import or any
        /// sanitize/projection reuse, keeping its durable compacted history.
        package var test_forcesColdDerivedTranscriptBuild = false
    #endif
    package var baseTranscriptProjection: AgentTranscriptProjection = .empty
    package var fullTranscriptProjection: AgentTranscriptProjection = .empty
    package var workingTranscriptProjection: AgentTranscriptProjection = .empty
    package var transcriptProjection: AgentTranscriptProjection = .empty
    package var turnProjectionCaches: [UUID: AgentTranscriptTurnProjectionCache] = [:]
    package var archivedTranscriptSnapshot: AgentArchivedTranscriptSnapshot = .empty
    package var isCompressedHistoryRevealed: Bool = false
    package var isTranscriptWindowExpanded: Bool = false
    package var transcriptProjectionProtection: AgentTranscriptProjectionProtection = .none
    package var transcriptCanonicalVisibleRowCount: Int = 0
    package var transcriptProjectionCounts: AgentTranscriptProjectionCounts = .zero
    package var transcriptAnalyticsSnapshot: AgentTranscriptAnalyticsSnapshot = .init()
    package var transcriptPerformanceSnapshot: AgentTranscriptPerformanceSnapshot = .empty
    package var ephemeralToolResultPayloadByItemID: [UUID: String] = [:]
    package var ephemeralToolResultPayloadRevisionByItemID: [UUID: Int] = [:]
    private(set) var oracleUIIdentitySidecarByChatID: [String: String] = [:]
    package private(set) var liveItemIDs: Set<UUID> = []
    private var toolCorrelationIndexes = ToolCorrelationIndexes()
    private var nextEphemeralToolResultPayloadRevision: Int = 1
    package var rawToolResultPayloadRenderRevisionByItemID: [UUID: Int] = [:]
    /// The caller is the static source location of the mutation entry call (diagnostics only).
    package var onSourceItemsChanged: ((AgentTabSession, AgentSourceItemsMutation, AgentSourceItemsMutationCaller) -> Void)?
    package var onRunStateChanged: ((AgentTabSession) -> Void)?
    #if DEBUG
        private(set) var test_incrementalRetentionCompactionCount = 0
        /// Duplicate-ID repair scans run at this session's source-write boundaries.
        private(set) var test_sourceItemDuplicateRepairScanCount = 0
        /// Full derived-state rebuilds (`rebuildSourceItemDerivedState`).
        private(set) var test_sourceItemDerivedRebuildCount = 0
    #endif

    /// Run state
    @Published package var runState: AgentSessionRunState = .idle {
        didSet {
            guard runState != oldValue else { return }
            onRunStateChanged?(self)
        }
    }

    @Published package var runningStatusText: String? = nil
    package var activeAgentRunStartedAt: Date?

    package enum RunningStatusSource: Equatable {
        case transport
        case reasoning
        case reconnect
    }

    package struct CodexReasoningSegmentState {
        package var summaryMarkdown: String = ""
        package var bodyMarkdown: String = ""
        var transcriptItemID: UUID?
        var statusTitle: String?
    }

    package struct AgentTurnRuntimeAnchor: Equatable {
        package let userItemID: UUID
        package let userSequenceIndex: Int
        package let startedAt: Date

        package init(
            userItemID: UUID,
            userSequenceIndex: Int,
            startedAt: Date
        ) {
            self.userItemID = userItemID
            self.userSequenceIndex = userSequenceIndex
            self.startedAt = startedAt
        }
    }

    package var runningStatusSource: RunningStatusSource?
    package var nativeControlProgressID: UUID?
    package var claudeReasoningStatusBuffer: String = ""
    package var claudeReasoningStatusPendingText: String?
    package var claudeReasoningStatusFlushTask: Task<Void, Never>?
    package var codexReasoningSegmentsByKey: [String: CodexReasoningSegmentState] = [:]
    package var pendingTurnRuntimeAnchors: [AgentTurnRuntimeAnchor] = []
    package var agentMessageRuntimeFootersByItemID: [UUID: AgentMessageRuntimeFooter] = [:]

    /// Tracks whether this session already contains a real user turn.
    /// Provider selection may still remain temporarily editable for a handoff destination
    /// until its first destination-side send succeeds.
    package var hasSentFirstMessage: Bool = false

    package var deservesProviderVisibleBranchSwitchNote: Bool {
        runState.isActive || providerSessionID != nil || !items.isEmpty || hasSentFirstMessage
    }

    /// Ephemeral location intent for a new manual thread. It is consumed on first send
    /// and intentionally never persisted as session state.
    package var pendingInitialStartLocation: AgentInitialStartLocation = .local
    package var composerSubmissionToken = UUID()
    package var activeComposerSubmitAttempt: AgentComposerSubmitAttempt?
    package var isComposerSubmissionInFlight: Bool {
        activeComposerSubmitAttempt != nil
    }

    package var isPreparingInitialWorktree: Bool = false
    package var isChangingExecutionLocation: Bool = false
    package var worktreeBindingTransitionInProgress: Bool = false

    // Wait/question state

    @Published package var waitingPrompt: String? = nil

    /// The three question props notify on aggregate (`hasPendingQuestionUI`) changes only:
    /// draft edits and non-nil replacement keep the aggregate and stay silent.
    @Published package var pendingAskUser: AgentAskUserPendingState? = nil {
        didSet {
            notePendingQuestionUIAggregateChange(
                from: oldValue != nil || pendingUserInputRequest != nil || pendingMCPElicitationRequest != nil
            )
        }
    }

    @Published package var pendingUserInputRequest: AgentRequestUserInputRequest? = nil {
        didSet {
            if pendingUserInputDrafts?.requestID != pendingUserInputRequest?.id {
                pendingUserInputDrafts = nil
            }
            notePendingQuestionUIAggregateChange(
                from: pendingAskUser != nil || oldValue != nil || pendingMCPElicitationRequest != nil
            )
        }
    }

    /// Partial answers of `pendingUserInputRequest`. Owned by the session (not the card) so
    /// shutdown preparation snapshots non-secret answers and vetoes on a non-empty secret one.
    /// Memory-only; dropped whenever the pending request changes.
    package var pendingUserInputDrafts: AgentRequestUserInputDraftState?

    @Published package var pendingApproval: AgentApprovalRequest? = nil
    @Published package var pendingPermissionsRequest: AgentPermissionsRequest? = nil
    @Published package var pendingMCPElicitationRequest: AgentMCPElicitationRequest? = nil {
        didSet {
            notePendingQuestionUIAggregateChange(
                from: pendingAskUser != nil || pendingUserInputRequest != nil || oldValue != nil
            )
        }
    }

    @Published package var pendingApplyEditsReview: PendingApplyEditsReview? = nil
    @Published package var pendingWorktreeMergeReview: PendingWorktreeMergeReview? = nil
    package var queuedUserInputRequests: [AgentRequestUserInputRequest] = []
    package var queuedMCPElicitationRequests: [AgentMCPElicitationRequest] = []
    package var transcriptViewportState: AgentTranscriptViewportState = .liveBottom
    package var transcriptAutoFollowArmingState: AgentTranscriptAutoFollowArmingState = .armed
    package var askUserContinuation: CheckedContinuation<AgentAskUserResponse, Error>?
    /// An `ask_user` whose snapshot is being committed before it is published (plan §E): a
    /// concurrent request is refused as if this one were already pending.
    package var recoveryQuestionCreationReservation: UUID?
    /// Interactions whose answer is flushing its latest snapshot before the reply is sent: further
    /// edits, answers, and the timeout are refused for them meanwhile.
    package var recoveryQuestionResolutionReservations: Set<UUID> = []
    package var askUserTimeoutTask: Task<Void, Never>?
    package var pendingAskUserTimeoutGeneration: UInt64 = 0
    package var hasPendingQuestionUI: Bool {
        pendingAskUser != nil || pendingUserInputRequest != nil || pendingMCPElicitationRequest != nil
    }

    /// Fired synchronously when `hasPendingQuestionUI` flips; wired by the owning view model.
    package var onPendingQuestionUIChanged: ((AgentTabSession) -> Void)?

    private func notePendingQuestionUIAggregateChange(from previousAggregate: Bool) {
        guard previousAggregate != hasPendingQuestionUI else { return }
        onPendingQuestionUIChanged?(self)
    }

    package var applyEditsApprovalSubscriptionID: UUID?
    package var applyEditsApprovalScopeGeneration: UInt64?
    package var applyEditsApprovalSubscriptionTask: Task<Void, Never>?
    package var applyEditsApprovalSetupID: UUID?
    package var worktreeMergeReviewContinuation: CheckedContinuation<WorktreeMergeReviewDecision, Never>?
    package var worktreeMergeReviewTimeoutTask: Task<Void, Never>?
    /// Step 5c: shown reviews whose decision was submitted (card cleared) but not yet processed by
    /// the waiting request. A lifecycle end treats them as shown, so a same-turn run end, reset, or
    /// replacement keeps them as history instead of withdrawing them. In memory only.
    package var resolvingWorktreeMergeReviewOperationIDs: Set<String> = []
    /// Step 5c: in-flight or unacknowledged Discard of an ended merge review. In memory only.
    package var worktreeMergeReviewDiscard: AgentWorktreeMergeReviewDiscardState?
    package var mcpControlContext: AgentMCPControlContext?
    #if DEBUG
        package var ompQualificationStartContext: OhMyPiAgentModeSmokeGate.StartContext? {
            didSet {
                if let ompQualificationStartContext {
                    mcpStartInvocationGenerationID = ompQualificationStartContext.generationID
                }
            }
        }

        /// Durable start ownership retained after any transient qualification context clears.
        package var mcpStartInvocationGenerationID: UUID?
        /// Atomic MainActor discard claim; a later invocation may not replace a claimed target.
        package var mcpStartDiscardClaimGenerationID: UUID?
        /// OMP qualification startup lease used only to join cancellation while still unreleased.
        var ompQualificationStartupLease: MCPBootstrapLease?
    #endif
    package var mcpStateObservationCancellable: AnyCancellable?
    package var mcpControlCleanupTask: Task<Void, Never>?
    package var mcpControlActivationGeneration: UInt64 = 0
    package var mcpFollowUpRunPendingUpdatedAt: Date?
    package var mcpFollowUpRunPending: Bool = false {
        didSet {
            if oldValue != mcpFollowUpRunPending {
                mcpFollowUpRunPendingUpdatedAt = Date()
            }
        }
    }

    package var isMCPInstructionDispatchInProgress: Bool = false
    /// Session provenance (plan §6.4). `.user` unless MCP control created or
    /// claimed this session.
    package var origin: AgentSessionOrigin = .user
    /// Whether this session was originally created by an MCP client (derived from `origin`).
    package var isMCPOriginated: Bool {
        origin.isMCPOriginated
    }

    /// Most recent resolved interaction (id + attribution), surfaced through MCP
    /// snapshots as `interaction_resolved` metadata on wait/poll responses.
    package var lastInteractionResolution: AgentRunMCPSnapshot.InteractionResolution?
    /// Staged `resolved_by` attribution for an in-flight MCP `respond` call.
    /// Consumed by `recordMCPInteractionResolution`; `nil` means user-local.
    package var pendingInteractionResolutionAttribution: String?
    /// Remote host/session binding for gateway-projected sessions.
    package var remoteHost: AgentSessionRemoteHostBinding?
    /// Optimistic local user rows awaiting replacement by host-projected transcript rows.
    package var pendingRemoteOptimisticUserItemIDs: Set<UUID> = []
    /// Exact provider-facing text used to match pending optimistic rows against host catch-up.
    /// Keys are transient and must remain a subset of `pendingRemoteOptimisticUserItemIDs`.
    package var pendingRemoteOptimisticProviderTextByItemID: [UUID: String] = [:]
    /// Provider payloads for explicit item-level resend; normalized name-only or window-ID selectors round-trip through persistence.
    package var remoteResendPayloadsByItemID: [UUID: AgentRemoteResendPayload] = [:]
    package var remoteResendInFlightItemIDs: Set<UUID> = []
    /// Optimistic item whose locally successful remote start produced the adopted session.
    /// Persisted from local success only; inbound binding/catch-up events must never infer this attribution.
    package var locallyAttributedStartItemID: UUID?

    /// Right utility panel state for this tab: segment, compare target, expansion, preview
    /// document. Intentionally never mapped into the persisted `AgentSession` DTO — see
    /// `AgentUtilityPanelTabState` for why none of it survives a relaunch.
    package var utilityPanel = AgentUtilityPanelTabState()

    /// Persisted logical-root to worktree bindings for this Agent session.
    package var worktreeBindings: [AgentSessionWorktreeBinding] = []
    /// Persisted resumable worktree-merge operations for this Agent session.
    package var worktreeMergeOperations: [AgentSessionWorktreeMergeOperation] = []
    /// Session-lifetime product profile. This is selected only for a fresh session and
    /// is never mutated after provider or transcript work begins.
    package private(set) var profile: AgentSessionProfile = .standard

    /// Adopt a profile while this tab is still an untouched construction placeholder.
    /// Persisted hydration and fresh Knowledge-session creation both use this narrow seam;
    /// live sessions must create a new tab instead of changing prompts or tool policy in place.
    @discardableResult
    package func adoptSessionProfile(_ requestedProfile: AgentSessionProfile) -> Bool {
        guard profile != requestedProfile else { return true }
        guard runState == .idle,
              runID == nil,
              activeRunAttemptID == nil,
              !hasSentFirstMessage,
              providerSessionID == nil,
              codexConversationID == nil,
              claudeController == nil,
              codexController == nil,
              acpController == nil,
              mcpControlContext == nil,
              items.isEmpty,
              transcript.turns.isEmpty
        else {
            return false
        }
        profile = requestedProfile
        return true
    }

    /// Permission profile for the current session. Set to `.mcpSafeDefaults`
    /// when MCP control is active, `.userConfigured` otherwise.
    package var permissionProfile: AgentProviderPermissionProfile = .userConfigured

    /// Instruction queue for when user sends while agent is not waiting (shared across all runners).
    /// Each entry carries the identity of the user input(s) it delivers.
    package var pendingInstructions: [AgentPendingInstruction] = []
    /// `.inactive` until recovery activation; `.mandatory` refuses untracked queued input.
    package var recoveryAdmissionMode: AgentRecoveryAdmissionMode = .inactive
    package let codexSteerAckTracker = CodexSteerAckTracker()

    /// Claude-only steering queue — carries draft text for restoration on cancel/failure
    package struct ClaudeSteeringInstruction: Equatable, Identifiable {
        package let id: UUID
        /// The Claude run this steering message was queued against.
        let targetRunID: UUID?
        /// The Claude runner attempt this steering message was queued against.
        let targetRunAttemptID: UUID?
        /// The text we actually send to the provider (may include workflow wrapping, etc.)
        let providerText: String
        let attachments: [AgentImageAttachment]
        let taggedFileAttachments: [AgentTaggedFileAttachment]
        package let documentAttachments: [AgentDocumentAttachment]
        /// The original user-typed text to restore into the composer on failure/cancel.
        let draftText: String
        /// The queued user input this steering delivers (its user item is the optimistic bubble).
        package let identity: AgentQueuedInputIdentity
        let createdAt: Date
        /// Claude turn completions protected by this accepted steering instruction.
        var supersedingProtectedTurnIDs: Set<UUID> = []

        package init(
            id: UUID,
            targetRunID: UUID?,
            targetRunAttemptID: UUID?,
            providerText: String,
            attachments: [AgentImageAttachment],
            taggedFileAttachments: [AgentTaggedFileAttachment],
            documentAttachments: [AgentDocumentAttachment] = [],
            draftText: String,
            identity: AgentQueuedInputIdentity,
            createdAt: Date,
            supersedingProtectedTurnIDs: Set<UUID> = []
        ) {
            self.id = id
            self.targetRunID = targetRunID
            self.targetRunAttemptID = targetRunAttemptID
            self.providerText = providerText
            self.attachments = attachments
            self.taggedFileAttachments = taggedFileAttachments
            self.documentAttachments = documentAttachments
            self.draftText = draftText
            self.identity = identity
            self.createdAt = createdAt
            self.supersedingProtectedTurnIDs = supersedingProtectedTurnIDs
        }

        /// The optimistic user bubble we appended (for potential removal on failure).
        var optimisticUserItemID: UUID? {
            identity.userItemID
        }
    }

    package var pendingClaudeSteeringInstructions: [ClaudeSteeringInstruction] = []
    /// Claude turn IDs whose terminal events should be treated as superseded by accepted steering.
    package var claudeSupersedingProtectedTurnIDs: Set<UUID> = []
    /// Task that drains `pendingClaudeSteeringInstructions` one-by-one, waiting for MCP tool idle between each.
    package var claudeSteeringFlushTask: Task<Void, Never>?

    /// ACP steering queue — carries text accepted for serialized live steering.
    package struct ACPSteeringInstruction: Identifiable {
        package let id: UUID
        /// The ACP process run this steering message was queued against.
        let targetRunID: UUID?
        /// The ACP runner attempt this steering message was queued against.
        let targetRunAttemptID: UUID?
        /// The steering text we actually send to the provider (may include workflow wrapping, etc.)
        package let providerText: String
        /// The active ACP prompt's user text when this steering was queued. Some
        /// providers drop the cancelled prompt from provider history, so the flush
        /// re-bundles this with `providerText` after session/cancel.
        let interruptedPromptProviderText: String?
        let attachments: [AgentImageAttachment]
        let taggedFileAttachments: [AgentTaggedFileAttachment]
        package let documentAttachments: [AgentDocumentAttachment]
        /// The original user-typed text to restore into the composer on failure/cancel.
        let draftText: String
        /// The queued user input this steering delivers (its user item is the optimistic bubble).
        package let identity: AgentQueuedInputIdentity
        let createdAt: Date

        package init(
            id: UUID,
            targetRunID: UUID?,
            targetRunAttemptID: UUID?,
            providerText: String,
            interruptedPromptProviderText: String?,
            attachments: [AgentImageAttachment],
            taggedFileAttachments: [AgentTaggedFileAttachment],
            documentAttachments: [AgentDocumentAttachment] = [],
            draftText: String,
            identity: AgentQueuedInputIdentity,
            createdAt: Date
        ) {
            self.id = id
            self.targetRunID = targetRunID
            self.targetRunAttemptID = targetRunAttemptID
            self.providerText = providerText
            self.interruptedPromptProviderText = interruptedPromptProviderText
            self.attachments = attachments
            self.taggedFileAttachments = taggedFileAttachments
            self.documentAttachments = documentAttachments
            self.draftText = draftText
            self.identity = identity
            self.createdAt = createdAt
        }

        /// The optimistic user bubble we appended (for potential removal on failure).
        var optimisticUserItemID: UUID? {
            identity.userItemID
        }
    }

    package var pendingACPSteeringInstructions: [ACPSteeringInstruction] = []
    /// Task that drains `pendingACPSteeringInstructions` one-by-one, waiting for MCP tool idle between each.
    package var acpSteeringFlushTask: Task<Void, Never>?

    /// Attention notifications only: which source rows are a run attempt's own output. Rows at or
    /// after `minimumSourceSequenceIndex` (the next index when the attempt began), plus the one
    /// earlier assistant row this attempt's authoritative final content actually replaced.
    /// Runtime-only; never persisted, published, or used by transcript or MCP authorities.
    package struct AttentionTextProvenance: Equatable {
        package let attemptID: UUID
        package let minimumSourceSequenceIndex: Int
        package var rewrittenPreBoundaryAssistantRowID: UUID?
    }

    package var attentionTextProvenance: AttentionTextProvenance?
    /// Attention notifications only: one settled completion capture held while ACP steering
    /// handoff work could still start a later attempt for it.
    package var attentionDeferredCompletion: AttentionNotificationCapture?
    /// Attention notifications only: ACP follow-up starts registered for observation whose start
    /// has not returned yet.
    package var attentionOutstandingFollowUpStartIDs: Set<UUID> = []

    /// Records that `attemptID`'s authoritative final content replaced an assistant row that
    /// predates the attempt. Call only after the replacement; it verifies the row now holds `text`.
    package func recordAttentionFinalContentRewrite(attemptID: UUID, rowID: UUID, text: String) {
        guard var provenance = attentionTextProvenance,
              provenance.attemptID == attemptID,
              let row = items.first(where: { $0.id == rowID }),
              row.kind == .assistant,
              row.text == text,
              row.sequenceIndex < provenance.minimumSourceSequenceIndex
        else { return }
        provenance.rewrittenPreBoundaryAssistantRowID = rowID
        attentionTextProvenance = provenance
    }

    /// Number of upcoming turnCompleted events that should be treated as intermediate
    /// because we successfully queued a follow-up prompt during the same run.
    package var pendingSupersedingTurnCompletionsUpdatedAt: Date?
    package var pendingSupersedingTurnCompletions: Int = 0 {
        didSet {
            if oldValue != pendingSupersedingTurnCompletions {
                pendingSupersedingTurnCompletionsUpdatedAt = Date()
            }
        }
    }

    struct CodexPendingAuthRetryTurn: Equatable {
        var text: String
        var images: [AgentImageAttachment]
        var model: String?
        var reasoningEffort: String?
        var serviceTier: String?
        var attachmentReservationID: UUID?
        var expectedTurnID: String?
        var retryAttempted: Bool = false
    }

    package enum CodexTurnKind: String {
        case user
        case compact
        case review
        case unknown
    }

    package struct CodexAuthoritativeTurnIdentity: Equatable {
        let threadID: String
        let turnID: String
        let turnKind: CodexTurnKind
        let controllerInstanceID: ObjectIdentifier
        let controllerGeneration: UUID
        let runID: UUID
        let runAttemptID: UUID
    }

    package struct CodexAnonymousTurnLiveness: Equatable {
        let threadID: String
        let turnKind: CodexTurnKind
        let controllerInstanceID: ObjectIdentifier
        let controllerGeneration: UUID
        let runID: UUID
        let runAttemptID: UUID
    }

    package enum CodexFallbackOrigin: Equatable {
        case manual
        case mcp(attemptID: UUID)

        var isMCP: Bool {
            switch self {
            case .mcp:
                true
            case .manual:
                false
            }
        }
    }

    @MainActor
    package final class CodexDispatchSerialGate {
        private var nextTicket: UInt64 = 0
        private var servingTicket: UInt64 = 0
        private var cancelledTickets: Set<UInt64> = []
        private var waiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]

        package func issueTicket() -> UInt64 {
            defer { nextTicket &+= 1 }
            return nextTicket
        }

        package func awaitTurn(_ ticket: UInt64) async -> Bool {
            if cancelledTickets.remove(ticket) != nil {
                advancePastCancelledTickets()
                return false
            }
            if ticket == servingTicket {
                return true
            }
            return await withCheckedContinuation { continuation in
                waiters[ticket] = continuation
            }
        }

        package func finish(_ ticket: UInt64) {
            guard ticket == servingTicket else { return }
            servingTicket &+= 1
            advancePastCancelledTickets()
            waiters.removeValue(forKey: servingTicket)?.resume(returning: true)
        }

        package func cancel(_ ticket: UInt64) {
            if let waiter = waiters.removeValue(forKey: ticket) {
                waiter.resume(returning: false)
            }
            cancelledTickets.insert(ticket)
            guard ticket == servingTicket else { return }
            advancePastCancelledTickets()
            waiters.removeValue(forKey: servingTicket)?.resume(returning: true)
        }

        private func advancePastCancelledTickets() {
            while cancelledTickets.remove(servingTicket) != nil {
                servingTicket &+= 1
            }
        }
    }

    package enum CodexFallbackReason: Equatable {
        case activeWithoutAuthoritativeIdentity
        /// A cold send found the just-resumed thread already active without a turn this
        /// coordinator saw start; the idle pump releases it once a read reports `.idle`.
        case resumedThreadActive
        case staleAuthoritativeIdentity
        case nonSteerableTurn(kind: CodexTurnKind)
        case noActiveTurn(failure: CodexAppServerClient.RequestFailure)
        case expectedTurnMismatch(
            expectedTurnID: String,
            actualTurnID: String?,
            failure: CodexAppServerClient.RequestFailure
        )
        case activeTurnNotSteerable(
            turnKind: String?,
            failure: CodexAppServerClient.RequestFailure
        )
    }

    package struct CodexFallbackSubmissionContext: Equatable {
        package let queueID: UUID
        let providerText: String
        package let images: [AgentImageAttachment]
        package let taggedFileAttachments: [AgentTaggedFileAttachment]
        /// Documents this submission delivers. Their manifest is already part of `providerText`
        /// once prepared; the records restore the composer when the submission is returned.
        package let documentAttachments: [AgentDocumentAttachment]
        package let draftText: String
        /// The user input this submission delivers. A durable identity's intent ID is the queue ID.
        package let identity: AgentQueuedInputIdentity
        package let origin: CodexFallbackOrigin
        package let dispatchTicket: UInt64?

        package init(
            queueID: UUID,
            providerText: String,
            images: [AgentImageAttachment],
            taggedFileAttachments: [AgentTaggedFileAttachment],
            documentAttachments: [AgentDocumentAttachment] = [],
            draftText: String,
            identity: AgentQueuedInputIdentity,
            origin: CodexFallbackOrigin,
            dispatchTicket: UInt64?
        ) {
            assert(
                identity.intentID == nil || identity.intentID == queueID,
                "A durable Codex fallback submission is queued under its recovery intent ID"
            )
            self.queueID = queueID
            self.providerText = providerText
            self.images = images
            self.taggedFileAttachments = taggedFileAttachments
            self.documentAttachments = documentAttachments
            self.draftText = draftText
            self.identity = identity
            self.origin = origin
            self.dispatchTicket = dispatchTicket
        }

        package var optimisticUserItemID: UUID? {
            identity.userItemID
        }
    }

    struct CodexFallbackBlockingTurn: Equatable {
        let threadID: String
        let turnID: String
        let controllerInstanceID: ObjectIdentifier
        let controllerGeneration: UUID
        let runID: UUID
        let runAttemptID: UUID
    }

    struct CodexPendingSteerLifecycleReconciliation: Equatable {
        let priorIdentity: CodexAuthoritativeTurnIdentity
        let acceptedDispatchTurnID: String
    }

    enum CodexFallbackQueueState: Equatable {
        case queued
        case eligibleForSuccessor(completedTurnID: String)
        case dispatching
        case awaitingLifecycleStart
        case lifecycleStarted
    }

    package struct CodexFallbackQueueEntry: Equatable, Identifiable {
        package let id: UUID
        /// Mutable only so a released delegated-question stage can remove its exact runtime
        /// block before dispatch (`removeReleasedStageBlockFromQueuedCodexFallbacks`).
        package var providerText: String
        let images: [AgentImageAttachment]
        let taggedFileAttachments: [AgentTaggedFileAttachment]
        package var documentAttachments: [AgentDocumentAttachment] = []
        let model: String?
        let reasoningEffort: String?
        let serviceTier: String?
        let attachmentReservationID: UUID?
        /// The user input this entry delivers (copied from its submission context).
        package let identity: AgentQueuedInputIdentity
        package var draftText: String
        let origin: CodexFallbackOrigin
        let fallbackReason: CodexFallbackReason
        let originThreadID: String
        let originControllerInstanceID: ObjectIdentifier
        let originControllerGeneration: UUID
        let originRunID: UUID
        let originRunAttemptID: UUID
        var blockingTurn: CodexFallbackBlockingTurn?
        var state: CodexFallbackQueueState

        var optimisticUserItemID: UUID? {
            identity.userItemID
        }
    }

    package var codexPendingTurnKind: CodexTurnKind?
    var codexPendingAuthRetryTurn: CodexPendingAuthRetryTurn?
    package var codexAuthoritativeActiveTurn: CodexAuthoritativeTurnIdentity?
    package var codexAnonymousActiveTurn: CodexAnonymousTurnLiveness?
    package var codexRoutingObservedTurnID: String?
    var codexPendingSteerLifecycleReconciliation: CodexPendingSteerLifecycleReconciliation?
    /// Tail of this session's provider-turn record writes (9-live R2): each write awaits the previous
    /// one, so they commit in authoritative-install order. Never awaited by event handling.
    package var codexProviderTurnWriteTask: Task<Void, Never>?
    package var codexFallbackQueue: [CodexFallbackQueueEntry] = []
    package var codexFallbackDispatchInFlight: CodexFallbackQueueEntry?
    var codexDeliveredMCPFallbackAttemptIDs: Set<UUID> = []
    var codexDeliveredMCPFallbackAttemptOrder: [UUID] = []
    package var codexFallbackPumpTask: Task<Void, Never>?
    var codexFallbackSuccessorRetryTask: Task<Void, Never>?
    package let codexDispatchSerialGate = CodexDispatchSerialGate()

    // Instruction steering coordination state
    package var instructionContinuation: CheckedContinuation<UserInstructionResponse, Error>?
    package var instructionTimeoutTask: Task<Void, Never>?
    package var instructionWaitID: UUID?
    /// The newest `wait_for_next_instruction` call (set at its entry, before any await). A queued-head
    /// drain that suspends hands the head off only while it still owns the wait; a newer call
    /// supersedes it.
    package var instructionWaitOwnerID: UUID?

    /// Agent run
    package var runID: UUID? {
        didSet {
            if let runID {
                lastObservedRunID = runID
            }
        }
    }

    private(set) var runLifecycleTracker = AgentRunLifecycleTracker()
    /// Monotonic count of run attempts begun on this tab. Unlike `activeRunOwnership`, terminal
    /// teardown never clears it, so work captured under one attempt can still tell that a later
    /// attempt took the tab after that attempt has ended and released its controller and run ID.
    private(set) var runAttemptGeneration: UInt64 = 0
    package var activeRunOwnership: AgentRunOwnership? {
        runLifecycleTracker.activeOwnership
    }

    package var activeRunAttemptID: UUID? {
        activeRunOwnership?.attemptID
    }

    package var activeRunLiveness: AgentRunLivenessSnapshot? {
        runLifecycleTracker.liveness
    }

    package var provider: HeadlessAgentProvider?
    package var agentTask: Task<Void, Never>?

    // Settings (per-tab)
    package var selectedAgent: AgentProviderKind = .claudeCode
    package var selectedModelRaw: String = AgentModel.defaultModel.rawValue
    package var ohMyPiThinkingSelections: OhMyPiThinkingSelections = .empty
    package var selectedReasoningEffortRaw: String?
    package var autoEditEnabled: Bool = true
    var selectedModel: AgentModel {
        get { AgentModel.resolvedModel(forRaw: selectedModelRaw, agentKind: selectedAgent) ?? .defaultModel }
        set { selectedModelRaw = newValue.rawValue }
    }

    /// Draft text for input field
    package var draftText: String = "" {
        didSet {
            guard draftText != oldValue else { return }
            draftMutationGeneration &+= 1
            notifyRecoveryComposerMutation()
        }
    }

    package private(set) var draftMutationGeneration: UInt64 = 0

    /// Selected workflow template for next message
    package var selectedWorkflow: AgentWorkflowDefinition? {
        didSet {
            guard selectedWorkflow != oldValue else { return }
            notifyRecoveryComposerMutation()
        }
    }

    /// Composer interview-first choice for this session's next first message (per session, part of
    /// the recoverable composer snapshot).
    package var interviewFirst: Bool = false {
        didSet {
            guard interviewFirst != oldValue else { return }
            notifyRecoveryComposerMutation()
        }
    }

    /// Recovery lane owning this durable session's composer persistence and input admission, when
    /// recovery is composed. Installed and replaced only through `AgentRecoveryCoordinator.claimLane`.
    package var recoveryLane: AgentRecoverySessionLane?

    /// The composed app-scoped recovery coordinator, also without a lane, so untracked input of an
    /// inactive admission still honors its shared action holds (review A P1-01).
    package weak var recoveryCoordinator: AgentRecoveryCoordinator?

    // The launch authority this session's managed provider launchers resolve. Read once per run, at
    // run start, only to derive the run-start registration mark
    // (`AgentRuntimeLaunchAuthority.runStartRegistrationMark`). Outside DEBUG it is always
    // `.production`, the same value every managed launcher uses (no production site passes a
    // launcher another authority), and `.production` is fixed for the process lifetime
    // (`AgentRecoveryActivation.production` and `AgentProcessRegistry.production` are `static let`).
    // If activation ever becomes switchable at runtime, the mark and the launchers need one shared
    // resolved authority instead.
    #if DEBUG
        /// The launchers' launch authority; settable so tests can inject one.
        package var runtimeLaunchAuthority: AgentRuntimeLaunchAuthority = .production
    #else
        /// The launchers' launch authority: always `.production`.
        package var runtimeLaunchAuthority: AgentRuntimeLaunchAuthority {
            .production
        }
    #endif

    /// The managed session context of this tab's provider work right now: the live lane's durable
    /// lifecycle binding plus the current run attempt and process run when they exist. `unavailable`
    /// (never a fabricated or sessionless identity) when no live recovery lane binds the session.
    package var runtimeSessionScope: AgentRuntimeSessionScope {
        runtimeSessionScope(processRunID: runID)
    }

    /// `runtimeSessionScope` for a process run the caller already holds (headless runs pass theirs).
    package func runtimeSessionScope(processRunID: UUID?) -> AgentRuntimeSessionScope {
        guard let lane = recoveryLane, !lane.isRetired else { return .unavailable }
        return .session(AgentRuntimeSessionAssociation(
            lifecycle: lane.binding,
            runAttemptID: activeRunAttemptID,
            processRunID: processRunID
        ))
    }

    /// Runs `operation` as an owner operation of this session (R6): captures this session's scope
    /// for `processRunID` now, synchronously, and binds it immutably for the operation's whole task
    /// tree (`AgentRuntimeOperationOwner`). Writes the operation makes later, including from its
    /// child tasks and late callbacks, carry this captured run attempt, never the one current when
    /// they write.
    package func withRuntimeOperation<T>(
        processRunID: UUID?,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        try await AgentRuntimeOperationOwner.$session.withValue(
            runtimeSessionScope(processRunID: processRunID),
            operation: operation
        )
    }

    /// Composite composer observation (text, images, tagged files, workflow, interview choice).
    /// Called synchronously after each composer mutation while installed and not suppressed.
    package var recoveryComposerObserver: (@MainActor (AgentTabSession) -> Void)?
    private var recoveryComposerObservationSuppression = 0

    /// Applies restored or programmatic composer state without reporting it as a new edit.
    package func withRecoveryComposerObservationSuppressed(_ body: () -> Void) {
        recoveryComposerObservationSuppression += 1
        defer { recoveryComposerObservationSuppression -= 1 }
        body()
    }

    private func notifyRecoveryComposerMutation() {
        guard recoveryComposerObservationSuppression == 0, let recoveryComposerObserver else { return }
        recoveryComposerObserver(self)
    }

    /// Pending image attachments for the next user turn
    @Published package var pendingImageAttachments: [AgentImageAttachment] = [] {
        didSet {
            guard pendingImageAttachments != oldValue else { return }
            notifyRecoveryComposerMutation()
        }
    }

    @Published package var pendingTaggedFileAttachments: [AgentTaggedFileAttachment] = [] {
        didSet {
            guard pendingTaggedFileAttachments != oldValue else { return }
            notifyRecoveryComposerMutation()
        }
    }

    /// Pending PDF/HTML document attachments for the next user turn (managed originals; a channel
    /// separate from images and tagged files, never pruned against mention tokens).
    @Published package var pendingDocumentAttachments: [AgentDocumentAttachment] = [] {
        didSet {
            guard pendingDocumentAttachments != oldValue else { return }
            notifyRecoveryComposerMutation()
        }
    }

    package var attachmentsPendingProviderConsumptionCleanup: [AgentImageAttachment] = []
    package var attachmentTurnState: AgentAttachmentTurnState = .idle

    /// Provider session ID for resumption (e.g., Claude CLI session_id)
    package var providerSessionID: String?
    /// Provider-history ledger and latest committed import receipt (lossless restart Phase 4).
    /// Hydrated from and persisted with the session. Changed on the main actor by the history-only
    /// merge (which commits only if the ledger still equals the one it read before its awaits),
    /// dispatch-baseline admission and the Step 4d3b live owner (insert and proof invalidation);
    /// cleared by a chat clear.
    package var providerHistoryRecovery: AgentSessionProviderHistoryRecovery?
    /// Recovery dispatch (Phase 4): the Claude conversation whose resume must not fall back to an
    /// implicit fresh conversation. Runtime-only; set before a recovery dispatch, cleared by a
    /// successful resume of that conversation or by an explicit new-conversation choice.
    package var recoveryResumeFallbackSuppressedConversationID: String?
    /// Recovery dispatch (Phase 4): the Claude conversation whose resume failed while the implicit
    /// fresh fallback was suppressed. Offers the explicit "Continue in a new conversation" choice.
    package var recoveryResumeUnavailableConversationID: String?
    /// History-only merge (Phase 4): the import receipt the next owner save must commit together
    /// with the imported rows and ledger (`AgentSessionDataService.saveAgentSession(...,
    /// committingHistoryImport:)`). Runtime-only; cleared once that save committed it.
    package var pendingHistoryImportCommit: AgentSessionProviderHistoryRecovery.ImportCommit?
    /// The latest import receipt an owner save of this tab committed (runtime-only evidence the
    /// cursor CAS waits for).
    package var committedHistoryImportID: UUID?
    package var providerTokenUsageByTurn: [AgentTokenUsagePersist] = []
    package var claudeConfiguredContextWindow: Int?
    package var claudeConfiguredContextWindowKey: ClaudeProvisionalContextWindowResolver.Key?
    package var claudePromptCacheRetention: MCPTimeoutPolicy.AgentLifecycleParentPromptCacheRetention = .standard
    package var pendingNonCodexUserInputTokenQueue: [Int] = []
    package var activeNonCodexTurnTokenAccumulator: AgentNonCodexTurnTokenAccumulator?
    /// Owner-keyed provider accounting (plan §3.2). Installed by persisted hydration or lazily when
    /// a native controller is installed; production verifies each execution (`.productionClaude`).
    /// Executions are keyed by actual process launch (`.launched` usage event), never by
    /// controller installation.
    package var usageAccounting: AgentUsageAccumulator?
    /// Identity of the native process currently owning accounting for this session.
    private(set) var activeNativeLaunch: NativeProcessLaunchIdentity?
    private var activeNativeRuntimeVersion: String?
    /// Session-owned forwarder from the controller's usage-evidence stream into the accumulator.
    /// Survives run-attempt consumer exits so late (for example cancellation) results still land.
    private var usageAccountingForwardingTask: Task<Void, Never>?
    private var usageAccountingForwardingControllerID: ObjectIdentifier?
    /// Distinguishes forwarders of the same controller instance across detach/reattach cycles,
    /// so a superseded forwarder can never dispose the launch a newer one is draining.
    private var usageAccountingForwardingGeneration: UInt64 = 0
    /// Invoked after an ingested usage event changed the execution verdict, transient
    /// latest-request presentation, or accepted accounting; the flag is `true` only when
    /// `ownedRevision` advanced (something to persist).
    package var onUsageAccountingChanged: ((AgentTabSession, _ didChangeAcceptedAccounting: Bool) -> Void)?
    #if DEBUG
        /// Events ingested through the session-owned seam (forwarder or direct), for test draining.
        private(set) var test_ingestedNativeUsageEventCount = 0
    #endif

    private struct ProviderUsageProjectionCacheKey: Equatable {
        var selectedAgent: AgentProviderKind
        var expectedOwnerSessionID: UUID?
        var accountingOwnerSessionID: UUID?
        var qualification: AgentUsageQualification?
        var eligibility: AgentUsageEligibility?
        var accountingRevision: UInt64?
        var presentationRevision: UInt64?
        var activeExecutionID: UUID?
        var executionVerdict: AgentUsageExecutionVerdict?
        var hasUnchargedDispatchedWork: Bool?
        var accountingGeneration: UInt64
    }

    private struct ProviderUsageProjectionCache {
        var key: ProviderUsageProjectionCacheKey
        var value: AgentProviderUsageSnapshot
    }

    private var providerUsageProjectionCache: ProviderUsageProjectionCache?
    /// Explicitly distinguishes same-owner hydration/replacement values whose owned revision is zero.
    private var usageAccountingGeneration: UInt64 = 0
    #if DEBUG
        private(set) var test_providerUsageProjectionComputationCount: Int = 0
    #endif

    package func replaceUsageAccounting(_ accounting: AgentUsageAccumulator?) {
        usageAccounting = accounting
        usageAccountingGeneration &+= 1
        providerUsageProjectionCache = nil
    }

    package func cachedProviderUsageProjection(
        selectedAgent: AgentProviderKind
    ) -> AgentProviderUsageSnapshot {
        let key = ProviderUsageProjectionCacheKey(
            selectedAgent: selectedAgent,
            expectedOwnerSessionID: activeAgentSessionID,
            accountingOwnerSessionID: usageAccounting?.ownerSessionID,
            qualification: usageAccounting?.qualification,
            eligibility: usageAccounting?.eligibility,
            accountingRevision: usageAccounting?.ownedRevision,
            presentationRevision: usageAccounting?.presentationRevision,
            activeExecutionID: usageAccounting?.activeExecutionID,
            executionVerdict: usageAccounting?.executionVerdict,
            hasUnchargedDispatchedWork: usageAccounting?.hasUnchargedDispatchedWork,
            accountingGeneration: usageAccountingGeneration
        )
        if let cached = providerUsageProjectionCache, cached.key == key {
            return cached.value
        }
        let value = AgentProviderUsageSnapshot.projected(
            selectedAgent: selectedAgent,
            accounting: usageAccounting,
            expectedOwnerSessionID: activeAgentSessionID
        )
        providerUsageProjectionCache = .init(key: key, value: value)
        #if DEBUG
            test_providerUsageProjectionComputationCount += 1
        #endif
        return value
    }

    // Codex native session identifiers and metadata
    package var codexConversationID: String?
    package var codexRolloutPath: String?
    package var codexModel: String?
    package var codexReasoningEffort: String?
    @Published package var codexContextUsage: AgentContextUsage? = nil
    @Published package var contextUsageSnapshot: ContextUsageSnapshot? = nil
    package var contextCompactedAt: Date?
    package var codexNeedsReconnect: Bool = false
    var codexResumeTimeoutState: AgentCodexResumeTimeoutState = .init()
    var codexToolPreferencesGeneration: Int = 0
    package var codexController: (any CodexSessionControlling)? {
        didSet {
            let oldIdentity = oldValue.map { ObjectIdentifier($0) }
            let newIdentity = codexController.map { ObjectIdentifier($0) }
            guard oldIdentity != newIdentity else { return }
            codexControllerGeneration = UUID()
            codexAuthoritativeActiveTurn = nil
            codexAnonymousActiveTurn = nil
            codexRoutingObservedTurnID = nil
        }
    }

    package private(set) var codexControllerGeneration = UUID()
    /// The permission profile the current Codex controller was created with.
    /// Used to detect when MCP control changes require controller recycling.
    package var codexControllerPermissionProfile: AgentProviderPermissionProfile?
    /// The session profile the current Codex controller was created with.
    /// Used to keep the provider prompt and native-tool surface stable for its lifetime.
    package var codexControllerSessionProfile: AgentSessionProfile?
    /// The task label kind the current Codex controller was created with.
    /// Used to detect when role-specific native tool overrides require controller recycling.
    package var codexControllerTaskLabelKind: AgentModelCatalog.TaskLabelKind?
    /// The effective workspace path the current Codex controller was created with.
    /// Used to recycle the provider when a session worktree binding changes cwd.
    var codexControllerWorkspacePath: String?
    struct CodexControllerFeatureState: Equatable {
        var computerUseEnabled: Bool
        var goalSupportEnabled: Bool
        var reasoningSummariesEnabled: Bool
    }

    package var pendingCodexComputerUseActivation: AgentCodexComputerUseActivation?
    var codexControllerFeatureState: CodexControllerFeatureState?
    var wantsCodexComputerUseForNextTurn: Bool {
        pendingCodexComputerUseActivation != nil
    }

    /// Coordinator-owned, non-persisted Claude permission request evidence.
    package var claudePermissionSessionState: ClaudePermissionSessionState = .notStarted

    var claudeController: (any NativeAgentRuntimeControlling)? {
        didSet {
            let oldIdentity = oldValue.map { ObjectIdentifier($0) }
            let newIdentity = claudeController.map { ObjectIdentifier($0) }
            guard oldIdentity != newIdentity else { return }
            syncUsageAccountingForwarding(to: claudeController)
        }
    }

    /// Controller installation only guarantees an owner-keyed accumulator and a session-owned
    /// forwarder for that controller's usage-evidence stream. Execution identity is created by
    /// the controller's `.launched` event (an actual process spawn) and disposed by
    /// `.launchEnded`. Replacing a controller disposes any execution immediately because the
    /// old forwarder is cancelled; removing it keeps the forwarder draining until the old
    /// process reports its end, so a cancellation result can still be attributed while a
    /// disposed execution keeps rejecting late input.
    private func syncUsageAccountingForwarding(to controller: (any NativeAgentRuntimeControlling)?) {
        guard let controller else {
            // Detached without a live launch (never launched, or startup failed): nothing can
            // arrive that this session may charge, so the forwarder ends now.
            if activeNativeLaunch == nil {
                let previous = usageAccountingStateSnapshot
                let disposedExecutionID = usageAccounting?.activeExecutionID
                usageAccounting?.endExecution(disposedExecutionID)
                cancelUsageAccountingForwarding()
                notifyUsageAccountingChangedIfNeeded(previousState: previous)
            }
            // Otherwise the forwarder keeps draining until `.launchEnded` (or the stream ends),
            // then terminates itself because the controller is no longer attached.
            return
        }
        if usageAccountingForwardingControllerID == ObjectIdentifier(controller),
           let task = usageAccountingForwardingTask, !task.isCancelled
        {
            // The same controller instance is re-attached while its forwarder still drains a live
            // launch. The evidence stream is single-consumer: cancelling this forwarder would end
            // it for good, so the forwarder, launch and execution are kept (OracleB P1#3).
            ensureUsageAccountingOwner()
            return
        }
        cancelUsageAccountingForwarding()
        let previous = usageAccountingStateSnapshot
        if let disposedExecutionID = usageAccounting?.activeExecutionID {
            usageAccounting?.endExecution(disposedExecutionID)
        }
        activeNativeLaunch = nil
        activeNativeRuntimeVersion = nil
        ensureUsageAccountingOwner()
        notifyUsageAccountingChangedIfNeeded(previousState: previous)
        startUsageAccountingForwarding(from: controller)
    }

    private func ensureUsageAccountingOwner() {
        if let owner = activeAgentSessionID, usageAccounting?.ownerSessionID != owner {
            replaceUsageAccounting(AgentUsageAccumulator(
                ownerSessionID: owner,
                persisted: nil,
                hasPriorHistory: hasSentFirstMessage,
                qualification: .productionClaude
            ))
        }
    }

    /// Cancelling the consuming task finishes that controller's `usageAccountingEvents` stream
    /// for good (later iterators get `nil` immediately), so this is only ever invoked where the
    /// controller is dropped or replaced — never on a session that keeps its attached
    /// controller and continues running turns (`cancelEphemeralRuntimeState` must not call it).
    private func cancelUsageAccountingForwarding() {
        usageAccountingForwardingTask?.cancel()
        usageAccountingForwardingTask = nil
        usageAccountingForwardingControllerID = nil
    }

    /// Explicit forwarder lifecycle: it holds only the controller's stream (never the
    /// controller), ingests until the stream ends, and terminates early once its controller is
    /// detached and the launch it was draining has ended. A stream that ends while a launch is
    /// still active (controller deallocated without `shutdown`) disposes that launch.
    private func startUsageAccountingForwarding(from controller: any NativeAgentRuntimeControlling) {
        let controllerID = ObjectIdentifier(controller)
        usageAccountingForwardingControllerID = controllerID
        usageAccountingForwardingGeneration &+= 1
        let generation = usageAccountingForwardingGeneration
        usageAccountingForwardingTask = Task { @MainActor [weak self, weak controller] in
            guard let stream = await controller?.usageAccountingEvents else { return }
            for await event in stream {
                guard let self, !Task.isCancelled, usageAccountingForwardingGeneration == generation else { return }
                ingestNativeUsageAccountingEvent(event)
                if claudeController == nil, activeNativeLaunch == nil {
                    break
                }
            }
            guard let self, !Task.isCancelled, usageAccountingForwardingGeneration == generation else { return }
            if let launch = activeNativeLaunch {
                ingestNativeUsageAccountingEvent(.launchEnded(launchToken: launch.token))
            }
            usageAccountingForwardingTask = nil
            usageAccountingForwardingControllerID = nil
        }
    }

    #if DEBUG
        var test_isUsageAccountingForwardingActive: Bool {
            usageAccountingForwardingTask.map { !$0.isCancelled } ?? false
        }
    #endif

    private struct UsageAccountingStateSnapshot: Equatable {
        var revision: UInt64?
        var presentationRevision: UInt64?
        var verdict: AgentUsageExecutionVerdict?
        var executionID: UUID?
    }

    private var usageAccountingStateSnapshot: UsageAccountingStateSnapshot? {
        guard let usageAccounting else { return nil }
        return .init(
            revision: usageAccounting.ownedRevision,
            presentationRevision: usageAccounting.presentationRevision,
            verdict: usageAccounting.executionVerdict,
            executionID: usageAccounting.activeExecutionID
        )
    }

    private func notifyUsageAccountingChangedIfNeeded(previousState: UsageAccountingStateSnapshot?) {
        let current = usageAccountingStateSnapshot
        guard current != previousState else { return }
        onUsageAccountingChanged?(self, current?.revision != previousState?.revision)
    }

    /// Session-owned accounting ingestion (plan §3.2). Every event carries the launch token of
    /// the process that produced it; the accumulator rejects anything for a disposed execution.
    /// Ownership policy (contract allowlist, queue bound, counter boundaries) is applied here, in
    /// core, from `ClaudeNativeUsageContract`; the controller only proves correlation.
    func ingestNativeUsageAccountingEvent(_ event: NativeUsageAccountingEvent) {
        let previous = usageAccountingStateSnapshot
        defer {
            #if DEBUG
                test_ingestedNativeUsageEventCount += 1
            #endif
            notifyUsageAccountingChangedIfNeeded(previousState: previous)
        }
        switch event {
        case let .launched(launch):
            if activeNativeLaunch?.token == launch.token {
                // Re-delivered launch evidence (a controller resubscription replays the
                // current launch's evidence to its new subscriber). This session already
                // holds that launch: registering it again would end and reopen its execution
                // at a fresh baseline, so continuity is kept and nothing is re-registered.
                // If the accounting owner changed under the launch, the launch stays
                // disposed for the new owner rather than gaining a zero baseline (review R2).
                return
            }
            ensureUsageAccountingOwner()
            activeNativeLaunch = launch
            activeNativeRuntimeVersion = nil
            let launchProviderSessionID: String? = if case let .resumedSession(sessionID) = launch.launchMode {
                sessionID
            } else {
                providerSessionID
            }
            usageAccounting?.beginAwaitingExecution(
                executionID: launch.token,
                providerSessionID: launchProviderSessionID,
                at: Date()
            )
        case let .runtimeEvidence(launchToken, runtimeVersion, _):
            guard let launch = activeNativeLaunch, launch.token == launchToken else { return }
            activeNativeRuntimeVersion = runtimeVersion
            usageAccounting?.resolveExecutionQualification(
                executionID: launchToken,
                verdict: ClaudeNativeUsageContract.verdict(for: launch, runtimeVersion: runtimeVersion),
                at: Date()
            )
        case .runtimeBinding:
            // Provenance diagnostics only (account category, model, key source); the reported
            // figures are not gated on them.
            break
        case let .dispatched(launchToken, turnID, _):
            usageAccounting?.registerTurn(turnID, executionID: launchToken)
        case let .counterBoundaryObserved(launchToken, kind):
            guard activeNativeLaunch?.token == launchToken else { return }
            if let reason = ClaudeNativeUsageContract.counterBoundaryBlock(
                contractID: usageAccounting?.executionVerdict?.contractID,
                kind: kind
            ) {
                usageAccounting?.resolveExecutionQualification(
                    executionID: launchToken,
                    verdict: .blocked(reason),
                    at: Date()
                )
            }
        case let .mainRequestUsageAttributed(attribution):
            guard activeNativeLaunch?.token == attribution.launchToken else { return }
            usageAccounting?.observeLatestClaudeRequest(
                observation: attribution.observation,
                requestID: attribution.requestID,
                executionID: attribution.launchToken,
                turnID: attribution.turnID
            )
        case let .resultAttributed(attribution):
            guard activeNativeLaunch?.token == attribution.launchToken else { return }
            if let contractID = usageAccounting?.executionVerdict?.contractID,
               let reason = ClaudeNativeUsageContract.queuePolicyBlock(
                   contractID: contractID,
                   queuedTurnCount: attribution.queuedTurnCount
               )
            {
                usageAccounting?.resolveExecutionQualification(
                    executionID: attribution.launchToken,
                    verdict: .blocked(reason),
                    at: Date()
                )
                return
            }
            usageAccounting?.observe(
                .init(
                    observation: attribution.observation,
                    reportedCost: AgentUsageObservationInput.exactCost(fromReported: attribution.reportedCost),
                    executionID: attribution.launchToken,
                    turnID: attribution.turnID,
                    attribution: .live,
                    hasOriginalResultAuthority: true,
                    terminalOutcome: attribution.turnStatus == .completed ? .completed : .interrupted,
                    childActivityObserved: attribution.childActivityObserved
                )
            )
        case let .turnClosed(launchToken, turnID, status):
            guard activeNativeLaunch?.token == launchToken else { return }
            usageAccounting?.closeTurn(turnID, outcome: status == .completed ? .completed : .interrupted)
        case let .blocked(launchToken, reason):
            let blockReason: AgentUsageExecutionBlockReason = switch reason {
            case .runtimeVersionConflict: .runtimeVersionConflict
            case .missingRuntimeVersion: .unsupportedRuntime(reason.description)
            case .providerSessionIdentityChanged, .desynchronized: .attributionDesynchronized(reason.description)
            }
            usageAccounting?.resolveExecutionQualification(
                executionID: launchToken,
                verdict: .blocked(blockReason),
                at: Date()
            )
        case let .launchEnded(launchToken):
            if activeNativeLaunch?.token == launchToken {
                activeNativeLaunch = nil
                activeNativeRuntimeVersion = nil
            }
            usageAccounting?.endExecution(launchToken)
        }
    }

    /// Re-registers the live launch on a replaced accumulator. The verdict the previous
    /// accumulator had already resolved for this same process is carried over: a blocked
    /// execution stays blocked, and a qualified one continues the persisted segment for its
    /// execution (the accumulator never reopens a zero baseline for a process it already has
    /// a checkpoint for — OracleA P0#3 / OracleB P1#1). Without a previous verdict the launch
    /// is resolved from its runtime evidence as usual. Still-open persisted turns of that
    /// execution are re-registered by the accumulator; dispatches that were never persisted
    /// are not reconstructed and their results stay rejected as unregistered.
    private func reattachActiveNativeLaunchToUsageAccounting(previousVerdict: AgentUsageExecutionVerdict?) {
        guard let launch = activeNativeLaunch else { return }
        let launchProviderSessionID: String? = if case let .resumedSession(sessionID) = launch.launchMode {
            sessionID
        } else {
            providerSessionID
        }
        usageAccounting?.beginAwaitingExecution(
            executionID: launch.token,
            providerSessionID: launchProviderSessionID,
            at: Date()
        )
        switch previousVerdict {
        case let .blocked(reason)?:
            usageAccounting?.resolveExecutionQualification(executionID: launch.token, verdict: .blocked(reason), at: Date())
        case let .qualified(contractID, baseline)?:
            usageAccounting?.resolveExecutionQualification(
                executionID: launch.token,
                verdict: .qualified(contractID: contractID, baseline: baseline),
                at: Date()
            )
        case .awaiting?, nil:
            if let version = activeNativeRuntimeVersion {
                usageAccounting?.resolveExecutionQualification(
                    executionID: launch.token,
                    verdict: ClaudeNativeUsageContract.verdict(for: launch, runtimeVersion: version),
                    at: Date()
                )
            }
        }
    }

    /// Installs the persisted `providerUsage` after hydration (plan §3.3).
    ///
    /// The on-disk payload is authoritative for a session being (re)loaded. An accumulator
    /// installed before hydration (a controller that arrived first) knows nothing about the
    /// persisted payload, so when it refuses the late hydration it is replaced rather than
    /// kept: the pre-hydration state can never overwrite the persisted payload on the next
    /// save. A live launch that survived (route activation keeps the controller while resetting
    /// accounting) is re-registered so later dispatches stay registered.
    package func installHydratedUsageAccounting(_ persisted: AgentProviderUsagePersist?, ownerSessionID: UUID) {
        let previous = usageAccountingStateSnapshot
        defer { notifyUsageAccountingChangedIfNeeded(previousState: previous) }
        if var accounting = usageAccounting,
           accounting.ownerSessionID == ownerSessionID,
           accounting.applyHydration(persisted, hasPriorHistory: hasSentFirstMessage)
        {
            replaceUsageAccounting(accounting)
            return
        }
        var previousVerdict: AgentUsageExecutionVerdict?
        if let launch = activeNativeLaunch, usageAccounting?.activeExecutionID == launch.token {
            previousVerdict = usageAccounting?.executionVerdict
        }
        replaceUsageAccounting(AgentUsageAccumulator(
            ownerSessionID: ownerSessionID,
            persisted: persisted,
            hasPriorHistory: hasSentFirstMessage,
            qualification: .productionClaude
        ))
        reattachActiveNativeLaunchToUsageAccounting(previousVerdict: previousVerdict)
    }

    // MARK: Codex usage accounting (plan §4.1)

    /// Pricing seam held by Codex dispatch; tests inject a transient store. Never waits.
    var codexPricingProvider: any OpenAIPricingProviding = OpenAIPricingStore.shared

    /// Registers the current controller generation as the Codex accounting execution. A thread
    /// that this generation will create fresh has a verified zero baseline; a resumed thread
    /// inherits unknown usage (prospective baseline). Idempotent for the same generation.
    func beginCodexUsageExecutionIfNeeded() {
        let previous = usageAccountingStateSnapshot
        defer { notifyUsageAccountingChangedIfNeeded(previousState: previous) }
        ensureUsageAccountingOwner()
        usageAccounting?.beginCodexExecution(
            executionID: codexControllerGeneration,
            threadOrigin: codexConversationID == nil ? .fresh : .resumed
        )
    }

    /// Registers the turn about to be dispatched (pricing snapshot frozen when available; the
    /// dispatch is tracked either way) and lets the store schedule at most one bounded
    /// background refresh (never awaited). Registration precedes the provider send because
    /// `turn/started` can be observed before the send returns. The typed receipt or lifecycle
    /// start records acceptance independently of turn identity; only a proven rejection of an
    /// unaccepted exact ticket withdraws it, while delivery-unknown work stays covered.
    @discardableResult
    func registerCodexUsageDispatch(requestedModel: String?) -> CodexDispatchTicket? {
        let previous = usageAccountingStateSnapshot
        defer { notifyUsageAccountingChangedIfNeeded(previousState: previous) }
        ensureUsageAccountingOwner()
        usageAccounting?.beginCodexExecution(
            executionID: codexControllerGeneration,
            threadOrigin: codexConversationID == nil ? .fresh : .resumed
        )
        codexPricingProvider.noteCodexDispatch()
        return usageAccounting?.registerCodexDispatch(
            executionID: codexControllerGeneration,
            requestedModelID: requestedModel ?? codexModel,
            pricing: codexPricingProvider.currentSnapshot()
        )
    }

    /// Records provider acceptance from the typed start receipt. Exact-ticket matching
    /// prevents a delayed receipt from accepting a successor dispatch.
    func acceptCodexUsageDispatch(_ ticket: CodexDispatchTicket?) {
        guard let ticket else { return }
        let previous = usageAccountingStateSnapshot
        defer { notifyUsageAccountingChangedIfNeeded(previousState: previous) }
        usageAccounting?.acceptCodexDispatch(ticket)
    }

    /// Records provider acceptance from `turn/started` before its optional identity is
    /// inspected. This keeps anonymous starts covered by later completion or teardown.
    func acceptCurrentCodexUsageDispatch() {
        let previous = usageAccountingStateSnapshot
        defer { notifyUsageAccountingChangedIfNeeded(previousState: previous) }
        usageAccounting?.acceptCurrentCodexDispatch(executionID: codexControllerGeneration)
    }

    /// The caller proved that the exact unaccepted dispatch was not submitted or was
    /// definitively rejected: withdraw it without an unmeasured marker. Accepted, bound, stale
    /// and cross-execution tickets are no-ops. Delivery-unknown errors must not call this method.
    func withdrawCodexUsageDispatch(_ ticket: CodexDispatchTicket?) {
        guard let ticket else { return }
        let previous = usageAccountingStateSnapshot
        defer { notifyUsageAccountingChangedIfNeeded(previousState: previous) }
        usageAccounting?.withdrawCodexDispatch(ticket)
    }

    func bindCodexUsageTurn(_ turnID: String?) {
        guard let turnID = turnID?.trimmingCharacters(in: .whitespacesAndNewlines), !turnID.isEmpty else { return }
        usageAccounting?.bindCodexTurn(executionID: codexControllerGeneration, turnID: turnID)
    }

    func ingestCodexUsageObservation(_ observation: CodexUsageObservation) {
        let previous = usageAccountingStateSnapshot
        defer { notifyUsageAccountingChangedIfNeeded(previousState: previous) }
        usageAccounting?.observeCodexUsage(observation, executionID: codexControllerGeneration, at: Date())
    }

    func noteCodexModelReroute(_ reroute: CodexModelReroute) {
        let previous = usageAccountingStateSnapshot
        defer { notifyUsageAccountingChangedIfNeeded(previousState: previous) }
        usageAccounting?.noteCodexReroute(executionID: codexControllerGeneration, reroute: reroute)
    }

    /// The provider reported a turn terminal. Dispatched work that never produced a usage
    /// observation is recorded as unmeasured rather than silently counted as zero. Callers
    /// pass the provider's turn identity or, for a nil-ID completion, the identity the
    /// coordinator's completion correlation established; without either, use
    /// `closeUnidentifiedCodexUsageTurn`.
    func closeCodexUsageTurn(_ turnID: String?) {
        guard let turnID = turnID?.trimmingCharacters(in: .whitespacesAndNewlines), !turnID.isEmpty else { return }
        let previous = usageAccountingStateSnapshot
        defer { notifyUsageAccountingChangedIfNeeded(previousState: previous) }
        usageAccounting?.closeCodexTurn(executionID: codexControllerGeneration, turnID: turnID)
    }

    /// A turn completion arrived without a turn identity and could not be correlated to a
    /// known turn: outstanding dispatched work on this generation is recorded as unmeasured
    /// (a provably owned late observation still upserts a bound turn's marker).
    func closeUnidentifiedCodexUsageTurn() {
        let previous = usageAccountingStateSnapshot
        defer { notifyUsageAccountingChangedIfNeeded(previousState: previous) }
        usageAccounting?.closeUnidentifiedCodexTurn(executionID: codexControllerGeneration)
    }

    /// The current controller generation is ending (cancel, failure, shutdown, replacement).
    /// Must run before `codexController` is reassigned, which rotates the generation.
    func endCodexUsageExecution(reason: String) {
        let previous = usageAccountingStateSnapshot
        defer { notifyUsageAccountingChangedIfNeeded(previousState: previous) }
        _ = reason
        usageAccounting?.endCodexExecution(executionID: codexControllerGeneration)
    }

    /// R6: runs a retired controller's cleanup, retained until it completes so registered
    /// successor starts on this tab can join it (`joinRuntimeRetirements`).
    package func retainRuntimeRetirement(_ cleanup: @escaping @MainActor () async -> Void) {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await cleanup()
            self?.runtimeRetirements[token] = nil
        }
        runtimeRetirements[token] = task
    }

    /// R6: waits for every retained retirement on this tab, including ones retained while joining.
    package func joinRuntimeRetirements() async {
        while let entry = runtimeRetirements.first {
            await entry.value.value
            runtimeRetirements[entry.key] = nil
        }
    }

    package var hasPendingRuntimeRetirements: Bool {
        !runtimeRetirements.isEmpty
    }

    package var acpController: ACPAgentSessionController?
    /// R6: cleanup of this tab's retired runtime controllers (any provider: replacement, reconnect
    /// or provider switch), keyed by retirement token. Every registered successor start joins it
    /// before reserving, so a session never races its own predecessor's still-active runtime.
    private var runtimeRetirements: [UUID: Task<Void, Never>] = [:]
    package var codexEventTask: Task<Void, Never>?
    package var codexEventTaskRunID: UUID?
    package var codexLastEventAt: Date?
    var codexWatchdogState: AgentCodexWatchdogState = .init()
    var codexNativeToolLiveness: AgentCodexNativeToolLivenessState = .init()
    /// Turn IDs started during the current run attempt, used to filter stale turnCompleted events.
    package var claudeExpectedTurnIDs: Set<UUID> = []
    package var hasReconciledPersistedCodexCommandStatus: Bool = false
    package var activeReasoningItemID: UUID?
    package var reasoningItemIDsByGroupID: [String: UUID] = [:]
    package var pendingAssistantDelta: String = ""
    /// The flush of whichever producer (VM or Codex coordinator) armed the current buffer timer;
    /// `drainPendingAssistantDelta()` applies the buffer through it, exactly as that timer would.
    package var assistantDeltaDrain: ((AgentTabSession) -> Void)?

    /// Applies buffered assistant text now through its producer's own flush, which clears the
    /// buffer and invalidates the pending timer first, so the text lands exactly once.
    package func drainPendingAssistantDelta() {
        guard !pendingAssistantDelta.isEmpty, let assistantDeltaDrain else { return }
        assistantDeltaDrain(self)
    }

    /// Rows of any kind appended by background (between-run) delivery. A run never resumes or
    /// replaces them, even when they landed below its user row, and each delivery's lookups
    /// skip the other's rows. Not persisted.
    package var backgroundRowIDs: Set<UUID> = []
    /// The event stream (provider launch) each background row came from, for rows delivered
    /// with a source. Background lookups of one stream skip another stream's rows.
    package var backgroundRowSourceIDs: [UUID: UUID] = [:]
    /// Each stream's current background message row, keyed by source. Further text and
    /// authoritative `final_content` from that stream go to it even after an interleaved system
    /// row or a run's terminal finalization ended its streaming; that message's other segment
    /// ends, a run taking over the stream, and a newer user row retire it.
    package var backgroundCurrentAssistantRowIDs: [UUID?: UUID] = [:]
    /// The Claude event stream (the tab's current router) whose between-run output may update
    /// session metadata. A replaced stream's output is still shown, but never overwrites the
    /// newer launch's provider session ID.
    package var claudeAuthoritativeEventSourceID: UUID?
    /// Step 4d3b (inactive): Claude producer launches whose live identity this owner refused or saw
    /// disqualified. The producer's own latch cannot hear owner-side conflicts, so their later
    /// output is never identified here; a refusal before any proof exists needs this. Not
    /// persisted (a relaunched producer has a new token; durable refusal is proof invalidation).
    package var claudeLiveTranscriptRefusedProducers: Set<UUID> = []
    /// Step 4d3c (inactive): per producer launch, the exact ledger keys that launch newly inserted
    /// (written with the row and ledger entry in the same main-actor step). A duplicate, an imported
    /// match or an agreeing result never acquires or transfers a key. Step 4d7: an exactly agreeing
    /// result (single text, or a whole Read chain) removes its exchange's keys, so an agreed proof is
    /// no longer revocable by this launch. A refusal invalidates only the remaining (unagreed) keys'
    /// proofs. Reset only by clear chat, which also detaches the tab's Claude controller. It is
    /// kept across run completion, cancellation, a new run, a merging import and persisted
    /// hydration or rebinding, which do not detach a still-attached producer: exact keys (provider,
    /// native session, entry) never match another conversation's rows, and a copied key the producer
    /// created stays its own. The refused latch above is never reset. Not persisted.
    package var claudeLiveTranscriptOwnedKeys: [UUID: Set<String>] = [:]

    /// Whether `rowID` is a background row delivered from `sourceID`'s stream.
    package func isBackgroundRow(_ rowID: UUID, from sourceID: UUID?) -> Bool {
        backgroundRowIDs.contains(rowID) && backgroundRowSourceIDs[rowID] == sourceID
    }

    /// Whether `rowID` belongs to a delivery: a run's rows are the non-background ones, and a
    /// background delivery's are `sourceID`'s stream's background rows.
    package func isDeliveryRow(_ rowID: UUID, background: Bool, sourceID: UUID?) -> Bool {
        background ? isBackgroundRow(rowID, from: sourceID) : !backgroundRowIDs.contains(rowID)
    }

    var pendingCodexAssistantScope: CodexNativeSessionController.ItemScope?
    var codexAssistantRowIDByScope: [CodexNativeSessionController.ItemScope: UUID] = [:]
    package var assistantDeltaFlushTask: Task<Void, Never>?
    package var assistantDeltaTaskGeneration: UInt64 = 0
    package var assistantDeltaFlushGeneration: UInt64 = 0
    var providerTerminalDrainGeneration: UInt64 = 0
    package var terminalCommitInProgress: Bool = false
    /// Set once by the irreversible lifecycle teardown (two-stage shutdown Stage B or the legacy
    /// close path) before it cancels the run, so a runner that commits first after its task is
    /// cancelled still records the teardown cause. Stage A never sets it.
    package var lifecycleTeardownCause: AgentRunTerminalCause?
    package var lastTerminalCommitRevision: AgentRunTerminalCommitRevision?
    var lastTerminalPublicationResult: AgentRunTerminalPublicationResult?
    /// Commit whose queued follow-up instruction was already consumed (at most one per commit).
    var terminalFollowUpTakenCommitID: UUID?
    var runAttemptTerminalResources: AgentRunAttemptTerminalResources?
    /// Handoff payload (injected into provider-facing text on first user send).
    /// Cleared only after the provider accepts the turn.
    package var pendingHandoff: AgentPendingHandoffState = .init()

    /// Pending scheduled (delayed) send for this session. Mirrors the persisted
    /// `AgentSession.scheduledSend` member; every durable change goes through the
    /// data service CAS (`mutateScheduledSend`), never through the ordinary save.
    package var scheduledSend: AgentScheduledSendMember?
    /// Most recent accepted scheduled dispatch (historical marker source).
    package var lastScheduledDispatch: AgentScheduledSendProvenance?
    /// `updatedAt` of the scheduled-send record as last observed on disk. This is the
    /// expected version handed to the CAS mutation; `nil` means no record is persisted.
    package var scheduledSendPersistedUpdatedAt: Date?
    /// Serializes complete schedule actions (install, edit, cancel, send-now, dispatch,
    /// coordinator persists) for this session so no two actions interleave their reads,
    /// writes, rollbacks, or attachment cleanup.
    package var scheduledSendActionTask: Task<Void, Never>?
    /// Workspace that owns the persisted schedule; persistence refuses any other target.
    package var scheduledSendWorkspaceID: UUID?
    /// True while `dispatchScheduledSend` owns this session between the persisted
    /// `.dispatching` attempt and the provider acceptance signal.
    package var isScheduledDispatchInFlight: Bool = false
    /// Projection of a provider-accepted dispatch whose durable commit is owned by the process
    /// coordinator's single recovery worker (see `AgentScheduledSendCoordinator`).
    package var scheduledSendPendingFinalization: AgentScheduledSendPendingFinalization?
    /// Finalized scheduled markers explicitly removed by the user (conversation reset). The
    /// next full save passes them atomically so persistence installs tombstones instead of
    /// treating the absence as a stale snapshot; cleared once that save commits.
    package var pendingFinalizedScheduledSendItemRemovals: [AgentScheduledSendFinalizedItemRemoval] = []
    /// Stable identity of an explicit conversation reset awaiting its committed save. Persistence
    /// records the canonical post-reset snapshot under this receipt so accepted-send recovery after
    /// accidental file loss never restores pre-reset history. Cleared once that save commits.
    package var pendingTranscriptResetReceipt: AgentSessionTranscriptResetReceipt?
    /// Durable session ID whose file this tab has already written or hydrated in this process.
    /// Saves targeting it require the existing incarnation (`.requireExisting`); a rebinding to a
    /// different ID is an initial creation again.
    package var persistedIncarnationSessionID: UUID?
    /// Captured, service-issued persistence state for the bound durable session (lifetime
    /// stamp + transcript-reset generation). Acquired only through a full editable load or a
    /// genuine initial creation and replaced only by this owner's own validated commits;
    /// never refreshed after a deletion/missing failure or a schedule-only refresh.
    package var persistenceState: AgentSessionPersistenceState?
    /// Durable session whose ownership was revoked (explicit deletion / stale lifetime). No
    /// fresh state may be acquired for it by this tab.
    package var persistenceRevokedSessionID: UUID?

    package func persistenceState(for sessionID: UUID) -> AgentSessionPersistenceState? {
        guard let persistenceState, persistenceState.stamp.sessionID == sessionID else { return nil }
        return persistenceState
    }

    /// Exact `(itemID, receipt)` markers currently carried by working items and transcript
    /// request anchors; captured before an explicit removal.
    package var finalizedScheduledSendItemMarkers: [AgentScheduledSendFinalizedItemRemoval] {
        var markers: [AgentScheduledSendFinalizedItemRemoval] = []
        var seen: Set<UUID> = []
        for item in items where item.kind == .user {
            guard let receipt = item.scheduledSend, seen.insert(item.id).inserted else { continue }
            markers.append(AgentScheduledSendFinalizedItemRemoval(itemID: item.id, receipt: receipt))
        }
        for turn in transcript.turns {
            guard let request = turn.request,
                  let receipt = request.scheduledSend,
                  seen.insert(request.id).inserted
            else { continue }
            markers.append(AgentScheduledSendFinalizedItemRemoval(itemID: request.id, receipt: receipt))
        }
        return markers
    }

    /// Last busy snapshot reported to the scheduled-send coordinator (change detection).
    package var lastReportedScheduledSendBusyState: AgentScheduledSendBusyState?
    /// Most recent non-nil `runID`, retained so a terminal publication that clears the run
    /// identity first can still be matched against a captured run.
    package private(set) var lastObservedRunID: UUID?

    package var pendingScheduledSendRecord: AgentScheduledSendPersist? {
        scheduledSend?.persistedValue
    }

    /// Whether `identity` is a scheduled attempt's input (its deterministic bubble): the in-flight
    /// attempt, one accepted and awaiting finalization, or a bubble stamped with its schedule
    /// receipt. The schedule owns that payload, so a refusal never also returns it to the composer.
    package func isScheduledAttemptInput(_ identity: AgentQueuedInputIdentity) -> Bool {
        guard let itemID = identity.userItemID else { return false }
        if pendingScheduledSendRecord?.attempt?.itemID == itemID { return true }
        if scheduledSendPendingFinalization?.attempt.itemID == itemID { return true }
        return items.contains { $0.id == itemID && $0.scheduledSend != nil }
    }

    /// True while this session owns provider work for a scheduled attempt (dispatch in
    /// flight or acceptance awaiting its durable finalization).
    package var ownsLiveScheduledAttempt: Bool {
        isScheduledDispatchInFlight || scheduledSendPendingFinalization != nil
    }

    package var isProviderSelectionLocked: Bool {
        hasSentFirstMessage && !pendingHandoff.defersProviderLockUntilSend
    }

    // Persistence
    package private(set) var persistentSessionBindingIdentity: AgentPersistentSessionBindingIdentity?
    package var activeAgentSessionID: UUID? {
        persistentSessionBindingIdentity?.sessionID
    }

    package private(set) var bindingTransitionGeneration: UInt64 = 0
    package private(set) var bindingTransitionInProgress: Bool = false
    package private(set) var persistenceMutationGeneration: UInt64 = 0
    package var saveRequestGeneration: UInt64 = 0
    package var parentSessionID: UUID?
    package var hasLoadedPersistedState: Bool = false
    /// How the most recent persisted load for this tab ended. Early exits that adopted
    /// nothing (stale binding, cancellation, superseded revision) leave `.unresolved`, so
    /// callers that need paired authority (remote materialization) validate this instead of
    /// trusting `hasLoadedPersistedState` alone.
    package var persistedLoadDisposition: PersistedLoadDisposition?

    package enum PersistedLoadDisposition: Equatable {
        /// The load exited before adopting anything (stale, cancelled, or superseded).
        case unresolved
        /// Persistence is suppressed for this launch.
        case suppressed
        /// The tab had no durable binding to load.
        case unbound
        /// No file exists for the bound session: the tab is a genuine creator.
        case noPayload
        /// Transcript and persistence state were adopted from one paired load.
        case applied
        /// Preparation or hydration threw.
        case failed
    }

    /// Stop-and-retain recovery after a committed peer transcript reset (see
    /// `AgentModeViewModel+StaleResetRecovery.swift`). While present: no save authority, not
    /// loaded, the retained working view stays visible, and new work is refused.
    package var staleResetRecovery: AgentStaleResetRecovery?
    /// The single recovery orchestration task (stop attempt or confirmed reload) for this tab.
    package var staleResetRecoveryTask: Task<Void, Never>?
    /// Removal admission recorded by the preflight; consumed at the final removal boundary.
    package var staleResetRemovalAdmission: AgentStaleResetRemovalAdmission?

    /// Whether this owner's working view may be presented: hydrated normally, or retained by
    /// a stale-reset recovery (which deliberately keeps `hasLoadedPersistedState == false`).
    package var isPresentableForOwner: Bool {
        hasLoadedPersistedState || staleResetRecovery != nil
    }

    /// Confirmed disposal or rebinding relinquishes the retained view: the marker is dropped so
    /// any suspended stop/reload continuation fails its captured-owner check.
    package func invalidateStaleResetRecoveryForLifecycle() {
        staleResetRecoveryTask?.cancel()
        staleResetRecoveryTask = nil
        staleResetRecovery = nil
    }

    package private(set) var authoritativeHydratedBinding: AgentPersistentSessionBindingIdentity?
    package private(set) var authoritativeHydratedBindingTransitionGeneration: UInt64?
    /// The in-flight paired load. Its value is that operation's own outcome; callers that await
    /// a load consume the returned disposition rather than session state, and cleanup only
    /// clears the handle that still identifies the same invocation.
    package var persistedLoadTask: Task<AgentPersistedLoadOutcome, Never>?
    /// Identity of the most recent paired load attempt started for this tab; cleared when a
    /// load is cancelled. Every publication and readiness change of a load is gated on it.
    package var currentPersistedLoadAttemptID: UUID?
    package var lastActivityAt: Date = .init()
    package var lastUserMessageAt: Date?
    package var lastCommandOutputSaveAt: Date?
    package var saveDebounceTask: Task<Void, Never>?
    package var isDirty: Bool = false {
        didSet {
            if isDirty {
                persistenceMutationGeneration &+= 1
                onPersistenceMutation?(self)
            }
        }
    }

    /// Called on every `isDirty = true`, including dirty-only edits that change no source item.
    /// Source-item mutations notify through `onSourceItemsChanged` first, before their dirty mark.
    package var onPersistenceMutation: ((AgentTabSession) -> Void)?
    /// Transcript save maximum wait (R3), transient and never persisted: when the first change
    /// not yet covered by a successful save happened. Later changes never move it; only a clean
    /// save receipt of the current projection (or finding nothing left to save) clears it.
    package var transcriptSaveFirstUnsavedAt: ContinuousClock.Instant?
    /// The single maximum-wait (or failed-save retry) timer for this owner.
    package var transcriptSaveMaxWaitTask: Task<Void, Never>?
    /// Identifies the armed timer; a wakeup whose generation no longer matches is obsolete.
    package var transcriptSaveMaxWaitGeneration: UInt64 = 0
    /// Consecutive maximum-wait saves that wrote nothing; spaces retries (at least 1 s apart).
    package var transcriptSaveMaxWaitRetryCount: Int = 0

    /// Withdraws the maximum-wait obligation and makes any armed timer's wakeup obsolete.
    package func invalidateTranscriptSaveMaxWait() {
        transcriptSaveMaxWaitTask?.cancel()
        transcriptSaveMaxWaitTask = nil
        transcriptSaveMaxWaitGeneration &+= 1
        transcriptSaveFirstUnsavedAt = nil
        transcriptSaveMaxWaitRetryCount = 0
    }

    package var sourceItemsRevision: Int = 0
    package var pendingSourceItemsMutationSummary: AgentPendingSourceItemsMutationSummary?
    package var pendingDerivedTranscriptRefreshReason: AgentDerivedTranscriptRefreshReason?
    package var derivedTranscriptRefreshTask: Task<Void, Never>?
    package var derivedTranscriptRefreshGeneration: UInt64 = 0
    /// Generation of the pending refresh task when it was scheduled with the background
    /// first-event delay. Freshness barriers flush only work that delay deferred.
    package var derivedTranscriptRefreshDeferredGeneration: UInt64?
    package var hasDeferredDerivedTranscriptRefresh: Bool {
        derivedTranscriptRefreshTask != nil
            && derivedTranscriptRefreshDeferredGeneration == derivedTranscriptRefreshGeneration
    }

    package var derivedTranscriptSyncState: AgentDerivedTranscriptSyncState?
    package var pendingCommandRunningByKey: [String: CodexNativeSessionController.CommandExecutionRunningUpdate] = [:]
    package var pendingCommandRunningFlushTask: Task<Void, Never>?
    var pendingCommandRunningFlushUsesLiveOutputDelay: Bool = false
    package var bashLiveExecutionByKey: [String: AgentBashLiveExecutionState] = [:]
    var bashLiveExecutionKeyByTranscriptItemID: [UUID: String] = [:]

    /// Sequence tracking
    package var nextSequenceIndex: Int = 0

    package var bashLiveExecutionByTranscriptItemID: [UUID: AgentBashLiveExecutionState] {
        var result: [UUID: AgentBashLiveExecutionState] = [:]
        for (itemID, key) in bashLiveExecutionKeyByTranscriptItemID {
            guard let state = bashLiveExecutionByKey[key] else { continue }
            result[itemID] = state
        }
        return result
    }

    package init(tabID: UUID) {
        self.tabID = tabID
    }

    deinit {
        applyEditsApprovalSubscriptionTask?.cancel()
        // Session disposal terminates the forwarder; a disposed session cannot own accounting.
        usageAccountingForwardingTask?.cancel()
    }

    /// Cancels all ephemeral runtime tasks and clears transient state on this
    /// session. Called by both `prepareSessionForWindowClose` and
    /// `prepareWorkspaceSwitchSessionDiscard` before the VM performs
    /// async teardown (provider dispose, coordinator shutdown, MCP cleanup).
    ///
    /// This method is purely synchronous and touches only TabSession-owned
    /// state. VM-owned interactions (cancelPendingQuestion, approval,
    /// instruction, applyEditsReview, MCP control, run cancellation) remain
    /// on the VM and are called separately by each teardown path.
    package func cancelEphemeralRuntimeState() {
        derivedTranscriptRefreshTask?.cancel()
        derivedTranscriptRefreshTask = nil
        derivedTranscriptRefreshDeferredGeneration = nil
        pendingDerivedTranscriptRefreshReason = nil
        pendingCommandRunningFlushTask?.cancel()
        pendingCommandRunningFlushTask = nil
        pendingCommandRunningByKey.removeAll()
        claudeSteeringFlushTask?.cancel()
        claudeSteeringFlushTask = nil
        acpSteeringFlushTask?.cancel()
        acpSteeringFlushTask = nil
        clearClaudeReasoningStatus(clearDisplayedStatus: true)
        assistantDeltaFlushTask?.cancel()
        assistantDeltaFlushTask = nil
        pendingAssistantDelta = ""
        agentTask?.cancel()
        agentTask = nil
        codexEventTask?.cancel()
        codexEventTask = nil
        codexEventTaskRunID = nil
        applyEditsApprovalSubscriptionTask?.cancel()
        applyEditsApprovalSubscriptionTask = nil
        applyEditsApprovalSetupID = nil
        applyEditsApprovalSubscriptionID = nil
        applyEditsApprovalScopeGeneration = nil
        // The usage-accounting forwarder is deliberately not touched here: this method keeps
        // `claudeController` attached, and cancelling the forwarder would finish that
        // controller's evidence stream irreversibly (every later launch/dispatch/result would be
        // dropped silently). Teardown paths end it by dropping the controller (coordinator
        // shutdown → detach → `claudeController = nil`), by stream end, or by session `deinit`.
    }

    @discardableResult
    package func beginPersistentBindingTransition() -> UInt64 {
        // Replacing an existing binding retires the previous owner's maximum wait. A genuine
        // creator's first binding (inside its first save) keeps its own obligation.
        if persistentSessionBindingIdentity != nil {
            invalidateTranscriptSaveMaxWait()
        }
        bindingTransitionGeneration &+= 1
        bindingTransitionInProgress = true
        authoritativeHydratedBinding = nil
        authoritativeHydratedBindingTransitionGeneration = nil
        return bindingTransitionGeneration
    }

    package func installPersistentSessionBinding(_ binding: AgentPersistentSessionBindingIdentity?) {
        precondition(binding == nil || binding?.tabID == tabID)
        persistentSessionBindingIdentity = binding
        bindingTransitionInProgress = false
    }

    package func finishPersistentBindingTransition(generation: UInt64) {
        guard bindingTransitionGeneration == generation else { return }
        bindingTransitionInProgress = false
    }

    package func markCurrentBindingHydrated() {
        guard isPresentableForOwner, !bindingTransitionInProgress else { return }
        authoritativeHydratedBinding = persistentSessionBindingIdentity
        authoritativeHydratedBindingTransitionGeneration = bindingTransitionGeneration
    }

    package func clearCurrentBindingHydration() {
        authoritativeHydratedBinding = nil
        authoritativeHydratedBindingTransitionGeneration = nil
    }

    package var hasBindingBlockingInteraction: Bool {
        waitingPrompt != nil
            || instructionContinuation != nil
            || pendingAskUser != nil
            || pendingUserInputRequest != nil
            || pendingApproval != nil
            || pendingPermissionsRequest != nil
            || pendingMCPElicitationRequest != nil
            || pendingApplyEditsReview != nil
            || pendingWorktreeMergeReview != nil
            || !queuedUserInputRequests.isEmpty
            || !queuedMCPElicitationRequests.isEmpty
    }

    package func persistentBindingTransitionToken() -> AgentPersistentBindingTransitionToken {
        AgentPersistentBindingTransitionToken(
            tabID: tabID,
            sessionIdentity: ObjectIdentifier(self),
            binding: persistentSessionBindingIdentity,
            transitionGeneration: bindingTransitionGeneration,
            sourceItemsRevision: sourceItemsRevision
        )
    }

    #if DEBUG
        func testInstallPersistentSessionBinding(sessionID: UUID?) {
            _ = beginPersistentBindingTransition()
            installPersistentSessionBinding(
                sessionID.map { AgentPersistentSessionBindingIdentity(tabID: tabID, sessionID: $0) }
            )
        }
    #endif

    func installRunAttemptTerminalResources(
        ownership: AgentRunOwnership,
        prepare: @escaping AgentRunAttemptTerminalResources.Prepare
    ) {
        guard isCurrentRunAttempt(ownership) else { return }
        runAttemptTerminalResources = AgentRunAttemptTerminalResources(
            ownership: ownership,
            prepare: prepare
        )
    }

    func claimRunAttemptTerminalTeardown(
        ownership: AgentRunOwnership,
        terminalState: AgentSessionRunState
    ) -> AgentRunAttemptTerminalResources.Teardown? {
        guard let resources = runAttemptTerminalResources else { return nil }
        let teardown = resources.claim(for: ownership, terminalState: terminalState)
        if resources.isClaimed {
            runAttemptTerminalResources = nil
        }
        return teardown
    }

    /// `inputUserItemID`: the user item this attempt's own input owns (non-Codex runners, from their
    /// handoff). The terminal barrier attributes the attempt's outcome to that item's execution turn
    /// instead of the last user item; `nil` keeps the legacy last-user-item attribution.
    @discardableResult
    func beginRunAttempt(source: String, attemptID: UUID = UUID(), inputUserItemID: UUID? = nil) -> AgentRunOwnership {
        assert(runAttemptTerminalResources == nil || runAttemptTerminalResources?.isClaimed == true)
        runAttemptGeneration &+= 1
        runAttemptTerminalResources = nil
        terminalCommitInProgress = false
        lastTerminalCommitRevision = nil
        lastTerminalPublicationResult = nil
        providerTerminalDrainGeneration = 0
        codexAuthoritativeActiveTurn = nil
        codexAnonymousActiveTurn = nil
        codexRoutingObservedTurnID = nil
        codexPendingSteerLifecycleReconciliation = nil
        var turnEpoch: AgentRunTurnEpoch?
        if var context = mcpControlContext {
            turnEpoch = context.preparedEpoch ?? context.currentEpoch
            if context.preparedEpoch != nil {
                context.preparedEpoch = nil
                mcpControlContext = context
            }
        }
        let ownership = runLifecycleTracker.begin(
            tabID: tabID,
            persistentSessionID: activeAgentSessionID,
            persistentBindingGeneration: persistentSessionBindingIdentity?.generation,
            bindingTransitionGeneration: bindingTransitionGeneration,
            attemptID: attemptID,
            turnEpoch: turnEpoch,
            // The run's provider, captured once at run start (recovery records it on the attempt).
            providerKindRaw: selectedAgent.rawValue,
            // Whether this run's launches are registered (Step 9-activation-b), from the same
            // authority and provider. A run on an authoritative remote host launches nothing here.
            runtimeRegistrationRaw: remoteHost == nil
                ? runtimeLaunchAuthority.runStartRegistrationMark(providerKindRaw: selectedAgent.rawValue)
                : nil
        )
        attentionTextProvenance = AttentionTextProvenance(
            attemptID: ownership.attemptID,
            minimumSourceSequenceIndex: nextSequenceIndex
        )
        runAttemptInputAttribution = inputUserItemID.map {
            AgentRunAttemptInputAttribution(attemptID: ownership.attemptID, userItemID: $0)
        }
        #if DEBUG
            AgentModePerfDiagnostics.increment("run.lifecycle.attempt.started")
            AgentModePerfDiagnostics.increment("run.lifecycle.attempt.started.source.\(source)")
            AgentModePerfDiagnostics.event(
                "run.lifecycle.attemptStarted",
                tabID: tabID,
                fields: [
                    "source": source,
                    "attemptID": AgentModePerfDiagnostics.shortID(ownership.attemptID),
                    "bindingGeneration": AgentModePerfDiagnostics.shortID(ownership.binding.generation),
                    "persistentBindingGeneration": AgentModePerfDiagnostics.shortID(ownership.binding.persistentBindingGeneration),
                    "bindingTransitionGeneration": String(ownership.binding.bindingTransitionGeneration),
                    "persistentSessionID": AgentModePerfDiagnostics.shortID(ownership.binding.persistentSessionID)
                ]
            )
        #endif
        return ownership
    }

    /// The user item whose turn the current run attempt's terminal outcome belongs to (F1), when its
    /// runner named one; see `beginRunAttempt(inputUserItemID:)`.
    package private(set) var runAttemptInputAttribution: AgentRunAttemptInputAttribution?

    /// A later input of the same run attempt crossed its provider boundary (steering): the attempt's
    /// outcome now belongs to that input's turn. Ignored for any other attempt.
    func noteRunAttemptInput(attemptID: UUID, userItemID: UUID) {
        guard activeRunAttemptID == attemptID else { return }
        runAttemptInputAttribution = AgentRunAttemptInputAttribution(attemptID: attemptID, userItemID: userItemID)
    }

    package func isCurrentRunAttempt(_ ownership: AgentRunOwnership, expectedRunID: UUID? = nil) -> Bool {
        guard activeRunOwnership == ownership else { return false }
        if let expectedRunID {
            return runID == expectedRunID
        }
        return true
    }

    package func isCurrentRunAttemptForCurrentBinding(
        _ ownership: AgentRunOwnership,
        expectedRunID: UUID? = nil
    ) -> Bool {
        guard isCurrentRunAttempt(ownership, expectedRunID: expectedRunID) else { return false }
        return ownership.binding.tabID == tabID
            && ownership.binding.persistentSessionID == activeAgentSessionID
            && ownership.binding.persistentBindingGeneration == persistentSessionBindingIdentity?.generation
            && ownership.binding.bindingTransitionGeneration == bindingTransitionGeneration
            && !bindingTransitionInProgress
    }

    @discardableResult
    func recordRunProgress(
        ownership: AgentRunOwnership,
        kind: AgentRunLivenessSignalKind,
        stage: AgentRunLifecycleStage,
        retryIntent: AgentRunRetryIntent = .none,
        timestampUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> AgentRunProgressAcceptance {
        let result = runLifecycleTracker.record(
            ownership: ownership,
            kind: kind,
            stage: stage,
            retryIntent: retryIntent,
            timestampUptimeNanoseconds: timestampUptimeNanoseconds
        )
        recordRunProgressDiagnostic(result, kind: kind, stage: stage)
        return result
    }

    @discardableResult
    func acceptRunProgress(_ signal: AgentRunProgressSignal) -> AgentRunProgressAcceptance {
        let result = runLifecycleTracker.accept(signal)
        recordRunProgressDiagnostic(result, kind: signal.kind, stage: signal.stage)
        return result
    }

    @discardableResult
    func endRunAttempt(ifCurrent ownership: AgentRunOwnership, source: String) -> Bool {
        guard runLifecycleTracker.end(ifCurrent: ownership) else { return false }
        recordRunAttemptEnded(ownership, source: source)
        return true
    }

    @discardableResult
    package func endCurrentRunAttempt(source: String) -> Bool {
        guard let ownership = activeRunOwnership else { return false }
        guard runLifecycleTracker.end(ifCurrent: ownership) else { return false }
        recordRunAttemptEnded(ownership, source: source)
        return true
    }

    @discardableResult
    func endRunAttempt(ifCurrentAttemptID attemptID: UUID, source: String) -> Bool {
        guard let ownership = activeRunOwnership, ownership.attemptID == attemptID else { return false }
        return endRunAttempt(ifCurrent: ownership, source: source)
    }

    private func recordRunAttemptEnded(_ ownership: AgentRunOwnership, source: String) {
        #if DEBUG
            AgentModePerfDiagnostics.increment("run.lifecycle.attempt.ended")
            AgentModePerfDiagnostics.increment("run.lifecycle.attempt.ended.source.\(source)")
            AgentModePerfDiagnostics.event(
                "run.lifecycle.attemptEnded",
                tabID: tabID,
                fields: [
                    "source": source,
                    "attemptID": AgentModePerfDiagnostics.shortID(ownership.attemptID)
                ]
            )
        #endif
    }

    private func recordRunProgressDiagnostic(
        _ result: AgentRunProgressAcceptance,
        kind: AgentRunLivenessSignalKind,
        stage: AgentRunLifecycleStage
    ) {
        #if DEBUG
            switch result {
            case .accepted:
                if kind == .stageTransition {
                    AgentModePerfDiagnostics.increment("run.lifecycle.stage.\(stage.rawValue)", tabID: tabID)
                }
            case let .rejected(reason):
                AgentModePerfDiagnostics.increment("run.lifecycle.progress.rejected.\(reason.rawValue)", tabID: tabID)
                AgentModePerfDiagnostics.event(
                    "run.lifecycle.progressRejected",
                    tabID: tabID,
                    fields: ["reason": reason.rawValue, "kind": kind.rawValue, "stage": stage.rawValue]
                )
            }
        #endif
    }

    @discardableResult
    package func setRunningStatus(_ text: String?, source: RunningStatusSource?) -> Bool {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (normalized?.isEmpty == false) ? normalized : nil
        let normalizedSource = value == nil ? nil : source
        guard runningStatusText != value || runningStatusSource != normalizedSource else { return false }
        runningStatusText = value
        runningStatusSource = normalizedSource
        return true
    }

    @discardableResult
    package func clearClaudeReasoningStatus(clearDisplayedStatus: Bool = true) -> Bool {
        claudeReasoningStatusBuffer = ""
        claudeReasoningStatusPendingText = nil
        claudeReasoningStatusFlushTask?.cancel()
        claudeReasoningStatusFlushTask = nil
        guard clearDisplayedStatus, runningStatusSource == .reasoning else { return false }
        return setRunningStatus(nil, source: nil)
    }

    var shouldSurfaceInteractionsInUI: Bool {
        true
    }

    package var uiWaitingPrompt: String? {
        shouldSurfaceInteractionsInUI ? waitingPrompt : nil
    }

    package var uiPendingAskUser: AgentAskUserPendingState? {
        shouldSurfaceInteractionsInUI ? pendingAskUser : nil
    }

    package var uiPendingUserInputRequest: AgentRequestUserInputRequest? {
        shouldSurfaceInteractionsInUI ? pendingUserInputRequest : nil
    }

    package var uiPendingApproval: AgentApprovalRequest? {
        shouldSurfaceInteractionsInUI ? pendingApproval : nil
    }

    package var uiPendingPermissionsRequest: AgentPermissionsRequest? {
        shouldSurfaceInteractionsInUI ? pendingPermissionsRequest : nil
    }

    package var uiPendingMCPElicitationRequest: AgentMCPElicitationRequest? {
        shouldSurfaceInteractionsInUI ? pendingMCPElicitationRequest : nil
    }

    package var uiPendingApplyEditsReview: PendingApplyEditsReview? {
        shouldSurfaceInteractionsInUI ? pendingApplyEditsReview : nil
    }

    package var uiPendingWorktreeMergeReview: PendingWorktreeMergeReview? {
        shouldSurfaceInteractionsInUI ? pendingWorktreeMergeReview : nil
    }

    struct ToolCorrelationScanResult {
        let indices: [Int]
        let scannedItemCount: Int

        var lastIndex: Int? {
            indices.last
        }
    }

    private enum ToolCorrelationBoundary: Equatable {
        case start
        case after(itemID: UUID, sequenceIndex: Int)
    }

    private struct ToolCorrelationIndexes: Equatable {
        var activeTurnBoundary: ToolCorrelationBoundary = .start
        var activeTurnStartIndex: Int = 0
        var itemIndicesByInvocationID: [UUID: Set<Int>] = [:]
        var itemIndicesBySignature: [String: Set<Int>] = [:]
        var pendingCallIndicesBySignature: [String: Set<Int>] = [:]
        var nilInvocationItemIndicesByName: [String: Set<Int>] = [:]
    }

    static func normalizedToolCorrelationName(_ toolName: String?) -> String {
        let normalized = MCPIntegrationHelper.normalizedRepoPromptToolName(toolName ?? "")
        if !normalized.isEmpty {
            return normalized
        }
        return toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    static func canonicalToolInvocationSignature(toolName: String?, argsJSON: String?) -> String {
        let normalizedToolName = normalizedToolCorrelationName(toolName)
        let normalizedArgs: String = {
            guard let raw = argsJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  JSONSerialization.isValidJSONObject(object),
                  let canonicalData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let canonical = String(data: canonicalData, encoding: .utf8)
            else {
                return argsJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            return canonical
        }()
        return "\(normalizedToolName)|\(normalizedArgs)"
    }

    func indexedToolItemIndices(invocationID: UUID) -> [Int] {
        sortedValidToolItemIndices(toolCorrelationIndexes.itemIndicesByInvocationID[invocationID] ?? [])
    }

    func indexedToolItemIndices(signature: String, pendingCallsOnly: Bool = false) -> [Int] {
        let indices = pendingCallsOnly
            ? toolCorrelationIndexes.pendingCallIndicesBySignature[signature] ?? []
            : toolCorrelationIndexes.itemIndicesBySignature[signature] ?? []
        return sortedValidToolItemIndices(indices)
    }

    func indexedNilInvocationToolItemIndices(normalizedToolName: String) -> [Int] {
        sortedValidToolItemIndices(
            toolCorrelationIndexes.nilInvocationItemIndicesByName[normalizedToolName] ?? []
        )
    }

    func activeTurnToolItemIndices(
        where predicate: (AgentChatItem) -> Bool
    ) -> ToolCorrelationScanResult {
        var matches: [Int] = []
        var scannedItemCount = 0
        guard toolCorrelationIndexes.activeTurnStartIndex < items.endIndex else {
            return ToolCorrelationScanResult(indices: [], scannedItemCount: 0)
        }
        for index in stride(
            from: items.index(before: items.endIndex),
            through: toolCorrelationIndexes.activeTurnStartIndex,
            by: -1
        ) {
            scannedItemCount += 1
            if predicate(items[index]) {
                matches.append(index)
            }
        }
        matches.reverse()
        return ToolCorrelationScanResult(indices: matches, scannedItemCount: scannedItemCount)
    }

    private func sortedValidToolItemIndices(_ indices: Set<Int>) -> [Int] {
        indices.lazy
            .filter { index in
                self.items.indices.contains(index)
                    && index >= self.toolCorrelationIndexes.activeTurnStartIndex
                    && Self.isToolCorrelationItem(self.items[index])
            }
            .sorted()
    }

    private static func isToolCorrelationItem(_ item: AgentChatItem) -> Bool {
        item.kind == .toolCall || item.kind == .toolResult
    }

    private func syncNextSequenceIndexFromItems() {
        let maxSequenceIndex = items.map(\.sequenceIndex).max() ?? -1
        nextSequenceIndex = max(nextSequenceIndex, maxSequenceIndex + 1)
    }

    private enum SourceItemsDispatch {
        case silent
        case notify(AgentSourceItemsMutation, AgentSourceItemsMutationCaller)
    }

    private func commitSourceItems(
        _ newItems: [AgentChatItem],
        dispatch: SourceItemsDispatch,
        diagnosticContext: String
    ) {
        let repairedItems = repairedSourceItems(newItems, diagnosticContext: diagnosticContext)
        suppressSourceItemsChanged = true
        items = repairedItems
        suppressSourceItemsChanged = false
        rebuildSourceItemDerivedState()
        sourceItemsRevision &+= 1
        derivedTranscriptSyncState = nil
        if case let .notify(mutation, caller) = dispatch {
            onSourceItemsChanged?(self, mutation, caller)
        }
    }

    private func repairedSourceItems(
        _ candidateItems: [AgentChatItem],
        diagnosticContext: String
    ) -> [AgentChatItem] {
        #if DEBUG
            test_sourceItemDuplicateRepairScanCount += 1
        #endif
        let repair = AgentSourceItemIDRepair.repairDuplicateIDs(in: candidateItems)
        if repair.didRepair {
            AgentSourceItemIDRepair.logDiagnostics(
                repair.diagnostics,
                context: "tab_session tab_id=\(tabID.uuidString) \(diagnosticContext)"
            )
        }
        return repair.items
    }

    @discardableResult
    private func repairStoredSourceItemsIfNeeded(diagnosticContext: String) -> Bool {
        let repairedItems = repairedSourceItems(items, diagnosticContext: diagnosticContext)
        guard repairedItems != items else { return false }
        suppressSourceItemsChanged = true
        items = repairedItems
        suppressSourceItemsChanged = false
        return true
    }

    @discardableResult
    private func commitRepairedSourceItemsIfNeeded(
        _ candidateItems: [AgentChatItem],
        diagnosticContext: String,
        caller: AgentSourceItemsMutationCaller
    ) -> Bool {
        #if DEBUG
            test_sourceItemDuplicateRepairScanCount += 1
        #endif
        let repair = AgentSourceItemIDRepair.repairDuplicateIDs(in: candidateItems)
        guard repair.didRepair else { return false }
        AgentSourceItemIDRepair.logDiagnostics(
            repair.diagnostics,
            context: "tab_session tab_id=\(tabID.uuidString) \(diagnosticContext)"
        )
        commitSourceItems(
            repair.items,
            dispatch: .notify(.structural, caller),
            diagnosticContext: "\(diagnosticContext).commit"
        )
        return true
    }

    /// Rebuilds derived state from `items`. Precondition: `items` already has unique IDs. Every
    /// caller establishes that at its source-write boundary (`items.didSet` and
    /// `commitSourceItems` repair first; `compactSummaryOnlyToolResultsAndAlignEphemeralPayloadMap`
    /// rebuilds only after a repair). This method does not repair source data.
    private func rebuildSourceItemDerivedState() {
        #if DEBUG
            test_sourceItemDerivedRebuildCount += 1
        #endif
        syncNextSequenceIndexFromItems()
        liveItemIDs = Set(items.map(\.id))
        assert(liveItemIDs.count == items.count, "rebuildSourceItemDerivedState requires unique source item IDs")
        replaceEphemeralToolResultPayloadMap(
            AgentTranscriptPresentationBuilder.rebuildEphemeralToolResultPayloadMap(
                from: items,
                diagnosticContext: "tab_session tab_id=\(tabID.uuidString) rebuildSourceItemDerivedState"
            ),
            liveItemIDs: liveItemIDs
        )
        rebuildToolCorrelationIndexes()
        assertSourceItemDerivedStateIsConsistentIfEnabled()
    }

    /// Whether a single-row write of `updatedID` (replacing `previousID`, if any) keeps source
    /// item IDs unique. Relies on the `liveItemIDs == Set(items.map(\.id))` invariant; a
    /// collision takes the existing repaired structural commit instead.
    private func admitsIncrementalSourceItemID(_ updatedID: UUID, replacing previousID: UUID?) -> Bool {
        if let previousID, previousID == updatedID { return true }
        return !liveItemIDs.contains(updatedID)
    }

    /// Narrow hot-path DEBUG check after an admitted single-row write: only the touched
    /// identities are inspected, plus the O(1) count invariant.
    private func assertIncrementalSourceItemIdentity(previousID: UUID?, updatedID: UUID) {
        #if DEBUG
            assert(liveItemIDs.contains(updatedID), "incremental source write lost its live item ID")
            if let previousID, previousID != updatedID {
                assert(!liveItemIDs.contains(previousID), "incremental source write kept a replaced live item ID")
            }
            assert(liveItemIDs.count == items.count, "incremental source write desynchronized live item IDs")
        #endif
    }

    private func rebuildToolCorrelationIndexes() {
        let activeTurnBoundaryOverride = runState.isActive ? toolCorrelationIndexes.activeTurnBoundary : nil
        toolCorrelationIndexes = Self.makeToolCorrelationIndexes(
            for: items,
            activeTurnBoundaryOverride: activeTurnBoundaryOverride
        )
    }

    private static func makeToolCorrelationIndexes(
        for items: [AgentChatItem],
        activeTurnBoundaryOverride: ToolCorrelationBoundary? = nil
    ) -> ToolCorrelationIndexes {
        var indexes = ToolCorrelationIndexes()
        let boundary: ToolCorrelationBoundary = if let activeTurnBoundaryOverride {
            activeTurnBoundaryOverride
        } else if let lastUserIndex = items.lastIndex(where: { $0.kind == .user }) {
            .after(
                itemID: items[lastUserIndex].id,
                sequenceIndex: items[lastUserIndex].sequenceIndex
            )
        } else {
            .start
        }
        indexes.activeTurnBoundary = boundary
        indexes.activeTurnStartIndex = resolvedToolCorrelationStartIndex(for: items, boundary: boundary)
        guard indexes.activeTurnStartIndex < items.endIndex else { return indexes }
        for index in indexes.activeTurnStartIndex ..< items.endIndex {
            addToolCorrelationItem(items[index], at: index, to: &indexes)
        }
        return indexes
    }

    private static func resolvedToolCorrelationStartIndex(
        for items: [AgentChatItem],
        boundary: ToolCorrelationBoundary
    ) -> Int {
        switch boundary {
        case .start:
            return items.startIndex
        case let .after(itemID, sequenceIndex):
            if let anchorIndex = items.firstIndex(where: { $0.id == itemID }) {
                return items.index(after: anchorIndex)
            }
            return items.firstIndex(where: { $0.sequenceIndex > sequenceIndex }) ?? items.endIndex
        }
    }

    private static func addToolCorrelationItem(
        _ item: AgentChatItem,
        at index: Int,
        to indexes: inout ToolCorrelationIndexes
    ) {
        guard isToolCorrelationItem(item), index >= indexes.activeTurnStartIndex else { return }
        if let invocationID = item.toolInvocationID {
            indexes.itemIndicesByInvocationID[invocationID, default: []].insert(index)
        }
        let signature = canonicalToolInvocationSignature(
            toolName: item.toolName,
            argsJSON: item.toolArgsJSON
        )
        indexes.itemIndicesBySignature[signature, default: []].insert(index)
        if item.kind == .toolCall {
            indexes.pendingCallIndicesBySignature[signature, default: []].insert(index)
        }
        if item.toolInvocationID == nil {
            let normalizedName = normalizedToolCorrelationName(item.toolName)
            indexes.nilInvocationItemIndicesByName[normalizedName, default: []].insert(index)
        }
    }

    private static func removeToolCorrelationItem(
        _ item: AgentChatItem,
        at index: Int,
        from indexes: inout ToolCorrelationIndexes
    ) {
        guard isToolCorrelationItem(item), index >= indexes.activeTurnStartIndex else { return }
        if let invocationID = item.toolInvocationID {
            remove(index, from: &indexes.itemIndicesByInvocationID, key: invocationID)
        }
        let signature = canonicalToolInvocationSignature(
            toolName: item.toolName,
            argsJSON: item.toolArgsJSON
        )
        remove(index, from: &indexes.itemIndicesBySignature, key: signature)
        if item.kind == .toolCall {
            remove(index, from: &indexes.pendingCallIndicesBySignature, key: signature)
        }
        if item.toolInvocationID == nil {
            let normalizedName = normalizedToolCorrelationName(item.toolName)
            remove(index, from: &indexes.nilInvocationItemIndicesByName, key: normalizedName)
        }
    }

    private static func remove<Key: Hashable>(
        _ index: Int,
        from map: inout [Key: Set<Int>],
        key: Key
    ) {
        guard var indices = map[key] else { return }
        indices.remove(index)
        map[key] = indices.isEmpty ? nil : indices
    }

    private func updateToolCorrelationIndexes(
        previousItem: AgentChatItem,
        updatedItem: AgentChatItem,
        at index: Int
    ) {
        guard previousItem.kind != .user, updatedItem.kind != .user else {
            rebuildToolCorrelationIndexes()
            return
        }
        Self.removeToolCorrelationItem(previousItem, at: index, from: &toolCorrelationIndexes)
        Self.addToolCorrelationItem(updatedItem, at: index, to: &toolCorrelationIndexes)
    }

    private func appendToolCorrelationIndexes(for item: AgentChatItem, at index: Int) {
        if item.kind == .user {
            guard !runState.isActive else { return }
            toolCorrelationIndexes = ToolCorrelationIndexes(
                activeTurnBoundary: .after(itemID: item.id, sequenceIndex: item.sequenceIndex),
                activeTurnStartIndex: index + 1
            )
            return
        }
        Self.addToolCorrelationItem(item, at: index, to: &toolCorrelationIndexes)
    }

    private func reconcileIncrementalEphemeralPayload(
        previousItem: AgentChatItem?,
        updatedItem: AgentChatItem?
    ) {
        if let previousItem, previousItem.id != updatedItem?.id {
            liveItemIDs.remove(previousItem.id)
            setEphemeralToolResultPayload(nil, for: previousItem.id)
        }
        guard let updatedItem else { return }
        liveItemIDs.insert(updatedItem.id)
        refreshEphemeralPayload(for: updatedItem)
    }

    private func refreshEphemeralPayload(for item: AgentChatItem) {
        if let retainedPayload = AgentToolResultPersistencePolicy.retainedEphemeralRawPayload(for: item) {
            let uiPayload = AgentToolResultPersistencePolicy.mergingOracleUIIdentitySidecars(
                into: retainedPayload,
                sidecarsByChatID: oracleUIIdentitySidecarByChatID
            )
            setEphemeralToolResultPayload(uiPayload, for: item.id)
        } else {
            setEphemeralToolResultPayload(nil, for: item.id)
        }
    }

    package func captureOracleUIIdentitySidecars(_ sidecarsByChatID: [String: String]) {
        guard !sidecarsByChatID.isEmpty else { return }
        oracleUIIdentitySidecarByChatID.merge(sidecarsByChatID) { _, latest in latest }
        for item in items {
            refreshEphemeralPayload(for: item)
        }
    }

    package func replaceEphemeralToolResultPayloadMap(_ payloadByItemID: [UUID: String], liveItemIDs: Set<UUID>) {
        let filteredPayloadByItemID = payloadByItemID.filter { itemID, payload in
            liveItemIDs.contains(itemID) && !payload.isEmpty
        }
        let previousPayloadByItemID = ephemeralToolResultPayloadByItemID
        ephemeralToolResultPayloadByItemID = filteredPayloadByItemID
        for itemID in Set(previousPayloadByItemID.keys).union(filteredPayloadByItemID.keys) {
            guard previousPayloadByItemID[itemID] != filteredPayloadByItemID[itemID] else { continue }
            if filteredPayloadByItemID[itemID] != nil {
                ephemeralToolResultPayloadRevisionByItemID[itemID] = consumeNextEphemeralToolResultPayloadRevision()
            } else {
                ephemeralToolResultPayloadRevisionByItemID.removeValue(forKey: itemID)
            }
        }
        pruneEphemeralToolResultPayloadRevisions(liveItemIDs: liveItemIDs)
    }

    private func setEphemeralToolResultPayload(_ payload: String?, for itemID: UUID) {
        let retainedPayload = payload.flatMap { $0.isEmpty ? nil : $0 }
        let previousPayload = ephemeralToolResultPayloadByItemID[itemID]
        guard previousPayload != retainedPayload else { return }
        if let retainedPayload {
            ephemeralToolResultPayloadByItemID[itemID] = retainedPayload
            ephemeralToolResultPayloadRevisionByItemID[itemID] = consumeNextEphemeralToolResultPayloadRevision()
        } else {
            ephemeralToolResultPayloadByItemID.removeValue(forKey: itemID)
            ephemeralToolResultPayloadRevisionByItemID.removeValue(forKey: itemID)
        }
    }

    private func consumeNextEphemeralToolResultPayloadRevision() -> Int {
        let revision = nextEphemeralToolResultPayloadRevision
        nextEphemeralToolResultPayloadRevision &+= 1
        return revision
    }

    private func pruneEphemeralToolResultPayloadRevisions(liveItemIDs: Set<UUID>) {
        ephemeralToolResultPayloadRevisionByItemID = ephemeralToolResultPayloadRevisionByItemID.filter {
            liveItemIDs.contains($0.key) && ephemeralToolResultPayloadByItemID[$0.key] != nil
        }
    }

    private func finishIncrementalSourceItemsMutation(
        _ mutation: AgentSourceItemsMutation,
        caller: AgentSourceItemsMutationCaller
    ) {
        sourceItemsRevision &+= 1
        derivedTranscriptSyncState = nil
        onSourceItemsChanged?(self, mutation, caller)
    }

    #if DEBUG
        func testAssertSourceItemDerivedStateIsConsistent() {
            assertSourceItemDerivedStateIsConsistent()
        }

        /// Follows the `GlobalSettingsStore` XCTest-detection precedent: direct xctest and SwiftPM
        /// runners need not set `XCTestConfigurationFilePath`.
        private static let isXCTestProcess =
            NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil
    #endif

    /// Full O(n) consistency sweep after a full derived rebuild or a flags-only streaming
    /// commit, run automatically only in XCTest processes or when transcript debug
    /// instrumentation is explicitly enabled. Ordinary DEBUG app runs and performance capture
    /// use the narrow touched-row checks instead. Single-row incremental writes are not swept
    /// automatically: an active-turn boundary frozen during a run outlives it until a full
    /// rebuild, which this sweep reports as desynchronized (pre-existing behavior).
    private func assertSourceItemDerivedStateIsConsistentIfEnabled(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        #if DEBUG
            guard Self.isXCTestProcess || AgentTranscriptDebugInstrumentation.isEnabled else { return }
            assertSourceItemDerivedStateIsConsistent(file: file, line: line)
        #endif
    }

    private func assertSourceItemDerivedStateIsConsistent(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        #if DEBUG
            assert(liveItemIDs == Set(items.map(\.id)), "live item ID index desynchronized", file: file, line: line)
            assert(items.count == liveItemIDs.count, "duplicate live item IDs detected", file: file, line: line)
            assert(
                ephemeralToolResultPayloadByItemID.keys.allSatisfy { liveItemIDs.contains($0) },
                "ephemeral payload map contains non-live item IDs",
                file: file,
                line: line
            )
            assert(
                toolCorrelationIndexes == Self.makeToolCorrelationIndexes(
                    for: items,
                    activeTurnBoundaryOverride: runState.isActive ? toolCorrelationIndexes.activeTurnBoundary : nil
                ),
                "tool correlation index desynchronized",
                file: file,
                line: line
            )
        #endif
    }

    @discardableResult
    package func mutateItemsBatch(
        mutation: AgentSourceItemsMutation = .structural,
        touchActivity: Bool = true,
        _ body: (inout [AgentChatItem]) -> Void,
        callerFileID: StaticString = #fileID,
        callerFunction: StaticString = #function,
        callerLine: UInt = #line
    ) -> Bool {
        let previousItems = items
        var updatedItems = previousItems
        body(&updatedItems)
        guard updatedItems != previousItems else { return false }
        preserveClaudeAssociatedToolPayloads(previous: previousItems, in: &updatedItems)
        guard updatedItems != previousItems else { return false }
        commitSourceItems(
            updatedItems,
            dispatch: .notify(
                mutation,
                .init(fileID: callerFileID, function: callerFunction, line: callerLine)
            ),
            diagnosticContext: "mutateItemsBatch"
        )
        if touchActivity {
            lastActivityAt = Date()
        }
        isDirty = true
        return true
    }

    /// Ends streaming of the assistant rows `shouldEnd` selects, as one ranged, non-structural
    /// mutation. The flipped indices are computed from the current items in this same
    /// main-actor turn, before the commit. The range is the lowest through highest flipped index;
    /// interior rows may be unchanged. No selected row means no
    /// mutation and no notification. Only `isStreaming` changes: IDs, kinds, order, and tool
    /// fields are untouched. Does not touch `lastActivityAt`.
    @discardableResult
    package func endStreamingAssistantRows(
        where shouldEnd: (AgentChatItem) -> Bool = { _ in true },
        callerFileID: StaticString = #fileID,
        callerFunction: StaticString = #function,
        callerLine: UInt = #line
    ) -> Bool {
        endStreamingRows(
            ofKind: .assistant,
            mutation: { .assistantStreamingStateChanged(changedIndexRange: $0) },
            where: shouldEnd,
            callerFileID: callerFileID,
            callerFunction: callerFunction,
            callerLine: callerLine
        )
    }

    /// Reasoning counterpart of `endStreamingAssistantRows`: ends streaming of the thinking rows
    /// `shouldEnd` selects, as one ranged, non-structural mutation with the same contract.
    @discardableResult
    package func endStreamingReasoningRows(
        where shouldEnd: (AgentChatItem) -> Bool,
        callerFileID: StaticString = #fileID,
        callerFunction: StaticString = #function,
        callerLine: UInt = #line
    ) -> Bool {
        endStreamingRows(
            ofKind: .thinking,
            mutation: { .reasoningStreamingStateChanged(changedIndexRange: $0) },
            where: shouldEnd,
            callerFileID: callerFileID,
            callerFunction: callerFunction,
            callerLine: callerLine
        )
    }

    private func endStreamingRows(
        ofKind kind: AgentChatItemKind,
        mutation: (ClosedRange<Int>) -> AgentSourceItemsMutation,
        where shouldEnd: (AgentChatItem) -> Bool,
        callerFileID: StaticString,
        callerFunction: StaticString,
        callerLine: UInt
    ) -> Bool {
        let flippedIndices = items.indices.filter { index in
            let item = items[index]
            return item.kind == kind && item.isStreaming && shouldEnd(item)
        }
        guard let firstIndex = flippedIndices.first, let lastIndex = flippedIndices.last else {
            return false
        }
        // Flags-only commit: IDs, sequence indexes, retained payloads (only `.toolResult` rows
        // retain one) and tool-correlation inputs are unchanged, so no duplicate repair or
        // derived rebuild runs. One array copy is still made.
        #if DEBUG
            let selectedRowsBefore = flippedIndices.map { items[$0] }
        #endif
        var updatedItems = items
        for index in flippedIndices {
            updatedItems[index].isStreaming = false
        }
        suppressSourceItemsChanged = true
        items = updatedItems
        suppressSourceItemsChanged = false
        #if DEBUG
            for (offset, index) in flippedIndices.enumerated() {
                var expected = selectedRowsBefore[offset]
                assert(expected.kind == kind && expected.isStreaming, "streaming end selected a non-streaming row")
                expected.isStreaming = false
                assert(items[index] == expected, "streaming end changed a field other than isStreaming")
            }
        #endif
        reconcileIdleToolCorrelationBoundaryIfStale()
        reconcileActiveToolCorrelationStartIfStale()
        assertSourceItemDerivedStateIsConsistentIfEnabled()
        finishIncrementalSourceItemsMutation(
            mutation(firstIndex ... lastIndex),
            caller: .init(fileID: callerFileID, function: callerFunction, line: callerLine)
        )
        isDirty = true
        return true
    }

    /// Keeps the one tool-correlation effect the former full rebuild had on a flags-only
    /// commit: outside an active run, a full rebuild re-derives the active-turn boundary from
    /// the last user row (a boundary frozen during a run can outlive it). The backward scan
    /// stops at the last user row; indexes are rebuilt only when that boundary is stale.
    private func reconcileIdleToolCorrelationBoundaryIfStale() {
        guard !runState.isActive else { return }
        let freshBoundary: ToolCorrelationBoundary = if let lastUserIndex = items.lastIndex(where: { $0.kind == .user }) {
            .after(itemID: items[lastUserIndex].id, sequenceIndex: items[lastUserIndex].sequenceIndex)
        } else {
            .start
        }
        guard toolCorrelationIndexes.activeTurnBoundary != freshBoundary else { return }
        rebuildToolCorrelationIndexes()
    }

    /// Keeps the former full rebuild's recovery during an active run: the frozen boundary is
    /// kept, but single-row writes do not re-resolve its start, so it can go stale (a removed
    /// anchor reappended, or a missing anchor's sequence-index fallback shifted by a sequence
    /// change). Rebuilds only the correlation indexes, and only when the resolved start moved;
    /// incremental maintenance keeps the maps consistent with the stored start otherwise.
    private func reconcileActiveToolCorrelationStartIfStale() {
        guard runState.isActive else { return }
        let resolvedStartIndex = Self.resolvedToolCorrelationStartIndex(
            for: items,
            boundary: toolCorrelationIndexes.activeTurnBoundary
        )
        guard toolCorrelationIndexes.activeTurnStartIndex != resolvedStartIndex else { return }
        rebuildToolCorrelationIndexes()
    }

    package enum SilentItemReplacementReason: String {
        case persistedSessionHydration
        case pendingToolFinalizationRepair
        case retentionCompaction
        case codexCommandStatusReconciliation
        case routeActivation
        /// O11: Send saved placed the same unsent saved input at the execution end (paired with
        /// its edited canonical transcript).
        case savedInputRelocation
        case clearedChat
        case stressHarnessReset
        case testOverride
    }

    /// Same turn/span structure and identical activities. Span metadata (for example a
    /// retained process `runID`) may differ: raw-input evidence only covers activities.
    private static func transcriptActivitiesMatch(_ lhs: AgentTranscript, _ rhs: AgentTranscript) -> Bool {
        guard lhs.turns.count == rhs.turns.count else { return false }
        for (lhsTurn, rhsTurn) in zip(lhs.turns, rhs.turns) {
            guard lhsTurn.id == rhsTurn.id,
                  lhsTurn.responseSpans.count == rhsTurn.responseSpans.count
            else {
                return false
            }
            for (lhsSpan, rhsSpan) in zip(lhsTurn.responseSpans, rhsTurn.responseSpans) {
                guard lhsSpan.id == rhsSpan.id, lhsSpan.activities == rhsSpan.activities else { return false }
            }
        }
        return true
    }

    /// Step 4d5 invariant backstop (not a display policy): a tool row associated to Claude provider
    /// history (imported or live canonical, whatever its proof) keeps its projected semantic payload
    /// (kind, text, tool name, invocation ID, arguments, output, error status and streaming state)
    /// through any incremental replacement or batch mutation; other presentation metadata may change.
    /// A replacement by a different item never displaces it. Call sites that must show different
    /// output append it as a separate unidentified row before reaching here.
    func preservingClaudeAssociatedToolPayload(of previous: AgentChatItem, in updated: AgentChatItem) -> AgentChatItem {
        guard previous.kind == .toolCall || previous.kind == .toolResult,
              providerHistoryRecovery?.associatesClaudeLocalItem(previous.id) == true
        else { return updated }
        return Self.restoringProjectedToolPayload(of: previous, in: updated)
    }

    private func preserveClaudeAssociatedToolPayloads(previous: [AgentChatItem], in updated: inout [AgentChatItem]) {
        guard let protectedIDs = providerHistoryRecovery?.claudeLocalItemIDs, !protectedIDs.isEmpty else { return }
        var protectedByID: [UUID: AgentChatItem] = [:]
        for item in previous where protectedIDs.contains(item.id) && (item.kind == .toolCall || item.kind == .toolResult) {
            protectedByID[item.id] = item
        }
        guard !protectedByID.isEmpty else { return }
        for index in updated.indices {
            guard let original = protectedByID[updated[index].id] else { continue }
            updated[index] = Self.restoringProjectedToolPayload(of: original, in: updated[index])
        }
    }

    private static func restoringProjectedToolPayload(of previous: AgentChatItem, in updated: AgentChatItem) -> AgentChatItem {
        guard updated.id == previous.id else { return previous }
        var restored = updated
        restored.kind = previous.kind
        restored.text = previous.text
        restored.toolName = previous.toolName
        restored.toolInvocationID = previous.toolInvocationID
        restored.toolArgsJSON = previous.toolArgsJSON
        restored.toolResultJSON = previous.toolResultJSON
        restored.toolIsError = previous.toolIsError
        restored.isStreaming = previous.isStreaming
        return restored
    }

    package func setItemsSilently(_ items: [AgentChatItem], reason: SilentItemReplacementReason) {
        if !runState.isActive, reason == .retentionCompaction, rawInputSanitizeEvidence != nil, self.items != items {
            dropRawInputSanitizeEvidenceAfterIdleRetention()
        }
        #if DEBUG
            if AgentTranscriptDebugInstrumentation.isEnabled {
                AgentTranscriptDebugInstrumentation.emit(AgentTranscriptDebugInstrumentation.sessionItemsReplacementHandler, .init(
                    reason: reason.rawValue,
                    previousItemCount: self.items.count,
                    newItemCount: items.count,
                    isEqual: self.items == items,
                    previousSignature: AgentTranscriptDebugInstrumentation.itemIdentitySignature(self.items),
                    newSignature: AgentTranscriptDebugInstrumentation.itemIdentitySignature(items)
                ))
            }
        #endif
        commitSourceItems(
            items,
            dispatch: .silent,
            diagnosticContext: "setItemsSilently reason=\(reason.rawValue)"
        )
        pendingSourceItemsMutationSummary = nil
        pendingDerivedTranscriptRefreshReason = nil
        derivedTranscriptRefreshGeneration &+= 1
        derivedTranscriptRefreshTask?.cancel()
        derivedTranscriptRefreshTask = nil
        derivedTranscriptRefreshDeferredGeneration = nil
    }

    @discardableResult
    package func replaceItemSilentlyForRetentionCompaction(
        at index: Int,
        with compactedItem: AgentChatItem,
        retainedRawPayload: String
    ) -> Bool {
        guard items.indices.contains(index) else { return false }
        let previousItem = items[index]
        guard previousItem.id == compactedItem.id,
              previousItem != compactedItem,
              ephemeralToolResultPayloadByItemID[previousItem.id] == retainedRawPayload
        else {
            return false
        }

        suppressSourceItemsChanged = true
        items[index] = compactedItem
        suppressSourceItemsChanged = false
        nextSequenceIndex = max(nextSequenceIndex, compactedItem.sequenceIndex + 1)
        updateToolCorrelationIndexes(
            previousItem: previousItem,
            updatedItem: compactedItem,
            at: index
        )
        sourceItemsRevision &+= 1
        derivedTranscriptSyncState = nil
        dropRawInputSanitizeEvidenceAfterIdleRetention()
        #if DEBUG
            test_incrementalRetentionCompactionCount += 1
        #endif
        assertSourceItemDerivedStateIsConsistent()
        return true
    }

    /// Retention changed source items: outside an active run, nothing refreshes soon enough
    /// for the evidence's pre-retention raw payloads to pay for their memory.
    private func dropRawInputSanitizeEvidenceAfterIdleRetention() {
        guard !runState.isActive else { return }
        rawInputSanitizeEvidence = nil
    }

    /// Compact any summary-only tool-result items in place and align
    /// `ephemeralToolResultPayloadByItemID` with the resulting live items.
    ///
    /// Used by captured-transcript apply paths so that when a stale captured
    /// presentation cannot be layered on top of newer live source items the
    /// live `toolResultJSON` is still reduced to its sanitized form (where
    /// policy requires it), the payload map only contains entries keyed by
    /// live item IDs, and stale payload entries for removed items are
    /// pruned. Mirrors the ephemeral-payload invariants that normal
    /// `TabSession` mutation helpers preserve via `reconcileEphemeralPayloadMap`.
    package func compactSummaryOnlyToolResultsAndAlignEphemeralPayloadMap() {
        if repairStoredSourceItemsIfNeeded(diagnosticContext: "compactSummaryOnlyToolResultsAndAlignEphemeralPayloadMap") {
            rebuildSourceItemDerivedState()
        }
        var alignedItems: [AgentChatItem] = []
        alignedItems.reserveCapacity(items.count)
        var alignedMap: [UUID: String] = [:]
        var itemsDidMutate = false
        for item in items {
            guard
                item.kind == .toolResult,
                let sanitized = AgentToolResultPersistencePolicy.sanitizedToolResult(for: item),
                sanitized.shouldRetainEphemeralRawPayload
            else {
                alignedItems.append(item)
                continue
            }
            let freshRetainedPayload: String? = {
                let raw = item.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let persisted = sanitized.resultJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !raw.isEmpty,
                      raw != persisted,
                      !AgentTranscriptToolNormalizer.isSummaryOnly(raw: raw)
                else {
                    return nil
                }
                return raw
            }()
            let existingRetainedPayload: String? = {
                let payload = ephemeralToolResultPayloadByItemID[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !payload.isEmpty else { return nil }
                return payload
            }()
            var compactedItem = item
            if compactedItem.toolResultJSON != sanitized.resultJSON {
                compactedItem.toolResultJSON = sanitized.resultJSON
                itemsDidMutate = true
            }
            if compactedItem.text != sanitized.text {
                compactedItem.text = sanitized.text
                itemsDidMutate = true
            }
            if compactedItem.toolIsError != sanitized.toolIsError {
                compactedItem.toolIsError = sanitized.toolIsError
                itemsDidMutate = true
            }
            alignedItems.append(compactedItem)
            if let retainedPayload = freshRetainedPayload ?? existingRetainedPayload {
                alignedMap[compactedItem.id] = retainedPayload
            }
        }
        if itemsDidMutate {
            dropRawInputSanitizeEvidenceAfterIdleRetention()
            sourceItemsRevision &+= 1
            derivedTranscriptSyncState = nil
            suppressSourceItemsChanged = true
            items = alignedItems
            suppressSourceItemsChanged = false
            syncNextSequenceIndexFromItems()
            liveItemIDs = Set(alignedItems.map(\.id))
            rebuildToolCorrelationIndexes()
        }
        replaceEphemeralToolResultPayloadMap(alignedMap, liveItemIDs: liveItemIDs)
        assertSourceItemDerivedStateIsConsistent()
    }

    package func clearDerivedTranscriptCaches() {
        rawInputSanitizeEvidence = nil
        transcript = .empty
        baseTranscriptProjection = .empty
        fullTranscriptProjection = .empty
        workingTranscriptProjection = .empty
        transcriptProjection = .empty
        turnProjectionCaches = [:]
        archivedTranscriptSnapshot = .empty
        isCompressedHistoryRevealed = false
        transcriptProjectionProtection = .none
        transcriptCanonicalVisibleRowCount = 0
        transcriptProjectionCounts = .zero
        transcriptAnalyticsSnapshot = .init()
        transcriptPerformanceSnapshot = .empty
        rawToolResultPayloadRenderRevisionByItemID = [:]
        derivedTranscriptSyncState = nil
    }

    package func replaceItems(
        _ items: [AgentChatItem],
        callerFileID: StaticString = #fileID,
        callerFunction: StaticString = #function,
        callerLine: UInt = #line
    ) {
        setItemsSilently(items, reason: .testOverride)
        pendingTurnRuntimeAnchors.removeAll()
        agentMessageRuntimeFootersByItemID.removeAll()
        pendingSourceItemsMutationSummary = nil
        onSourceItemsChanged?(
            self,
            .replaceAll,
            .init(fileID: callerFileID, function: callerFunction, line: callerLine)
        )
        lastActivityAt = Date()
        isDirty = true
    }

    package func appendItem(
        _ item: AgentChatItem,
        callerFileID: StaticString = #fileID,
        callerFunction: StaticString = #function,
        callerLine: UInt = #line
    ) {
        let caller = AgentSourceItemsMutationCaller(
            fileID: callerFileID,
            function: callerFunction,
            line: callerLine
        )
        var newItem = item
        newItem.sequenceIndex = nextSequenceIndex
        nextSequenceIndex += 1
        if !admitsIncrementalSourceItemID(newItem.id, replacing: nil),
           commitRepairedSourceItemsIfNeeded(items + [newItem], diagnosticContext: "appendItem", caller: caller)
        {
            if newItem.kind == .user {
                hasSentFirstMessage = true
                lastUserMessageAt = newItem.timestamp
            }
            lastActivityAt = Date()
            isDirty = true
            return
        }
        let appendedIndex = items.count
        suppressSourceItemsChanged = true
        items.append(newItem)
        suppressSourceItemsChanged = false
        reconcileIncrementalEphemeralPayload(previousItem: nil, updatedItem: newItem)
        assertIncrementalSourceItemIdentity(previousID: nil, updatedID: newItem.id)
        appendToolCorrelationIndexes(for: newItem, at: appendedIndex)
        finishIncrementalSourceItemsMutation(.append(index: appendedIndex, itemKind: newItem.kind), caller: caller)
        if newItem.kind == .user {
            hasSentFirstMessage = true
            lastUserMessageAt = newItem.timestamp
        }
        lastActivityAt = Date()
        isDirty = true
    }

    package func replaceItem(
        at index: Int,
        with updatedItem: AgentChatItem,
        callerFileID: StaticString = #fileID,
        callerFunction: StaticString = #function,
        callerLine: UInt = #line
    ) {
        let caller = AgentSourceItemsMutationCaller(
            fileID: callerFileID,
            function: callerFunction,
            line: callerLine
        )
        guard items.indices.contains(index) else { return }
        let previousItem = items[index]
        let updatedItem = preservingClaudeAssociatedToolPayload(of: previousItem, in: updatedItem)
        guard updatedItem != previousItem else { return }
        if !admitsIncrementalSourceItemID(updatedItem.id, replacing: previousItem.id) {
            var candidateItems = items
            candidateItems[index] = updatedItem
            if commitRepairedSourceItemsIfNeeded(candidateItems, diagnosticContext: "replaceItem", caller: caller) {
                lastActivityAt = Date()
                isDirty = true
                return
            }
        }
        suppressSourceItemsChanged = true
        items[index] = updatedItem
        suppressSourceItemsChanged = false
        nextSequenceIndex = max(nextSequenceIndex, updatedItem.sequenceIndex + 1)
        reconcileIncrementalEphemeralPayload(previousItem: previousItem, updatedItem: updatedItem)
        assertIncrementalSourceItemIdentity(previousID: previousItem.id, updatedID: updatedItem.id)
        updateToolCorrelationIndexes(previousItem: previousItem, updatedItem: updatedItem, at: index)
        finishIncrementalSourceItemsMutation(
            .replace(index: index, previousKind: previousItem.kind, currentKind: updatedItem.kind),
            caller: caller
        )
        lastActivityAt = Date()
        isDirty = true
    }

    package func mutateItem(
        at index: Int,
        _ mutate: (inout AgentChatItem) -> Void,
        callerFileID: StaticString = #fileID,
        callerFunction: StaticString = #function,
        callerLine: UInt = #line
    ) {
        let caller = AgentSourceItemsMutationCaller(
            fileID: callerFileID,
            function: callerFunction,
            line: callerLine
        )
        guard items.indices.contains(index) else { return }
        let previousItem = items[index]
        var updatedItem = previousItem
        mutate(&updatedItem)
        updatedItem = preservingClaudeAssociatedToolPayload(of: previousItem, in: updatedItem)
        guard updatedItem != previousItem else { return }
        if !admitsIncrementalSourceItemID(updatedItem.id, replacing: previousItem.id) {
            var candidateItems = items
            candidateItems[index] = updatedItem
            if commitRepairedSourceItemsIfNeeded(candidateItems, diagnosticContext: "mutateItem", caller: caller) {
                lastActivityAt = Date()
                isDirty = true
                return
            }
        }
        suppressSourceItemsChanged = true
        items[index] = updatedItem
        suppressSourceItemsChanged = false
        nextSequenceIndex = max(nextSequenceIndex, updatedItem.sequenceIndex + 1)
        reconcileIncrementalEphemeralPayload(previousItem: previousItem, updatedItem: updatedItem)
        assertIncrementalSourceItemIdentity(previousID: previousItem.id, updatedID: updatedItem.id)
        updateToolCorrelationIndexes(previousItem: previousItem, updatedItem: updatedItem, at: index)
        finishIncrementalSourceItemsMutation(.mutate(index: index, itemKind: updatedItem.kind), caller: caller)
        lastActivityAt = Date()
        isDirty = true
    }

    @discardableResult
    package func removeItem(
        at index: Int,
        callerFileID: StaticString = #fileID,
        callerFunction: StaticString = #function,
        callerLine: UInt = #line
    ) -> AgentChatItem? {
        guard items.indices.contains(index) else { return nil }
        let removed = items[index]
        suppressSourceItemsChanged = true
        items.remove(at: index)
        suppressSourceItemsChanged = false
        reconcileIncrementalEphemeralPayload(previousItem: removed, updatedItem: nil)
        rebuildToolCorrelationIndexes()
        finishIncrementalSourceItemsMutation(
            .remove(index: index, itemKind: removed.kind),
            caller: .init(fileID: callerFileID, function: callerFunction, line: callerLine)
        )
        lastActivityAt = Date()
        isDirty = true
        return removed
    }

    func updateLastItem(
        _ mutate: (inout AgentChatItem) -> Void,
        callerFileID: StaticString = #fileID,
        callerFunction: StaticString = #function,
        callerLine: UInt = #line
    ) {
        let caller = AgentSourceItemsMutationCaller(
            fileID: callerFileID,
            function: callerFunction,
            line: callerLine
        )
        guard !items.isEmpty else { return }
        let index = items.count - 1
        let previousItem = items[index]
        var updatedItem = previousItem
        mutate(&updatedItem)
        updatedItem = preservingClaudeAssociatedToolPayload(of: previousItem, in: updatedItem)
        guard updatedItem != previousItem else { return }
        if !admitsIncrementalSourceItemID(updatedItem.id, replacing: previousItem.id) {
            var candidateItems = items
            candidateItems[index] = updatedItem
            if commitRepairedSourceItemsIfNeeded(candidateItems, diagnosticContext: "updateLastItem", caller: caller) {
                lastActivityAt = Date()
                isDirty = true
                return
            }
        }
        suppressSourceItemsChanged = true
        items[index] = updatedItem
        suppressSourceItemsChanged = false
        nextSequenceIndex = max(nextSequenceIndex, updatedItem.sequenceIndex + 1)
        reconcileIncrementalEphemeralPayload(previousItem: previousItem, updatedItem: updatedItem)
        assertIncrementalSourceItemIdentity(previousID: previousItem.id, updatedID: updatedItem.id)
        updateToolCorrelationIndexes(previousItem: previousItem, updatedItem: updatedItem, at: index)
        finishIncrementalSourceItemsMutation(
            .replace(index: index, previousKind: previousItem.kind, currentKind: updatedItem.kind),
            caller: caller
        )
        lastActivityAt = Date()
        isDirty = true
    }

    func bashLiveExecution(for transcriptItemID: UUID) -> AgentBashLiveExecutionState? {
        guard let key = bashLiveExecutionKeyByTranscriptItemID[transcriptItemID] else { return nil }
        return bashLiveExecutionByKey[key]
    }

    func setBashLiveExecution(_ state: AgentBashLiveExecutionState) {
        bashLiveExecutionByKey[state.executionKey] = state
        bashLiveExecutionKeyByTranscriptItemID[state.transcriptItemID] = state.executionKey
        lastActivityAt = Date()
    }

    @discardableResult
    func removeBashLiveExecution(forKey key: String) -> AgentBashLiveExecutionState? {
        guard let removed = bashLiveExecutionByKey.removeValue(forKey: key) else { return nil }
        bashLiveExecutionKeyByTranscriptItemID.removeValue(forKey: removed.transcriptItemID)
        lastActivityAt = Date()
        return removed
    }

    @discardableResult
    func removeBashLiveExecution(forTranscriptItemID transcriptItemID: UUID) -> AgentBashLiveExecutionState? {
        guard let key = bashLiveExecutionKeyByTranscriptItemID[transcriptItemID] else { return nil }
        return removeBashLiveExecution(forKey: key)
    }

    func clearBashLiveExecutions() {
        guard !bashLiveExecutionByKey.isEmpty || !bashLiveExecutionKeyByTranscriptItemID.isEmpty else { return }
        bashLiveExecutionByKey.removeAll()
        bashLiveExecutionKeyByTranscriptItemID.removeAll()
        lastActivityAt = Date()
    }
}
