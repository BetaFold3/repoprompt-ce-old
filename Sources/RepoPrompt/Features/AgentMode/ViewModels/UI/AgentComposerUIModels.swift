import Foundation
import RepoPromptAgentCore
import RepoPromptWorkspace

struct AgentComposerFocusRequest: Equatable {
    enum Reason: Equatable {
        case newSession
        case newKnowledgeSession
        case reusedPlaceholder
    }

    let id: UUID
    let tabID: UUID
    let reason: Reason
}

struct AgentDraftRestorationProps: Equatable {
    let id: UUID
    let tabID: UUID
    let text: String
    let message: String
    let strategy: AgentModeRunService.DraftRestorationStrategy

    init(_ event: AgentModeViewModel.DraftRestorationEvent) {
        id = event.id
        tabID = event.tabID
        text = event.text
        message = event.message
        strategy = event.strategy
    }
}

struct AgentStagedSlashCommandProps: Equatable {
    enum Kind: Equatable {
        case codexGoal
    }

    enum GoalAction: String, Equatable {
        case setObjective
        case show
        case pause
        case resume
        case clear
    }

    let kind: Kind
    let displayText: String
    let action: GoalAction
    let selectedWorkflowName: String?
    let appliesSelectedWorkflowContext: Bool
}

struct AgentRunCancelTarget: Equatable {
    let tabID: UUID
    let expectedRunID: UUID?
    let expectedActiveAgentSessionID: UUID?
    let expectedRunAttemptID: UUID?
    let expectedPendingUserInputRequestID: CodexAppServerRequestID?
}

struct AgentComposerSubmissionLatch {
    struct CompletionEffects: Equatable {
        let matchedAttempt: Bool
        let shouldClearInput: Bool
        let blockedMessage: String?

        static let stale = CompletionEffects(
            matchedAttempt: false,
            shouldClearInput: false,
            blockedMessage: nil
        )
    }

    private(set) var activeAttemptsByTabID: [UUID: AgentComposerSubmitAttempt] = [:]
    private(set) var inputRevision: UInt64 = 0
    private(set) var noticeRevision: UInt64 = 0

    func isLatched(for tabID: UUID?) -> Bool {
        guard let tabID else { return false }
        return activeAttemptsByTabID[tabID] != nil
    }

    func activeAttemptID(for tabID: UUID?) -> UUID? {
        guard let tabID else { return nil }
        return activeAttemptsByTabID[tabID]?.id
    }

    mutating func advanceInputRevision() {
        inputRevision &+= 1
    }

    mutating func advanceNoticeRevision() {
        noticeRevision &+= 1
    }

    mutating func begin(
        target: AgentComposerSubmitTarget,
        rawDraftSnapshot: String,
        attemptID: UUID = UUID()
    ) -> AgentComposerSubmitAttempt? {
        guard activeAttemptsByTabID[target.tabID] == nil else { return nil }
        let attempt = AgentComposerSubmitAttempt(
            id: attemptID,
            target: target,
            inputRevision: inputRevision,
            noticeRevision: noticeRevision,
            rawDraftSnapshot: rawDraftSnapshot
        )
        activeAttemptsByTabID[target.tabID] = attempt
        return attempt
    }

    @discardableResult
    mutating func cancel(_ attempt: AgentComposerSubmitAttempt) -> Bool {
        guard activeAttemptsByTabID[attempt.sourceTabID]?.id == attempt.id else { return false }
        activeAttemptsByTabID.removeValue(forKey: attempt.sourceTabID)
        return true
    }

    mutating func complete(
        _ attempt: AgentComposerSubmitAttempt,
        result: AgentModeViewModel.UserTurnSubmissionResult,
        currentTabID: UUID?,
        currentRawDraft: String
    ) -> CompletionEffects {
        guard activeAttemptsByTabID[attempt.sourceTabID]?.id == attempt.id else {
            return .stale
        }
        activeAttemptsByTabID.removeValue(forKey: attempt.sourceTabID)

        let inputStillMatches = currentTabID == attempt.sourceTabID
            && inputRevision == attempt.inputRevision
            && currentRawDraft == attempt.rawDraftSnapshot
        switch result {
        case .submitted, .scheduled:
            return CompletionEffects(
                matchedAttempt: true,
                shouldClearInput: inputStillMatches,
                blockedMessage: nil
            )
        case let .blocked(message):
            let mayPublishNotice = inputStillMatches && noticeRevision == attempt.noticeRevision
            return CompletionEffects(
                matchedAttempt: true,
                shouldClearInput: false,
                blockedMessage: mayPublishNotice ? message : nil
            )
        }
    }
}

/// The composer's submit-guidance notice. A transient notice clears after
/// `transientDurationNanoseconds`; a persistent one (9-live V1: a durable-admission refusal) stays
/// until the next submit attempt or composer text change.
struct AgentComposerSubmitNotice: Equatable {
    static let transientDurationNanoseconds: UInt64 = 3_000_000_000

    private(set) var message: String?
    private(set) var isPersistent = false

    /// Shows `message` (an empty one shows nothing). Returns whether a dismiss timer is needed.
    @discardableResult
    mutating func show(_ message: String, persistent: Bool) -> Bool {
        guard !message.isEmpty else { return false }
        self.message = message
        isPersistent = persistent
        return !persistent
    }

    /// The dismiss timer of the transient `message` fired: clears it unless it was replaced or is
    /// persistent. Returns whether it cleared.
    mutating func transientTimerFired(for message: String) -> Bool {
        guard !isPersistent, self.message == message else { return false }
        self.message = nil
        return true
    }

    /// A submit attempt or a composer text change: clears a persistent notice. Returns whether it
    /// cleared.
    mutating func clearPersistent() -> Bool {
        guard isPersistent else { return false }
        message = nil
        isPersistent = false
        return true
    }
}

struct AgentScheduledSendProps: Equatable, Identifiable {
    enum Status: Equatable {
        case scheduled
        case waitingForCurrentRun(blockingSessionName: String?)
        case waitingForWorkspace(blockingSessionName: String?)
        case needsConfirmation(AgentScheduledSendPersist.ConfirmationReason?)
        case dispatching
        /// Provider accepted the message; the durable commit of item + receipt is still pending
        /// and automatic persistence retries are in progress.
        case finalizing
        /// Provider accepted the message; automatic persistence stopped. Only a persistence
        /// retry is offered (never a provider re-send).
        case savingFailed(message: String?)
        case failed(message: String?)
        /// Persisted member this build cannot read; only Discard is offered.
        case unreadable
    }

    let id: UUID
    let tabID: UUID
    let notBefore: Date
    let rawText: String
    let attachments: AgentAttachmentStripSnapshot
    let isNewSessionStart: Bool
    let runAlongsideOtherSessions: Bool
    let firstEligibleAt: Date?
    let status: Status
    /// Recovery guidance that must be visible before any re-drive (for example the explicit
    /// duplicate-delivery warning after an interrupted dispatch whose bubble already exists).
    let recoveryMessage: String?
    /// A coordinator decision that the record requires confirmation whose durable save has not
    /// been acknowledged yet. Automatic sending is paused; the banner presents the confirmation
    /// state derived from the decision rather than from the persisted record.
    let pendingConfirmationSaving: PendingConfirmationSaving?
    /// What unresolved recovery this schedule waits for (lossless restart F2): the scheduler's
    /// recorded blocker, so Send now never looks like it silently did nothing.
    let recoveryBlockedMessage: String?

    enum PendingConfirmationSaving: Equatable {
        case saving
        case needsAttention(message: String?)
    }

    init(
        tabID: UUID,
        scheduledSend: AgentScheduledSendPersist,
        blockingSessionName: String? = nil,
        recoveryPhase: AgentScheduledSendRecoveryPhase? = nil,
        pendingConfirmation: AgentScheduledSendPendingConfirmationStatus? = nil,
        recoveryBlocker: AgentScheduledSendRecoveryBlocker? = nil
    ) {
        id = scheduledSend.id
        recoveryBlockedMessage = scheduledSend.state == .dispatching
            ? nil
            : recoveryBlocker.map(Self.recoveryBlockedMessage(for:))
        self.tabID = tabID
        notBefore = scheduledSend.notBefore
        rawText = scheduledSend.rawText
        attachments = AgentAttachmentStripSnapshot(
            scopeTabID: tabID,
            imageAttachments: scheduledSend.attachments,
            taggedFileAttachments: scheduledSend.taggedFileAttachments
        )
        isNewSessionStart = scheduledSend.isNewSessionStart
        runAlongsideOtherSessions = scheduledSend.runAlongsideOtherSessions
        firstEligibleAt = scheduledSend.firstEligibleAt
        if let pendingConfirmation, scheduledSend.state != .dispatching {
            // Derived projection: the decision blocks sending now even though the persisted
            // record has not been rewritten yet.
            status = .needsConfirmation(pendingConfirmation.reason)
            switch pendingConfirmation.phase {
            case let .needsAttention(lastFailure):
                pendingConfirmationSaving = .needsAttention(message: lastFailure)
                recoveryMessage = Self.pendingConfirmationAttentionMessage
            case .waitingForOwner, .saving, .waitingToRetry:
                pendingConfirmationSaving = .saving
                recoveryMessage = Self.pendingConfirmationSavingMessage
            }
            return
        }
        pendingConfirmationSaving = nil
        status = switch scheduledSend.state {
        case .scheduled where scheduledSend.firstEligibleAt != nil && scheduledSend.isNewSessionStart:
            .waitingForWorkspace(blockingSessionName: blockingSessionName)
        case .scheduled where scheduledSend.firstEligibleAt != nil:
            .waitingForCurrentRun(blockingSessionName: blockingSessionName)
        case .scheduled:
            .scheduled
        case .needsConfirmation:
            .needsConfirmation(scheduledSend.confirmationReason)
        case .dispatching where recoveryPhase != nil:
            Self.acceptedStatus(for: recoveryPhase)
        case .dispatching:
            .dispatching
        case .failed:
            .failed(message: scheduledSend.lastFailureMessage)
        }
        recoveryMessage = switch scheduledSend.state {
        case .needsConfirmation:
            scheduledSend.lastFailureMessage.flatMap { $0.isEmpty ? nil : $0 }
        case .dispatching where recoveryPhase.map(Self.isAttention) == true:
            Self.savingFailedRecoveryMessage
        case .scheduled, .dispatching, .failed:
            nil
        }
    }

    static let savingFailedRecoveryMessage =
        "Message sent, but saving has not completed. Retry saving will not send the message again."
    static let pendingConfirmationSavingMessage =
        "Automatic sending is paused until this confirmation is saved."
    static let pendingConfirmationAttentionMessage =
        "Automatic sending is paused. Saving the confirmation failed; retry saving or confirm the message yourself."

    /// Plain, short wording for the banner. The first applicable reason wins; counts are other
    /// sessions in this workspace.
    static func recoveryBlockedMessage(for blocker: AgentScheduledSendRecoveryBlocker) -> String {
        func sessions(_ count: Int, _ adjective: String) -> String {
            count == 1 ? "1 \(adjective) session" : "\(count) \(adjective) sessions"
        }
        if blocker.workspaceRestriction != nil {
            return "Waiting: this workspace couldn't be checked for interrupted work. Restart RepoPrompt to check again."
        }
        if blocker.destinationUnresolved {
            // Own-session causes vary (held transfer, restriction, earlier-launch process, crash
            // hold); not every one is resolvable from Needs Attention, so no pointer is given.
            return "Waiting until this session's recovery is resolved."
        }
        if !blocker.interruptedSessionIDs.isEmpty {
            let count = blocker.interruptedSessionIDs.count
            return "Will send after \(sessions(count, "interrupted")) in this workspace \(count == 1 ? "is" : "are") resolved: choose It stopped (not Dismiss) in Needs Attention…"
        }
        if !blocker.restrictedSessionIDs.isEmpty {
            let count = blocker.restrictedSessionIDs.count
            return "Will send after \(sessions(count, "unchecked")) in this workspace \(count == 1 ? "is" : "are") resolved. Restart RepoPrompt to check again."
        }
        if blocker.recoveryActionInProgress {
            return "Will send after a recovery action in this workspace finishes."
        }
        if blocker.runtimeOwnershipUnresolved {
            return "Will send after agent processes from an earlier launch are checked. See Needs Attention…"
        }
        let others = blocker.otherUnresolvedSessionIDs.count
        if others > 0 {
            return "Will send after \(others == 1 ? "1 session" : "\(others) sessions") in this workspace finish\(others == 1 ? "es" : "") recovery. Review Needs Attention…"
        }
        return "Will send after interrupted work in this workspace is resolved. Review Needs Attention…"
    }

    private static func acceptedStatus(for phase: AgentScheduledSendRecoveryPhase?) -> Status {
        switch phase {
        case let .needsAttention(reason)?:
            .savingFailed(message: attentionMessage(for: reason))
        case .awaitingProviderOutcome?, .saving?, .waitingToRetry?, nil:
            .finalizing
        }
    }

    private static func isAttention(_ phase: AgentScheduledSendRecoveryPhase) -> Bool {
        if case .needsAttention = phase { return true }
        return false
    }

    private static func attentionMessage(for reason: AgentScheduledSendRecoveryAttentionReason) -> String? {
        switch reason {
        case let .persistenceExhausted(lastFailure):
            lastFailure.isEmpty ? nil : lastFailure
        case .destinationUnavailable:
            "The workspace storage folder is unavailable."
        case let .invalidAcceptanceEvidence(detail):
            detail.isEmpty ? nil : detail
        case .unresolvedProviderOutcome:
            "The provider outcome was not reported before this window went away."
        }
    }

    private init(unreadableForTabID tabID: UUID) {
        id = tabID
        self.tabID = tabID
        notBefore = .distantPast
        rawText = ""
        attachments = AgentAttachmentStripSnapshot(
            scopeTabID: tabID,
            imageAttachments: [],
            taggedFileAttachments: []
        )
        isNewSessionStart = false
        runAlongsideOtherSessions = false
        firstEligibleAt = nil
        status = .unreadable
        pendingConfirmationSaving = nil
        recoveryBlockedMessage = nil
        recoveryMessage = "This scheduled message was saved by a newer or incompatible version and can't be read here. It will never be sent automatically."
    }

    static func unreadable(tabID: UUID) -> AgentScheduledSendProps {
        AgentScheduledSendProps(unreadableForTabID: tabID)
    }

    var isUnreadable: Bool {
        status == .unreadable
    }
}

struct AgentScheduledSendActions {
    let executeSchedule: (
        _ claim: AgentModeViewModel.AgentComposerSubmitClaim,
        _ text: String,
        _ notBefore: Date,
        _ runAlongsideOtherSessions: Bool
    ) async -> AgentModeViewModel.UserTurnSubmissionResult
    let update: (
        _ tabID: UUID,
        _ scheduleID: UUID,
        _ text: String,
        _ notBefore: Date,
        _ runAlongsideOtherSessions: Bool,
        _ removingImageAttachmentIDs: Set<UUID>,
        _ removingTaggedFileAttachmentIDs: Set<UUID>
    ) async -> String?
    let cancel: (_ tabID: UUID, _ scheduleID: UUID) async -> String?
    let sendNow: (
        _ tabID: UUID,
        _ scheduleID: UUID,
        _ runAlongsideOtherSessions: Bool
    ) async -> String?
    let discardUnreadable: (_ tabID: UUID) async -> String?
    /// Persistence-only retry for an accepted message whose durable save stopped; never a send.
    let retrySaving: (_ tabID: UUID) async -> String?
}

/// Presentation of a stale-reset recovery: this tab retains a local conversation that cannot be
/// saved because the conversation was reset in another window; only an explicit reload replaces it.
struct AgentStaleResetRecoveryProps: Equatable, Identifiable {
    enum Status: Equatable {
        case stopping
        case retained
        case reloading
    }

    let tabID: UUID
    let recoveryID: UUID
    let status: Status
    /// Last reported problem (failed stop or failed reload); the retained view is unchanged.
    let problem: String?

    var id: UUID {
        recoveryID
    }

    var canReload: Bool {
        status == .retained
    }

    var canRetryStop: Bool {
        status == .stopping && problem != nil
    }
}

struct AgentStaleResetRecoveryActions {
    /// Explicitly confirmed replacement of the retained view by the persisted snapshot.
    let reloadLatest: (_ tabID: UUID, _ recoveryID: UUID) async -> String?
    /// One more stop attempt after a reported stop problem.
    let retryStopping: (_ tabID: UUID, _ recoveryID: UUID) async -> String?
}

/// Lossless-restart recovery banner: the exact session filter of the coordinator's app-wide
/// recovery catalog (Phase 2) for the active session, plus its owner's composer-preparation
/// failure. Only needs-action items are shown (O34-1); in the ready state the banner exists only
/// while it has rows. Needs-action items elsewhere are counted on its Needs Attention button while
/// it is shown. Opening a row never starts a provider.
struct AgentRecoveryListProps: Equatable {
    enum Status: Equatable {
        case loading
        case ready
        /// Startup (or composition) failed: every send route stays closed until Retry succeeds.
        case failed(String)
    }

    let status: Status
    let rows: [AgentRecoveryListRowProps]
    let canRetry: Bool
    /// Undismissed needs-action catalog items outside this banner (shown in the Needs Attention
    /// sheet).
    var otherItemCount: Int = 0

    /// Nothing to show in the ready state: no rows of this session. Items elsewhere never keep the
    /// banner visible on their own (O34-1).
    var isEmpty: Bool {
        status == .ready && rows.isEmpty
    }

    /// Banner header. F3: `rows` are this session's items and `otherItemCount` the items elsewhere
    /// (the "Needs Attention (n)…" button), so the two counts are never merged and a session with
    /// no rows never claims "0 items need your attention".
    var headerText: String {
        switch status {
        case .loading:
            return "Checking for work interrupted when RepoPrompt last closed…"
        case let .failed(message):
            return message
        case .ready:
            if rows.isEmpty {
                // Fallback only: a ready banner without rows is hidden (`isEmpty`), so this text is
                // never shown.
                return "Nothing interrupted in this session."
            }
            let elsewhere = otherItemCount == 1
                ? "1 item elsewhere needs attention."
                : "\(otherItemCount) items elsewhere need attention."
            if otherItemCount == 0 {
                return rows.count == 1
                    ? "1 saved or interrupted item needs your attention."
                    : "\(rows.count) saved or interrupted items need your attention."
            }
            let here = rows.count == 1
                ? "1 saved or interrupted item in this session needs your attention."
                : "\(rows.count) saved or interrupted items in this session need your attention."
            return "\(here) \(elsewhere)"
        }
    }
}

/// One row of the app-wide Needs Attention sheet.
struct AgentRecoveryNeedsAttentionRow: Equatable, Identifiable {
    let row: AgentRecoveryListRowProps
    let isDismissed: Bool
    /// The item belongs to another workspace (actions may need that workspace open).
    let isOtherWorkspace: Bool
    /// Which sheet section lists it (O34-2).
    let attention: AgentRecoveryCatalogAttention
    /// Why the note is cleared from ordinary presentation (listed only under "Show dismissed and
    /// cleared"); `nil` when it is not cleared.
    var automaticClear: AgentRecoveryCatalogAutomaticClear?
    /// The catalog item exactly as displayed: bulk Dismiss acts on it, never on a newer item with
    /// the same ID.
    var item: AgentRecoveryCatalogItem?

    var id: String {
        row.id
    }

    /// Listed only while "Show dismissed and cleared" is on (never counted).
    var isHidden: Bool {
        isDismissed || automaticClear != nil
    }
}

extension Notification.Name {
    /// A window's view model asks its root sheet host (`AgentRecoveryNeedsAttentionHost`) to present
    /// the Needs Attention sheet; the host consumes the view model's pending request. `object`: the
    /// `AgentModeViewModel`.
    static let agentRecoveryNeedsAttentionRequested = Notification.Name("AgentRecovery.needsAttentionRequested")
}

struct AgentRecoveryListRowProps: Equatable, Identifiable {
    enum Action: Hashable {
        /// Move the held input into this session's (empty) composer, then withdraw it.
        case edit
        /// Withdraw the held input (the row stays until the withdrawal commits).
        case remove
        /// Open the session's tab; actions apply only to the open session.
        case open
        /// Confirm that the previous run is no longer running (the exact published crash hold).
        case confirmStopped
        /// Durably dismiss the card in its displayed state (it returns if that state changes). It
        /// never resolves, withdraws, removes, confirms, or releases anything.
        case dismiss
        /// Remove the saved historical question (its request already ended).
        case removeSavedQuestion
        /// Place the displayed held or unsaved draft into this session's empty message box.
        case restoreDraft
        /// Discard exactly the displayed held or unsaved draft (after `confirmation`); current
        /// typing is kept and saved.
        case discardDraft
        /// Write the message box again after a failed save.
        case retrySave
        /// R10: stop owning a held scheduled transfer (after `confirmation`). The message stays
        /// visible with its uncertain delivery; it is never marked "not delivered" or resent.
        case cancelSchedule
        /// R6: run one fresh discovery of surviving agent processes (covers missed exit events).
        case refreshProcesses
        /// R6: persist Let finish for the displayed runtime; it keeps watching and stays restricted.
        case letProcessFinish
        /// Phase 4 (gated OFF in production): a new continuation message through normal dispatch.
        case continueTurn
        /// Phase 4 (gated OFF): send the one saved, never handed-off message through normal dispatch.
        case sendSaved
        /// Phase 4 (gated OFF): send a saved question's text and partial answer as ordinary input.
        case answerAsInput
        /// Phase 4 (gated OFF): import what the provider recorded; never sends anything.
        case reconcileHistory
        /// Phase 4 (gated OFF): explicit fresh conversation after a failed Claude resume.
        case continueInNewConversation
        /// Step 5b: open the existing delegated child session linked under this run attempt. It
        /// only opens that session; nothing is recreated, restarted, or resent.
        case openDelegatedSession(UUID)
        /// Step 5a: copy the exact stored edit proposal (its full proposed text) to the pasteboard.
        /// Never writes the target file.
        case copyProposal
        /// Step 5a: durably withdraw the stored edit proposal (after `confirmation`). The target
        /// file is never touched.
        case discardProposal
    }

    let id: String
    let sessionID: UUID?
    let sessionName: String
    let title: String
    let detail: String
    /// Viewable full text (View): the original input when the row is held input, or the full
    /// per-child status when the row is a run with delegated-child links.
    let text: String?
    let attachmentNames: [String]
    let actions: [Action]
    let isWorking: Bool
    /// Persistent inline error of the last failed action (Retry by repeating it).
    let error: String?
    /// Explicit confirmation shown before a destructive `discardDraft`.
    var confirmation: String?
    /// Phase 4: editable continuation text shown before `continueTurn` / `continueInNewConversation`
    /// is chosen (the R7 default). The exact edited text is what the choice reserves and sends.
    var continuationText: String?
    /// Phase 4: shown in the continuation editor when an earlier choice may have reached the agent;
    /// sending from that editor is the explicit confirmation.
    var continuationWarning: String?
    /// Step 5a: opening View asks `AgentRecoveryListActions.inspect` for a transient comparison of
    /// the target file with the stored proposal.
    var inspectsOnView = false
}

struct AgentRecoveryListActions {
    let perform: (_ rowID: String, _ action: AgentRecoveryListRowProps.Action) async -> Void
    /// Phase 4: a continuation choice with the card's edited text and the warning it showed.
    var performContinuation: (
        _ rowID: String,
        _ action: AgentRecoveryListRowProps.Action,
        _ text: String,
        _ acknowledgedWarning: String?
    ) async -> Void = { _, _, _, _ in }
    /// 9-live R4b/R5: the app-wide in-memory Continue draft of a row, read when its editor opens.
    /// Required (review B L7): a construction site that omits it would silently lose R5.
    let continuationDraft: (_ rowID: String) -> String?
    /// 9-live R5: every edit in a row's Continue editor (in memory; survives the editor closing).
    let updateContinuationDraft: (_ rowID: String, _ text: String) -> Void
    let retryStartup: () -> Void
    /// Presents the app-wide Needs Attention sheet.
    var openNeedsAttention: () -> Void = {}
    /// Step 5a: a transient, read-only comparison shown in an `inspectsOnView` row's viewer (nil
    /// when unavailable). Never blocks View or Copy.
    var inspect: (_ rowID: String) async -> String? = { _ in nil }
}

struct AgentComposerProps: Equatable {
    let currentTabID: UUID?
    let submitTarget: AgentComposerSubmitTarget?
    let attachments: AgentAttachmentStripSnapshot
    let scheduledSend: AgentScheduledSendProps?
    let staleResetRecovery: AgentStaleResetRecoveryProps?
    let canSchedule: Bool
    /// Semantic first-prompt predicate (unlinked tab or linked-but-untouched session): the
    /// schedule control offers "Run alongside other sessions" exactly when the record will be a
    /// workspace-gated new-session start.
    let scheduleTargetIsNewSessionStart: Bool
    let runState: AgentSessionRunState
    let cancelTarget: AgentRunCancelTarget?
    let isAgentBusy: Bool
    let isWaitingForInstruction: Bool
    let canUseLinkedAgentSession: Bool
    let isCurrentTabMCPControlled: Bool
    let areModelControlsDisabled: Bool
    let providerControls: AgentProviderControlsBinding?
    let isCodexRunActive: Bool
    let hasAvailableAgentProviders: Bool
    let canSendWithCurrentProvider: Bool
    let unavailableSelectedAgentMessage: String?
    let runLocation: AgentRunLocation?
    let runLocationHostDisplayName: String?
    let remoteHostCatalog: RemoteHostAgentCatalog?
    let selectedAgent: AgentProviderKind
    let selectedModelRaw: String
    let selectedModelDisplayName: String
    let ohMyPiThinkingSelections: OhMyPiThinkingSelections
    let selectedReasoningEffortRaw: String?
    let selectedReasoningEffortDisplayName: String
    let availableAgents: [AgentProviderKind]
    let isProviderPickerLockedForCurrentTab: Bool
    let lockedAgentSelectionMessage: String?
    let autoEditEnabled: Bool
    let stagedSlashCommand: AgentStagedSlashCommandProps?
    let draftRestorationEvent: AgentDraftRestorationProps?
    let fileTagLookupContextIdentity: AgentWorkspaceLookupContextIdentity
    /// Pending child questions addressed to this tab's agent (delegated ask_user plan §6.5).
    var delegatedQuestions: [AgentDelegatedQuestionBannerRow] = []
    /// Lossless-restart recovery list for this workspace (open and closed sessions).
    var recoveryList: AgentRecoveryListProps?
    /// R4 edit freeze of this window (quit or window close preserving it): the composer is disabled.
    var isShutdownFrozen = false

    static let empty = AgentComposerProps(
        currentTabID: nil,
        submitTarget: nil,
        attachments: AgentAttachmentStripSnapshot(
            imageAttachments: [],
            taggedFileAttachments: []
        ),
        scheduledSend: nil,
        staleResetRecovery: nil,
        canSchedule: false,
        scheduleTargetIsNewSessionStart: false,
        runState: .idle,
        cancelTarget: nil,
        isAgentBusy: false,
        isWaitingForInstruction: false,
        canUseLinkedAgentSession: false,
        isCurrentTabMCPControlled: false,
        areModelControlsDisabled: false,
        providerControls: nil,
        isCodexRunActive: false,
        hasAvailableAgentProviders: false,
        canSendWithCurrentProvider: false,
        unavailableSelectedAgentMessage: nil,
        runLocation: nil,
        runLocationHostDisplayName: nil,
        remoteHostCatalog: nil,
        selectedAgent: .claudeCode,
        selectedModelRaw: AgentModel.defaultModel.rawValue,
        selectedModelDisplayName: AgentModel.defaultModel.displayName,
        ohMyPiThinkingSelections: .empty,
        selectedReasoningEffortRaw: nil,
        selectedReasoningEffortDisplayName: "",
        availableAgents: [],
        isProviderPickerLockedForCurrentTab: false,
        lockedAgentSelectionMessage: nil,
        autoEditEnabled: ApplyEditsApprovalStore.globalDefaultAutoEditEnabled(),
        stagedSlashCommand: nil,
        draftRestorationEvent: nil,
        fileTagLookupContextIdentity: AgentWorkspaceLookupContextSource(
            activeAgentSessionID: nil,
            worktreeBindings: []
        ).identity
    )
}
