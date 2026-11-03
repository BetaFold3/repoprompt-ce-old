import Foundation
import RepoPromptAgentCore
import RepoPromptWorkspace

enum AgentSidebarThreadKey: Hashable, Equatable {
    case session(UUID)
    case tab(UUID)

    static func key(sessionID: UUID?, tabID: UUID) -> AgentSidebarThreadKey {
        if let sessionID {
            return .session(sessionID)
        }
        return .tab(tabID)
    }
}

extension AgentModeViewModel {
    enum UserTurnSubmissionResult: Equatable {
        case submitted
        case scheduled(id: UUID)
        case blocked(message: String)
    }

    /// Origin of a prepared user turn (plan §3.3). `.scheduled` carries the frozen record and
    /// the persisted attempt whose `itemID` becomes the optimistic bubble's identity; it never
    /// reads or clears composer pending state.
    enum UserTurnInputSource {
        case composer
        case scheduled(record: AgentScheduledSendPersist, attempt: AgentScheduledSendPersist.Attempt)
    }

    /// Whether the shared append seam appended the turn's bubble or reused an authorized, already
    /// shown deterministic bubble (Send saved, review A P1-06).
    enum PreparedUserTurnBubbleDisposition: Equatable {
        case appended
        case reused
    }

    /// Result of the shared append seam used by composer, MCP, and scheduled turns.
    struct PreparedUserTurnAppend {
        let userItem: AgentChatItem
        /// Provider text before workflow wrapping (native slash provider text or the typed text,
        /// interview-first preamble included when consumed). Remote start naming derives from it.
        let effectiveUserText: String
        let wrappedText: String
        let codexCompactionInFlight: Bool
        let stagedCodexComputerUseActivationID: UUID?
        var disposition: PreparedUserTurnBubbleDisposition = .appended

        /// The bubble failure cleanup may remove: only one this submission appended. A reused
        /// bubble belongs to an earlier submission and is never deleted.
        var removableUserItemID: UUID? {
            disposition == .appended ? userItem.id : nil
        }
    }

    struct AgentComposerSubmitClaim {
        let attempt: AgentComposerSubmitAttempt
        let sourceSession: AgentTabSession
        let draftMutationGeneration: UInt64
    }

    enum AgentComposerSubmitClaimRejection: Equatable {
        case missingSession
        case sourceSessionIdentityMismatch
        case activeAttemptExists(activeAttemptID: UUID)
        case targetRejected(reason: String)
        case initialWorktreePreparationInProgress
        case executionLocationChangeInProgress

        var diagnosticReason: String {
            switch self {
            case .missingSession:
                "missing_session"
            case .sourceSessionIdentityMismatch:
                "source_session_identity_mismatch"
            case .activeAttemptExists:
                "existing_claim"
            case let .targetRejected(reason):
                reason
            case .initialWorktreePreparationInProgress:
                "initial_worktree_preparation_in_progress"
            case .executionLocationChangeInProgress:
                "execution_location_change_in_progress"
            }
        }
    }

    enum AgentComposerSubmitClaimResult {
        case claimed(AgentComposerSubmitClaim)
        case rejected(AgentComposerSubmitClaimRejection)
    }

    struct AssistantPresentationRequest: Equatable {
        let tabID: UUID
        let sessionIdentity: ObjectIdentifier
        let persistentBinding: AgentPersistentSessionBindingIdentity?
        let bindingTransitionGeneration: UInt64
        let sourceItemsRevision: Int
        let flushGeneration: UInt64
    }

    struct PersistedHydrationCommitToken: Equatable {
        let transition: AgentPersistentBindingTransitionToken
        let requestedSessionID: UUID
    }

    struct SessionPersistenceContext: Equatable {
        let workspace: WorkspaceModel
        let workspaceOwner: SessionIndexOwner?

        var workspaceID: UUID {
            workspace.id
        }
    }

    enum SessionAccessError: Error, Equatable {
        case tabUnavailable(tabID: UUID)
        case removalInProgress(tabID: UUID, operationID: UUID)
        case ownerChanged(tabID: UUID)
    }

    struct SessionSaveCommitToken: Equatable {
        let tabID: UUID
        let sessionIdentity: ObjectIdentifier
        let workspaceID: UUID
        let workspaceOwner: SessionIndexOwner?
        let binding: AgentPersistentSessionBindingIdentity
        let bindingTransitionGeneration: UInt64
        let sourceItemsRevision: Int
        let persistenceMutationGeneration: UInt64
        let saveRequestGeneration: UInt64
    }

    /// Operation-owned compose-tab removal batch: the complete requested tab set with each
    /// target's ownership state captured before the first admission await (a live owner with its
    /// binding/transition identity, or explicit absence), the workspace owner captured at entry,
    /// the admitted targets, and the verdict — scoped to this operation rather than to whatever
    /// object currently occupies a tab ID or whichever workspace is active later.
    @MainActor
    final class ComposeTabRemovalOperation {
        /// Ownership observed at admission entry, before any await.
        struct EntryOwner {
            let session: AgentTabSession
            let binding: AgentPersistentSessionBindingIdentity?
            let transitionGeneration: UInt64
        }

        struct Target {
            let tabID: UUID
            let session: AgentTabSession
            let binding: AgentPersistentSessionBindingIdentity?
            let transitionGeneration: UInt64
            let admissionID: UUID
            let consentedEpisodeID: UUID?
        }

        struct CleanupDescriptor {
            let tabID: UUID
            let session: AgentTabSession?
            let boundSessionID: UUID?
            let runID: UUID?
            let approvalScope: ApplyEditsApprovalScope
            let approvalSubscriptionID: UUID?
            let approvalScopeGeneration: UInt64?
            let mcpContext: AgentMCPControlContext?
            var deletionCandidates: [AgentSessionDeletionCandidate]
            var deletionDiscoverySucceeded = true
        }

        enum Phase: Equatable {
            case admitted
            case preparing
            case prepared
            case committed
            case cleaning
            case finished
            case aborted
        }

        let id: UUID
        let reason: PromptViewModel.ComposeTabRemovalReason
        /// Workspace/storage owner captured before admission. Every persistence action
        /// uses this value and never reacquires the active workspace.
        let persistenceContext: SessionPersistenceContext
        let requestedTabIDs: Set<UUID>
        let requestedStashedTabIDs: Set<UUID>
        /// Requested tabs that had no live session at entry; they must still have none at commit.
        let absentTabIDs: Set<UUID>
        let targets: [Target]
        var cleanupDescriptorsByTabID: [UUID: CleanupDescriptor] = [:]
        var phase: Phase = .admitted
        var cleanupTask: Task<Void, Never>?
        var cleanupFailures: [String] = []
        var isCallerFinalized = false

        var workspace: WorkspaceModel {
            persistenceContext.workspace
        }

        var workspaceID: UUID {
            persistenceContext.workspaceID
        }

        init(
            id: UUID,
            reason: PromptViewModel.ComposeTabRemovalReason,
            persistenceContext: SessionPersistenceContext,
            requestedTabIDs: Set<UUID>,
            requestedStashedTabIDs: Set<UUID>,
            absentTabIDs: Set<UUID>,
            targets: [Target]
        ) {
            self.id = id
            self.reason = reason
            self.persistenceContext = persistenceContext
            self.requestedTabIDs = requestedTabIDs
            self.requestedStashedTabIDs = requestedStashedTabIDs
            self.absentTabIDs = absentTabIDs
            self.targets = targets
        }
    }

    /// Confirmation request issued before a lifecycle operation would destroy or replace a tab
    /// whose retained local conversation cannot be saved.
    struct AgentStaleResetDiscardRequest: Equatable {
        let tabCount: Int
        /// Human-readable operation, e.g. "Closing the tab".
        let operation: String

        var title: String {
            tabCount == 1 ? "Discard the unsaved conversation?" : "Discard \(tabCount) unsaved conversations?"
        }

        var message: String {
            let subject = tabCount == 1
                ? "This session has a local conversation that could not be saved after it was reset in another window."
                : "\(tabCount) sessions have local conversations that could not be saved after they were reset in another window."
            return "\(subject) \(operation) will discard that local conversation permanently."
        }

        var confirmButtonTitle: String {
            "Discard and Continue"
        }
    }

    enum PersistentBindingResolution: Equatable {
        case unique(tabID: UUID)
        case notFound
        case ambiguous(tabIDs: [UUID])
    }

    enum PersistentBindingMutationError: Error, Equatable {
        case staleTransition
        case blockedByOwnership
        case ambiguous
        case tabNotFound
    }

    /// Reason tag emitted by sidebar forced-refresh call sites. Used purely for
    /// diagnostics and fingerprint-skipped events; does not gate publication.
    enum SidebarRefreshReason: String, Equatable, Hashable {
        case sessionList
        case sessionIndex
        case sortDates
        case runState
        case mcpControl
        case sessionName
        case parentRepair
        case metadataUpdated
        case delegatedQuestion
        case search
        case visibleCount
        case explicit
    }

    /// Signature of a compose tab's sidebar-rendered metadata. Captured separately
    /// from live `TabSession` state because sidebar rows resolve titles, pinned
    /// grouping, explicit session IDs, workspace order, and fallback activity dates
    /// from `ComposeTabState` values passed by the sidebar view.
    struct AgentSessionSidebarTabMetadataSignature: Equatable {
        let tabID: UUID
        let order: Int
        let normalizedName: String
        let activeAgentSessionID: UUID?
        let isPinned: Bool
        let lastModified: Date
    }

    /// Signature of a single `TabSession`'s sidebar-relevant state. Captured into a
    /// value type so fingerprint comparison is cheap and does not depend on the
    /// class identity of the live `TabSession` reference.
    struct AgentSessionSidebarTabSignature: Equatable {
        let tabID: UUID
        let activeAgentSessionID: UUID?
        let parentSessionID: UUID?
        let hasLoadedPersistedState: Bool
        let itemsIsEmpty: Bool
        let runState: AgentSessionRunState
        let lastActivityAt: Date
        let lastUserMessageAt: Date?
    }

    /// Fingerprint of every VM-level input that affects the rendered session sidebar.
    /// `syncSidebarUIState(refresh:reason:)` gates forced revisions on changes to
    /// this fingerprint, ensuring duplicate refresh requests during steady provider
    /// output do not bump `AgentSessionSidebarUIStore.revision`.
    struct AgentSessionSidebarContentFingerprint: Equatable {
        let currentTabID: UUID?
        let sessionListCacheReady: Bool
        let tabsWithActiveAgentRun: Set<UUID>
        let mcpControlledTabIDs: Set<UUID>
        let tabMetadataSignatures: [AgentSessionSidebarTabMetadataSignature]
        let sessionSignatures: [AgentSessionSidebarTabSignature]
        let sessionIndex: [UUID: AgentSessionIndexEntry]
        var pairedDeviceDisplayNameByBareID: [String: String] = [:]
        let sessionListSortDates: [UUID: Date]
        let sidebarRestoreFrozenOrderByTabID: [UUID: Int]
        /// Delegated ask_user badges keyed by durable session ID (plan §6.5).
        var delegatedQuestionAttentionBySessionID: [UUID: AgentDelegatedQuestionSidebarAttention] = [:]
    }

    struct ActiveUIInvalidation: OptionSet {
        let rawValue: Int

        static let composer = ActiveUIInvalidation(rawValue: 1 << 0)
        static let statusPills = ActiveUIInvalidation(rawValue: 1 << 1)
        static let runtimeMetrics = ActiveUIInvalidation(rawValue: 1 << 2)
        static let transcript = ActiveUIInvalidation(rawValue: 1 << 3)
        static let runInteraction = ActiveUIInvalidation(rawValue: 1 << 4)

        static let all: ActiveUIInvalidation = [
            .composer,
            .statusPills,
            .runtimeMetrics,
            .transcript,
            .runInteraction
        ]
    }

    /// Compatibility alias retained while Agent Mode call sites migrate to the
    /// provider binding layer's top-level permission profile model.
    typealias AgentPermissionProfile = AgentProviderPermissionProfile

    /// Internal for cross-file AgentModeViewModel extension access after the mechanical file split.
    enum MCPActiveInstructionDeliverySignalTiming: Equatable {
        /// The instruction can wake MCP waiters as soon as the local optimistic submit is accepted.
        case afterOptimisticSubmit
        /// The runtime has a provider-specific handoff path and wakes MCP waiters after provider send.
        case afterProviderSend
    }

    enum ActiveProviderSteeringRoute: Equatable {
        case acpPrompt
        case claudeNativeInterrupt
    }

    enum MCPInstructionDispatch: String, Equatable {
        case deliveredIntoWaitingContinuation = "delivered_waiting_continuation"
        case queuedClaudeInterrupt = "queued_claude_interrupt"
        case queuedACPInterrupt = "queued_acp_interrupt"
        case queuedFollowUp = "queued_follow_up"
        case dispatchedCodexTurn = "dispatched_codex_turn"
        case startedRun = "started_run"

        /// Whether this dispatch sent an instruction into an already-running session.
        /// Used to suppress stale assistant previews in the immediate steer response.
        var isActiveRunDispatch: Bool {
            switch self {
            case .queuedClaudeInterrupt, .queuedACPInterrupt, .queuedFollowUp, .dispatchedCodexTurn:
                true
            case .deliveredIntoWaitingContinuation, .startedRun:
                false
            }
        }

        /// Whether MCP waiters should be woken as soon as `mcpDispatchInstruction` returns.
        /// Some runtimes accept the local queue before provider delivery; those signal later
        /// from their provider-specific flush path.
        var signalsMCPDeliveryAfterDispatch: Bool {
            guard isActiveRunDispatch else { return false }
            switch self {
            case .queuedClaudeInterrupt, .queuedACPInterrupt:
                return false
            case .queuedFollowUp, .dispatchedCodexTurn:
                return true
            case .deliveredIntoWaitingContinuation, .startedRun:
                return false
            }
        }
    }

    struct MCPActiveInstructionDispatchPlan {
        let delivery: MCPInstructionDispatch
        let codexAttemptID: UUID?
        let signalsDeliveryAfterDispatch: Bool
    }

    struct MCPInteractionResponsePayload: Equatable {
        let text: String?
        let skip: Bool
        let explicitSkip: Bool
        let decisionRaw: String?
        let amendment: String?
        let answersByQuestionID: [String: [String]]
        let askUserAnswersByQuestionID: [String: AgentAskUserAnswer]
        let hasStructuredAnswerObjects: Bool
        let elicitationActionRaw: String?
        let elicitationContent: [String: AgentJSONValue]
        let elicitationMeta: [String: AgentJSONValue]

        init(
            text: String?,
            skip: Bool,
            explicitSkip: Bool = false,
            decisionRaw: String?,
            amendment: String?,
            answersByQuestionID: [String: [String]],
            askUserAnswersByQuestionID: [String: AgentAskUserAnswer] = [:],
            hasStructuredAnswerObjects: Bool = false,
            elicitationActionRaw: String? = nil,
            elicitationContent: [String: AgentJSONValue] = [:],
            elicitationMeta: [String: AgentJSONValue] = [:]
        ) {
            self.text = text
            self.skip = skip
            self.explicitSkip = explicitSkip
            self.decisionRaw = decisionRaw
            self.amendment = amendment
            self.answersByQuestionID = answersByQuestionID
            self.askUserAnswersByQuestionID = askUserAnswersByQuestionID
            self.hasStructuredAnswerObjects = hasStructuredAnswerObjects
            self.elicitationActionRaw = elicitationActionRaw
            self.elicitationContent = elicitationContent
            self.elicitationMeta = elicitationMeta
        }
    }

    struct MCPSessionTarget: Equatable {
        /// How this session target was obtained.
        enum Origin: Equatable {
            case existingSession
            case existingTab
            case createdForSessionResume
            case createdNewTab
        }

        let tabID: UUID
        let sessionID: UUID?
        let origin: Origin
        /// Profile adopted by a newly created child tab (`childSessionProfile`), or nil. MCP control
        /// activation expects this profile instead of `.standard`; it is never inferred from a tab.
        var adoptedSessionProfile: AgentSessionProfile?
    }

    struct NativeSlashPreparedUserTurn: Equatable {
        let command: CodexAgentModeCoordinator.NativeSlashCommand
        let argumentsText: String
        let providerText: String
        let bubbleWorkflow: AgentWorkflowDefinition?
        let shouldEnableCodexComputerUse: Bool
    }

    /// Why a refresh made no incremental final-turn import attempt. Diagnostics only: mirrors,
    /// but never drives, the source-summary admission in `refreshDerivedTranscriptState`. The
    /// run-state-only alternative and forced-cold derivation are decided in the view model only;
    /// a refused run-state-only refresh reports `missingSummary`.
    struct DerivedTranscriptIncrementalNoAttemptDiagnosis: Equatable {
        /// First failing admission guard, in the guard's evaluation order.
        enum Primary: String {
            case reasonNotLive
            case pendingQuestion
            case missingSummary
            case summaryRejected
        }

        /// Every flag present on the pending summary, reported even when an earlier guard
        /// already failed, so overlapping causes stay visible.
        struct SummaryFlags: OptionSet, Equatable {
            let rawValue: Int
            static let removal = SummaryFlags(rawValue: 1 << 0)
            static let replaceAll = SummaryFlags(rawValue: 1 << 1)
            static let user = SummaryFlags(rawValue: 1 << 2)
            static let structural = SummaryFlags(rawValue: 1 << 3)
            static let unranged = SummaryFlags(rawValue: 1 << 4)

            init(rawValue: Int) {
                self.rawValue = rawValue
            }

            init(_ summary: AgentPendingSourceItemsMutationSummary) {
                var flags: SummaryFlags = []
                if summary.containsRemoval { flags.insert(.removal) }
                if summary.containsReplaceAll { flags.insert(.replaceAll) }
                if summary.containsUserMutation { flags.insert(.user) }
                if summary.containsStructuralMutation { flags.insert(.structural) }
                if summary.containsUnrangedMutation { flags.insert(.unranged) }
                self = flags
            }

            /// Static labels joined by `-` in a fixed order; nil when empty.
            var label: String? {
                let ordered: [(SummaryFlags, String)] = [
                    (.removal, "removal"),
                    (.replaceAll, "replaceAll"),
                    (.user, "user"),
                    (.structural, "structural"),
                    (.unranged, "unranged")
                ]
                let labels = ordered.compactMap { contains($0.0) ? $0.1 : nil }
                return labels.isEmpty ? nil : labels.joined(separator: "-")
            }
        }

        let primary: Primary
        let summaryFlags: SummaryFlags

        /// Returns nil when the source-summary admission would attempt an incremental import.
        static func diagnose(
            reason: AgentDerivedTranscriptRefreshReason,
            hasPendingQuestion: Bool,
            summary: AgentPendingSourceItemsMutationSummary?
        ) -> DerivedTranscriptIncrementalNoAttemptDiagnosis? {
            let flags = summary.map(SummaryFlags.init) ?? []
            let primary: Primary
            if reason != .liveMutation {
                primary = .reasonNotLive
            } else if hasPendingQuestion {
                primary = .pendingQuestion
            } else if let summary {
                guard !summary.allowsIncrementalFinalTurnRebuild else { return nil }
                primary = .summaryRejected
            } else {
                primary = .missingSummary
            }
            return DerivedTranscriptIncrementalNoAttemptDiagnosis(primary: primary, summaryFlags: flags)
        }
    }

    struct PersistableTranscriptSnapshot {
        let transcript: AgentTranscript
        let projectionCounts: AgentTranscriptProjectionCounts
        let canonicalVisibleRowCount: Int
        let lastUserMessageAt: Date?
    }

    struct ActiveTranscriptFollowBindingState: Equatable {
        var tabID: UUID?
        var viewportState: AgentTranscriptViewportState = .liveBottom
        var armingState: AgentTranscriptAutoFollowArmingState = .armed
    }

    struct ActivePermissionChromeState: Equatable {
        let permissionProfile: AgentPermissionProfile
        let isSubagent: Bool
        let externallyManagedReason: String?

        static let userConfigured = ActivePermissionChromeState(
            permissionProfile: .userConfigured,
            isSubagent: false,
            externallyManagedReason: nil
        )
    }

    struct SidebarSession: Identifiable, Equatable {
        let id: UUID
        let tabID: UUID
        let title: String
        let lastUserMessageAt: Date?
        let activityDate: Date
        let isPinned: Bool
        let sessionID: UUID?
        let parentSessionID: UUID?
        let depth: Int
        let isMCPControlled: Bool
        let remoteHostName: String?
        let remoteHostAbbreviation: String?
        let remoteControlDeviceID: String?
        let remoteControlDeviceDisplayName: String?
        /// Bound-worktree visual identity for this session (Item 10). Nil when
        /// the session has no worktree bindings. Carries the representative
        /// (first) binding when a session is bound to multiple roots.
        let worktree: AgentWorktreeIndicator?
        /// Active worktree merge attention for this session (Item 8). Set when
        /// the session has an awaiting-approval, conflicted, or
        /// awaiting-commit merge operation; nil otherwise.
        let worktreeMergeAttention: AgentWorktreeMergeAttention?
        let scheduledSendStatus: AgentSidebarScheduledSendStatus?
        /// Delegated ask_user legibility (plan §6.5): pending child questions on a parent row,
        /// or "Waiting on parent agent" / "Needs your answer" on an asking child row.
        let delegatedQuestionAttention: AgentDelegatedQuestionSidebarAttention?
        let threadKey: AgentSidebarThreadKey?
        let hasThreadChildren: Bool
        let isThreadCollapsed: Bool
        let hiddenThreadDescendantCount: Int
        /// Number of hidden descendants (under this collapsed parent) that
        /// currently carry an unseen run-state attention badge. Used to tint
        /// the parent row's collapsed-count chip so a hidden sub-agent chat
        /// completing or needing approval still gets a visible signal.
        let hiddenThreadDescendantAttentionCount: Int
        let threadActivityDate: Date?
        let searchFields: AgentSessionSearchFields

        init(
            id: UUID,
            tabID: UUID,
            title: String,
            lastUserMessageAt: Date?,
            activityDate: Date,
            isPinned: Bool,
            sessionID: UUID?,
            parentSessionID: UUID?,
            depth: Int,
            isMCPControlled: Bool,
            remoteHostName: String? = nil,
            remoteHostAbbreviation: String? = nil,
            remoteControlDeviceID: String? = nil,
            remoteControlDeviceDisplayName: String? = nil,
            worktree: AgentWorktreeIndicator? = nil,
            worktreeMergeAttention: AgentWorktreeMergeAttention? = nil,
            scheduledSendStatus: AgentSidebarScheduledSendStatus? = nil,
            delegatedQuestionAttention: AgentDelegatedQuestionSidebarAttention? = nil,
            threadKey: AgentSidebarThreadKey? = nil,
            hasThreadChildren: Bool = false,
            isThreadCollapsed: Bool = false,
            hiddenThreadDescendantCount: Int = 0,
            hiddenThreadDescendantAttentionCount: Int = 0,
            threadActivityDate: Date? = nil,
            searchFields: AgentSessionSearchFields = .empty
        ) {
            self.id = id
            self.tabID = tabID
            self.title = title
            self.lastUserMessageAt = lastUserMessageAt
            self.activityDate = activityDate
            self.isPinned = isPinned
            self.sessionID = sessionID
            self.parentSessionID = parentSessionID
            self.depth = depth
            self.isMCPControlled = isMCPControlled
            self.remoteHostName = remoteHostName
            self.remoteHostAbbreviation = remoteHostAbbreviation
            self.remoteControlDeviceID = remoteControlDeviceID
            self.remoteControlDeviceDisplayName = remoteControlDeviceDisplayName
            self.worktree = worktree
            self.worktreeMergeAttention = worktreeMergeAttention
            self.scheduledSendStatus = scheduledSendStatus
            self.delegatedQuestionAttention = delegatedQuestionAttention
            self.threadKey = threadKey
            self.hasThreadChildren = hasThreadChildren
            self.isThreadCollapsed = isThreadCollapsed
            self.hiddenThreadDescendantCount = hiddenThreadDescendantCount
            self.hiddenThreadDescendantAttentionCount = hiddenThreadDescendantAttentionCount
            self.threadActivityDate = threadActivityDate
            self.searchFields = searchFields
        }
    }

    /// Internal for cross-file AgentModeViewModel extension access after the mechanical file split.
    struct SessionTreeNode {
        var parentSessionID: UUID?
        var composeTabIDs: Set<UUID> = []
        var stashedTabIDs: Set<UUID> = []
    }

    enum ExecutionLocationChangeConfirmation: Equatable {
        case startedThreadRestart
        case activeRunStop
    }

    enum ExecutionLocationChangeResult: Equatable {
        case applied
        case unchanged
        case confirmationRequired(ExecutionLocationChangeConfirmation)
        case blocked(String)
    }

    enum WorktreeBindingTransitionIntent {
        case initialSend
        case userExecutionLocationChange(confirmation: ExecutionLocationChangeConfirmation?)
        case externalManagement
    }

    /// Internal for cross-file AgentModeViewModel extension access after the mechanical file split.
    struct PendingUserTurnState: Equatable {
        let workflow: AgentWorkflowDefinition?
        let imageAttachments: [AgentImageAttachment]
        let taggedFileAttachments: [AgentTaggedFileAttachment]
        let initialStartLocation: AgentInitialStartLocation
        let remoteHost: AgentSessionRemoteHostBinding?

        var isEmpty: Bool {
            workflow == nil
                && imageAttachments.isEmpty
                && taggedFileAttachments.isEmpty
                && initialStartLocation == .local
                && remoteHost == nil
        }
    }

    /// Event emitted when queued steering text needs to be restored to the composer
    /// (e.g., steering send failed, or the user cancelled the run while messages were queued).
    struct DraftRestorationEvent: Equatable, Identifiable {
        let id: UUID
        let tabID: UUID
        let text: String
        let message: String
        let strategy: AgentModeRunService.DraftRestorationStrategy
    }

    /// Internal for cross-file AgentModeViewModel extension access after the mechanical file split.
    struct ImageAttachmentFingerprint: Hashable {
        let byteCount: Int64
        let digestHex: String
    }

    struct SlashSkillToken: Equatable {
        let name: String
        let tokenRange: NSRange
        let argumentsRange: NSRange
    }

    struct ResolvedSlashSkillInvocation: Equatable {
        let definition: AgentSkillDefinition
        let token: SlashSkillToken
    }

    /// Internal for cross-file AgentModeViewModel extension access after the mechanical file split.
    struct ResolvedNativeSlashCommand: Equatable {
        let command: CodexAgentModeCoordinator.NativeSlashCommand
        let token: SlashSkillToken
        let argumentsText: String
    }
}

extension AgentModeViewModel.MCPInstructionDispatch {
    /// Human-readable explanation of how an instruction was delivered.
    var deliveryExplanation: String? {
        switch self {
        case .startedRun:
            "Started a new run."
        case .deliveredIntoWaitingContinuation:
            "Delivered immediately into the pending prompt."
        case .queuedFollowUp:
            "Queued as the next turn once the active run reaches a safe handoff point."
        case .dispatchedCodexTurn:
            "Delivered to the active Codex run."
        case .queuedClaudeInterrupt:
            "Queued for Claude and requested an interrupt at the next decision point."
        case .queuedACPInterrupt:
            "Queued for ACP and will cancel the active prompt before sending steering."
        }
    }
}
