import AppKit
import RepoPromptAgentCore
import RepoPromptUI
import SwiftUI

extension EnvironmentValues {
    @Entry var agentWindowIsFocused: Bool = true
}

// MARK: - Message Footer Strip

/// An inline footer strip with timestamp and a subtle copy button.
/// Always rendered inside the bubble layout so the copy button is reliably hoverable.
///
/// Performance notes:
/// - Uses the shared message timestamp formatter so timestamp labels stay consistent.
/// - Observes FontScaleManager so footer text follows Agent Mode text size.
private struct MessageFooterStrip: View {
    let text: String
    let timestamp: Date
    let isTrailing: Bool
    var handoffConfig: AgentHandoffConfig?
    let hasHandoffButton: Bool
    /// When non-nil, shows this message's frozen/live runtime marker beside the timestamp.
    var runtimeFooter: AgentMessageRuntimeFooter?
    @Environment(\.agentWindowIsFocused) private var agentWindowIsFocused
    @State private var isHoveringCopy = false
    @State private var showCopied = false
    @State private var isHoveringHandoff = false
    @State private var showHandoffPopover = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        HStack(spacing: 6) {
            if isTrailing { Spacer(minLength: 0) }

            if isTrailing {
                elapsedStatusView
                timestampText
                handoffButton
                copyButton
            } else {
                copyButton
                handoffButton
                timestampText
                elapsedStatusView
            }

            if !isTrailing { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 4)
    }

    private var timestampText: some View {
        MessageTimestampText(date: timestamp)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
            .foregroundColor(.secondary.opacity(0.7))
    }

    @ViewBuilder
    private var elapsedStatusView: some View {
        if let runtimeFooter {
            if let completedDate = runtimeFooter.completedDate {
                #if DEBUG
                    let _ = AgentModePerfDiagnostics.increment("timeline.messageFooter.completed")
                #endif
                let elapsed = AgentRuntimeDurationFormatter.string(from: runtimeFooter.anchorDate, to: completedDate)
                Text("\(runtimeFooter.statusText) \(elapsed)")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                    .monospacedDigit()
            } else if agentWindowIsFocused {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    #if DEBUG
                        let _ = AgentModePerfDiagnostics.increment("timeline.messageFooter.tick")
                    #endif
                    runtimeFooterText(runtimeFooter, now: timeline.date)
                }
                #if DEBUG
                .onAppear {
                        AgentModePerfDiagnostics.increment("timeline.messageFooter.liveMount")
                    }
                #endif
            } else {
                #if DEBUG
                    let _ = AgentModePerfDiagnostics.increment("timeline.messageFooter.unfocused")
                #endif
                runtimeFooterText(runtimeFooter, now: Date())
            }
        }
    }

    private func runtimeFooterText(_ runtimeFooter: AgentMessageRuntimeFooter, now: Date) -> some View {
        let elapsed = AgentRuntimeDurationFormatter.string(from: runtimeFooter.anchorDate, to: now)
        return Text("\(runtimeFooter.statusText) · \(elapsed)")
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
            .foregroundColor(.secondary.opacity(0.7))
            .monospacedDigit()
    }

    private var copyButton: some View {
        Button(action: copyToClipboard) {
            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(
                    showCopied
                        ? .green
                        : (isHoveringCopy ? BubbleColors.highContrastCopyIconHover : BubbleColors.copyIconNormal)
                )
                .frame(width: 16, height: 16)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHoveringCopy = hovering
            }
        }
        .hoverTooltip("Copy message")
    }

    @ViewBuilder
    private var handoffButton: some View {
        if let config = handoffConfig {
            Button {
                showHandoffPopover = true
            } label: {
                Image(systemName: "arrow.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(
                        isHoveringHandoff ? BubbleColors.highContrastCopyIconHover : BubbleColors.copyIconNormal
                    )
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(PlainButtonStyle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHoveringHandoff = hovering
                }
            }
            .hoverTooltip("Handoff to new chat")
            .popover(isPresented: $showHandoffPopover, arrowEdge: .bottom) {
                AgentHandoffPopover(config: config) {
                    showHandoffPopover = false
                }
            }
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            showCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.15)) {
                showCopied = false
            }
        }
    }
}

// MARK: - Agent Message Bubble

typealias CodexManagedLoginAction = (@MainActor @escaping (URL) -> Void) async throws -> Bool

/// A bubble view for displaying agent chat items (user, assistant, tool calls, etc.)
@MainActor
struct AgentMessageBubble: View {
    let item: AgentChatItem
    let isMostRecentEditBubble: Bool
    let windowID: Int
    let currentWorkspaceID: UUID?
    let currentTabID: UUID?
    let suppressAskUserTranscriptUI: Bool
    let contextBuilderContext: ContextBuilderCardContext?
    let agentControlToolCardContext: AgentControlToolCardContext?
    let agentOracleToolCardContext: AgentOracleToolCardContext?
    let promptManager: PromptViewModel?
    var handoffConfig: AgentHandoffConfig?
    let rawToolResultPayload: String?
    let rawToolResultPayloadRenderRevision: Int
    let showRunScopedToolCancel: Bool
    let cancelActiveToolsAction: (() -> Void)?
    let codexManagedLoginAction: CodexManagedLoginAction?
    let runLocallyInsteadAction: (() -> Void)?
    let resendUndeliveredAction: (() -> Void)?
    let linkifiesUserDocumentPaths: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.agentRecentAssistantItemIDs) private var recentAssistantItemIDs
    @Environment(\.agentMessageRuntimeFooterByItemID) private var runtimeFooterByItemID
    @Environment(\.agentAssistantExpansionStore) private var assistantExpansionStore
    @Environment(\.agentAssistantSearchFlashedItemID) private var flashedAssistantItemID
    @StateObject private var fallbackAssistantExpansionStore = AssistantTranscriptExpansionStore()
    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var isStartingCodexManagedLogin = false
    @State private var codexManagedLoginFeedback: String?
    @State private var codexManagedLoginCompleted = false
    @State private var isAskUserExchangeExpanded = false
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    init(
        item: AgentChatItem,
        isMostRecentEditBubble: Bool = false,
        windowID: Int,
        currentWorkspaceID: UUID? = nil,
        currentTabID: UUID? = nil,
        suppressAskUserTranscriptUI: Bool = false,
        contextBuilderContext: ContextBuilderCardContext? = nil,
        agentControlToolCardContext: AgentControlToolCardContext? = nil,
        agentOracleToolCardContext: AgentOracleToolCardContext? = nil,
        promptManager: PromptViewModel? = nil,
        handoffConfig: AgentHandoffConfig? = nil,
        rawToolResultPayload: String? = nil,
        rawToolResultPayloadRenderRevision: Int = 0,
        showRunScopedToolCancel: Bool = false,
        cancelActiveToolsAction: (() -> Void)? = nil,
        codexManagedLoginAction: CodexManagedLoginAction? = nil,
        runLocallyInsteadAction: (() -> Void)? = nil,
        resendUndeliveredAction: (() -> Void)? = nil,
        linkifiesUserDocumentPaths: Bool = false
    ) {
        self.item = item
        self.isMostRecentEditBubble = isMostRecentEditBubble
        self.windowID = windowID
        self.currentWorkspaceID = currentWorkspaceID
        self.currentTabID = currentTabID
        self.suppressAskUserTranscriptUI = suppressAskUserTranscriptUI
        self.contextBuilderContext = contextBuilderContext
        self.agentControlToolCardContext = agentControlToolCardContext
        self.agentOracleToolCardContext = agentOracleToolCardContext
        self.promptManager = promptManager
        self.handoffConfig = handoffConfig
        self.rawToolResultPayload = rawToolResultPayload
        self.rawToolResultPayloadRenderRevision = rawToolResultPayloadRenderRevision
        self.showRunScopedToolCancel = showRunScopedToolCancel
        self.cancelActiveToolsAction = cancelActiveToolsAction
        self.codexManagedLoginAction = codexManagedLoginAction
        self.runLocallyInsteadAction = runLocallyInsteadAction
        self.resendUndeliveredAction = resendUndeliveredAction
        self.linkifiesUserDocumentPaths = linkifiesUserDocumentPaths
    }

    private var runtimeFooter: AgentMessageRuntimeFooter? {
        runtimeFooterByItemID[item.id]
    }

    private var normalizedToolName: String? {
        normalizedToolCardName(item.toolName)?.lowercased()
    }

    private var renderingItem: AgentChatItem {
        guard item.kind == .toolResult,
              let rawToolResultPayload,
              !rawToolResultPayload.isEmpty
        else {
            return item
        }
        var updated = item
        updated.toolResultJSON = rawToolResultPayload
        updated.text = rawToolResultPayload
        return updated
    }

    var body: some View {
        let renderItem = renderingItem
        switch renderItem.kind {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        case .assistantInline:
            assistantInline
        case .toolCall:
            if isHiddenAgentTool(item.toolName) {
                EmptyView()
            } else if isAskUserTool(item.toolName) {
                if suppressAskUserTranscriptUI {
                    EmptyView()
                } else {
                    askUserQuestionPendingView
                }
            } else if normalizedToolName == "context_builder", let contextBuilderContext {
                ContextBuilderCallCard(item: item, context: contextBuilderContext)
            } else {
                ToolCardRouter.callView(
                    for: item,
                    oracleOpenContext: .init(
                        windowID: windowID,
                        workspaceID: currentWorkspaceID,
                        tabID: currentTabID
                    ),
                    contextBuilder: contextBuilderContext,
                    agentControlContext: agentControlToolCardContext,
                    showRunScopedToolCancel: showRunScopedToolCancel,
                    cancelActiveToolsAction: cancelActiveToolsAction
                )
            }
        case .toolResult:
            if isHiddenAgentTool(renderItem.toolName) {
                EmptyView()
            } else if isAskUserTool(renderItem.toolName) {
                askUserQuestionExchangeView
            } else if normalizedToolName == "context_builder", let contextBuilderContext {
                ContextBuilderResultCard(item: renderItem, context: contextBuilderContext)
                    .id(rawToolResultPayloadRenderRevision)
            } else {
                ToolCardRouter.resultView(
                    for: renderItem,
                    isMostRecentEditBubble: isMostRecentEditBubble,
                    oracleOpenContext: .init(
                        windowID: windowID,
                        workspaceID: currentWorkspaceID,
                        tabID: currentTabID
                    ),
                    oracleToolCardContext: agentOracleToolCardContext,
                    contextBuilder: contextBuilderContext,
                    promptManager: promptManager
                )
                .id(rawToolResultPayloadRenderRevision)
            }
        case .system:
            systemBubble
        case .error:
            errorBubble
        case .thinking:
            thinkingBubble
        }
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)

            VStack(alignment: .trailing, spacing: 6) {
                if !item.attachments.isEmpty {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        AgentAttachmentsStrip(
                            imageAttachments: item.attachments,
                            taggedFileAttachments: item.taggedFileAttachments,
                            disabled: true,
                            allowsRemoval: false
                        )
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    if item.isUndeliveredRemoteSend {
                        HStack(spacing: 6) {
                            Text("Undelivered")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                                .foregroundStyle(.red)
                            if let resendUndeliveredAction {
                                Button("Resend", action: resendUndeliveredAction)
                                    .buttonStyle(.plain)
                            }
                        }
                    } else if let recoveryDelivery = item.recoveryDelivery {
                        // Recovery evidence only: no resend action (that is the remote flag's).
                        Text(Self.recoveryDeliveryLabel(recoveryDelivery))
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                            .foregroundStyle(recoveryDelivery == .notSent ? Color.red : Color.orange)
                            .hoverTooltip(Self.recoveryDeliveryHelp(recoveryDelivery))
                    }
                    if item.codexGoalMode != nil || item.workflow != nil {
                        HStack(spacing: 6) {
                            if let codexGoalMode = item.codexGoalMode {
                                codexGoalModeBadge(codexGoalMode, hasWorkflow: item.workflow != nil)
                            }
                            if let workflow = item.workflow {
                                workflowBadge(workflow)
                            }
                        }
                    }
                    if !item.taggedFileAttachments.isEmpty {
                        TaggedFilesBadge(attachments: item.taggedFileAttachments)
                    }
                    CollapsibleUserMessage(
                        text: item.text,
                        linkifiesDocumentPaths: linkifiesUserDocumentPaths
                    )
                }
                .padding(12)
                .background(BubbleColors.lightBlue)
                .cornerRadius(20)
                .opacity(item.isUndeliveredRemoteSend || item.recoveryDelivery != nil ? 0.65 : 1)

                if let scheduledSend = item.scheduledSend {
                    scheduledSendMarker(scheduledSend)
                }

                MessageFooterStrip(text: item.text, timestamp: item.timestamp, isTrailing: true, handoffConfig: handoffConfig, hasHandoffButton: handoffConfig != nil)
            }
        }
    }

    /// R1a label of a user bubble whose earlier-launch intent has no acceptance evidence.
    static func recoveryDeliveryLabel(_ delivery: AgentUserItemRecoveryDelivery) -> String {
        switch delivery {
        case .notSent: "Not sent"
        case .unconfirmed: "Delivery unconfirmed"
        case .notConfirmedByAgent: "Not confirmed"
        }
    }

    static func recoveryDeliveryHelp(_ delivery: AgentUserItemRecoveryDelivery) -> String {
        switch delivery {
        case .notSent:
            // Verified non-delivery says nothing about how RepoPrompt exited (O50).
            "This message was not delivered to the agent."
        case .unconfirmed:
            "RepoPrompt stopped before the agent confirmed this message. Sending it again might duplicate it."
        case .notConfirmedByAgent:
            "The agent didn't confirm it received this message. Sending it again might duplicate it."
        }
    }

    /// Receipt-kind-aware schedule marker: only provider acceptance says "Sent". A saved-in-queue
    /// receipt saved the input for sending; a legacy receipt proves neither.
    static func scheduledSendMarkerText(_ provenance: AgentScheduledSendProvenance) -> String {
        let sentAt = AgentScheduledSendDateFormatting.dateAndTime(provenance.sentAt)
        let outcome = switch provenance.kind {
        case .providerAccepted: "Sent \(sentAt)"
        case .savedInQueue: "Saved for sending \(sentAt)"
        case .legacyUnknown: "Dispatched \(sentAt)"
        }
        return "Scheduled for \(AgentScheduledSendDateFormatting.dateAndTime(provenance.scheduledFor)) · \(outcome)"
    }

    private func scheduledSendMarker(_ provenance: AgentScheduledSendProvenance) -> some View {
        Label {
            Text(Self.scheduledSendMarkerText(provenance))
        } icon: {
            Image(systemName: "clock")
        }
        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
        .foregroundStyle(.secondary.opacity(0.75))
    }

    private func codexGoalModeBadge(_ metadata: AgentCodexGoalModeMetadata, hasWorkflow: Bool) -> some View {
        let labelText: String = switch metadata.action {
        case .setObjective:
            hasWorkflow ? "/goal context" : "/goal"
        case .show:
            "/goal show"
        case .pause:
            "/goal pause"
        case .resume:
            "/goal resume"
        case .clear:
            "/goal clear"
        }
        let tooltip = switch metadata.action {
        case .setObjective where hasWorkflow:
            "This message set a Codex goal. The selected workflow was applied as goal context, not as a separate user turn."
        case .setObjective:
            "This message set a Codex goal."
        case .show, .pause, .resume, .clear:
            "Codex goal control command."
        }

        return HStack(spacing: 4) {
            Image(systemName: "target")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
            Text(labelText)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
        }
        .foregroundColor(.green)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.green.opacity(0.15))
        .clipShape(Capsule())
        .hoverTooltip(tooltip)
        .accessibilityLabel(Text(labelText))
        .accessibilityHint(Text(tooltip))
    }

    private func workflowBadge(_ workflow: AgentWorkflowDefinition) -> some View {
        HStack(spacing: 4) {
            Image(systemName: workflow.iconName)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
            Text(workflow.displayName)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
        }
        .foregroundColor(workflow.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(workflow.accentColor.opacity(0.15))
        .clipShape(Capsule())
    }

    // MARK: - Assistant Bubble (inline style, no bubble)

    private var assistantBubble: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                assistantContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(assistantSearchFlashBackground)

                MessageFooterStrip(
                    text: item.text,
                    timestamp: item.timestamp,
                    isTrailing: false,
                    handoffConfig: handoffConfig,
                    hasHandoffButton: handoffConfig != nil,
                    runtimeFooter: runtimeFooter
                )
            }

            Spacer(minLength: 60)
        }
    }

    // MARK: - Assistant Inline

    private var assistantInline: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                assistantContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(assistantSearchFlashBackground)

                MessageFooterStrip(
                    text: item.text,
                    timestamp: item.timestamp,
                    isTrailing: false,
                    handoffConfig: handoffConfig,
                    hasHandoffButton: handoffConfig != nil,
                    runtimeFooter: runtimeFooter
                )
            }
            Spacer(minLength: 60)
        }
    }

    /// Brief highlight applied to the row transcript search just navigated to. No intra-text
    /// highlighting in v1 — see `AgentAssistantTranscriptSearchMatch`.
    private var assistantSearchFlashBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor.opacity(flashedAssistantItemID == item.id ? 0.14 : 0))
            .animation(.easeOut(duration: 0.5), value: flashedAssistantItemID)
    }

    @ViewBuilder
    private var assistantContent: some View {
        if shouldShowCollapsedAssistantView {
            CollapsibleAssistantTranscriptContent(
                text: item.text,
                itemID: item.id,
                expansionStore: assistantExpansionStore ?? fallbackAssistantExpansionStore
            )
        } else {
            MarkdownTextView(
                text: item.text,
                isMarkdown: true,
                allowInteraction: true,
                detectsMarkdownFilePaths: true,
                renderCadence: item.isStreaming ? .streamingCoalesced : .immediate,
                prefersSynchronousFirstLayout: true
            )
        }
    }

    private var shouldShowCollapsedAssistantView: Bool {
        guard item.kind == .assistant || item.kind == .assistantInline else { return false }
        guard !item.isStreaming else { return false }
        guard !recentAssistantItemIDs.contains(item.id) else { return false }
        guard item.attachments.isEmpty, item.taggedFileAttachments.isEmpty, item.workflow == nil else { return false }
        let lineLimit = 10
        #if DEBUG
            let diagnosticsStartMS = AgentTextDerivationPerfDiagnostics.start()
        #endif
        let boundedLineCount = AgentAssistantLineDerivation.lineCount(upTo: lineLimit, in: item.text)
        let needsCollapse = !boundedLineCount.isExact || boundedLineCount.count > lineLimit
        #if DEBUG
            AgentTextDerivationPerfDiagnostics.record(
                source: .assistantCollapseCheck,
                startMS: diagnosticsStartMS,
                text: item.text,
                lineCount: boundedLineCount.count,
                previewLineCount: lineLimit,
                needsCollapse: needsCollapse,
                expanded: false,
                didSplitFullArray: false,
                fields: [
                    "isStreaming": String(item.isStreaming),
                    "lineCountIsExact": String(boundedLineCount.isExact)
                ]
            )
        #endif
        return needsCollapse
    }

    // MARK: - Tool Call Bubble

    private var toolCallBubble: some View {
        let presentation = toolCallBubblePresentation(toolName: item.toolName, args: item.toolArgsJSON)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 8) {
                    // Header with tool icon and name
                    HStack(spacing: 6) {
                        Image(systemName: presentation.iconName)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                            .foregroundColor(.orange)

                        Text(presentation.title)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold))
                            .foregroundColor(.primary)

                        // Show key argument inline for common tools
                        if let summary = presentation.summary {
                            Text(summary)
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        MessageTimestampText(date: item.timestamp)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                            .foregroundColor(.secondary)
                    }

                    // Arguments (if present and not already summarized inline)
                    if let args = item.toolArgsJSON, !args.isEmpty, shouldShowFullArgs(toolName: item.toolName) {
                        CollapsibleCodeBlock(
                            content: formatJSON(args),
                            language: "json",
                            previewLineCount: 5
                        )
                    }
                }
                .padding(10)
                .background(BubbleColors.toolCallBackground(colorScheme: colorScheme))
                .cornerRadius(12)
            }

            Spacer(minLength: 40)
        }
    }

    // MARK: - Tool Result Bubble

    private var toolResultBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 8) {
                    // Header with tool-specific icon
                    HStack(spacing: 6) {
                        Image(systemName: toolResultIconName(for: item.toolName))
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                            .foregroundColor(.green)

                        Text(toolResultDisplayName(for: item.toolName))
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        // Show result summary if available
                        if let summary = toolResultSummary(toolName: item.toolName, result: item.toolResultJSON) {
                            Text(summary)
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                .foregroundColor(.secondary.opacity(0.8))
                                .lineLimit(1)
                        }

                        Spacer()

                        MessageTimestampText(date: item.timestamp)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                            .foregroundColor(.secondary)
                    }

                    // Result content with appropriate rendering
                    if let result = item.toolResultJSON, !result.isEmpty {
                        ToolResultContentView(
                            content: result,
                            toolName: item.toolName,
                            previewLineCount: previewLineCount(for: item.toolName)
                        )
                    } else if !item.text.isEmpty {
                        Text(item.text)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .background(BubbleColors.toolResultBackground(colorScheme: colorScheme))
                .cornerRadius(12)
            }

            Spacer(minLength: 40)
        }
    }

    // MARK: - Ask User Question Views

    /// Pending question (tool_call state) - shows structured questions while waiting for response
    private var askUserQuestionPendingView: some View {
        let summary = parseAskUserQuestionSummaryRobust(args: item.toolArgsJSON, result: nil)
        return HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 14))
                        .foregroundColor(.blue)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.displayTitle)
                            .font(fontPreset.standardFont)
                            .foregroundColor(.primary)
                            .textSelection(.enabled)

                        if let context = summary.contextLine {
                            Text(context)
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }

                        askUserQuestionList(summary.questions)

                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                            Text("Waiting for response...")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                timestampView
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.blue.opacity(0.2), lineWidth: 1)
            )

            Spacer(minLength: 40)
        }
    }

    /// Completed question exchange (tool_result state) - shows Q&A grouped together
    private var askUserQuestionExchangeView: some View {
        let summary = parseAskUserQuestionSummaryRobust(args: item.toolArgsJSON, result: item.toolResultJSON)
        let isExpanded = !summary.isHistoricalScalar && isAskUserExchangeExpanded
        return HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 14))
                        .foregroundColor(.blue)

                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(summary.displayTitle)
                                    .font(fontPreset.standardFont)
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                                if let status = summary.statusText {
                                    Text(status)
                                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.12))
                                        .cornerRadius(6)
                                        .textSelection(.enabled)
                                }
                            }
                            if let context = summary.contextLine {
                                Text(context)
                                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(isExpanded ? nil : 2)
                                    .textSelection(.enabled)
                            }
                        }

                        AskUserQuestionResultView(summary: summary, isExpanded: isExpanded)

                        if !summary.isHistoricalScalar {
                            Button {
                                if isExpanded {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isAskUserExchangeExpanded.toggle()
                                    }
                                } else {
                                    isAskUserExchangeExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
                                    Text(isExpanded ? "Show less" : "Show full exchange")
                                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                }
                                .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                timestampView
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.blue.opacity(0.2), lineWidth: 1)
            )

            Spacer(minLength: 40)
        }
    }

    private func askUserQuestionList(_ questions: [AskUserQuestionSummary.Question]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(questions.prefix(3).enumerated()), id: \.element.id) { index, question in
                HStack(alignment: .top, spacing: 5) {
                    Text(questions.count == 1 ? "Q" : "Q\(index + 1)")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: questions.count == 1 ? 14 : 22, alignment: .leading)
                    Text(question.question)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            if questions.count > 3 {
                Text("+ \(questions.count - 3) more")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - System Bubble

    private var systemBubble: some View {
        HStack {
            if let summaryLines = legacyTranscriptSummaryLines {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(summaryLines.primary)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        Text(summaryLines.secondary)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10.5, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(
                    minHeight: AgentTranscriptCollapsedCardMetrics.collapsedHeight,
                    maxHeight: AgentTranscriptCollapsedCardMetrics.collapsedHeight,
                    alignment: .leading
                )
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(BubbleColors.toolResultBackground(colorScheme: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                )
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(item.text)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                            .foregroundColor(.secondary)

                        Spacer()

                        MessageTimestampText(date: item.timestamp)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                    }

                    if let runLocallyInsteadAction {
                        Button("Run locally instead", action: runLocallyInsteadAction)
                            .buttonStyle(.plain)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(BubbleColors.toolResultBackground(colorScheme: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - Error Bubble

    private var legacyTranscriptSummaryLines: (primary: String, secondary: String)? {
        let rawParts = item.text
            .components(separatedBy: " • ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard rawParts.count >= 2 else { return nil }
        let joined = item.text.lowercased()
        guard joined.contains("tool called")
            || joined.contains("tools called")
            || joined.contains("hidden tool call")
            || joined.contains("hidden tool calls")
        else {
            return nil
        }
        let firstLineCount = rawParts.count >= 4 ? 2 : 1
        let primary = rawParts.prefix(firstLineCount).joined(separator: " • ")
        let secondary = rawParts.dropFirst(firstLineCount).joined(separator: " • ")
        guard !secondary.isEmpty else { return nil }
        return (primary, secondary)
    }

    private var errorBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                            .foregroundColor(BubbleColors.errorRed)

                        Text(item.text)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 13))
                            .foregroundColor(.primary)
                    }

                    if shouldShowCodexManagedLoginAction {
                        VStack(alignment: .leading, spacing: 6) {
                            if !codexManagedLoginCompleted {
                                Button(action: startCodexManagedChatgptLogin) {
                                    HStack(spacing: 6) {
                                        if isStartingCodexManagedLogin {
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                        Text(isStartingCodexManagedLogin ? "Opening ChatGPT login…" : CodexManagedAuthRecoveryClassifier.loginActionTitle)
                                    }
                                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.primary)
                                .disabled(isStartingCodexManagedLogin)
                            }

                            if let feedback = codexManagedLoginFeedback {
                                Text(feedback)
                                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                    .foregroundColor(codexManagedLoginCompleted ? .secondary : BubbleColors.errorRed)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(BubbleColors.errorBackground(colorScheme: colorScheme))
                .cornerRadius(12)

                MessageFooterStrip(
                    text: item.text,
                    timestamp: item.timestamp,
                    isTrailing: false,
                    hasHandoffButton: false
                )
            }

            Spacer(minLength: 60)
        }
    }

    // MARK: - Thinking Bubble

    private var thinkingBubble: some View {
        HStack(spacing: 0) {
            // Thin left accent bar
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 3)
                .padding(.vertical, 4)

            MarkdownTextView(
                text: item.text,
                isMarkdown: true,
                allowInteraction: true,
                forceTextColor: .secondary.opacity(0.85),
                detectsMarkdownFilePaths: true
            )
            .padding(.vertical, 6)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Prevent the HStack from stretching vertically to fill available space.
        // The RoundedRectangle accent bar (a Shape) is vertically greedy and will
        // expand when the parent offers more height than the text content needs
        // (e.g. when the transcript frame has minHeight: viewportHeight).
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(BubbleColors.thinkingBubbleBackground(colorScheme: colorScheme))
        )
        .padding(.trailing, 60)
    }

    // MARK: - Tool Name Helpers

    /// Check if tool name is a RepoPrompt ask-user variant.
    private func isAskUserTool(_ name: String?) -> Bool {
        MCPIntegrationHelper.isRepoPromptAskUserToolName(name)
    }

    /// Hide internal coordination tools from transcript cards.
    private func isHiddenAgentTool(_ name: String?) -> Bool {
        AgentToolTrackingSupport.shouldHideToolFromTranscript(name)
    }

    // MARK: - Helper Views

    private var timestampView: some View {
        MessageTimestampText(date: item.timestamp)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
            .foregroundColor(.secondary.opacity(0.7))
            .padding(.horizontal, 4)
    }

    private var shouldShowCodexManagedLoginAction: Bool {
        item.kind == .error && CodexManagedAuthRecoveryClassifier.preservesAsUserFacingGuidance(item.text)
    }

    private func startCodexManagedChatgptLogin() {
        guard !isStartingCodexManagedLogin else { return }
        isStartingCodexManagedLogin = true
        codexManagedLoginFeedback = nil
        codexManagedLoginCompleted = false

        Task { @MainActor in
            defer { isStartingCodexManagedLogin = false }
            do {
                guard let codexManagedLoginAction else {
                    codexManagedLoginFeedback = "Codex login is unavailable in this view. Open CLI Providers to sign in."
                    return
                }
                let authenticated = try await codexManagedLoginAction { url in
                    NSWorkspace.shared.open(url)
                }
                guard authenticated else {
                    codexManagedLoginFeedback = "Codex login did not complete. Retry the login or open CLI Providers."
                    return
                }
                codexManagedLoginCompleted = true
                codexManagedLoginFeedback = "Login complete. Send your next message to reconnect Codex."
            } catch {
                codexManagedLoginFeedback = error.localizedDescription
            }
        }
    }

    private func formatJSON(_ jsonString: String) -> String {
        ToolJSON.prettyPrinted(jsonString)
    }

    // MARK: - Tool Display Helpers

    private struct ToolCallBubblePresentation {
        let iconName: String
        let title: String
        let summary: String?
    }

    private func toolCallBubblePresentation(toolName: String?, args: String?) -> ToolCallBubblePresentation {
        let normalized = normalizedToolCardName(toolName) ?? toolName
        let argsObject = parseJSONObject(args)
        let webPresentation = AgentWebToolActionPresentation.classify(AgentWebToolActionInput(
            rawToolName: toolName,
            normalizedToolName: normalized,
            argsObject: argsObject,
            resultObject: nil
        ))
        return ToolCallBubblePresentation(
            iconName: toolIconName(forNormalizedToolName: normalized),
            title: webPresentation?.title ?? toolDisplayName(forNormalizedToolName: normalized),
            summary: webPresentation?.subtitle ?? toolArgsSummary(normalizedToolName: normalized, argsObject: argsObject)
        )
    }

    /// Get appropriate icon for tool call
    private func toolIconName(forNormalizedToolName normalized: String?) -> String {
        switch normalized {
        case "ask_user_question", "ask_user": "questionmark.circle"
        case "read_file": "doc.text"
        case "apply_edits": "pencil"
        case "file_actions": "doc.badge.plus"
        case "file_search": "magnifyingglass.circle"
        case "search", "web_read": "globe"
        case "get_file_tree": "folder"
        case "get_code_structure": "list.bullet.indent"
        case "manage_selection": "checkmark.circle"
        case "workspace_context": "square.stack.3d.up"
        case "ask_oracle", "oracle_send": "brain"
        case "oracle_utils": "brain.head.profile"
        case "chat_send": "bubble.left.and.bubble.right"
        case "context_builder": "sparkles"
        default: "gearshape.fill"
        }
    }

    /// Get human-readable display name for tool
    private func toolDisplayName(forNormalizedToolName normalized: String?) -> String {
        switch normalized {
        case "ask_user_question", "ask_user": "User Question"
        case "read_file": "Read File"
        case "apply_edits": "Edit File"
        case "file_actions": "File Action"
        case "file_search": "Search"
        case "search": "Web Search"
        case "web_read": "Read Web Page"
        case "get_file_tree": "File Tree"
        case "get_code_structure": "Code Structure"
        case "manage_selection": "Selection"
        case "workspace_context": "Context"
        case "ask_oracle", "oracle_send": "Oracle"
        case "oracle_utils": "Oracle Utils"
        case "chat_send": "Chat"
        case "context_builder": "Context Builder"
        case let name?: name
        default: "Tool Call"
        }
    }

    /// Extract key argument for inline display
    private func toolArgsSummary(normalizedToolName: String?, argsObject json: [String: Any]?) -> String? {
        guard let json else { return nil }

        switch normalizedToolName {
        case "ask_user_question", "ask_user":
            if let question = json["question"] as? String {
                return compactSingleLine(question, maxLength: 80)
            }
        case "read_file":
            if let path = json["path"] as? String {
                return shortenPath(path)
            }
        case "apply_edits":
            if let path = json["path"] as? String {
                return shortenPath(path)
            }
        case "file_search":
            if let pattern = json["pattern"] as? String {
                return "\"\(pattern)\""
            }
        case "get_file_tree":
            if let path = json["path"] as? String {
                return shortenPath(path)
            }
        case "manage_selection":
            if let op = json["op"] as? String {
                return op
            }
        case "ask_oracle":
            if let mode = json["mode"] as? String, !mode.isEmpty {
                return mode
            }
            if let message = json["message"] as? String, !message.isEmpty {
                return compactSingleLine(message, maxLength: 80)
            }
        default:
            break
        }
        return nil
    }

    /// Whether to show full args block (hide for simple tools with inline summary)
    private func shouldShowFullArgs(toolName: String?) -> Bool {
        switch toolName {
        case "ask_user_question", "ask_user":
            false
        case "read_file", "get_file_tree":
            false // Path shown inline
        case "manage_selection":
            true // Show full args to see paths
        default:
            true
        }
    }

    /// Shorten a file path for display
    private func shortenPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count <= 2 {
            return path
        }
        // Show last 2 components
        return "..." + components.suffix(2).joined(separator: "/")
    }

    // MARK: - Tool Result Display Helpers

    /// Get icon for tool result
    private func toolResultIconName(for toolName: String?) -> String {
        switch toolName {
        case "ask_user_question", "ask_user": "questionmark.circle.fill"
        case "read_file": "doc.text.fill"
        case "apply_edits": "checkmark.circle.fill"
        case "file_search": "magnifyingglass"
        case "get_file_tree": "folder.fill"
        case "get_code_structure": "list.bullet.indent"
        case "ask_oracle", "oracle_send", "chat_send": "sparkles"
        default: "arrow.turn.down.right"
        }
    }

    /// Get display name for tool result
    private func toolResultDisplayName(for toolName: String?) -> String {
        switch toolName {
        case "ask_user_question", "ask_user": "User Question"
        case "read_file": "File Content"
        case "apply_edits": "Edit Result"
        case "file_search": "Search Results"
        case "get_file_tree": "File Tree"
        case "get_code_structure": "Code Structure"
        case "manage_selection": "Selection Updated"
        case "ask_oracle", "oracle_send": "Oracle Response"
        case "oracle_utils": "Oracle Result"
        case "chat_send": "Chat Response"
        case let name?: "\(name) Result"
        default: "Result"
        }
    }

    /// Extract summary from tool result for header display
    private func toolResultSummary(toolName: String?, result: String?) -> String? {
        guard let result else { return nil }

        switch toolName {
        case "ask_user_question", "ask_user":
            if let resultObject = parseJSONObject(result) {
                let skipped = resultObject["skipped"] as? Bool ?? false
                let timedOut = resultObject["timed_out"] as? Bool ?? false
                let response = resultObject["response"] as? String
                let structuredAnswers = resultObject["answers"] as? [String: Any]
                if skipped {
                    return "Skipped"
                }
                if timedOut {
                    return "Timed out"
                }
                if response?.isEmpty == false || structuredAnswers?.isEmpty == false {
                    return "Answered"
                }
            }
        case "read_file":
            let lines = result.components(separatedBy: "\n").count
            return "\(lines) lines"
        case "file_search":
            // Look for match count in result
            if result.contains("matches") || result.contains("match") {
                if let range = result.range(of: #"(\d+)\s*(match|result)"#, options: .regularExpression) {
                    return String(result[range])
                }
            }
        case "apply_edits":
            if result.contains("✅") || result.lowercased().contains("success") {
                return "Success"
            } else if result.contains("❌") || result.lowercased().contains("failed") {
                return "Failed"
            }
        default:
            break
        }
        return nil
    }

    /// Get preview line count based on tool type
    private func previewLineCount(for toolName: String?) -> Int {
        switch toolName {
        case "ask_user_question", "ask_user": 5
        case "apply_edits": 20 // Show more for diffs
        case "read_file": 15
        case "file_search": 15
        case "get_file_tree": 25
        case "get_code_structure": 20
        default: 10
        }
    }
}

// MARK: - Ask User Question Summary

struct AskUserQuestionSummary {
    struct Option {
        let label: String
        let description: String?
        let isSelected: Bool
    }

    struct Question: Identifiable {
        let id: String
        let header: String?
        let question: String
        let context: String?
        let options: [Option]
        let answer: String?
        let customResponse: String?
        let skipped: Bool
    }

    let title: String?
    let context: String?
    let questions: [Question]
    let skipped: Bool
    let timedOut: Bool
    let isHistoricalScalar: Bool

    var displayTitle: String {
        if let title, !title.isEmpty {
            return questions.count > 1 ? "\(title) (\(questions.count) questions)" : title
        }
        return questions.count == 1 ? "Question" : "Clarifying questions (\(questions.count) questions)"
    }

    var contextLine: String? {
        guard let context, !context.isEmpty else { return nil }
        return context
    }

    var statusText: String? {
        if skipped { return "Skipped" }
        if timedOut { return "Timed out" }
        return nil
    }
}

/// Display-only loss tolerance: consume each entry even when its shape is malformed.
private struct AskUserDisplayValue<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct AskUserQuestionArgs: Decodable {
    struct Option: Decodable {
        let label: String
        let description: String?

        private enum CodingKeys: String, CodingKey {
            case label
            case description
        }

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let label = try? value.decode(String.self) {
                self.label = label
                description = nil
            } else {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                label = try container.decode(String.self, forKey: .label)
                description = try? container.decodeIfPresent(String.self, forKey: .description)
            }
        }
    }

    struct Question: Decodable {
        let id: String?
        let header: String?
        let question: String
        let context: String?
        let options: [Option]

        private enum CodingKeys: String, CodingKey {
            case id
            case header
            case question
            case context
            case options
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            header = try? container.decodeIfPresent(String.self, forKey: .header)
            question = try container.decode(String.self, forKey: .question)
            context = try? container.decodeIfPresent(String.self, forKey: .context)
            options = (try? container.decodeIfPresent([AskUserDisplayValue<Option>].self, forKey: .options))?
                .compactMap(\.value) ?? []
        }
    }

    let title: String?
    let context: String?
    let questions: [(originalIndex: Int, question: Question)]?
    let question: String?

    private enum CodingKeys: String, CodingKey {
        case title
        case context
        case questions
        case question
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        context = try? container.decodeIfPresent(String.self, forKey: .context)
        questions = (try? container.decodeIfPresent([AskUserDisplayValue<Question>].self, forKey: .questions))?
            .enumerated().compactMap { index, entry in
                entry.value.map { (originalIndex: index, question: $0) }
            }
        question = try? container.decodeIfPresent(String.self, forKey: .question)
    }
}

private struct AskUserQuestionResult: Decodable {
    struct Answer: Decodable {
        let answers: [String]?
        let selectedOptions: [String]?
        let customResponse: String?
        let skipped: Bool?

        private enum CodingKeys: String, CodingKey {
            case answers
            case selectedOptions = "selected_options"
            case customResponse = "custom_response"
            case skipped
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            answers = (try? container.decodeIfPresent([AskUserDisplayValue<String>].self, forKey: .answers))?
                .compactMap(\.value)
            selectedOptions = (try? container.decodeIfPresent([AskUserDisplayValue<String>].self, forKey: .selectedOptions))?
                .compactMap(\.value)
            customResponse = try? container.decodeIfPresent(String.self, forKey: .customResponse)
            skipped = try? container.decodeIfPresent(Bool.self, forKey: .skipped)
        }
    }

    let answers: [String: Answer]?
    let response: String?
    let skipped: Bool?
    let timedOut: Bool?

    private enum CodingKeys: String, CodingKey {
        case answers
        case response
        case skipped
        case timedOut = "timed_out"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        answers = (try? container.decodeIfPresent([String: AskUserDisplayValue<Answer>].self, forKey: .answers))?
            .compactMapValues(\.value)
        response = try? container.decodeIfPresent(String.self, forKey: .response)
        skipped = try? container.decodeIfPresent(Bool.self, forKey: .skipped)
        timedOut = try? container.decodeIfPresent(Bool.self, forKey: .timedOut)
    }
}

/// Robust parsing that handles the structured ask_user contract and display-only historical scalar transcripts.
/// Write-side scalar requests are rejected by the MCP API; this parser intentionally keeps old transcript data readable.
func parseAskUserQuestionSummaryRobust(args: String?, result: String?) -> AskUserQuestionSummary {
    let argsDTO = ToolJSON.decode(AskUserQuestionArgs.self, from: args)
    let resultDTO = ToolJSON.decode(AskUserQuestionResult.self, from: result)
    let resultString = result?.trimmingCharacters(in: .whitespacesAndNewlines)
    let structuredQuestions = argsDTO?.questions ?? []
    let isStructured = !structuredQuestions.isEmpty
    let timedOut = resultDTO?.timedOut ?? false
    let skipped = resultDTO?.skipped ?? false

    if isStructured {
        let questions = structuredQuestions.map { originalIndex, question -> AskUserQuestionSummary.Question in
            let fallbackID = "question_\(originalIndex + 1)"
            let id = normalizedNonEmpty(question.id) ?? fallbackID
            let answer = resultDTO?.answers?[id]
            let questionSkipped = answer?.skipped ?? skipped
            let selectedOptions = Set(answer?.selectedOptions?.compactMap(normalizedNonEmpty) ?? [])
            let options = question.options.compactMap { option -> AskUserQuestionSummary.Option? in
                guard let label = normalizedNonEmpty(option.label) else { return nil }
                return AskUserQuestionSummary.Option(
                    label: label,
                    description: normalizedNonEmpty(option.description),
                    isSelected: selectedOptions.contains(label)
                )
            }
            return AskUserQuestionSummary.Question(
                id: id,
                header: normalizedNonEmpty(question.header),
                question: question.question,
                context: normalizedNonEmpty(question.context),
                options: options,
                answer: questionSkipped ? "Skipped" : displayAnswer(from: answer, timedOut: timedOut),
                customResponse: normalizedNonEmpty(answer?.customResponse),
                skipped: questionSkipped
            )
        }
        return AskUserQuestionSummary(
            title: normalizedNonEmpty(argsDTO?.title),
            context: normalizedNonEmpty(argsDTO?.context),
            questions: questions.isEmpty ? [fallbackQuestion()] : questions,
            skipped: skipped,
            timedOut: timedOut,
            isHistoricalScalar: false
        )
    }

    let question = normalizedNonEmpty(argsDTO?.question) ?? "Question"
    let response: String? = {
        if let resultDTO {
            return normalizedNonEmpty(resultDTO.response)
        }
        return normalizedNonEmpty(resultString)
    }()
    let scalarQuestion = AskUserQuestionSummary.Question(
        id: "question",
        header: nil,
        question: question,
        context: nil,
        options: [],
        answer: scalarDisplayAnswer(response: response, skipped: skipped, timedOut: timedOut),
        customResponse: nil,
        skipped: skipped
    )
    return AskUserQuestionSummary(
        title: nil,
        context: nil,
        questions: [scalarQuestion],
        skipped: skipped,
        timedOut: timedOut,
        isHistoricalScalar: true
    )
}

private func parseAskUserQuestionSummary(args: String?, result: String?) -> AskUserQuestionSummary? {
    let argsDTO = ToolJSON.decode(AskUserQuestionArgs.self, from: args)
    guard argsDTO?.question != nil || !(argsDTO?.questions?.isEmpty ?? true) else { return nil }
    return parseAskUserQuestionSummaryRobust(args: args, result: result)
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

private func fallbackQuestion() -> AskUserQuestionSummary.Question {
    AskUserQuestionSummary.Question(
        id: "question",
        header: nil,
        question: "Question",
        context: nil,
        options: [],
        answer: nil,
        customResponse: nil,
        skipped: false
    )
}

private func displayAnswer(from answer: AskUserQuestionResult.Answer?, timedOut: Bool) -> String? {
    guard let answer else { return timedOut ? "No response (timed out)" : nil }
    if answer.skipped == true {
        return "Skipped"
    }
    let explicitAnswers = answer.answers?.compactMap(normalizedNonEmpty) ?? []
    if !explicitAnswers.isEmpty {
        return explicitAnswers.joined(separator: ", ")
    }
    var parts = answer.selectedOptions?.compactMap(normalizedNonEmpty) ?? []
    if let custom = normalizedNonEmpty(answer.customResponse) {
        parts.append(custom)
    }
    if !parts.isEmpty {
        return parts.joined(separator: ", ")
    }
    return timedOut ? "No response (timed out)" : "No response"
}

private func scalarDisplayAnswer(response: String?, skipped: Bool, timedOut: Bool) -> String {
    if skipped { return "Skipped" }
    if timedOut { return response ?? "Timed out" }
    return response ?? "No response"
}

/// Parse JSON object from a raw JSON string (no markdown handling).
private func parseJSONObject(_ jsonString: String?) -> [String: Any]? {
    guard let data = ToolJSON.data(from: jsonString),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let dict = obj as? [String: Any]
    else { return nil }
    return dict
}

private func compactSingleLine(_ text: String, maxLength: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let singleLine = trimmed.replacingOccurrences(of: "\n", with: " ")
    if singleLine.count <= maxLength {
        return singleLine
    }
    let endIndex = singleLine.index(singleLine.startIndex, offsetBy: maxLength)
    return String(singleLine[..<endIndex]) + "..."
}

enum AgentAssistantLineDerivation {
    struct PreviewSummary: Equatable {
        let lineCount: Int
        let previewText: String
        let displayedLineCount: Int
        let remainingLineCount: Int
        let needsCollapse: Bool
    }

    static func lineCount(upTo limit: Int, in text: String) -> (count: Int, isExact: Bool) {
        var count = 1
        guard limit >= count else {
            return (count, false)
        }

        for scalar in text.unicodeScalars where CharacterSet.newlines.contains(scalar) {
            count += 1
            if count > limit {
                return (count, false)
            }
        }
        return (count, true)
    }

    static func previewSummary(for text: String, previewLineCount: Int) -> PreviewSummary {
        let normalizedPreviewLineCount = max(0, previewLineCount)
        let lines = text.components(separatedBy: .newlines)
        return PreviewSummary(
            lineCount: lines.count,
            previewText: lines.prefix(normalizedPreviewLineCount).joined(separator: "\n"),
            displayedLineCount: min(lines.count, normalizedPreviewLineCount),
            remainingLineCount: max(0, lines.count - normalizedPreviewLineCount),
            needsCollapse: lines.count > normalizedPreviewLineCount
        )
    }
}

private struct CollapsibleAssistantTranscriptContent: View {
    let text: String
    /// Stable message ID this row's expansion state is keyed by in `expansionStore`.
    let itemID: UUID
    /// Owned by `AgentModeChatDetailView` for the displayed session; injected via
    /// `agentAssistantExpansionStore` so a manual chevron toggle here and a transcript-search
    /// expand-on-match both route through the same ephemeral, id-keyed store (Workstream 5 item 1).
    @ObservedObject var expansionStore: AssistantTranscriptExpansionStore
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var isExpanded: Bool {
        expansionStore.isExpanded(itemID)
    }

    private let previewLineCount = 10

    private var lineSummary: AgentAssistantLineDerivation.PreviewSummary {
        #if DEBUG
            let diagnosticsStartMS = AgentTextDerivationPerfDiagnostics.start()
        #endif
        let summary = AgentAssistantLineDerivation.previewSummary(
            for: text,
            previewLineCount: previewLineCount
        )
        #if DEBUG
            AgentTextDerivationPerfDiagnostics.record(
                source: .assistantPreview,
                startMS: diagnosticsStartMS,
                text: text,
                lineCount: summary.lineCount,
                previewLineCount: previewLineCount,
                displayedLineCount: isExpanded ? summary.lineCount : summary.displayedLineCount,
                remainingLineCount: summary.remainingLineCount,
                needsCollapse: summary.needsCollapse,
                expanded: isExpanded,
                didSplitFullArray: false
            )
        #endif
        return summary
    }

    var body: some View {
        let summary = lineSummary
        VStack(alignment: .leading, spacing: 6) {
            if isExpanded || !summary.needsCollapse {
                MarkdownTextView(
                    text: text,
                    isMarkdown: true,
                    allowInteraction: true,
                    detectsMarkdownFilePaths: true
                )
            } else {
                Text(summary.previewText)
                    .font(fontPreset.standardFont)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .lineLimit(previewLineCount)
            }

            if summary.needsCollapse {
                Button {
                    if isExpanded {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expansionStore.toggle(itemID)
                        }
                    } else {
                        expansionStore.toggle(itemID)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
                        Text(isExpanded ? "Show less" : "Show \(summary.remainingLineCount) more lines")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct AskUserQuestionResultView: View {
    let summary: AskUserQuestionSummary
    let isExpanded: Bool
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(summary.questions.enumerated()), id: \.element.id) { index, question in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(summary.questions.count == 1 ? "Q" : "Q\(index + 1)")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: summary.questions.count == 1 ? 14 : 22, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            if let header = question.header {
                                Text(header)
                                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                                    .foregroundColor(.primary)
                            }
                            Text(question.question)
                                .font(fontPreset.standardFont)
                                .foregroundColor(.primary)
                                .lineLimit(isExpanded ? nil : 3)
                                .textSelection(.enabled)

                            if isExpanded {
                                if let context = question.context {
                                    Text(context)
                                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                }

                                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: option.isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                            .foregroundColor(option.isSelected ? .blue : .secondary)
                                            .accessibilityLabel(option.isSelected ? "Selected option" : "Unselected option")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(option.label)
                                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                                .foregroundColor(.primary)
                                                .textSelection(.enabled)
                                            if let description = option.description {
                                                Text(description)
                                                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                                    .foregroundColor(.secondary)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    HStack(alignment: .top, spacing: 6) {
                        Text("A")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: summary.questions.count == 1 ? 14 : 22, alignment: .leading)
                        Text(question.answer ?? "No response")
                            .font(fontPreset.standardFont)
                            .foregroundColor(question.skipped || summary.timedOut ? .secondary : .primary)
                            .lineLimit(isExpanded ? nil : 3)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
}

// MARK: - Shared Components

// CollapsibleUserMessage is now in Common/CollapsibleUserMessage.swift

// MARK: - Tool Result Content View

/// Renders tool result content with markdown support and collapsible preview
struct ToolResultContentView: View {
    let content: String
    let toolName: String?
    let previewLineCount: Int

    @State private var isExpanded = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    init(content: String, toolName: String? = nil, previewLineCount: Int = 10) {
        self.content = content
        self.toolName = toolName
        self.previewLineCount = previewLineCount
    }

    private var lines: [String] {
        #if DEBUG
            let diagnosticsStartMS = AgentTextDerivationPerfDiagnostics.start()
        #endif
        let derivedLines = content.components(separatedBy: "\n")
        #if DEBUG
            let diagnosticsIsDiff = diagnosticsStartMS == nil ? nil : isDiffContent
            let diagnosticsIsJSON = diagnosticsStartMS == nil ? nil : isJSONContent
            AgentTextDerivationPerfDiagnostics.record(
                source: .toolResultPreview,
                startMS: diagnosticsStartMS,
                text: content,
                lineCount: derivedLines.count,
                previewLineCount: previewLineCount,
                displayedLineCount: isExpanded ? derivedLines.count : min(derivedLines.count, previewLineCount),
                remainingLineCount: max(0, derivedLines.count - previewLineCount),
                needsCollapse: derivedLines.count > previewLineCount,
                expanded: isExpanded,
                toolName: toolName,
                isDiff: diagnosticsIsDiff,
                isJSON: diagnosticsIsJSON,
                didSplitFullArray: true
            )
        #endif
        return derivedLines
    }

    private var needsCollapse: Bool {
        lines.count > previewLineCount
    }

    private var displayContent: String {
        if isExpanded || !needsCollapse {
            return content
        }
        return lines.prefix(previewLineCount).joined(separator: "\n")
    }

    private var remainingLineCount: Int {
        max(0, lines.count - previewLineCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Render based on content type
            if isDiffContent {
                // Render diffs with syntax highlighting
                DiffContentView(content: displayContent)
            } else if isJSONContent {
                // Render JSON with formatting
                CollapsibleCodeBlock(
                    content: prettyPrintJSON(displayContent),
                    language: "json",
                    previewLineCount: previewLineCount
                )
            } else {
                CodeBlock(content: displayContent, allowTextInteraction: true)
            }

            if needsCollapse, !isDiffContent, !isJSONContent {
                expandCollapseButton
            }
        }
    }

    /// Pretty print JSON if possible
    private func prettyPrintJSON(_ jsonString: String) -> String {
        #if DEBUG
            let diagnosticsStartMS = AgentTextDerivationPerfDiagnostics.start()
        #endif
        let output: String
        let didPrettyPrint: Bool
        if let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: prettyData, encoding: .utf8)
        {
            output = prettyString
            didPrettyPrint = true
        } else {
            output = jsonString
            didPrettyPrint = false
        }
        #if DEBUG
            AgentTextDerivationPerfDiagnostics.record(
                source: .toolResultJSONPrettyPrint,
                startMS: diagnosticsStartMS,
                text: jsonString,
                toolName: toolName,
                isJSON: true,
                fields: ["prettyPrinted": String(didPrettyPrint)]
            )
        #endif
        return output
    }

    private var looksLikeMarkdown: Bool {
        false
    }

    /// Check if content looks like a diff
    private var isDiffContent: Bool {
        let diffIndicators = [
            "--- a/",
            "+++ b/",
            "@@ ",
            "Unified Diff",
            "### Unified Diff"
        ]
        return diffIndicators.contains { content.contains($0) }
    }

    /// Check if content is JSON
    private var isJSONContent: Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
            (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
    }

    private var expandCollapseButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
                Text(isExpanded ? "Show less" : "Show \(remainingLineCount) more lines")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(PlainButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Diff Content View

/// Renders diff content with proper syntax highlighting for additions/deletions
private struct DiffContentView: View {
    let content: String
    @State private var isExpanded = false
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private let previewLineCount = 20

    private var lines: [String] {
        #if DEBUG
            let diagnosticsStartMS = AgentTextDerivationPerfDiagnostics.start()
        #endif
        let derivedLines = content.components(separatedBy: "\n")
        #if DEBUG
            AgentTextDerivationPerfDiagnostics.record(
                source: .diffPreview,
                startMS: diagnosticsStartMS,
                text: content,
                lineCount: derivedLines.count,
                previewLineCount: previewLineCount,
                displayedLineCount: isExpanded ? derivedLines.count : min(derivedLines.count, previewLineCount),
                remainingLineCount: max(0, derivedLines.count - previewLineCount),
                needsCollapse: derivedLines.count > previewLineCount,
                expanded: isExpanded,
                isDiff: true,
                didSplitFullArray: true
            )
        #endif
        return derivedLines
    }

    private var needsCollapse: Bool {
        lines.count > previewLineCount
    }

    private var displayLines: [String] {
        if isExpanded || !needsCollapse {
            return lines
        }
        return Array(lines.prefix(previewLineCount))
    }

    private var remainingLineCount: Int {
        max(0, lines.count - previewLineCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                        diffLine(line)
                    }
                }
            }
            .font(fontPreset.swiftUIFont(sizeAtNormal: 11, design: .monospaced))
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .cornerRadius(6)

            if needsCollapse {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
                        Text(isExpanded ? "Show less" : "Show \(remainingLineCount) more lines")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func diffLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        HStack(spacing: 0) {
            if trimmed.hasPrefix("+") && !trimmed.hasPrefix("+++") {
                // Addition line
                Text(line)
                    .foregroundColor(Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.1))
            } else if trimmed.hasPrefix("-") && !trimmed.hasPrefix("---") {
                // Deletion line
                Text(line)
                    .foregroundColor(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
            } else if trimmed.hasPrefix("@@") {
                // Hunk header
                Text(line)
                    .foregroundColor(Color.cyan)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cyan.opacity(0.1))
            } else if trimmed.hasPrefix("---") || trimmed.hasPrefix("+++") {
                // File header
                Text(line)
                    .foregroundColor(Color.secondary)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Context line
                Text(line)
                    .foregroundColor(Color.primary.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Tagged Files Badge

enum TaggedFilesBadgeInteractionKind: Equatable {
    case none
    case button
    case menu
}

struct TaggedFilesBadgePreviewTarget: Identifiable {
    let id: UUID
    let displayName: String
    let target: MarkdownFileLinkTarget
}

@MainActor
enum TaggedFilesBadgeInteraction {
    static func previewTargets(
        in attachments: [AgentTaggedFileAttachment]
    ) -> [TaggedFilesBadgePreviewTarget] {
        attachments.compactMap { attachment in
            guard
                let target = MarkdownFileLinkTarget.canonicalFilePath(attachment.relativePath),
                AgentTranscriptPreviewLinkRoutingPolicy.isPreviewable(target)
            else {
                return nil
            }
            return TaggedFilesBadgePreviewTarget(
                id: attachment.id,
                displayName: attachment.displayName,
                target: target
            )
        }
    }

    static func kind(for targets: [TaggedFilesBadgePreviewTarget]) -> TaggedFilesBadgeInteractionKind {
        switch targets.count {
        case 0: .none
        case 1: .button
        default: .menu
        }
    }

    static func open(
        _ target: TaggedFilesBadgePreviewTarget,
        using opener: MarkdownFileLinkOpener
    ) async -> Bool {
        await opener.open(target.target)
    }
}

/// Compact badge showing attached file name(s) in a user message bubble.
/// Shows the file name for a single file, or "+N files attached" for multiple.
private struct TaggedFilesBadge: View {
    let attachments: [AgentTaggedFileAttachment]
    @Environment(\.markdownFileLinkOpener) private var markdownFileLinkOpener
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        let targets = TaggedFilesBadgeInteraction.previewTargets(in: attachments)
        if let markdownFileLinkOpener {
            switch TaggedFilesBadgeInteraction.kind(for: targets) {
            case .none:
                badgeLabel
            case .button:
                Button {
                    open(targets[0], using: markdownFileLinkOpener)
                } label: {
                    badgeLabel
                }
                .buttonStyle(.plain)
            case .menu:
                Menu {
                    ForEach(targets) { target in
                        Button(target.displayName) {
                            open(target, using: markdownFileLinkOpener)
                        }
                    }
                } label: {
                    badgeLabel
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        } else {
            badgeLabel
        }
    }

    private var badgeLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "paperclip")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
            Text(label)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.1))
        .clipShape(Capsule())
    }

    private func open(
        _ target: TaggedFilesBadgePreviewTarget,
        using opener: MarkdownFileLinkOpener
    ) {
        Task { @MainActor in
            _ = await TaggedFilesBadgeInteraction.open(target, using: opener)
        }
    }

    private var label: String {
        switch attachments.count {
        case 1:
            attachments[0].displayName
        default:
            "+\(attachments.count) files attached"
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct AgentMessageBubble_Previews: PreviewProvider {
        static var previews: some View {
            ScrollView {
                VStack(spacing: 12) {
                    AgentMessageBubble(item: .user("Hello, can you help me with my code?"), windowID: 0)

                    AgentMessageBubble(item: .assistant("Of course! I'd be happy to help. What would you like to work on?"), windowID: 0)

                    AgentMessageBubble(item: .toolCall(name: "read_file", argsJSON: "{\"path\": \"/src/main.swift\"}"), windowID: 0)

                    AgentMessageBubble(item: .toolResult(name: "read_file", resultJSON: "import Foundation\n\nfunc main() {\n    print(\"Hello\")\n}"), windowID: 0)

                    AgentMessageBubble(item: .system("Agent started"), windowID: 0)

                    AgentMessageBubble(item: .error("Failed to read file: Permission denied"), windowID: 0)

                    AgentMessageBubble(item: .thinking("Analyzing the codebase..."), windowID: 0)
                }
                .padding()
            }
            .frame(width: 500, height: 600)
        }
    }
#endif
