import RepoPromptAgentCore
import RepoPromptUI
import SwiftUI

func performAgentToolCardExpansionStateUpdateWithoutAnimation(_ update: () -> Void) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
        update()
    }
}

extension EnvironmentValues {
    @Entry var agentToolCardAutoExpandEnabled: Bool = true

    @Entry var agentLiveBashExecutionByItemID: [UUID: AgentBashLiveExecutionState] = [:]

    @Entry var agentRecentAssistantItemIDs: Set<UUID> = []

    @Entry var agentMessageRuntimeFooterByItemID: [UUID: AgentMessageRuntimeFooter] = [:]

    @Entry var agentApprovalVisible: Bool = false

    /// Ephemeral, id-keyed collapse state for assistant transcript messages (Workstream 5 item 1).
    /// Nil avoids constructing a main-actor store as a nonisolated EnvironmentValues default.
    @Entry var agentAssistantExpansionStore: AssistantTranscriptExpansionStore?

    /// The assistant message ID transcript search just navigated to, so its row can briefly
    /// flash. Cleared automatically by `AgentAssistantTranscriptSearchViewModel`.
    @Entry var agentAssistantSearchFlashedItemID: UUID?
}

enum AgentToolCardRenderedBashPhase: String, Equatable {
    case live
    case completed
}

enum AgentToolCardRenderMode: String, Equatable {
    case diffPreview
    case toolSpecificNoDiff
    case markdownFallback
}

struct AgentToolCardRenderState: Equatable {
    let itemID: UUID
    let toolName: String
    let isExpanded: Bool
    let bashPhase: AgentToolCardRenderedBashPhase?
    let renderMode: AgentToolCardRenderMode?
}

struct AgentToolCardRenderStatePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: AgentToolCardRenderState] = [:]

    static func reduce(value: inout [UUID: AgentToolCardRenderState], nextValue: () -> [UUID: AgentToolCardRenderState]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Shared container providing consistent UI chrome for all tool cards
/// Supports collapsed (1-line summary) and expanded states via isExpanded binding
struct ToolCardContainer<Content: View>: View {
    let iconName: String
    let iconColor: Color
    let title: String
    /// Optional small source label (for example an external MCP server) shown after the title.
    let sourceLabel: String?
    let headerStatusText: String?
    let detailText: String?
    let subtitle: String?
    let status: ToolCardStatus
    let timestamp: Date?
    let showsTimestamp: Bool
    let headerTrailingView: AnyView?
    let isExpandable: Bool
    let managesOwnExpansion: Bool
    let debugItemID: UUID?
    let debugToolName: String?
    let debugBashPhase: AgentToolCardRenderedBashPhase?
    let debugRenderMode: AgentToolCardRenderMode?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    init(
        iconName: String,
        iconColor: Color = .orange,
        title: String,
        sourceLabel: String? = nil,
        headerStatusText: String? = nil,
        detailText: String? = nil,
        subtitle: String? = nil,
        status: ToolCardStatus = .neutral,
        timestamp: Date? = nil,
        showsTimestamp: Bool = true,
        headerTrailingView: AnyView? = nil,
        isExpandable: Bool = true,
        debugItemID: UUID? = nil,
        debugToolName: String? = nil,
        debugBashPhase: AgentToolCardRenderedBashPhase? = nil,
        debugRenderMode: AgentToolCardRenderMode? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.iconName = iconName
        self.iconColor = iconColor
        self.title = title
        self.sourceLabel = ToolCardSourceLabel.displayText(sourceLabel)
        self.headerStatusText = headerStatusText
        self.detailText = detailText
        self.subtitle = subtitle
        self.status = status
        self.timestamp = timestamp
        self.showsTimestamp = showsTimestamp
        self.headerTrailingView = headerTrailingView
        self.isExpandable = isExpandable
        managesOwnExpansion = false
        self.debugItemID = debugItemID
        self.debugToolName = debugToolName
        self.debugBashPhase = debugBashPhase
        self.debugRenderMode = debugRenderMode
        _isExpanded = isExpanded
        self.content = content
    }

    init(
        iconName: String,
        iconColor: Color = .orange,
        title: String,
        sourceLabel: String? = nil,
        headerStatusText: String? = nil,
        detailText: String? = nil,
        subtitle: String? = nil,
        status: ToolCardStatus = .neutral,
        timestamp: Date? = nil,
        showsTimestamp: Bool = true,
        headerTrailingView: AnyView? = nil,
        isExpandable: Bool = true,
        managesOwnExpansion: Bool,
        debugItemID: UUID? = nil,
        debugToolName: String? = nil,
        debugBashPhase: AgentToolCardRenderedBashPhase? = nil,
        debugRenderMode: AgentToolCardRenderMode? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.iconName = iconName
        self.iconColor = iconColor
        self.title = title
        self.sourceLabel = ToolCardSourceLabel.displayText(sourceLabel)
        self.headerStatusText = headerStatusText
        self.detailText = detailText
        self.subtitle = subtitle
        self.status = status
        self.timestamp = timestamp
        self.showsTimestamp = showsTimestamp
        self.headerTrailingView = headerTrailingView
        self.isExpandable = isExpandable
        self.managesOwnExpansion = managesOwnExpansion
        self.debugItemID = debugItemID
        self.debugToolName = debugToolName
        self.debugBashPhase = debugBashPhase
        self.debugRenderMode = debugRenderMode
        _isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        HStack {
            cardBody
            Spacer(minLength: 40)
        }
        .preference(key: AgentToolCardRenderStatePreferenceKey.self, value: debugRenderStatePreference)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            // Header row (always visible - serves as 1-line summary when collapsed)
            // Entire row is clickable to expand/collapse when expandable
            if isExpandable {
                if headerTrailingView == nil {
                    Button(action: toggleExpansion) {
                        headerRow
                    }
                    .buttonStyle(.plain)
                } else {
                    expandableHeaderRowWithTrailingControl
                }
            } else {
                headerRow
            }

            // Content area (only shown when expanded)
            if isExpanded, isExpandable {
                content()
            }
        }
        .padding(10)
        .background(backgroundColor)
        .cornerRadius(12)
        .contentShape(Rectangle())
    }

    private func toggleExpansion() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isExpanded.toggle()
        }
    }

    private var expandableHeaderRowWithTrailingControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button(action: toggleExpansion) {
                    headerLeadingContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if let headerTrailingView {
                    headerTrailingView
                } else if showsTimestamp, let timestamp {
                    MessageTimestampText(date: timestamp)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }

            if let detailText {
                Button(action: toggleExpansion) {
                    headerDetailText(detailText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                headerLeadingContent
                Spacer()

                if let headerTrailingView {
                    headerTrailingView
                } else if showsTimestamp, let timestamp {
                    MessageTimestampText(date: timestamp)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }

            if let detailText {
                headerDetailText(detailText)
            }
        }
    }

    private var headerLeadingContent: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundColor(iconColor)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .layoutPriority(ToolCardSourceLabel.titleLayoutPriority(hasSourceLabel: sourceLabel != nil))

            if let sourceLabel {
                ToolCardSourceLabelText(text: sourceLabel)
            }

            if let headerStatusText, !headerStatusText.isEmpty {
                StatusBadge(text: headerStatusText, status: status)
            } else {
                StatusDot(status: status, size: 6)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func headerDetailText(_ detailText: String) -> some View {
        Text(detailText)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 17)
    }

    private var backgroundColor: Color {
        switch status {
        case .running:
            BubbleColors.toolCallBackground(colorScheme: colorScheme)
        case .failure:
            BubbleColors.errorBackground(colorScheme: colorScheme)
        default:
            BubbleColors.toolResultBackground(colorScheme: colorScheme)
        }
    }

    private var debugRenderStatePreference: [UUID: AgentToolCardRenderState] {
        guard let debugItemID,
              let debugToolName,
              !debugToolName.isEmpty
        else {
            return [:]
        }
        return [
            debugItemID: AgentToolCardRenderState(
                itemID: debugItemID,
                toolName: debugToolName,
                isExpanded: isExpanded && isExpandable,
                bashPhase: debugBashPhase,
                renderMode: debugRenderMode
            )
        ]
    }
}

// MARK: - Static Tool Card Container (Non-Expandable)

/// Container for tool cards that don't need expansion (e.g., tool calls in progress)
struct StaticToolCardContainer<Content: View>: View {
    let iconName: String
    let iconColor: Color
    let title: String
    /// Optional small source label (for example an external MCP server) shown after the title.
    let sourceLabel: String?
    let subtitle: String?
    let status: ToolCardStatus
    let timestamp: Date?
    let showsTimestamp: Bool
    let headerTrailingView: AnyView?
    let onTap: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    init(
        iconName: String,
        iconColor: Color = .orange,
        title: String,
        sourceLabel: String? = nil,
        subtitle: String? = nil,
        status: ToolCardStatus = .neutral,
        timestamp: Date? = nil,
        showsTimestamp: Bool = true,
        headerTrailingView: AnyView? = nil,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.iconName = iconName
        self.iconColor = iconColor
        self.title = title
        self.sourceLabel = ToolCardSourceLabel.displayText(sourceLabel)
        self.subtitle = subtitle
        self.status = status
        self.timestamp = timestamp
        self.showsTimestamp = showsTimestamp
        self.headerTrailingView = headerTrailingView
        self.onTap = onTap
        self.content = content
    }

    var body: some View {
        Group {
            if let onTap, headerTrailingView == nil {
                Button(action: onTap) {
                    cardBody
                }
                .buttonStyle(.plain)
            } else if let onTap {
                cardBodyWithLeadingTap(onTap)
            } else {
                cardBody
            }
        }
    }

    private var cardBody: some View {
        HStack {
            cardContent {
                standardHeaderRow
            }

            Spacer(minLength: 40)
        }
    }

    private func cardBodyWithLeadingTap(_ onTap: @escaping () -> Void) -> some View {
        HStack {
            cardContent {
                standardHeaderRow(tappableLeadingAction: onTap)
            }

            Spacer(minLength: 40)
        }
    }

    private func cardContent(@ViewBuilder header: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header()
            content()
        }
        .padding(10)
        .background(backgroundColor)
        .cornerRadius(12)
        .contentShape(Rectangle())
    }

    private var standardHeaderRow: some View {
        standardHeaderRow(tappableLeadingAction: nil)
    }

    private func standardHeaderRow(tappableLeadingAction: (() -> Void)?) -> some View {
        HStack(spacing: 6) {
            if let tappableLeadingAction {
                HStack(spacing: 6) {
                    headerLeadingContent
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: tappableLeadingAction)
            } else {
                headerLeadingContent
                Spacer()
            }

            if let headerTrailingView {
                headerTrailingView
            } else if showsTimestamp, let timestamp {
                MessageTimestampText(date: timestamp)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }

    private var headerLeadingContent: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundColor(iconColor)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .layoutPriority(ToolCardSourceLabel.titleLayoutPriority(hasSourceLabel: sourceLabel != nil))

            if let sourceLabel {
                ToolCardSourceLabelText(text: sourceLabel)
            }

            StatusDot(status: status, size: 6)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .running:
            BubbleColors.toolCallBackground(colorScheme: colorScheme)
        case .failure:
            BubbleColors.errorBackground(colorScheme: colorScheme)
        default:
            BubbleColors.toolResultBackground(colorScheme: colorScheme)
        }
    }
}

// MARK: - Tool Card Source Label

/// Pure presentation rules for the optional header source label shared by both containers.
enum ToolCardSourceLabel {
    /// Trimmed label, or nil when absent or blank so blank labels never render an empty chip.
    static func displayText(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// The title keeps the default priority without a source label, so existing cards lay out
    /// unchanged. With a label, the action title wins space first at narrow header widths and the
    /// source label and subtitle truncate before it.
    static func titleLayoutPriority(hasSourceLabel: Bool) -> Double {
        hasSourceLabel ? 1 : 0
    }
}

/// Small secondary label for the tool source (for example `BusyCal`) next to the card title.
struct ToolCardSourceLabelText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityLabel("Source: \(text)")
    }
}

// MARK: - Tool Card Cancel Button

/// Plain cancel button for the far-right header slot of running RepoPrompt MCP tool cards.
struct ToolCardCancelButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Cancel")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

// MARK: - Path Helpers

/// Shorten a file path for display (show last 2 components)
func shortenPath(_ path: String) -> String {
    let components = path.split(separator: "/")
    if components.count <= 2 {
        return path
    }
    return "…/" + components.suffix(2).joined(separator: "/")
}

/// Extract just the filename from a path
func fileName(from path: String) -> String {
    (path as NSString).lastPathComponent
}

// MARK: - Preview

#if DEBUG
    struct ToolCardContainer_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 12) {
                PreviewExpandableCard()

                StaticToolCardContainer(
                    iconName: "folder",
                    iconColor: .orange,
                    title: "File Tree",
                    subtitle: "5 roots",
                    status: .success,
                    timestamp: Date()
                ) {
                    EmptyView()
                }

                StaticToolCardContainer(
                    iconName: "magnifyingglass.circle",
                    iconColor: .orange,
                    title: "Search",
                    subtitle: "\"TODO\"",
                    status: .warning,
                    timestamp: Date()
                ) {
                    StatusBadge(text: "Partial", status: .warning)
                }
            }
            .padding()
            .frame(width: 400)
        }
    }

    private struct PreviewExpandableCard: View {
        @State private var isExpanded = false

        var body: some View {
            ToolCardContainer(
                iconName: "doc.text",
                title: "Read File",
                subtitle: "main.swift \u{2022} Lines 1-50 of 200",
                status: .success,
                timestamp: Date(),
                isExpanded: $isExpanded
            ) {
                Text("File content would go here...")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
#endif
