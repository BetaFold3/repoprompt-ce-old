//
//  AgentInputBar.swift
//  RepoPrompt
//
//  Input bar for Agent Mode with shared send/cancel controls.
//  Uses ComposerChrome for the floating bubble container.
//

import AppKit
import Combine
import RepoPromptAgentCore
import RepoPromptUI
import RepoPromptWorkspace
import SwiftUI
import UniformTypeIdentifiers

struct AgentComposerActions {
    let storeDraft: (_ tabID: UUID, _ text: String) -> Void
    let retrieveDraft: (_ tabID: UUID) -> String
    let claimSubmit: (_ attempt: AgentComposerSubmitAttempt) -> AgentModeViewModel.AgentComposerSubmitClaimResult
    let executeSubmit: (_ claim: AgentModeViewModel.AgentComposerSubmitClaim, _ text: String) async -> AgentModeViewModel.UserTurnSubmissionResult
    let scheduledSend: AgentScheduledSendActions
    let staleResetRecovery: AgentStaleResetRecoveryActions
    let cancelRun: (_ target: AgentRunCancelTarget) async -> Void
    let attachImages: (_ tabID: UUID, _ urls: [URL]) -> Void
    let removeImage: (_ tabID: UUID, _ attachmentID: UUID) -> Void
    let commitTaggedFile: (_ tabID: UUID, _ suggestion: MentionSuggestion, _ displayName: String) -> Void
    let removeTaggedFile: (_ tabID: UUID, _ attachmentID: UUID) -> Void
    let agentWorkspaceLookupContext: (_ tabID: UUID?) async -> WorkspaceLookupContext
    let slashSkillSuggestions: (_ query: String) async -> [MentionSuggestion]
    let modelOptions: (_ agent: AgentProviderKind, _ includeClaudeEffortVariants: Bool) -> [AgentModelOption]
    let canSelectAgentInCurrentChat: (_ agent: AgentProviderKind) -> Bool
    /// Returns a localized rejection message when the presentation snapshot is stale.
    let selectAgentModel: (_ agent: AgentProviderKind, _ rawModel: String) -> String?
    let selectOhMyPiThinking: (_ exactModelID: String, _ value: String?) -> Void
    let selectRemoteAgentModel: (_ rawModel: String) -> Void
    let reasoningEffortOptionsForCurrentSelection: () -> [CodexReasoningEffort]
    let selectReasoningEffort: (_ effort: CodexReasoningEffort?) -> Void
    let setAutoEditEnabled: (_ enabled: Bool) -> Void
    let setProviderPermissionLevel: (_ id: AgentProviderPermissionLevelID) -> Void
    let applyCodexToolSettingMutation: (_ mutation: CodexToolSettingMutation) -> Void
    let applyClaudeToolSettingMutation: (_ mutation: ClaudeToolSettingMutation) -> Void
    let setClaudeEffortLevel: (_ level: ClaudeCodeEffortLevel) -> Void
    let openCLIProvidersSettings: () -> Void
    /// Delegated ask_user parent banner actions (plan §6.5); nil hides the Open action.
    var delegatedQuestions: AgentDelegatedQuestionBannerActions?
    /// Lossless-restart recovery list actions; nil hides the list.
    var recoveryList: AgentRecoveryListActions?
    /// Live R4 edit freeze (quit or window close preserving this window): the composer refuses
    /// edits and image attachments at their entry instead of accepting input it could lose.
    var isShutdownFrozen: () -> Bool = { false }
}

enum CursorModelProviderChipDisplay {
    static func name(
        rawModel: String,
        fallbackDisplayName: String,
        parameterLauncherAvailable: Bool
    ) -> String {
        guard parameterLauncherAvailable else { return fallbackDisplayName }
        return AgentModelCatalog.displayName(
            for: rawModel,
            agentKind: .cursor,
            availability: .init(cursorAvailable: true),
            includeEffortSuffix: false,
            includeCursorParameterSuffix: false
        )
    }
}

struct AgentComposerFocusObservationCue: Equatable {
    enum RequestAction: Equatable {
        case none
        case applyAndConsume(UUID)
        case leavePending
        case discard(UUID)
    }

    let tabID: UUID?
    let requestID: UUID?
    let requestTabID: UUID?

    init(tabID: UUID?, request: AgentComposerFocusRequest?) {
        self.tabID = tabID
        requestID = request?.id
        requestTabID = request?.tabID
    }

    static func tabChanged(from oldValue: Self, to newValue: Self) -> Bool {
        oldValue.tabID != newValue.tabID
    }

    func requestAction(discardMismatch: Bool) -> RequestAction {
        guard let requestID, let requestTabID else { return .none }
        guard requestTabID == tabID else {
            return discardMismatch ? .discard(requestID) : .leavePending
        }
        return .applyAndConsume(requestID)
    }
}

struct AgentInputBar: View {
    let agentModeVM: AgentModeViewModel
    @ObservedObject var composerUI: AgentComposerUIStore
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    let oracleViewModel: OracleViewModel
    let promptManager: PromptViewModel
    let workspaceSearchService: WorkspaceSearchService
    let selectionCoordinator: WorkspaceSelectionCoordinator
    let runtimeVM: AgentRuntimeSidebarViewModel
    let windowID: Int
    let currentTabID: UUID?

    @Binding var resetTextFieldTrigger: Bool
    @Binding var composerBottomInset: CGFloat
    @Binding var transcriptBottomClearance: CGFloat

    @FocusState var isFocused: Bool
    @State private var composerFocusToken: UUID?

    /// Height of the footer spacing below the composer chrome
    static let footerHeight: CGFloat = 28

    private var composerFocusObservationCue: AgentComposerFocusObservationCue {
        AgentComposerFocusObservationCue(
            tabID: currentTabID,
            request: composerUI.focusRequest
        )
    }

    private var composerPlaceholderText: String {
        if let stagedSlashCommand = statusPillsUI.snapshot.stagedSlashCommand {
            switch stagedSlashCommand.action {
            case .setObjective where stagedSlashCommand.appliesSelectedWorkflowContext:
                return "Describe the Codex goal — selected workflow context will be included."
            case .setObjective:
                return "Describe the Codex goal..."
            case .show, .pause, .resume, .clear:
                return "Press Return to run the Codex goal command."
            }
        }
        if let workflow = statusPillsUI.snapshot.selectedWorkflow {
            if let builtIn = workflow.builtInWorkflow {
                return builtIn.composerGuidanceText
            }
            if let description = workflow.descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                return description
            }
        }
        return "Send a message..."
    }

    var body: some View {
        #if DEBUG
            let _ = AgentModePerfDiagnostics.increment("ui.body.inputBar")
        #endif
        AgentComposerView(
            props: composerUI.props,
            placeholderText: composerPlaceholderText,
            actions: composerActions,
            promptManager: promptManager,
            workspaceSearchService: workspaceSearchService,
            selectionCoordinator: selectionCoordinator,
            windowID: windowID,
            currentTabID: currentTabID,
            composerFocusToken: composerFocusToken,
            resetTextFieldTrigger: $resetTextFieldTrigger,
            composerBottomInset: $composerBottomInset,
            transcriptBottomClearance: $transcriptBottomClearance,
            isFocused: _isFocused
        )
        .equatable()
        .overlay(alignment: .bottom) {
            statusPills
                .padding(.bottom, Self.footerHeight + ComposerChrome<EmptyView, EmptyView>.baseBarHeight + composerBottomInset - 8)
        }
        // R4 edit freeze, published through the observed composer store (the detail view holds the
        // view model unobserved); after the overlay so the status pills are covered too. The text
        // field also refuses edits at its entry while frozen.
        .disabled(composerUI.props.isShutdownFrozen)
        .onChange(of: composerFocusObservationCue) { oldCue, newCue in
            let tabChanged = AgentComposerFocusObservationCue.tabChanged(
                from: oldCue,
                to: newCue
            )
            if tabChanged {
                composerFocusToken = nil
            }
            applyComposerFocusRequest(discardMismatch: tabChanged)
        }
        .onAppear {
            applyComposerFocusRequest(discardMismatch: false)
        }
    }

    private func applyComposerFocusRequest(discardMismatch: Bool) {
        switch composerFocusObservationCue.requestAction(discardMismatch: discardMismatch) {
        case .none, .leavePending:
            return
        case let .discard(requestID):
            composerUI.consumeFocusRequest(id: requestID)
        case let .applyAndConsume(requestID):
            #if DEBUG || EDIT_FLOW_PERF
                // Token handed to the text field only; not composer readiness.
                AgentInteractionLatencyProbe.composerFocusTokenApplied(requestID: requestID)
            #endif
            composerFocusToken = requestID
            isFocused = true
            composerUI.consumeFocusRequest(id: requestID)
        }
    }

    private var composerActions: AgentComposerActions {
        AgentComposerActions(
            storeDraft: { tabID, text in agentModeVM.storeDraftText(for: tabID, text) },
            retrieveDraft: { tabID in agentModeVM.retrieveDraftText(for: tabID) },
            claimSubmit: { attempt in agentModeVM.claimComposerSubmitAttempt(attempt) },
            executeSubmit: { claim, text in
                await agentModeVM.executeComposerSubmitAttempt(text: text, claim: claim)
            },
            scheduledSend: AgentScheduledSendActions(
                executeSchedule: { claim, text, notBefore, runAlongsideOtherSessions in
                    await agentModeVM.executeComposerScheduleAttempt(
                        text: text,
                        notBefore: notBefore,
                        runAlongsideOtherSessions: runAlongsideOtherSessions,
                        claim: claim
                    )
                },
                update: {
                    tabID,
                    scheduleID,
                    text,
                    notBefore,
                    runAlongsideOtherSessions,
                    removingImageAttachmentIDs,
                    removingTaggedFileAttachmentIDs in
                    await agentModeVM.updateScheduledSend(
                        tabID: tabID,
                        scheduleID: scheduleID,
                        text: text,
                        notBefore: notBefore,
                        runAlongsideOtherSessions: runAlongsideOtherSessions,
                        removingImageAttachmentIDs: removingImageAttachmentIDs,
                        removingTaggedFileAttachmentIDs: removingTaggedFileAttachmentIDs
                    )
                },
                cancel: { tabID, scheduleID in
                    await agentModeVM.cancelScheduledSend(
                        tabID: tabID,
                        scheduleID: scheduleID
                    )
                },
                sendNow: { tabID, scheduleID, runAlongsideOtherSessions in
                    await agentModeVM.sendScheduledSendNow(
                        tabID: tabID,
                        scheduleID: scheduleID,
                        runAlongsideOtherSessions: runAlongsideOtherSessions
                    )
                },
                discardUnreadable: { tabID in
                    await agentModeVM.discardUnreadableScheduledSend(tabID: tabID)
                },
                retrySaving: { tabID in
                    await agentModeVM.retryScheduledSendSaving(tabID: tabID)
                }
            ),
            staleResetRecovery: AgentStaleResetRecoveryActions(
                reloadLatest: { tabID, recoveryID in
                    await agentModeVM.reloadLatestForStaleResetRecovery(tabID: tabID, recoveryID: recoveryID)
                },
                retryStopping: { tabID, recoveryID in
                    await agentModeVM.retryStaleResetRecoveryStop(tabID: tabID, recoveryID: recoveryID)
                }
            ),
            cancelRun: { target in _ = await agentModeVM.cancelAgentRun(target: target, cause: .userCancel) },
            attachImages: { tabID, urls in agentModeVM.attachImages(tabID: tabID, urls: urls) },
            removeImage: { tabID, attachmentID in agentModeVM.removePendingImage(tabID: tabID, attachmentID: attachmentID) },
            commitTaggedFile: { tabID, suggestion, displayName in
                agentModeVM.commitPendingTaggedFile(
                    tabID: tabID,
                    relativePath: suggestion.relativePath,
                    displayName: displayName
                )
            },
            removeTaggedFile: { tabID, attachmentID in agentModeVM.removePendingTaggedFile(tabID: tabID, attachmentID: attachmentID) },
            agentWorkspaceLookupContext: { tabID in
                guard let tabID else { return .visibleWorkspace }
                return await agentModeVM.agentWorkspaceLookupContext(tabID: tabID)
            },
            slashSkillSuggestions: { query in await agentModeVM.slashSkillSuggestions(for: query) },
            modelOptions: { agent, includeClaudeEffortVariants in
                agentModeVM.modelOptions(for: agent, includeClaudeEffortVariants: includeClaudeEffortVariants)
            },
            canSelectAgentInCurrentChat: { agent in agentModeVM.canSelectAgentInCurrentChat(agent) },
            selectAgentModel: { agent, rawModel in
                guard let sourceTabID = currentTabID else {
                    return AgentModelSelectionCommitError.sourceUnavailable.localizedDescription
                }
                do {
                    try agentModeVM.commitCurrentSessionModelSelection(
                        agent: agent,
                        rawModel: rawModel,
                        explicitCodexEffort: nil,
                        sourceTabID: sourceTabID
                    )
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            selectOhMyPiThinking: { exactModelID, value in
                guard let sourceTabID = currentTabID else { return }
                agentModeVM.commitOhMyPiThinkingSelection(
                    value,
                    exactModelID: exactModelID,
                    sourceTabID: sourceTabID
                )
            },
            selectRemoteAgentModel: { rawModel in
                agentModeVM.selectRemoteAgentModel(rawModel: rawModel)
            },
            reasoningEffortOptionsForCurrentSelection: { agentModeVM.reasoningEffortOptionsForCurrentSelection() },
            selectReasoningEffort: { effort in agentModeVM.selectReasoningEffort(effort) },
            setAutoEditEnabled: { enabled in agentModeVM.setAutoEditEnabled(enabled) },
            setProviderPermissionLevel: { id in agentModeVM.setProviderPermissionLevel(id) },
            applyCodexToolSettingMutation: { mutation in
                agentModeVM.applyCodexToolSettingMutation(mutation)
            },
            applyClaudeToolSettingMutation: { mutation in
                agentModeVM.applyClaudeToolSettingMutation(mutation)
            },
            setClaudeEffortLevel: { level in agentModeVM.setClaudeEffortLevel(level) },
            openCLIProvidersSettings: {
                NotificationCenter.default.post(
                    name: .showCLIProvidersTab,
                    object: nil,
                    userInfo: ["windowID": windowID]
                )
            },
            delegatedQuestions: AgentDelegatedQuestionBannerActions(
                openChild: { row in await agentModeVM.openDelegatedQuestionChild(row) }
            ),
            recoveryList: AgentRecoveryListActions(
                perform: { rowID, action in
                    await agentModeVM.performRecoveryListAction(rowID: rowID, action: action)
                },
                performContinuation: { rowID, action, text, warning in
                    await agentModeVM.performRecoveryListContinuation(
                        rowID: rowID,
                        action: action,
                        text: text,
                        acknowledgedWarning: warning
                    )
                },
                continuationDraft: { rowID in agentModeVM.recoveryContinuationDraft(rowID: rowID) },
                updateContinuationDraft: { rowID, text in
                    agentModeVM.updateRecoveryContinuationDraft(rowID: rowID, text: text)
                },
                retryStartup: { agentModeVM.retryRecoveryStartup() },
                openNeedsAttention: { agentModeVM.presentRecoveryNeedsAttention() },
                inspect: { rowID in await agentModeVM.inspectRecoveryEditProposal(rowID: rowID) }
            ),
            isShutdownFrozen: { agentModeVM.isShutdownFrozen }
        )
    }

    @ViewBuilder
    private var statusPills: some View {
        #if DEBUG
            let _ = AgentModePerfDiagnostics.increment("ui.body.inputBar.statusPills")
        #endif
        AgentStatusPillsRow(
            agentModeVM: agentModeVM,
            statusPillsUI: statusPillsUI,
            oracleViewModel: oracleViewModel,
            promptManager: promptManager,
            selectionCoordinator: selectionCoordinator,
            runtimeVM: runtimeVM,
            windowID: windowID
        )
        .padding(.horizontal, 28)
    }
}

enum AgentFileMentionText {
    static func attachmentDisplayName(for suggestion: MentionSuggestion) -> String {
        let trimmedPath = suggestion.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPath.isEmpty {
            return trimmedPath
        }
        return suggestion.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removingTaggedMention(
        displayName: String,
        relativePath: String,
        from text: String
    ) -> String {
        guard !text.isEmpty else { return text }
        var candidates: [String] = []
        appendNonEmpty(displayName, to: &candidates)
        appendNonEmpty(relativePath, to: &candidates)
        guard !candidates.isEmpty else { return text }

        var reduced = text
        for candidate in candidates {
            reduced = removingTaggedPath(candidate, from: reduced)
        }
        return reduced
    }

    private static func appendNonEmpty(_ value: String, to candidates: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
        candidates.append(trimmed)
    }

    private static func removingTaggedPath(_ relativePath: String, from text: String) -> String {
        guard !relativePath.isEmpty, !text.isEmpty else { return text }
        let escapedPath = escapePathForAtCommand(relativePath)
        // Consume one trailing horizontal space after the token when present.
        // `FileTagMentionHelper.commitHighlighted` inserts mentions as "@path " and without
        // consuming that space explicit chip removal would leave a visible gap.
        let pattern = "(^|\\s)@\(NSRegularExpression.escapedPattern(for: escapedPath))(?=$|\\s)[ \\t]?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        let reduced = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
        return reduced.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
    }

    private static func escapePathForAtCommand(_ path: String) -> String {
        var escaped = ""
        for character in path {
            switch character {
            case "\\", " ", ",", ";", "!", "?", "(", ")", "[", "]", "{", "}":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return escaped
    }
}

struct AgentComposerView: View, Equatable {
    let props: AgentComposerProps
    let placeholderText: String
    let actions: AgentComposerActions
    let promptManager: PromptViewModel
    let workspaceSearchService: WorkspaceSearchService
    let selectionCoordinator: WorkspaceSelectionCoordinator
    let windowID: Int
    let currentTabID: UUID?
    let composerFocusToken: UUID?

    @Binding var resetTextFieldTrigger: Bool
    @Binding var composerBottomInset: CGFloat
    @Binding var transcriptBottomClearance: CGFloat

    @FocusState var isFocused: Bool

    @State private var localInputText: String = ""
    @State private var submissionLatch = AgentComposerSubmissionLatch()
    @State private var editorTextFieldHeight: CGFloat = ResizableTextField.height(forPresetIndex: 0, preset: .normal)
    @State private var isInputEmpty: Bool = true
    @State private var chromeOcclusion: CGFloat = 0
    @State private var isSyncingDraftFromSession: Bool = false
    @State private var isImageDropTargeted: Bool = false
    @State private var showCodexToolsPopover: Bool = false
    @State private var showCursorModelParametersPopover: Bool = false
    @State private var cursorPopoverOriginTabID: UUID?
    @State private var cursorPopoverOriginAgent: AgentProviderKind?
    @State private var cursorLastSelfCommittedRaw: String?
    @State private var cursorParameterCatalogRevision: UInt = 0
    @State private var ohMyPiThinkingRevision: UInt = 0
    @State private var showPermissionPopover: Bool = false
    @State private var showClaudeToolsPopover: Bool = false
    @State private var steeringNotice = AgentComposerSubmitNotice()
    @State private var steeringUnsupportedDismissTask: Task<Void, Never>?
    @State private var modelMenuSnapshotByAgent: [AgentProviderKind: [AgentModelOption]]? = nil
    @State private var modelMenuSnapshotReleaseTask: Task<Void, Never>? = nil

    @ObservedObject private var fontScale = FontScaleManager.shared
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private let imageInputAdapter = AgentImageInputAdapter()
    private static let staleSubmitTargetMessage = "This composer changed before the message could be sent. Please try again."

    static func hasEquivalentRenderIdentity(
        lhsProps: AgentComposerProps,
        lhsPlaceholderText: String,
        lhsCurrentTabID: UUID?,
        lhsComposerFocusToken: UUID?,
        rhsProps: AgentComposerProps,
        rhsPlaceholderText: String,
        rhsCurrentTabID: UUID?,
        rhsComposerFocusToken: UUID?
    ) -> Bool {
        lhsProps == rhsProps &&
            lhsPlaceholderText == rhsPlaceholderText &&
            lhsCurrentTabID == rhsCurrentTabID &&
            lhsComposerFocusToken == rhsComposerFocusToken
    }

    static func == (lhs: AgentComposerView, rhs: AgentComposerView) -> Bool {
        hasEquivalentRenderIdentity(
            lhsProps: lhs.props,
            lhsPlaceholderText: lhs.placeholderText,
            lhsCurrentTabID: lhs.currentTabID,
            lhsComposerFocusToken: lhs.composerFocusToken,
            rhsProps: rhs.props,
            rhsPlaceholderText: rhs.placeholderText,
            rhsCurrentTabID: rhs.currentTabID,
            rhsComposerFocusToken: rhs.composerFocusToken
        )
    }

    private var hasPendingImageAttachments: Bool {
        props.attachments.hasImages
    }

    private var hasPendingTaggedFileAttachments: Bool {
        props.attachments.hasTaggedFiles
    }

    private var hasPendingAttachments: Bool {
        hasPendingImageAttachments || hasPendingTaggedFileAttachments
    }

    private var isCodexRunActive: Bool {
        props.isCodexRunActive
    }

    private var canUseLinkedAgentSession: Bool {
        props.canUseLinkedAgentSession
    }

    private var canAttachImages: Bool {
        !props.isAgentBusy && currentTabID != nil
    }

    private var renderedSubmitTarget: AgentComposerSubmitTarget? {
        guard let target = props.submitTarget,
              target.tabID == props.currentTabID,
              target.tabID == currentTabID
        else { return nil }
        return target
    }

    private var canSubmitToRenderedTarget: Bool {
        props.canSendWithCurrentProvider
            && renderedSubmitTarget != nil
            && !submissionLatch.isLatched(for: currentTabID)
    }

    private var renderedScheduledSend: AgentScheduledSendProps? {
        guard let scheduledSend = props.scheduledSend,
              scheduledSend.tabID == props.currentTabID,
              scheduledSend.tabID == currentTabID
        else { return nil }
        return scheduledSend
    }

    private var renderedDelegatedQuestions: [AgentDelegatedQuestionBannerRow] {
        guard props.currentTabID == currentTabID, actions.delegatedQuestions != nil else { return [] }
        return props.delegatedQuestions
    }

    private var renderedRecoveryList: AgentRecoveryListProps? {
        guard actions.recoveryList != nil, props.currentTabID == currentTabID else { return nil }
        return props.recoveryList
    }

    private var recoveryListBannerReservedHeight: CGFloat {
        guard let list = renderedRecoveryList else { return 0 }
        return AgentRecoveryListBanner.reservedHeight(for: list) + AgentAttachmentStripLayout.composerVerticalSpacingWhenPresent
    }

    private var renderedStaleResetRecovery: AgentStaleResetRecoveryProps? {
        guard let recovery = props.staleResetRecovery,
              recovery.tabID == props.currentTabID,
              recovery.tabID == currentTabID
        else { return nil }
        return recovery
    }

    private var hasSchedulableContent: Bool {
        !localInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasPendingAttachments
    }

    private var canScheduleToRenderedTarget: Bool {
        props.canSchedule
            && renderedScheduledSend == nil
            && hasSchedulableContent
            && props.canSendWithCurrentProvider
            && renderedSubmitTarget != nil
            && !submissionLatch.isLatched(for: currentTabID)
    }

    private var isNewSessionScheduleTarget: Bool {
        props.scheduleTargetIsNewSessionStart
    }

    private var localInputTextBinding: Binding<String> {
        Binding(
            get: { localInputText },
            set: { setLocalInputText($0) }
        )
    }

    private var isCurrentTabMCPControlled: Bool {
        props.isCurrentTabMCPControlled
    }

    private var modelControlsDisabled: Bool {
        props.areModelControlsDisabled
    }

    private var modelControlsDisabledTooltip: String {
        "Model and effort controls are locked while this session is controlled by an MCP agent."
    }

    private var permissionBinding: AgentPermissionChromeBinding? {
        props.providerControls?.permission
    }

    private var permissionControlsDisabled: Bool {
        permissionBinding?.externallyManagedReason != nil
    }

    private var steeringUnsupportedMessage: String? {
        steeringNotice.message
    }

    private var hasSteeringUnsupportedNotice: Bool {
        guard let message = steeringUnsupportedMessage else { return false }
        return !message.isEmpty
    }

    private var steeringUnsupportedInfoBoxHeight: CGFloat {
        fontPreset.scaledClamped(48, min: 48, max: 62)
    }

    private var steeringUnsupportedInfoBoxReservedHeight: CGFloat {
        guard hasSteeringUnsupportedNotice else { return 0 }
        return steeringUnsupportedInfoBoxHeight + AgentAttachmentStripLayout.composerVerticalSpacingWhenPresent
    }

    private var scheduledSendBannerReservedHeight: CGFloat {
        guard renderedScheduledSend != nil else { return 0 }
        return 48 + AgentAttachmentStripLayout.composerVerticalSpacingWhenPresent
    }

    private var staleResetRecoveryBannerReservedHeight: CGFloat {
        guard renderedStaleResetRecovery != nil else { return 0 }
        return 48 + AgentAttachmentStripLayout.composerVerticalSpacingWhenPresent
    }

    private var delegatedQuestionsBannerReservedHeight: CGFloat {
        let rowCount = renderedDelegatedQuestions.count
        guard rowCount > 0 else { return 0 }
        return AgentDelegatedQuestionsBanner.reservedHeight(rowCount: rowCount)
            + AgentAttachmentStripLayout.composerVerticalSpacingWhenPresent
    }

    private var mainContentHeight: CGFloat {
        editorTextFieldHeight + AgentAttachmentStripLayout.reservedHeight(
            hasImages: hasPendingImageAttachments,
            hasTaggedFiles: hasPendingTaggedFileAttachments
        ) + steeringUnsupportedInfoBoxReservedHeight + scheduledSendBannerReservedHeight
            + staleResetRecoveryBannerReservedHeight + delegatedQuestionsBannerReservedHeight
            + recoveryListBannerReservedHeight
    }

    private var composerChromeVerticalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 8)
    }

    private var composerChromeInnerSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 2)
    }

    private var composerControlStripHeight: CGFloat {
        fontPreset.scaledClamped(40, min: 40, max: 44)
    }

    /// Height of the footer spacing below the composer chrome
    static let footerHeight: CGFloat = 28
    /// Extra transcript clearance needed so the overlaid status pills don't cover
    /// the in-transcript running indicator when we restore/scroll to the bottom.
    /// The pills sit 8pt into the transcript area and are 28pt tall, so we need
    /// 20pt beyond the composer's own occlusion to keep the spinner fully visible.
    private static let transcriptBottomExtraPadding: CGFloat = 20

    /// Agent mode uses ComposerChrome's upward counter-shift behavior.
    /// Chrome occlusion includes that half-shift, which can over-push transcript/pills.
    /// Subtract half of total main-content growth so overlays track the composer's
    /// visual top consistently whether growth comes from text or attachments.
    private var adjustedOcclusion: CGFloat {
        let baseHeight = ResizableTextField.height(forPresetIndex: 0, preset: fontPreset)
        let growth = max(0, mainContentHeight - baseHeight)
        return max(0, chromeOcclusion - (growth * 0.5)).rounded(.up)
    }

    /// Single transcript-facing bottom clearance contract consumed by AgentModeView.
    /// Keeps the composer growth math local to the input bar while preserving a small
    /// extra cushion above the overlaid status pills.
    private var currentTranscriptBottomClearance: CGFloat {
        max(0, adjustedOcclusion + Self.transcriptBottomExtraPadding).rounded(.up)
    }

    private func syncTranscriptGeometry() {
        assignGeometryValue(adjustedOcclusion, to: $composerBottomInset)
        assignGeometryValue(currentTranscriptBottomClearance, to: $transcriptBottomClearance)
    }

    private func assignGeometryValue(_ newValue: CGFloat, to binding: Binding<CGFloat>) {
        guard abs(binding.wrappedValue - newValue) >= 0.5 else { return }
        binding.wrappedValue = newValue
    }

    var body: some View {
        #if DEBUG
            let _ = AgentModePerfDiagnostics.increment("ui.body.composer")
        #endif
        VStack(spacing: 0) {
            ComposerChrome(
                bottomOcclusion: $chromeOcclusion,
                mainContentHeight: mainContentHeight,
                highlightColor: isCurrentTabMCPControlled ? .orange : nil,
                bubbleVerticalPaddingOverride: composerChromeVerticalPadding,
                bubbleInnerSpacingOverride: composerChromeInnerSpacing,
                controlStripHeightOverride: composerControlStripHeight,
                main: { mainContent },
                strip: { controlStrip }
            )

            // Bottom spacing to keep bar off the very bottom
            Spacer()
                .frame(height: Self.footerHeight)
        }
        .onChange(of: chromeOcclusion) { _, _ in
            // Bubble overlap above the base bar (used to offset transcript and overlays).
            syncTranscriptGeometry()
        }
        .onChange(of: mainContentHeight) { _, _ in
            // Keep in sync when composer growth compensation changes.
            syncTranscriptGeometry()
        }
        .onAppear {
            // Initialize transcript clearance from the current composer geometry.
            syncTranscriptGeometry()
        }
        .onAppear {
            // Restore draft if we have one stored
            if let tabID = currentTabID {
                loadDraftFromSession(for: tabID)
            }
        }
        .onDisappear {
            // Store draft when leaving
            if let tabID = currentTabID {
                actions.storeDraft(tabID, localInputText)
            }
            steeringUnsupportedDismissTask?.cancel()
            steeringUnsupportedDismissTask = nil
            modelMenuSnapshotReleaseTask?.cancel()
            modelMenuSnapshotReleaseTask = nil
            modelMenuSnapshotByAgent = nil
            dismissCursorModelParametersPopover()
        }
        .onChange(of: currentTabID) { oldTabID, newTabID in
            // Switch drafts when tab changes
            if let oldTabID {
                actions.storeDraft(oldTabID, localInputText)
            }
            if let newTabID {
                loadDraftFromSession(for: newTabID)
            }
            // Review A LIST-01: a persistent refusal belongs to the previous tab's send, also when
            // the new tab's draft is identical (no text change fires).
            clearPersistentSteeringNotice()
            dismissCursorModelParametersPopover()
        }
        .onChange(of: props.selectedAgent) { _, selectedAgent in
            if selectedAgent != .cursor {
                dismissCursorModelParametersPopover()
            }
        }
        .onChange(of: modelControlsDisabled) { _, isDisabled in
            if isDisabled {
                dismissCursorModelParametersPopover()
            }
        }
        .onChange(of: props.selectedModelRaw) { _, selectedModelRaw in
            guard showCursorModelParametersPopover else { return }
            if selectedModelRaw != cursorLastSelfCommittedRaw {
                dismissCursorModelParametersPopover()
            }
        }
        .onChange(of: cursorParameterPickerIsAvailable) { _, isAvailable in
            if !isAvailable {
                dismissCursorModelParametersPopover()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .cursorModelParameterCatalogDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            cursorParameterCatalogRevision &+= 1
            if !cursorParameterPickerIsAvailable {
                dismissCursorModelParametersPopover()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .ohMyPiThinkingCapabilitiesDidChange)
                .merge(with: NotificationCenter.default.publisher(for: .ohMyPiThinkingCapabilityProbeStateDidChange))
                .receive(on: DispatchQueue.main)
        ) { _ in
            ohMyPiThinkingRevision &+= 1
        }
        .onChange(of: showCursorModelParametersPopover) { _, isPresented in
            if !isPresented {
                clearCursorModelParametersPopoverIdentity()
            }
        }
        .onChange(of: localInputText) { _, newValue in
            isInputEmpty = newValue.isEmpty
            clearPersistentSteeringNotice()
            guard let tabID = currentTabID, !isSyncingDraftFromSession else { return }
            actions.storeDraft(tabID, newValue)
        }
        .onChange(of: props.draftRestorationEvent) { _, event in
            guard let event, event.tabID == currentTabID else { return }
            isSyncingDraftFromSession = true
            let restoredText: String
            switch event.strategy {
            case .replaceIfEmpty:
                let trimmed = localInputText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty else {
                    isSyncingDraftFromSession = false
                    return
                }
                restoredText = event.text
            case .prependAlways:
                let existing = localInputText.trimmingCharacters(in: .whitespacesAndNewlines)
                if existing.isEmpty {
                    restoredText = event.text
                } else {
                    restoredText = event.text + "\n" + existing
                }
            case let .appendAfterBlankLine(result):
                guard let update = AgentModeViewModel.recoveryComposerAppendUpdate(live: localInputText, result: result) else {
                    isSyncingDraftFromSession = false
                    if !event.message.isEmpty {
                        showSteeringUnsupportedNotice(event.message)
                    }
                    return
                }
                restoredText = update
            }
            setLocalInputText(restoredText, forceRevision: true)
            actions.storeDraft(event.tabID, restoredText)
            DispatchQueue.main.async {
                isSyncingDraftFromSession = false
            }
            if !event.message.isEmpty {
                showSteeringUnsupportedNotice(event.message)
            }
        }
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isImageDropTargeted, perform: handleImageDrop(providers:))
        .overlay(imageDropOutline)
    }

    // MARK: - Transient Submit Guidance

    @ViewBuilder
    private var steeringUnsupportedInfoBox: some View {
        if let message = steeringUnsupportedMessage, !message.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                    .padding(.top, 1)
                Text(message)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: steeringUnsupportedInfoBoxHeight, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Main Content (ResizableTextField)

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: AgentAttachmentStripLayout.composerVerticalSpacingWhenPresent) {
            if let recoveryList = renderedRecoveryList, let recoveryListActions = actions.recoveryList {
                AgentRecoveryListBanner(props: recoveryList, actions: recoveryListActions)
            }

            if let staleResetRecovery = renderedStaleResetRecovery {
                AgentStaleResetRecoveryBanner(
                    props: staleResetRecovery,
                    actions: actions.staleResetRecovery
                )
            }

            if let scheduledSend = renderedScheduledSend {
                AgentScheduledSendBanner(
                    props: scheduledSend,
                    actions: actions.scheduledSend
                )
            }

            if let delegatedQuestionActions = actions.delegatedQuestions, !renderedDelegatedQuestions.isEmpty {
                AgentDelegatedQuestionsBanner(
                    rows: renderedDelegatedQuestions,
                    actions: delegatedQuestionActions
                )
            }

            if hasSteeringUnsupportedNotice {
                steeringUnsupportedInfoBox
            }

            if hasPendingAttachments {
                AgentAttachmentsStrip(
                    snapshot: props.attachments,
                    allowsRemoval: true,
                    onRemoveImage: removeImageAttachment,
                    onRemoveTaggedFile: removeTaggedFileAttachment
                )
                .equatable()
            }

            ResizableTextField(
                text: localInputTextBinding,
                placeholder: placeholderText,
                onReturn: sendMessage,
                resetTrigger: $resetTextFieldTrigger,
                onImagePaste: handleImagePaste(pasteboard:),
                features: .agentInputBar(
                    fileTagStore: promptManager.fileManager.workspaceFileContextStore,
                    fileTagSearchService: workspaceSearchService,
                    fileTagSelectionCoordinator: selectionCoordinator,
                    fileTagLookupContextIdentity: AnyHashable(props.fileTagLookupContextIdentity),
                    fileTagLookupContextProvider: { [tabID = props.currentTabID] in
                        await actions.agentWorkspaceLookupContext(tabID)
                    },
                    fileMentionPickerConfiguration: globalSettings.fileMentionPickerConfiguration(),
                    onFileTagCommitted: handleFileTagCommitted(_:),
                    slashSkillSuggestionsProvider: { query in
                        await actions.slashSkillSuggestions(query)
                    },
                    snippetPaletteItemsProvider: { [promptManager] in
                        promptManager.storedPrompts.map { prompt in
                            SnippetPaletteItem(
                                id: prompt.id,
                                title: prompt.title,
                                content: prompt.content
                            )
                        }
                    },
                    snippetPaletteScope: currentTabID.map {
                        SnippetPaletteScope(windowID: windowID, tabID: $0)
                    },
                    composerFocusToken: composerFocusToken,
                    acceptsEdits: { [actions] in !actions.isShutdownFrozen() }
                ),
                onHeightChange: { newHeight in
                    editorTextFieldHeight = newHeight
                }
            )
            .frame(height: editorTextFieldHeight)
            .focused($isFocused)
            .overlay(
                Text(placeholderText)
                    .font(fontPreset.standardFont)
                    .foregroundColor(.secondary)
                    .opacity(isInputEmpty ? 1 : 0)
                    .padding(.leading, 5)
                    .padding(.top, 8)
                    .allowsHitTesting(false),
                alignment: .topLeading
            )
        }
    }

    // MARK: - Control Strip

    private var controlStrip: some View {
        HStack(spacing: 0) {
            // Left side: Combined provider/model + effort + tool/permission controls.
            // Keep this horizontally scrollable so lower-priority chips do not get clipped
            // out of view in narrower windows.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if isCurrentTabMCPControlled {
                        mcpControlChip
                    }
                    if props.hasAvailableAgentProviders {
                        agentProviderModelPicker
                        cursorModelParameterLauncher
                        remoteReasoningEffortPicker
                        reasoningEffortPicker
                        claudeEffortPicker
                        codexToolsButton
                        claudeToolsButton
                    } else {
                        connectAgentProvidersButton
                    }
                    approvalPopoverChip
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transaction { transaction in
                transaction.animation = nil
            }

            // Right side: Attach + Context indicator + Send/Cancel button
            HStack(spacing: 8) {
                Button(action: pickImages) {
                    Image(systemName: "photo.badge.plus")
                        .foregroundColor(canAttachImages ? .secondary : .gray)
                        .font(.system(size: 16))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(!canAttachImages)
                .hoverTooltip("Attach Images")
                .transaction { transaction in
                    transaction.animation = nil
                }

                HStack(spacing: props.cancelTarget == nil ? 0 : 8) {
                    if let cancelTarget = props.cancelTarget {
                        CancelButton(action: { cancelRun(cancelTarget) })
                    } else {
                        SendOrResendButton(
                            inputText: localInputText,
                            hasMessages: false, // Disable resend in agent mode - just show greyed send button
                            sendWhenEmpty: hasPendingAttachments,
                            sendTooltip: "Send Message",
                            foregroundColor: .accentColor,
                            sendAction: sendMessage,
                            resendAction: {}
                        )
                        .disabled(!canSubmitToRenderedTarget)

                        Divider()
                            .frame(height: 24)
                    }

                    ScheduleSendMenuButton(
                        isEnabled: canScheduleToRenderedTarget,
                        isNewSessionStart: isNewSessionScheduleTarget,
                        hasExistingScheduledSend: renderedScheduledSend != nil,
                        isDetached: props.cancelTarget != nil,
                        onSchedule: { notBefore, runAlongsideOtherSessions in
                            scheduleMessage(
                                notBefore: notBefore,
                                runAlongsideOtherSessions: runAlongsideOtherSessions
                            )
                        }
                    )
                }
                .background {
                    if props.cancelTarget == nil {
                        Capsule()
                            .fill(Color.secondary.opacity(0.035))
                    }
                }
                .overlay {
                    if props.cancelTarget == nil {
                        Capsule()
                            .stroke(Color.secondary.opacity(0.1), lineWidth: 0.5)
                    }
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: composerControlStripHeight)
    }

    // MARK: - MCP Control Chip

    private var mcpControlChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "server.rack")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                .foregroundColor(.orange)
            Text("MCP")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundColor(.orange)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.10))
        .cornerRadius(4)
        .hoverTooltip("This session is controlled by an MCP agent")
    }

    // MARK: - Agent Pickers

    private enum LayoutMetrics {
        static let providerChipMaxWidth: CGFloat = 250
        static let permissionChipMaxWidth: CGFloat = 120
    }

    private var providerChipMaxWidth: CGFloat {
        fontPreset.scaledClamped(LayoutMetrics.providerChipMaxWidth, max: 340)
    }

    private var approvalPopoverWidth: CGFloat {
        fontPreset.scaledClamped(280, max: 380)
    }

    private var codexToolsPopoverWidth: CGFloat {
        fontPreset.scaledClamped(300, max: 400)
    }

    private var cursorParametersPopoverWidth: CGFloat {
        fontPreset.scaledClamped(340, max: 440)
    }

    private var claudeToolsPopoverWidth: CGFloat {
        fontPreset.scaledClamped(280, max: 380)
    }

    private var pickerChipColor: Color {
        Color.secondary.opacity(0.1)
    }

    private var providerChipTitle: String {
        let modelDisplayName = inputBarSelectedModelDisplayName
        let truncatedModelName = String.truncateModelName(
            modelDisplayName,
            maxLength: 24
        )
        if let remoteCatalog = props.remoteHostCatalog {
            let remoteTitle = remoteCatalog.chipTitle(forModelID: props.selectedModelRaw)
            return String.truncateModelName(remoteTitle, maxLength: 30)
        }
        return "\(props.selectedAgent.displayName) · \(truncatedModelName)"
    }

    private var selectedModelShowsFastWarning: Bool {
        guard props.remoteHostCatalog == nil else { return false }
        return AgentModelSelectionWarningVisuals.showsWarning(
            agent: props.selectedAgent,
            rawModel: props.selectedModelRaw
        )
    }

    private func providerChipTooltip(isLocked: Bool, lockedMessage: String?) -> String {
        let baseTooltip: String = if modelControlsDisabled {
            modelControlsDisabledTooltip
        } else if isLocked {
            lockedMessage ?? "This chat is limited to this agent family."
        } else {
            "Choose agent and model"
        }
        guard selectedModelShowsFastWarning else { return baseTooltip }
        return "\(baseTooltip)\n\(AgentModelSelectionWarningVisuals.warningTooltip(for: props.selectedAgent))"
    }

    private var inputBarSelectedModelDisplayName: String {
        CursorModelProviderChipDisplay.name(
            rawModel: props.selectedModelRaw,
            fallbackDisplayName: props.selectedModelDisplayName,
            parameterLauncherAvailable: cursorParameterPickerIsAvailable
        )
    }

    private var connectAgentProvidersButton: some View {
        Button(action: openCLIProvidersSettings) {
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                Text("Connect CLI Providers")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.10))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .hoverTooltip("Open Settings to connect Claude Code, Codex, OpenCode, or Cursor for Agent Mode")
        .fixedSize(horizontal: true, vertical: false)
    }

    private func openCLIProvidersSettings() {
        actions.openCLIProvidersSettings()
    }

    @ViewBuilder
    private var agentProviderModelPicker: some View {
        let isLocked = props.isProviderPickerLockedForCurrentTab
        let lockedMessage = props.lockedAgentSelectionMessage
        StableMenuButton(
            items: agentProviderModelMenuItems,
            triggerStyle: .plain,
            onOpen: captureModelMenuSnapshot
        ) {
            HStack(spacing: 4) {
                Image(systemName: providerChipIconName)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                if selectedModelShowsFastWarning {
                    Image(systemName: AgentModelSelectionWarningVisuals.iconSystemName)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                        .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
                }
                Text(providerChipTitle)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 9))
                }
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: providerChipMaxWidth, alignment: .leading)
            .foregroundColor(selectedModelShowsFastWarning ? .orange : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .disabled(modelControlsDisabled)
        .opacity(modelControlsDisabled ? 0.55 : 1.0)
        .hoverTooltip(providerChipTooltip(isLocked: isLocked, lockedMessage: lockedMessage))
        .frame(maxWidth: providerChipMaxWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var providerChipIconName: String {
        if props.remoteHostCatalog != nil {
            return RemoteHostAgentCatalog.agentKind(forModelID: props.selectedModelRaw)?.iconName ?? "network"
        }
        return props.selectedAgent.iconName
    }

    private func agentProviderModelMenuItems() -> [StableMenuItem] {
        if let remoteCatalog = props.remoteHostCatalog {
            return remoteHostModelMenuItems(remoteCatalog)
        }
        var items: [StableMenuItem] = []
        if let lockedMessage = props.lockedAgentSelectionMessage {
            items.append(.message(lockedMessage))
            items.append(.separator)
        }

        items.append(.header("Model"))
        for agent in props.availableAgents {
            let canSelectAgent = actions.canSelectAgentInCurrentChat(agent)
            if canSelectAgent {
                if agent == .ohMyPi {
                    items.append(.lazySubmenu(
                        agent.displayName,
                        onOpen: {
                            let options = inputBarModelOptions(for: .ohMyPi)
                            OhMyPiThinkingSweepTrigger.onProviderSubmenuOpen(
                                wireIDs: options.map(\.rawValue),
                                selectedRawModel: props.selectedAgent == .ohMyPi
                                    ? props.selectedModelRaw
                                    : nil,
                                workspacePath: nil
                            )
                        },
                        items: {
                            inputBarModelMenuItems(for: .ohMyPi)
                        }
                    ))
                } else {
                    let modelItems = inputBarModelMenuItems(for: agent)
                    items.append(.submenu(agent.displayName, items: modelItems))
                }
            } else {
                items.append(.action(
                    agent.displayName,
                    isEnabled: false,
                    imageSystemName: "lock.fill"
                ) {})
            }
        }
        AgentProviderSettingsMenuAction.appendStableMenuItem(
            to: &items,
            windowID: windowID,
            availableAgents: props.availableAgents
        )
        return items
    }

    private func remoteHostModelMenuItems(_ catalog: RemoteHostAgentCatalog) -> [StableMenuItem] {
        var items: [StableMenuItem] = []
        if let hostName = props.runLocationHostDisplayName {
            items.append(.header("Model on \(hostName)"))
        } else {
            items.append(.header("Remote model"))
        }
        items.append(remoteHostModelMenuItem(
            title: RemoteHostAgentCatalog.hostDefaultDisplayName,
            rawModel: RemoteHostAgentCatalog.hostDefaultModelID,
            imageSystemName: "network"
        ))
        let structuredGroups = catalog.structuredAgentGroups
        if !structuredGroups.isEmpty {
            items.append(.separator)
            for agent in structuredGroups {
                let modelItems = agent.models.compactMap { modelGroup in
                    remoteHostBaseModelMenuItem(
                        modelGroup,
                        imageSystemName: agent.agentKind?.iconName
                    )
                }
                guard !modelItems.isEmpty else { continue }
                items.append(.submenu(agent.name, items: modelItems))
            }
        } else {
            let selectableAgents = catalog.selectableAgents
            if !selectableAgents.isEmpty {
                items.append(.separator)
                for agent in selectableAgents {
                    let modelItems = agent.models.map { model in
                        remoteHostModelMenuItem(
                            title: model.name,
                            rawModel: model.modelID,
                            imageSystemName: RemoteHostAgentCatalog.agentKind(forModelID: model.modelID)?.iconName
                        )
                    }
                    items.append(.submenu(agent.name, items: modelItems))
                }
            }
        }
        if catalog.selectableAgents.isEmpty, catalog.isDegraded {
            items.append(.message("Using the host default because this host did not expose a model catalog."))
        }
        return items
    }

    private func remoteHostModelMenuItem(
        title: String,
        rawModel: String,
        imageSystemName: String?
    ) -> StableMenuItem {
        StableMenuItem.action(
            title,
            isEnabled: true,
            isSelected: props.selectedModelRaw == rawModel,
            imageSystemName: imageSystemName
        ) {
            actions.selectRemoteAgentModel(rawModel)
        }
    }

    private func remoteHostBaseModelMenuItem(
        _ modelGroup: RemoteHostBaseModelGroup,
        imageSystemName: String?
    ) -> StableMenuItem? {
        guard let rawModel = modelGroup.preferredModelID else { return nil }
        return StableMenuItem.action(
            modelGroup.displayName,
            isEnabled: true,
            isSelected: modelGroup.containsModelID(props.selectedModelRaw),
            imageSystemName: imageSystemName
        ) {
            actions.selectRemoteAgentModel(rawModel)
        }
    }

    private func inputBarModelMenuItems(for agent: AgentProviderKind) -> [StableMenuItem] {
        _ = ohMyPiThinkingRevision
        let options = inputBarModelOptions(for: agent)
        if agent == .cursor {
            return AgentModelStableMenuItems.cursorModelItems(
                options: options,
                selectedAgent: props.selectedAgent,
                selectedModelRaw: props.selectedModelRaw
            ) { selectedAgent, model in
                if let message = actions.selectAgentModel(selectedAgent, model.rawValue) {
                    showSteeringUnsupportedNotice(message)
                }
            }
        }
        if agent == .ohMyPi {
            let onSelect: (AgentProviderKind, AgentModelOption) -> Bool = { selectedAgent, model in
                if let message = actions.selectAgentModel(selectedAgent, model.rawValue) {
                    showSteeringUnsupportedNotice(message)
                    return false
                }
                OhMyPiThinkingSelectionProbeTrigger.afterExplicitSelection(
                    agent: selectedAgent,
                    rawModel: model.rawValue
                )
                return true
            }
            if let currentTabID {
                return AgentModelStableMenuItems.ohMyPiModelItems(
                    options: options,
                    selectedAgent: props.selectedAgent,
                    selectedModelRaw: props.selectedModelRaw,
                    thinkingDestinationForModel: { exactModelID in
                        inputBarOhMyPiThinkingDestination(
                            tabID: currentTabID,
                            exactModelID: exactModelID
                        )
                    },
                    onSelect: onSelect
                )
            }
            return AgentModelStableMenuItems.ohMyPiModelItems(
                options: options,
                selectedAgent: props.selectedAgent,
                selectedModelRaw: props.selectedModelRaw
            ) { selectedAgent, model in
                _ = onSelect(selectedAgent, model)
            }
        }
        guard agent == .openCode else {
            return options.map { inputBarModelMenuItem(agent: agent, model: $0) }
        }
        return AgentModelCatalog.openCodeMenu(for: options).providerGroups.flatMap { providerGroup -> [StableMenuItem] in
            let modelItems = providerGroup.groups.map { inputBarOpenCodeModelMenuItem(agent: agent, group: $0) }
            guard providerGroup.rendersAsSubmenu else { return modelItems }
            return [.submenu(providerGroup.displayName, items: modelItems)]
        }
    }

    private func inputBarOpenCodeModelMenuItem(agent: AgentProviderKind, group: AgentModelCatalog.OpenCodeMenuGroup) -> StableMenuItem {
        if group.rendersAsSubmenu {
            return StableMenuItem.submenu(
                group.modelDisplayName,
                items: group.options.map { menuOption in
                    inputBarModelMenuItem(agent: agent, model: menuOption.option, title: menuOption.displayName)
                }
            )
        }
        if let menuOption = group.options.first {
            return inputBarModelMenuItem(agent: agent, model: menuOption.option, title: menuOption.displayName)
        }
        return .separator
    }

    private func inputBarModelMenuItem(agent: AgentProviderKind, model: AgentModelOption, title: String? = nil) -> StableMenuItem {
        let isSelected = props.selectedAgent == agent && AgentModelCatalog.modelOptionIsSelected(
            optionRaw: model.rawValue,
            selectedRaw: props.selectedModelRaw,
            agentKind: agent
        )
        return StableMenuItem.action(
            title ?? model.displayName,
            isEnabled: true,
            isSelected: isSelected,
            imageSystemName: AgentModelSelectionWarningVisuals.stableMenuImageSystemName(agent: agent, rawModel: model.rawValue),
            style: AgentModelSelectionWarningVisuals.stableMenuStyle(agent: agent, rawModel: model.rawValue)
        ) {
            if let message = actions.selectAgentModel(agent, model.rawValue) {
                showSteeringUnsupportedNotice(message)
            }
        }
    }

    private func inputBarOhMyPiThinkingDestination(
        tabID: UUID,
        exactModelID: String
    ) -> ModelDestination {
        ModelDestination(
            id: "agentInputBar.\(tabID.uuidString).\(exactModelID)",
            getter: { exactModelID },
            applier: { _ in },
            thinkingGetter: { props.ohMyPiThinkingSelections },
            thinkingApplier: { selections in
                actions.selectOhMyPiThinking(exactModelID, selections.value(for: exactModelID))
            }
        )
    }

    private func inputBarModelOptions(for agent: AgentProviderKind) -> [AgentModelOption] {
        let sourceOptions: [AgentModelOption]
        let includeClaudeEffortVariants = !agent.usesClaudeTooling
        if let snapshot = modelMenuSnapshotByAgent?[agent] {
            sourceOptions = snapshot
        } else {
            sourceOptions = actions.modelOptions(agent, includeClaudeEffortVariants)
        }
        let filtered = sourceOptions.filter { !$0.isPlaceholderDefault }
        return filtered.isEmpty ? sourceOptions : filtered
    }

    @MainActor
    private func captureModelMenuSnapshot() {
        guard props.remoteHostCatalog == nil else { return }
        modelMenuSnapshotReleaseTask?.cancel()
        var snapshot: [AgentProviderKind: [AgentModelOption]] = [:]
        for agent in props.availableAgents {
            snapshot[agent] = actions.modelOptions(agent, !agent.usesClaudeTooling)
        }
        modelMenuSnapshotByAgent = snapshot
        modelMenuSnapshotReleaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            modelMenuSnapshotByAgent = nil
            modelMenuSnapshotReleaseTask = nil
        }
    }

    private var cursorParameterPickerIsAvailable: Bool {
        cursorModelParameterPicker(selectedModelRaw: props.selectedModelRaw) != nil
    }

    private func cursorModelParameterPicker(
        selectedModelRaw: String
    ) -> CursorModelParameterPickerViewModel? {
        guard props.remoteHostCatalog == nil, props.selectedAgent == .cursor else {
            return nil
        }
        _ = cursorParameterCatalogRevision
        return CursorModelParameterPickerViewModel(
            modelRaw: selectedModelRaw,
            selectedModelRaw: selectedModelRaw,
            specs: CursorModelParameterCatalog.shared.parameterSpecs(forModel: selectedModelRaw),
            isEnabled: CursorParameterizedModels.isEnabled
        )
    }

    private var cursorPopoverPicker: CursorModelParameterPickerViewModel? {
        cursorModelParameterPicker(
            selectedModelRaw: cursorLastSelfCommittedRaw ?? props.selectedModelRaw
        )
    }

    @ViewBuilder
    private var cursorModelParameterLauncher: some View {
        if let picker = cursorModelParameterPicker(selectedModelRaw: props.selectedModelRaw) {
            let showsWarning = picker.summaryShowsFastWarning
            Button {
                presentCursorModelParametersPopover()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    if showsWarning {
                        Image(systemName: AgentModelSelectionWarningVisuals.iconSystemName)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                    }
                    Text(picker.summaryLabel)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .semibold))
                }
                .foregroundColor(showsWarning ? .orange : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(pickerChipColor)
                .cornerRadius(4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(modelControlsDisabled)
            .opacity(modelControlsDisabled ? 0.55 : 1.0)
            .hoverTooltip(
                modelControlsDisabled
                    ? modelControlsDisabledTooltip
                    : picker.detailTooltip
            )
            .popover(isPresented: $showCursorModelParametersPopover, arrowEdge: .bottom) {
                cursorModelParametersPopoverContent
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var cursorModelParametersPopoverContent: some View {
        if let picker = cursorPopoverPicker {
            Form {
                switch picker.selectionState {
                case .inheritedBareBase:
                    Section {
                        cursorParameterNotice(
                            "Inherited from Cursor's global settings. Choosing an option will enforce a complete model configuration."
                        )
                    }
                case .partialOrUnsupportedBracket:
                    Section {
                        cursorParameterNotice(
                            "This selection has missing, invalid, or unsupported settings. Valid values are preserved; missing values use catalog defaults."
                        )
                    }
                case .notSelected, .fullyEnforced:
                    EmptyView()
                }

                ForEach(picker.parameters, id: \.id) { parameter in
                    Section {
                        cursorParameterControl(parameter, picker: picker)
                        if let description = parameter.description {
                            Text(description)
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                                .foregroundStyle(
                                    cursorParameterIsFastEnabled(parameter, picker: picker)
                                        ? Color.orange
                                        : Color.secondary
                                )
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        Text(parameter.label)
                    }
                }

                Section {
                    Button("Reset to Default Settings") {
                        commitCursorModelParameterSelection(picker.defaultSelectionRaw())
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: cursorParametersPopoverWidth)
        } else {
            Text("Cursor model settings are unavailable.")
                .font(fontPreset.captionFont)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(width: cursorParametersPopoverWidth)
        }
    }

    @ViewBuilder
    private func cursorParameterControl(
        _ parameter: CursorModelParameterPickerViewModel.Parameter,
        picker: CursorModelParameterPickerViewModel
    ) -> some View {
        if CursorModelParameterPickerViewModel.isFastParameter(parameter.id),
           let onOption = parameter.options.first(where: {
               $0.value.caseInsensitiveCompare("true") == .orderedSame
           }),
           let offOption = parameter.options.first(where: {
               $0.value.caseInsensitiveCompare("false") == .orderedSame
           })
        {
            let isOn = cursorParameterIsFastEnabled(parameter, picker: picker)
            Toggle(isOn: Binding(
                get: { isOn },
                set: { enabled in
                    commitCursorModelParameterSelection(
                        picker.selectionRaw(
                            setting: parameter.id,
                            to: enabled ? onOption.value : offOption.value
                        )
                    )
                }
            )) {
                HStack(spacing: 5) {
                    Text(isOn ? onOption.displayName : offOption.displayName)
                    if isOn {
                        Image(systemName: AgentModelSelectionWarningVisuals.iconSystemName)
                            .foregroundStyle(Color.orange)
                    }
                }
                .foregroundStyle(isOn ? Color.orange : Color.primary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        } else {
            Picker(
                "Value",
                selection: Binding(
                    get: { picker.value(for: parameter.id) ?? parameter.defaultValue },
                    set: { value in
                        commitCursorModelParameterSelection(
                            picker.selectionRaw(setting: parameter.id, to: value)
                        )
                    }
                )
            ) {
                ForEach(parameter.options, id: \.value) { option in
                    Text(option.displayName).tag(option.value)
                }
            }
            .labelsHidden()
        }
    }

    private func cursorParameterNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(message)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cursorParameterIsFastEnabled(
        _ parameter: CursorModelParameterPickerViewModel.Parameter,
        picker: CursorModelParameterPickerViewModel
    ) -> Bool {
        CursorModelParameterPickerViewModel.isFastParameter(parameter.id)
            && picker.value(for: parameter.id)?.caseInsensitiveCompare("true") == .orderedSame
    }

    private func presentCursorModelParametersPopover() {
        guard !modelControlsDisabled,
              cursorModelParameterPicker(selectedModelRaw: props.selectedModelRaw) != nil
        else {
            return
        }
        cursorPopoverOriginTabID = currentTabID
        cursorPopoverOriginAgent = props.selectedAgent
        cursorLastSelfCommittedRaw = props.selectedModelRaw
        showCursorModelParametersPopover = true
    }

    private func commitCursorModelParameterSelection(_ selectionRaw: String?) {
        guard let selectionRaw,
              showCursorModelParametersPopover,
              !modelControlsDisabled,
              currentTabID == cursorPopoverOriginTabID,
              props.selectedAgent == .cursor,
              props.selectedAgent == cursorPopoverOriginAgent
        else {
            return
        }
        cursorLastSelfCommittedRaw = selectionRaw
        if let message = actions.selectAgentModel(.cursor, selectionRaw) {
            cursorLastSelfCommittedRaw = nil
            showSteeringUnsupportedNotice(message)
        }
    }

    private func dismissCursorModelParametersPopover() {
        showCursorModelParametersPopover = false
        clearCursorModelParametersPopoverIdentity()
    }

    private func clearCursorModelParametersPopoverIdentity() {
        cursorPopoverOriginTabID = nil
        cursorPopoverOriginAgent = nil
        cursorLastSelfCommittedRaw = nil
    }

    @ViewBuilder
    private var remoteReasoningEffortPicker: some View {
        if let remoteCatalog = props.remoteHostCatalog {
            let efforts = remoteCatalog.effortOptions(forModelID: props.selectedModelRaw)
            if !efforts.isEmpty {
                Menu {
                    ForEach(efforts) { option in
                        Button {
                            actions.selectRemoteAgentModel(option.modelID)
                        } label: {
                            HStack {
                                Text(option.displayName)
                                if props.selectedModelRaw == option.modelID {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(remoteCatalog.effortDisplayName(forModelID: props.selectedModelRaw) ?? "Effort")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(pickerChipColor)
                    .cornerRadius(4)
                }
                .menuStyle(.borderlessButton)
                .disabled(modelControlsDisabled)
                .opacity(modelControlsDisabled ? 0.55 : 1.0)
                .hoverTooltip(modelControlsDisabled ? modelControlsDisabledTooltip : "Remote reasoning effort")
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var reasoningEffortPicker: some View {
        if props.remoteHostCatalog == nil, props.selectedAgent == .codexExec {
            let efforts = actions.reasoningEffortOptionsForCurrentSelection()
            Menu {
                ForEach(efforts, id: \.rawValue) { effort in
                    Button {
                        actions.selectReasoningEffort(effort)
                    } label: {
                        HStack {
                            Text(effort.displayName)
                            if props.selectedReasoningEffortRaw == effort.rawValue {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(props.selectedReasoningEffortDisplayName)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(pickerChipColor)
                .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .disabled(efforts.isEmpty || modelControlsDisabled)
            .opacity(modelControlsDisabled ? 0.55 : 1.0)
            .hoverTooltip(modelControlsDisabled ? modelControlsDisabledTooltip : "Codex reasoning effort")
            .fixedSize()
        }
    }

    @ViewBuilder
    private var claudeEffortPicker: some View {
        if props.remoteHostCatalog == nil,
           props.selectedAgent.usesClaudeTooling,
           let claudeTools = props.providerControls?.claudeTools
        {
            let efforts = AgentModelCatalog.supportedClaudeEfforts(
                forSelectedModelRaw: props.selectedModelRaw,
                agentKind: props.selectedAgent
            )
            Menu {
                ForEach(efforts, id: \.rawValue) { level in
                    Button {
                        actions.setClaudeEffortLevel(level)
                    } label: {
                        HStack {
                            Text(level.displayName)
                            if claudeTools.effortLevel == level {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(claudeTools.effortLevel.displayName)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(pickerChipColor)
                .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .disabled(modelControlsDisabled || efforts.isEmpty)
            .opacity(modelControlsDisabled ? 0.55 : 1.0)
            .fixedSize()
            .hoverTooltip(modelControlsDisabled ? modelControlsDisabledTooltip : "Claude effort level")
        }
    }

    @ViewBuilder
    private var codexToolsButton: some View {
        if props.remoteHostCatalog == nil, props.selectedAgent == .codexExec {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                Text("Tools")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .semibold))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isCodexRunActive else { return }
                showCodexToolsPopover.toggle()
            }
            .popover(isPresented: $showCodexToolsPopover, arrowEdge: .bottom) {
                codexToolsPopoverContent
            }
            .opacity(isCodexRunActive ? 0.4 : 1.0)
            .hoverTooltip(isCodexRunActive ? "Tool controls locked during active run" : "Configure Codex tools & MCP servers")
            .fixedSize()
        }
    }

    @ViewBuilder
    private var claudeToolsButton: some View {
        if props.remoteHostCatalog == nil, props.selectedAgent.usesClaudeTooling {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                Text("Tools")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .semibold))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                showClaudeToolsPopover.toggle()
            }
            .popover(isPresented: $showClaudeToolsPopover, arrowEdge: .bottom) {
                claudeToolsPopoverContent
            }
            .hoverTooltip("Configure Claude tools")
            .fixedSize()
        }
    }

    private var permissionChipIconName: String {
        permissionBinding?.sessionStatus?.iconName
            ?? permissionBinding?.iconName
            ?? "shield"
    }

    private var permissionChipDisplayName: String {
        permissionBinding?.sessionStatus?.title
            ?? permissionBinding?.displayName
            ?? "Default"
    }

    private var permissionChipIsWarning: Bool {
        permissionBinding?.sessionStatus?.isWarning
            ?? permissionBinding?.isWarning
            ?? false
    }

    private var permissionOptionsTitle: String {
        permissionBinding?.providerID == .claude ? "Configured Preference" : "Sandbox Level"
    }

    @ViewBuilder
    private var approvalPopoverChip: some View {
        let warn = permissionChipIsWarning
        Button {
            showPermissionPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: permissionChipIconName)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                Text("Permissions · \(permissionChipDisplayName)")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .semibold))
            }
            .foregroundColor(warn ? .orange : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .hoverTooltip("Permissions & approval settings")
        .popover(isPresented: $showPermissionPopover, arrowEdge: .bottom) {
            approvalPopoverContent
        }
    }

    @ViewBuilder
    private var managedPermissionInfoBlock: some View {
        if let reason = permissionBinding?.externallyManagedReason {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(reason)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
    }

    @ViewBuilder
    private var permissionSessionStatusBlock: some View {
        if let permissionBinding,
           let status = permissionBinding.sessionStatus
        {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: status.iconName)
                    Text(status.title)
                        .fontWeight(.semibold)
                }
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundStyle(status.isWarning ? Color.orange : Color.secondary)

                Text(status.detail)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let configured = permissionBinding.configuredMode {
                    permissionStatusRow(label: "Configured", mode: configured)
                }
                permissionStatusRow(label: "Requested", mode: status.requestedMode)
                if let resolved = status.resolvedLaunchMode {
                    permissionStatusRow(label: "Launch request", mode: resolved)
                }
                if let acknowledged = status.acknowledgedMode {
                    permissionStatusRow(label: "Acknowledged request", mode: acknowledged)
                }
            }
            .padding(8)
            .background((status.isWarning ? Color.orange : Color.secondary).opacity(0.08))
            .cornerRadius(6)
        }
    }

    private func permissionStatusRow(
        label: String,
        mode: AgentPermissionModePresentationBinding
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(label):")
                .foregroundStyle(.tertiary)
            Text(mode.displayName)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
    }

    private var approvalPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))
                .padding(.bottom, 2)

            managedPermissionInfoBlock
            permissionSessionStatusBlock

            VStack(alignment: .leading, spacing: 6) {
                Text(permissionOptionsTitle)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                if let permissionBinding {
                    ForEach(permissionBinding.options) { option in
                        permissionRow(
                            title: option.title,
                            icon: option.iconName,
                            isSelected: option.isSelected,
                            disabled: !option.isEnabled
                        ) {
                            actions.setProviderPermissionLevel(option.id)
                        }
                    }

                    if let detailText = permissionBinding.options.first(where: { $0.isSelected })?.detailText,
                       !detailText.isEmpty
                    {
                        Text(detailText)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                            .foregroundStyle(permissionBinding.isWarning ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Permission settings are unavailable until a session is active.")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Toggle(isOn: Binding(
                get: { props.autoEditEnabled },
                set: { actions.setAutoEditEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Edit")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    Text("Apply file edits without approval")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(permissionControlsDisabled)
        }
        .padding(14)
        .frame(width: approvalPopoverWidth)
    }

    private func permissionRow(
        title: String,
        icon: String,
        isSelected: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .frame(width: fontPreset.scaledClamped(16, max: 22))
                Text(title)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .foregroundStyle(disabled ? .tertiary : .primary)
    }

    @ViewBuilder
    private var codexToolsPopoverContent: some View {
        if let codexTools = props.providerControls?.codexTools {
            Form {
                if isCodexRunActive {
                    Section {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                            Text("Tool settings are locked during an active run")
                                .font(fontPreset.captionFont)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Section {
                    Toggle("Bash", isOn: Binding(
                        get: { codexTools.bashToolEnabled },
                        set: { newValue in
                            actions.applyCodexToolSettingMutation(.bashTool(enabled: newValue))
                        }
                    ))

                    Toggle("Search", isOn: Binding(
                        get: { codexTools.searchToolEnabled },
                        set: { newValue in
                            actions.applyCodexToolSettingMutation(.searchTool(enabled: newValue))
                        }
                    ))

                    Toggle("Goals", isOn: Binding(
                        get: { codexTools.goalSupportEnabled },
                        set: { newValue in
                            actions.applyCodexToolSettingMutation(.goalSupport(enabled: newValue))
                        }
                    ))
                    .hoverTooltip("Codex /goal support is enabled by default. Turn this off to stop RepoPrompt from enabling features.goals for Codex app-server launch and thread config.")

                    Toggle("Reasoning Summaries", isOn: Binding(
                        get: { codexTools.reasoningSummariesEnabled },
                        set: { newValue in
                            actions.applyCodexToolSettingMutation(.reasoningSummaries(enabled: newValue))
                        }
                    ))
                    .hoverTooltip("Controls model_reasoning_summary for Codex Agent Mode app-server thread start/resume. Off sends none; on sends auto.")
                } header: {
                    Text("Tools")
                }

                Section {
                    if codexTools.mcpServerEntries.isEmpty {
                        Text("No servers in ~/.codex/config.toml")
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(codexTools.mcpServerEntries, id: \.normalizedName) { entry in
                            let isRepoPromptServer = entry.normalizedName.compare(MCPIntegrationHelper.repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
                            Toggle(
                                isOn: Binding(
                                    get: {
                                        codexTools.mcpServerStatesByNormalizedName[normalizedServerToggleKey(entry.normalizedName)] ?? isRepoPromptServer
                                    },
                                    set: { newValue in
                                        actions.applyCodexToolSettingMutation(
                                            .mcpServer(normalizedName: entry.normalizedName, enabled: newValue)
                                        )
                                    }
                                )
                            ) {
                                HStack(spacing: 4) {
                                    Text(entry.normalizedName)
                                    if isRepoPromptServer {
                                        Text("(required)")
                                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .disabled(isRepoPromptServer)
                        }
                    }
                } header: {
                    Text("MCP Servers")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: codexToolsPopoverWidth)
            .disabled(isCodexRunActive)
        } else {
            Text("Codex tool settings are unavailable until a session is active.")
                .font(fontPreset.captionFont)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(width: codexToolsPopoverWidth)
        }
    }

    @ViewBuilder
    private var claudeToolsPopoverContent: some View {
        if let claudeTools = props.providerControls?.claudeTools {
            Form {
                ClaudeToolSettingsActiveRunNotice(
                    isVisible: props.selectedAgent.usesClaudeTooling && props.runState.isActive,
                    fontPreset: fontPreset
                )

                Section {
                    Toggle("Bash", isOn: Binding(
                        get: { claudeTools.bashToolEnabled },
                        set: { newValue in
                            actions.applyClaudeToolSettingMutation(.bashTool(enabled: newValue))
                        }
                    ))
                } header: {
                    Text("Tools")
                }

                Section {
                    Toggle("Suppress Third-Party MCP Servers", isOn: Binding(
                        get: { claudeTools.mcpStrictModeEnabled },
                        set: { newValue in
                            actions.applyClaudeToolSettingMutation(.mcpStrictMode(enabled: newValue))
                        }
                    ))
                } header: {
                    Text("MCP Servers")
                } footer: {
                    Text(
                        claudeTools.mcpStrictModeEnabled
                            ? "Third-party MCP servers from your Claude config are ignored for this launch. This is not end-to-end tool containment."
                            : "Other MCP servers from your Claude config will also be loaded."
                    )
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Lazy Tool Loading", isOn: Binding(
                        get: { claudeTools.toolSearchEnabled },
                        set: { newValue in
                            actions.applyClaudeToolSettingMutation(.toolSearch(enabled: newValue))
                        }
                    ))
                } header: {
                    Text("Tool Search")
                } footer: {
                    Text(
                        claudeTools.toolSearchEnabled
                            ? "Claude searches for each tool before using it. Uses less context but adds latency."
                            : "All tools are preloaded into context. Faster but uses more tokens."
                    )
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(.secondary)
                }

                Section {
                    Picker(selection: Binding(
                        get: { claudeTools.agentModePromptDelivery },
                        set: { newValue in
                            actions.applyClaudeToolSettingMutation(
                                .agentModePromptDelivery(delivery: newValue)
                            )
                        }
                    )) {
                        ForEach(ClaudeAgentToolPreferences.AgentModePromptDelivery.allCases, id: \.rawValue) { delivery in
                            Text(delivery.displayName).tag(delivery)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                } header: {
                    Text("Sys Prompt Packaging")
                } footer: {
                    Text(claudeTools.agentModePromptDelivery.detailText)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: claudeToolsPopoverWidth)
        } else {
            Text("Claude tool settings are unavailable until a session is active.")
                .font(fontPreset.captionFont)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(width: claudeToolsPopoverWidth)
        }
    }

    private var imageDropOutline: some View {
        Group {
            if isImageDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 2)
                    .padding(.bottom, Self.footerHeight)
            }
        }
    }

    // MARK: - Actions

    private func scheduleMessage(
        notBefore: Date,
        runAlongsideOtherSessions: Bool
    ) {
        clearPersistentSteeringNotice()
        guard !submissionLatch.isLatched(for: currentTabID) else {
            logViewSubmitRejection(reason: "local_attempt_latched", target: renderedSubmitTarget, persistent: true)
            return
        }
        guard canScheduleToRenderedTarget else {
            logViewSubmitRejection(reason: "schedule_unavailable_for_rendered_target", target: renderedSubmitTarget, persistent: true)
            return
        }

        let rawDraftSnapshot = localInputText
        let trimmed = rawDraftSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || hasPendingAttachments else {
            logViewSubmitRejection(reason: "empty_draft", target: renderedSubmitTarget, persistent: true)
            return
        }
        guard let submitTarget = renderedSubmitTarget else {
            logViewSubmitRejection(reason: "view_nil_target", target: props.submitTarget, persistent: true)
            showSteeringUnsupportedNotice(Self.staleSubmitTargetMessage)
            return
        }
        guard let attempt = submissionLatch.begin(
            target: submitTarget,
            rawDraftSnapshot: rawDraftSnapshot
        ) else {
            logViewSubmitRejection(reason: "local_attempt_latched", target: submitTarget, persistent: true)
            return
        }

        actions.storeDraft(attempt.sourceTabID, rawDraftSnapshot)
        switch actions.claimSubmit(attempt) {
        case let .claimed(claim):
            Task { @MainActor in
                let submissionResult = await actions.scheduledSend.executeSchedule(
                    claim,
                    trimmed,
                    notBefore,
                    runAlongsideOtherSessions
                )
                let effects = submissionLatch.complete(
                    attempt,
                    result: submissionResult,
                    currentTabID: currentTabID,
                    currentRawDraft: localInputText
                )
                guard effects.matchedAttempt else {
                    logViewSubmitRejection(reason: "stale_schedule_completion", target: attempt.target)
                    return
                }
                if effects.shouldClearInput {
                    setLocalInputText("")
                    resetTextFieldTrigger.toggle()
                }
                if let blockedMessage = effects.blockedMessage {
                    // The reason only: the message can carry error descriptions.
                    logViewSubmitRejection(reason: "schedule_completion_blocked", target: attempt.target, persistent: true)
                    showSteeringUnsupportedNotice(
                        blockedMessage,
                        persistent: AgentModeViewModel.isRecoveryAdmissionRefusalNotice(blockedMessage)
                    )
                }
            }
        case let .rejected(rejection):
            submissionLatch.cancel(attempt)
            logViewSubmitRejection(reason: "schedule_claim_\(rejection.diagnosticReason)", target: submitTarget, persistent: true)
            if case .activeAttemptExists = rejection {
                return
            }
            showSteeringUnsupportedNotice(Self.staleSubmitTargetMessage)
        }
    }

    private func sendMessage() {
        clearPersistentSteeringNotice()
        guard !submissionLatch.isLatched(for: currentTabID) else {
            logViewSubmitRejection(reason: "local_attempt_latched", target: renderedSubmitTarget, persistent: true)
            return
        }
        guard props.canSendWithCurrentProvider else {
            logViewSubmitRejection(
                reason: props.hasAvailableAgentProviders ? "selected_provider_unavailable" : "no_agent_providers",
                target: renderedSubmitTarget,
                persistent: true
            )
            if props.hasAvailableAgentProviders {
                showSteeringUnsupportedNotice(props.unavailableSelectedAgentMessage ?? "Connect this agent provider in Settings before sending.")
            } else {
                openCLIProvidersSettings()
            }
            return
        }
        let rawDraftSnapshot = localInputText
        let trimmed = rawDraftSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || hasPendingAttachments else {
            logViewSubmitRejection(reason: "empty_draft", target: renderedSubmitTarget, persistent: true)
            return
        }
        guard let submitTarget = renderedSubmitTarget else {
            logViewSubmitRejection(reason: "view_nil_target", target: props.submitTarget, persistent: true)
            showSteeringUnsupportedNotice(Self.staleSubmitTargetMessage)
            return
        }
        guard let attempt = submissionLatch.begin(
            target: submitTarget,
            rawDraftSnapshot: rawDraftSnapshot
        ) else {
            logViewSubmitRejection(reason: "local_attempt_latched", target: submitTarget, persistent: true)
            return
        }

        actions.storeDraft(attempt.sourceTabID, rawDraftSnapshot)
        switch actions.claimSubmit(attempt) {
        case let .claimed(claim):
            Task { @MainActor in
                let submissionResult = await actions.executeSubmit(claim, trimmed)
                let effects = submissionLatch.complete(
                    attempt,
                    result: submissionResult,
                    currentTabID: currentTabID,
                    currentRawDraft: localInputText
                )
                guard effects.matchedAttempt else {
                    logViewSubmitRejection(reason: "stale_completion", target: attempt.target)
                    return
                }
                if effects.shouldClearInput {
                    setLocalInputText("")
                    resetTextFieldTrigger.toggle()
                }
                if let blockedMessage = effects.blockedMessage {
                    // The reason only: the message can carry error descriptions.
                    logViewSubmitRejection(reason: "completion_blocked", target: attempt.target, persistent: true)
                    // 9-live V1: a recovery admission refusal stays until the next attempt or edit.
                    showSteeringUnsupportedNotice(
                        blockedMessage,
                        persistent: AgentModeViewModel.isRecoveryAdmissionRefusalNotice(blockedMessage)
                    )
                }
            }
        case let .rejected(rejection):
            submissionLatch.cancel(attempt)
            logViewSubmitRejection(reason: "claim_\(rejection.diagnosticReason)", target: submitTarget, persistent: true)
            if case .activeAttemptExists = rejection {
                return
            }
            showSteeringUnsupportedNotice(Self.staleSubmitTargetMessage)
        }
    }

    /// Shows `message` under the composer: for 3 seconds, or until the next submit attempt or text
    /// change when `persistent`.
    private func showSteeringUnsupportedNotice(_ message: String, persistent: Bool = false) {
        guard !message.isEmpty else { return }
        submissionLatch.advanceNoticeRevision()
        let noticeRevision = submissionLatch.noticeRevision
        steeringUnsupportedDismissTask?.cancel()
        steeringUnsupportedDismissTask = nil
        var needsTimer = false
        withAnimation(.easeInOut(duration: 0.15)) {
            needsTimer = steeringNotice.show(message, persistent: persistent)
        }
        guard needsTimer else { return }
        steeringUnsupportedDismissTask = Task {
            try? await Task.sleep(nanoseconds: AgentComposerSubmitNotice.transientDurationNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard submissionLatch.noticeRevision == noticeRevision else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    _ = steeringNotice.transientTimerFired(for: message)
                }
                steeringUnsupportedDismissTask = nil
            }
        }
    }

    /// 9-live V1: the next submit attempt, composer text change, or tab change clears a persistent
    /// notice.
    private func clearPersistentSteeringNotice() {
        guard steeringNotice.isPersistent else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            _ = steeringNotice.clearPersistent()
        }
    }

    /// `persistent` also writes the reason to the always-on `ComposerSubmit` log.
    private func logViewSubmitRejection(reason: String, target: AgentComposerSubmitTarget?, persistent: Bool = false) {
        if persistent {
            AgentComposerSubmitDiagnostics.viewRejected(
                reason: reason,
                currentTabID: currentTabID,
                propsTabID: props.currentTabID,
                targetTabID: target?.tabID
            )
        }
        #if DEBUG
            AgentModePerfDiagnostics.event(
                "agent.composer.submit.rejected",
                tabID: currentTabID,
                fields: [
                    "reason": reason,
                    "currentTabID": AgentModePerfDiagnostics.shortID(currentTabID),
                    "propsTabID": AgentModePerfDiagnostics.shortID(props.currentTabID),
                    "targetTabID": AgentModePerfDiagnostics.shortID(target?.tabID),
                    "attemptID": AgentModePerfDiagnostics.shortID(submissionLatch.activeAttemptID(for: currentTabID)),
                    "inputRevision": String(submissionLatch.inputRevision),
                    "expectedSubmissionToken": AgentModePerfDiagnostics.shortID(target?.expectedSubmissionToken),
                    "expectedSourceAgentSessionID": AgentModePerfDiagnostics.shortID(target?.expectedSourceAgentSessionID),
                    "expectedPersistentBindingGeneration": AgentModePerfDiagnostics.shortID(target?.expectedPersistentBindingIdentity?.generation),
                    "expectedBindingTransitionGeneration": target.map { String($0.expectedBindingTransitionGeneration) } ?? "nil"
                ]
            )
        #endif
    }

    private func cancelRun(_ target: AgentRunCancelTarget) {
        Task {
            await actions.cancelRun(target)
        }
    }

    private func pickImages() {
        guard canAttachImages, let tabID = currentTabID else { return }
        Task { @MainActor in
            let targetWindow = WindowStatesManager.shared.allWindows.first { $0.windowID == windowID }?.nsWindow
            let urls = await OpenPanelService.shared.pickImageFiles(
                title: "Choose Images",
                message: "Attach one or more images for the next turn.",
                attachedTo: targetWindow
            )
            actions.attachImages(tabID, urls)
        }
    }

    private func handleFileTagCommitted(_ suggestion: MentionSuggestion) {
        guard let tabID = currentTabID else { return }
        let attachmentDisplayName = AgentFileMentionText.attachmentDisplayName(for: suggestion)
        actions.commitTaggedFile(tabID, suggestion, attachmentDisplayName)
    }

    private func removeImageAttachment(_ attachmentID: UUID) {
        guard let tabID = currentTabID else { return }
        actions.removeImage(tabID, attachmentID)
    }

    private func removeTaggedFileAttachment(_ attachmentID: UUID) {
        guard let tabID = currentTabID else { return }
        let attachment = props.attachments.taggedFileAttachments
            .first(where: { $0.id == attachmentID })
        actions.removeTaggedFile(tabID, attachmentID)
        if let attachment {
            setLocalInputText(
                AgentFileMentionText.removingTaggedMention(
                    displayName: attachment.displayName,
                    relativePath: attachment.relativePath,
                    from: localInputText
                )
            )
        }
    }

    private func handleImageDrop(providers: [NSItemProvider]) -> Bool {
        guard let tabID = currentTabID else {
            return false
        }
        // Frozen: the drop is refused (never accepted), so the source keeps it.
        guard !actions.isShutdownFrozen() else {
            return false
        }
        return imageInputAdapter.loadPreparedImages(from: providers) { prepared in
            guard !prepared.isEmpty else { return }
            Task { @MainActor in
                // A freeze that began while the images loaded: the composer is not changed.
                guard !actions.isShutdownFrozen() else {
                    imageInputAdapter.cleanupTemporaryFiles(prepared)
                    return
                }
                attachPreparedImages(prepared, tabID: tabID)
            }
        }
    }

    private func handleImagePaste(pasteboard: NSPasteboard) -> Bool {
        guard let tabID = currentTabID else {
            return false
        }
        guard imageInputAdapter.shouldConsumePasteAsImageAttachment(from: pasteboard) else {
            return false
        }
        // Frozen: the image is consumed unattached (never inserted as text, never accepted).
        guard !actions.isShutdownFrozen() else {
            return true
        }
        let prepared = imageInputAdapter.preparedImages(from: pasteboard)
        guard !prepared.isEmpty else {
            return false
        }
        attachPreparedImages(prepared, tabID: tabID)
        return true
    }

    private func attachPreparedImages(_ prepared: [AgentImageInputAdapter.PreparedImage], tabID: UUID) {
        let urls = prepared.map(\.url)
        actions.attachImages(tabID, urls)
        imageInputAdapter.cleanupTemporaryFiles(prepared)
    }

    private func normalizedServerToggleKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func setLocalInputText(_ newValue: String, forceRevision: Bool = false) {
        guard forceRevision || localInputText != newValue else {
            isInputEmpty = newValue.isEmpty
            return
        }
        submissionLatch.advanceInputRevision()
        localInputText = newValue
        isInputEmpty = newValue.isEmpty
    }

    private func loadDraftFromSession(for tabID: UUID) {
        isSyncingDraftFromSession = true
        setLocalInputText(actions.retrieveDraft(tabID), forceRevision: true)
        DispatchQueue.main.async {
            isSyncingDraftFromSession = false
        }
    }
}

struct AgentImageInputAdapter {
    struct PreparedImage: Equatable {
        let url: URL
        let isTemporary: Bool
    }

    private let fileManager: FileManager
    private let temporaryRoot: URL
    private let preferredImageTypes: [UTType] = [.png, .jpeg, .heic, .heif, .gif, .bmp, .tiff]

    private static let maxPlainTextCandidateCharacters = 50000
    private static let maxPlainTextLineCount = 500
    private static let markdownLinkTargetRegex = try! NSRegularExpression(pattern: #"\(([^)\r\n]+)\)"#)
    private static let quotedPathRegex = try! NSRegularExpression(pattern: #"\"([^\"]+)\"|'([^']+)'|`([^`]+)`"#)
    private static let fileURLTokenRegex = try! NSRegularExpression(pattern: #"file://[^\s<>()\[\]{}\"'`]+"#)
    private static let absolutePathTokenRegex = try! NSRegularExpression(pattern: #"(?:^|[\s:=,])((?:~|/)[^\s<>()\[\]{}\"'`]+)"#)
    private static let pathHintTokens = ["file://", "/", "~", ".png", ".jpg", ".jpeg", ".jfif", ".webp", ".avif", ".gif", ".bmp", ".tif", ".tiff", ".heic", ".heif", ".svg"]
    private static let fallbackImageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jfif", "jpe", "gif", "bmp", "webp", "avif", "heic", "heif", "tif", "tiff", "svg", "ico"
    ]

    init(fileManager: FileManager = .default, temporaryRoot: URL? = nil) {
        self.fileManager = fileManager
        self.temporaryRoot = temporaryRoot
            ?? MCPFilesystemConstants.identity.temporaryRootURL(fileManager: fileManager)
            .appendingPathComponent("AgentImageInput", isDirectory: true)
            .standardizedFileURL
    }

    func preparedImages(from pasteboard: NSPasteboard) -> [PreparedImage] {
        let fileURLPrepared = preparedFileURLImages(from: pasteboard, includePlainTextReferences: true)
        if !fileURLPrepared.isEmpty {
            return fileURLPrepared
        }

        var prepared = preparedImageDataRepresentations(from: pasteboard)
        if prepared.isEmpty {
            prepared = preparedNSImageObjects(from: pasteboard)
        }

        return deduplicated(prepared)
    }

    func shouldConsumePasteAsImageAttachment(from pasteboard: NSPasteboard) -> Bool {
        if hasExplicitImagePasteboardType(in: pasteboard) {
            return true
        }
        if shouldConsumeNSImageReadablePasteboard(pasteboard) {
            return true
        }
        if !preparedFileURLImages(from: pasteboard, includePlainTextReferences: false).isEmpty {
            return true
        }
        guard let plainString = pasteboard.string(forType: .string) else {
            return false
        }
        guard !fileURLs(fromPlainText: plainString).isEmpty else {
            return false
        }
        return shouldConsumePlainTextPaste(plainString)
    }

    func loadPreparedImages(
        from providers: [NSItemProvider],
        completion: @escaping ([PreparedImage]) -> Void
    ) -> Bool {
        let candidates = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || bestImageTypeIdentifier(from: $0.registeredTypeIdentifiers) != nil
        }
        guard !candidates.isEmpty else {
            return false
        }

        let lockQueue = DispatchQueue(label: "AgentImageInputAdapter.lock")
        let group = DispatchGroup()
        var prepared: [PreparedImage] = []

        for provider in candidates {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let fileURL = droppedFileURL(from: item), isImageFileURL(fileURL) {
                        lockQueue.sync {
                            prepared.append(PreparedImage(url: fileURL.standardizedFileURL, isTemporary: false))
                        }
                        group.leave()
                        return
                    }

                    guard let imageTypeIdentifier = bestImageTypeIdentifier(from: provider.registeredTypeIdentifiers) else {
                        group.leave()
                        return
                    }
                    provider.loadDataRepresentation(forTypeIdentifier: imageTypeIdentifier) { data, _ in
                        defer { group.leave() }
                        guard let data, !data.isEmpty else { return }
                        do {
                            let fileURL = try writeTemporaryImageData(data, typeIdentifier: imageTypeIdentifier)
                            lockQueue.sync {
                                prepared.append(PreparedImage(url: fileURL, isTemporary: true))
                            }
                        } catch {
                            return
                        }
                    }
                }
                continue
            }

            guard let imageTypeIdentifier = bestImageTypeIdentifier(from: provider.registeredTypeIdentifiers) else {
                continue
            }
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: imageTypeIdentifier) { data, _ in
                defer { group.leave() }
                guard let data, !data.isEmpty else { return }
                do {
                    let fileURL = try writeTemporaryImageData(data, typeIdentifier: imageTypeIdentifier)
                    lockQueue.sync {
                        prepared.append(PreparedImage(url: fileURL, isTemporary: true))
                    }
                } catch {
                    return
                }
            }
        }

        group.notify(queue: .main) {
            lockQueue.sync {
                let deduplicatedPrepared = deduplicated(prepared)
                DispatchQueue.main.async {
                    completion(deduplicatedPrepared)
                }
            }
        }
        return true
    }

    func cleanupTemporaryFiles(_ prepared: [PreparedImage]) {
        let temporaryPrefix = temporaryRoot.path + "/"
        for entry in prepared where entry.isTemporary {
            let standardized = entry.url.standardizedFileURL
            guard standardized.path.hasPrefix(temporaryPrefix) else { continue }
            try? fileManager.removeItem(at: standardized)
        }
    }

    private func writeTemporaryImageData(_ data: Data, typeIdentifier: String) throws -> URL {
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let fileExtension = (UTType(typeIdentifier)?.preferredFilenameExtension ?? "png")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationURL = temporaryRoot
            .appendingPathComponent("pasted-image-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension.isEmpty ? "png" : fileExtension)
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    private func bestImageTypeIdentifier(from identifiers: [String]) -> String? {
        let imageIdentifiers = identifiers.compactMap { identifier -> (raw: String, canonical: UTType)? in
            guard let canonical = canonicalImageType(forIdentifier: identifier) else { return nil }
            return (identifier, canonical)
        }
        guard !imageIdentifiers.isEmpty else { return nil }

        for preferred in preferredImageTypes {
            if let match = imageIdentifiers.first(where: { $0.canonical == preferred }) {
                return match.raw
            }
        }
        return imageIdentifiers.first?.raw
    }

    private func bestImagePasteboardType(from types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        imagePasteboardTypeCandidates(from: types).first
    }

    private func imagePasteboardTypeCandidates(from types: [NSPasteboard.PasteboardType]) -> [NSPasteboard.PasteboardType] {
        let imageTypes = types.compactMap { type -> (raw: NSPasteboard.PasteboardType, canonical: UTType)? in
            guard let canonical = canonicalImageType(forPasteboardType: type) else { return nil }
            return (type, canonical)
        }
        guard !imageTypes.isEmpty else { return [] }

        var ordered: [NSPasteboard.PasteboardType] = []
        for preferred in preferredImageTypes {
            for candidate in imageTypes where candidate.canonical == preferred {
                if !ordered.contains(candidate.raw) {
                    ordered.append(candidate.raw)
                }
            }
        }
        for candidate in imageTypes where !ordered.contains(candidate.raw) {
            ordered.append(candidate.raw)
        }
        return ordered
    }

    private func canonicalImageType(forIdentifier identifier: String) -> UTType? {
        ImagePasteboardTypes.canonicalImageType(forIdentifier: identifier)
    }

    private func canonicalImageType(forPasteboardType type: NSPasteboard.PasteboardType) -> UTType? {
        canonicalImageType(forIdentifier: type.rawValue)
    }

    private func preparedImageDataRepresentations(from pasteboard: NSPasteboard) -> [PreparedImage] {
        var prepared: [PreparedImage] = []

        for item in pasteboard.pasteboardItems ?? [] {
            guard let representation = firstImageDataRepresentation(in: item) else { continue }
            do {
                let fileURL = try writeTemporaryImageData(
                    representation.data,
                    typeIdentifier: representation.typeIdentifier
                )
                prepared.append(PreparedImage(url: fileURL, isTemporary: true))
            } catch {
                continue
            }
        }

        if prepared.isEmpty, let representation = firstImageDataRepresentation(in: pasteboard) {
            do {
                let fileURL = try writeTemporaryImageData(
                    representation.data,
                    typeIdentifier: representation.typeIdentifier
                )
                prepared.append(PreparedImage(url: fileURL, isTemporary: true))
            } catch {
                // Ignore fallback conversion errors.
            }
        }

        return prepared
    }

    private func preparedNSImageObjects(from pasteboard: NSPasteboard) -> [PreparedImage] {
        guard let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] else {
            return []
        }

        var prepared: [PreparedImage] = []
        for image in images {
            guard let representation = imageDataRepresentation(from: image) else { continue }
            do {
                let fileURL = try writeTemporaryImageData(
                    representation.data,
                    typeIdentifier: representation.typeIdentifier
                )
                prepared.append(PreparedImage(url: fileURL, isTemporary: true))
            } catch {
                continue
            }
        }
        return prepared
    }

    private func firstImageDataRepresentation(
        in item: NSPasteboardItem
    ) -> (data: Data, typeIdentifier: String)? {
        for pasteboardType in imagePasteboardTypeCandidates(from: item.types) {
            guard let data = item.data(forType: pasteboardType), !data.isEmpty else { continue }
            let typeIdentifier = canonicalImageType(forPasteboardType: pasteboardType)?.identifier ?? pasteboardType.rawValue
            return (data, typeIdentifier)
        }
        return nil
    }

    private func firstImageDataRepresentation(
        in pasteboard: NSPasteboard
    ) -> (data: Data, typeIdentifier: String)? {
        guard let types = pasteboard.types else { return nil }
        for pasteboardType in imagePasteboardTypeCandidates(from: types) {
            guard let data = pasteboard.data(forType: pasteboardType), !data.isEmpty else { continue }
            let typeIdentifier = canonicalImageType(forPasteboardType: pasteboardType)?.identifier ?? pasteboardType.rawValue
            return (data, typeIdentifier)
        }
        return nil
    }

    private func imageDataRepresentation(from image: NSImage) -> (data: Data, typeIdentifier: String)? {
        guard let tiffData = image.tiffRepresentation, !tiffData.isEmpty else {
            return nil
        }
        if let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]),
           !pngData.isEmpty
        {
            return (pngData, UTType.png.identifier)
        }
        return (tiffData, UTType.tiff.identifier)
    }

    private func preparedFileURLImages(
        from pasteboard: NSPasteboard,
        includePlainTextReferences: Bool
    ) -> [PreparedImage] {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []

        for item in pasteboard.pasteboardItems ?? [] {
            if let fileURLString = item.string(forType: .fileURL),
               let fileURL = URL(string: fileURLString),
               fileURL.isFileURL
            {
                urls.append(fileURL)
            } else if let fileURLData = item.data(forType: .fileURL),
                      let fileURL = URL(dataRepresentation: fileURLData, relativeTo: nil),
                      fileURL.isFileURL
            {
                urls.append(fileURL)
            }

            if includePlainTextReferences, let plainString = item.string(forType: .string) {
                urls.append(contentsOf: fileURLs(fromPlainText: plainString))
            }
        }

        if includePlainTextReferences, let plainString = pasteboard.string(forType: .string) {
            urls.append(contentsOf: fileURLs(fromPlainText: plainString))
        }

        let prepared = urls
            .map(\.standardizedFileURL)
            .filter { $0.isFileURL && fileManager.fileExists(atPath: $0.path) && isImageFileURL($0) }
            .map { PreparedImage(url: $0, isTemporary: false) }
        return deduplicated(prepared)
    }

    private func fileURLs(fromPlainText text: String) -> [URL] {
        let cappedText = text.count > Self.maxPlainTextCandidateCharacters
            ? String(text.prefix(Self.maxPlainTextCandidateCharacters))
            : text
        var results: [URL] = []
        var seenPaths: Set<String> = []
        var processedLineCount = 0
        cappedText.enumerateLines { line, stop in
            if processedLineCount >= Self.maxPlainTextLineCount {
                stop = true
                return
            }
            processedLineCount += 1
            guard lineLikelyContainsPathReference(line) else { return }
            for candidate in fileReferenceCandidates(in: line) {
                guard let fileURL = fileURLFromPlainText(candidate) else { continue }
                let standardizedURL = fileURL.standardizedFileURL
                let key = standardizedURL.path
                guard !key.isEmpty else { continue }
                guard !seenPaths.contains(key) else { continue }
                seenPaths.insert(key)
                results.append(standardizedURL)
            }
        }
        return results
    }

    private func shouldConsumeNSImageReadablePasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) else {
            return false
        }
        guard let plainString = pasteboard.string(forType: .string) else {
            return true
        }
        let trimmed = plainString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }
        guard !fileURLs(fromPlainText: plainString).isEmpty else {
            return false
        }
        return shouldConsumePlainTextPaste(plainString)
    }

    private func hasExplicitImagePasteboardType(in pasteboard: NSPasteboard) -> Bool {
        if let types = pasteboard.types,
           bestImagePasteboardType(from: types) != nil
        {
            return true
        }
        for item in pasteboard.pasteboardItems ?? [] {
            if bestImagePasteboardType(from: item.types) != nil {
                return true
            }
        }
        return false
    }

    private func shouldConsumePlainTextPaste(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let cappedText = trimmed.count > Self.maxPlainTextCandidateCharacters
            ? String(trimmed.prefix(Self.maxPlainTextCandidateCharacters))
            : trimmed
        let lines = cappedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        guard lines.count <= Self.maxPlainTextLineCount else { return false }
        return lines.allSatisfy { lineLooksLikeStandaloneImageReference($0) }
    }

    private func lineLooksLikeStandaloneImageReference(_ line: String) -> Bool {
        if fileURLFromPlainText(line) != nil {
            return true
        }
        if let markdownTarget = firstMarkdownImageTarget(in: line),
           fileURLFromPlainText(markdownTarget) != nil
        {
            return true
        }
        return false
    }

    private func firstMarkdownImageTarget(in line: String) -> String? {
        markdownImageTargets(in: line, requireStandaloneLine: true).first
    }

    private func markdownImageTargets(in line: String, requireStandaloneLine: Bool = false) -> [String] {
        let characters = Array(line)
        guard !characters.isEmpty else { return [] }

        var targets: [String] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "!", index + 1 < characters.count, characters[index + 1] == "[" else {
                index += 1
                continue
            }

            let imageStart = index
            guard let altEnd = findClosingBracket(in: characters, startingAt: index + 1) else {
                index += 2
                continue
            }
            guard altEnd + 1 < characters.count, characters[altEnd + 1] == "(" else {
                index = altEnd + 1
                continue
            }

            guard let parsed = parseMarkdownLinkTarget(in: characters, openingParenIndex: altEnd + 1) else {
                index = altEnd + 2
                continue
            }

            if requireStandaloneLine {
                let prefix = String(characters[..<imageStart]).trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = String(characters[(parsed.closingParenIndex + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty || !suffix.isEmpty {
                    index = parsed.closingParenIndex + 1
                    continue
                }
            }

            targets.append(parsed.target)
            index = parsed.closingParenIndex + 1
        }

        return targets
    }

    private func findClosingBracket(in characters: [Character], startingAt openingBracketIndex: Int) -> Int? {
        guard openingBracketIndex < characters.count, characters[openingBracketIndex] == "[" else {
            return nil
        }
        var index = openingBracketIndex + 1
        var isEscaping = false
        while index < characters.count {
            let character = characters[index]
            if isEscaping {
                isEscaping = false
                index += 1
                continue
            }
            if character == "\\" {
                isEscaping = true
                index += 1
                continue
            }
            if character == "]" {
                return index
            }
            index += 1
        }
        return nil
    }

    private func parseMarkdownLinkTarget(
        in characters: [Character],
        openingParenIndex: Int
    ) -> (target: String, closingParenIndex: Int)? {
        guard openingParenIndex < characters.count, characters[openingParenIndex] == "(" else {
            return nil
        }
        var depth = 1
        var index = openingParenIndex + 1
        var target = ""
        var isEscaping = false
        while index < characters.count {
            let character = characters[index]
            if isEscaping {
                target.append(character)
                isEscaping = false
                index += 1
                continue
            }
            if character == "\\" {
                isEscaping = true
                index += 1
                continue
            }
            if character == "(" {
                depth += 1
                target.append(character)
                index += 1
                continue
            }
            if character == ")" {
                depth -= 1
                if depth == 0 {
                    return (
                        target.trimmingCharacters(in: .whitespacesAndNewlines),
                        index
                    )
                }
                target.append(character)
                index += 1
                continue
            }
            target.append(character)
            index += 1
        }
        return nil
    }

    private func lineLikelyContainsPathReference(_ line: String) -> Bool {
        let lower = line.lowercased()
        for token in Self.pathHintTokens where lower.contains(token) {
            return true
        }
        return false
    }

    private func fileReferenceCandidates(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates = [trimmed]
        candidates.append(contentsOf: markdownImageTargets(in: line))
        appendMatches(regex: Self.markdownLinkTargetRegex, in: line, captureGroup: 1, into: &candidates)
        appendMatches(regex: Self.quotedPathRegex, in: line, captureGroup: 1, into: &candidates)
        appendMatches(regex: Self.quotedPathRegex, in: line, captureGroup: 2, into: &candidates)
        appendMatches(regex: Self.quotedPathRegex, in: line, captureGroup: 3, into: &candidates)
        appendMatches(regex: Self.fileURLTokenRegex, in: line, into: &candidates)
        appendMatches(regex: Self.absolutePathTokenRegex, in: line, captureGroup: 1, into: &candidates)
        return candidates
    }

    private func appendMatches(
        regex: NSRegularExpression,
        in text: String,
        captureGroup: Int? = nil,
        into candidates: inout [String]
    ) {
        let nsText = text as NSString
        let searchRange = NSRange(location: 0, length: nsText.length)
        regex.enumerateMatches(in: text, options: [], range: searchRange) { match, _, _ in
            guard let match else { return }
            let range: NSRange
            if let captureGroup {
                guard match.numberOfRanges > captureGroup else { return }
                range = match.range(at: captureGroup)
            } else {
                range = match.range
            }
            guard range.location != NSNotFound, range.length > 0 else { return }
            candidates.append(nsText.substring(with: range))
        }
    }

    private func fileURLFromPlainText(_ rawText: String) -> URL? {
        let normalized = normalizedPlainTextCandidate(rawText)
        guard !normalized.isEmpty else { return nil }
        let unescaped = unescapePathEscapes(in: normalized)

        if let fileURL = URL(string: unescaped), fileURL.isFileURL {
            return fileURL
        }

        if unescaped.hasPrefix("file://") {
            var pathPart = String(unescaped.dropFirst("file://".count))
            if pathPart.hasPrefix("localhost/") {
                pathPart = String(pathPart.dropFirst("localhost/".count))
            }
            if !pathPart.hasPrefix("/") {
                pathPart = "/" + pathPart
            }
            let decodedPath = pathPart.removingPercentEncoding ?? pathPart
            return URL(fileURLWithPath: decodedPath)
        }

        if unescaped.hasPrefix("file:/") {
            let normalized = "file://" + String(unescaped.dropFirst("file:/".count))
            if let fileURL = URL(string: normalized), fileURL.isFileURL {
                return fileURL
            }
        }

        guard unescaped.hasPrefix("/") || unescaped.hasPrefix("~") else { return nil }
        let expandedPath = (unescaped as NSString).expandingTildeInPath
        let decodedPath = expandedPath.removingPercentEncoding ?? expandedPath
        return URL(fileURLWithPath: decodedPath)
    }

    private func normalizedPlainTextCandidate(_ rawText: String) -> String {
        var value = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }

        while let first = value.first, "<[({".contains(first) {
            value.removeFirst()
        }
        while let last = value.last, ">)]},.;:!?".contains(last) {
            value.removeLast()
        }

        if value.count > 1,
           (value.hasPrefix("\"") && value.hasSuffix("\""))
           || (value.hasPrefix("'") && value.hasSuffix("'"))
           || (value.hasPrefix("`") && value.hasSuffix("`"))
        {
            value.removeFirst()
            value.removeLast()
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func unescapePathEscapes(in value: String) -> String {
        guard value.contains("\\") else { return value }
        let escapable: Set<Character> = [" ", "(", ")", "[", "]", "{", "}", "!", "?", ",", ";", "\"", "'", "`"]
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character == "\\" {
                let nextIndex = value.index(after: index)
                if nextIndex < value.endIndex {
                    let next = value[nextIndex]
                    if escapable.contains(next) {
                        output.append(next)
                    } else {
                        output.append("\\")
                        output.append(next)
                    }
                    index = value.index(after: nextIndex)
                    continue
                }
            }
            output.append(character)
            index = value.index(after: index)
        }
        return output
    }

    private func isImageFileURL(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if type.conforms(to: .image) {
                return true
            }
        }

        let rawExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawExtension.isEmpty else { return false }
        let normalizedExtension = rawExtension.lowercased()
        if let type = UTType(filenameExtension: normalizedExtension) {
            if type.conforms(to: .image) {
                return true
            }
        }
        return Self.fallbackImageFileExtensions.contains(normalizedExtension)
    }

    private func droppedFileURL(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? URL {
            return url
        }
        if let nsURL = item as? NSURL {
            return nsURL as URL
        }
        if let string = item as? String, let url = URL(string: string), url.isFileURL {
            return url
        }
        return nil
    }

    private func deduplicated(_ prepared: [PreparedImage]) -> [PreparedImage] {
        var seenPaths: Set<String> = []
        var result: [PreparedImage] = []
        for entry in prepared {
            let path = entry.url.standardizedFileURL.path
            guard !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)
            result.append(entry)
        }
        return result
    }
}
