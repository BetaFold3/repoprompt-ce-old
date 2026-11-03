import RepoPromptAgentCore
import RepoPromptUI
import SwiftUI

struct AgentRemoteControlDeviceBadgeText: Equatable {
    let label: String
    let badgeTooltip: String
    let statusPlateTooltip: String
}

extension AgentSidebarScheduledSendStatus {
    var tooltipText: String {
        func scheduledText(_ date: Date?) -> String {
            date.map { "Scheduled for \(AgentScheduledSendDateFormatting.dateAndTime($0))" }
                ?? "Scheduled message"
        }
        switch self {
        case let .pending(date):
            return scheduledText(date)
        case let .dispatching(date):
            return scheduledText(date) + " · Sending"
        case let .needsConfirmation(date):
            return scheduledText(date) + " · Needs confirmation"
        case let .failed(date):
            return scheduledText(date) + " · Send failed"
        case .unreadable:
            return "Unreadable scheduled message · Open chat to review"
        case let .sent(provenance):
            return "Scheduled for \(AgentScheduledSendDateFormatting.dateAndTime(provenance.scheduledFor))"
                + " · Sent \(AgentScheduledSendDateFormatting.dateAndTime(provenance.sentAt))"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .needsConfirmation, .failed, .unreadable:
            true
        case .pending, .dispatching, .sent:
            false
        }
    }
}

// MARK: - Agent Session Row

struct AgentSessionRow: View {
    let title: String
    let isActive: Bool
    let isPinned: Bool
    let isMCPControlled: Bool
    let runState: AgentSessionRunState
    let isWaiting: Bool
    /// When non-nil, the session raised a completed/failed/waiting transition
    /// while the user was NOT viewing it. Drives a persistent attention badge
    /// that survives re-renders until the session is selected/resumed or the
    /// user dismisses the badge explicitly.
    var attentionRunState: AgentSessionRunState?
    var remoteHostName: String?
    var remoteHostAbbreviation: String?
    var remoteControlDeviceID: String?
    var remoteControlDeviceDisplayName: String?
    /// Bound-worktree visual identity for this session (Item 10). When non-nil,
    /// a small colored dot/ring is overlaid at the bottom-right of the status
    /// plate without shifting the title — see `worktreeMarker`.
    var worktree: AgentWorktreeIndicator?
    /// Active worktree merge attention for this session (Item 8). When non-nil
    /// the row paints a compact merge marker after the title slot and exposes
    /// it through the row's hover tooltip and accessibility label without
    /// shifting layout — see `mergeAttentionBadge`.
    var worktreeMergeAttention: AgentWorktreeMergeAttention?
    var scheduledSendStatus: AgentSidebarScheduledSendStatus?
    /// Delegated ask_user legibility (plan §6.5): a compact badge that never takes focus.
    var delegatedQuestionAttention: AgentDelegatedQuestionSidebarAttention?
    let threadDepth: Int
    var hasThreadChildren: Bool = false
    var isThreadCollapsed: Bool = false
    var hiddenThreadDescendantCount: Int = 0
    /// Number of descendants hidden under this collapsed parent that carry
    /// an unseen run-state attention badge. When > 0 the hidden-count chip is
    /// tinted to mirror the mcp-status-style "something happened" cue.
    var hiddenThreadDescendantAttentionCount: Int = 0
    var onToggleThreadCollapse: (() -> Void)?
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onStash: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    var onDismissAttention: (() -> Void)?

    @State private var isHovered = false
    @State private var isPinHovered = false
    @State private var isDeleteHovered = false
    @State private var isRenameHovered = false
    @State private var isStashHovered = false
    @State private var isDisclosureHovered = false
    @State private var isDismissAttentionHovered = false
    @State private var showRenameAlert = false
    @State private var showDeleteConfirmation = false
    @State private var renameText = ""
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var rowMinHeight: CGFloat {
        fontPreset.scaledClamped(28, min: 28, max: 38)
    }

    private var rowHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    private var rowVerticalPadding: CGFloat {
        fontPreset.scaledClamped(4, max: 7)
    }

    private var rowCornerRadius: CGFloat {
        fontPreset.scaledClamped(14, max: 18)
    }

    private var rowSpacing: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var titlePinSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    private var titleVStackSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    private var pinFontSize: CGFloat {
        fontPreset.scaledClamped(10, max: 13)
    }

    private var chipHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(5, max: 7)
    }

    private var chipVerticalPadding: CGFloat {
        fontPreset.scaledClamped(1, max: 2)
    }

    private var leadingIndent: CGFloat {
        CGFloat(threadDepth) * fontPreset.scaledClamped(14, min: 14, max: 20)
    }

    private var showsDisclosureChevron: Bool {
        threadDepth == 0 && hasThreadChildren && onToggleThreadCollapse != nil
    }

    private var hiddenCountTooltip: String {
        let base = hiddenThreadDescendantCount == 1
            ? "1 sub-agent chat hidden"
            : "\(hiddenThreadDescendantCount) sub-agent chats hidden"
        guard hiddenThreadDescendantAttentionCount > 0 else { return base }
        let suffix = hiddenThreadDescendantAttentionCount == 1
            ? "1 needs attention"
            : "\(hiddenThreadDescendantAttentionCount) need attention"
        return base + " — " + suffix
    }

    private var disclosureAccessibilityLabel: String {
        isThreadCollapsed ? "Expand sub-agent chats" : "Collapse sub-agent chats"
    }

    private var pinActionLabel: String {
        isPinned ? "Unpin chat" : "Pin chat"
    }

    private var renameActionLabel: String {
        "Rename chat"
    }

    private var stashActionLabel: String {
        "Stash chat for later"
    }

    private var dismissAttentionActionLabel: String {
        "Dismiss status badge"
    }

    private var deleteActionLabel: String {
        "Delete chat"
    }

    private func beginRename() {
        renameText = title
        showRenameAlert = true
    }

    private func requestDeleteConfirmation() {
        showDeleteConfirmation = true
    }

    var body: some View {
        HStack(spacing: rowSpacing) {
            if threadDepth > 0 {
                Spacer()
                    .frame(width: leadingIndent)
            }

            // MCP-controlled cue is folded into the existing status plate
            // (orange-tinted dot/chevron + orange running arc) so it no
            // longer pushes the title sideways. See `mcpAccentColor`,
            // `plateGlyph`, and `AgentRowActivityArc(tint:)` below.

            // Unified 14pt status plate.
            //
            // One slot carries both the row's identity glyph (chevron for
            // expandable roots, arrow for sub-agents, anchor dot or attention
            // glyph for leaf roots) AND its run-state status (plate fill +
            // optional halo + optional running arc). Folding both into a
            // single slot keeps the title's leading X stable regardless of
            // run state — previously the title shifted ~14pt sideways when a
            // row transitioned in/out of running/waiting/failed.
            statusPlate

            // Session name
            VStack(alignment: .leading, spacing: titleVStackSpacing) {
                HStack(spacing: titlePinSpacing) {
                    Text(title)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let scheduledSendStatus {
                        scheduledSendBadge(for: scheduledSendStatus)
                    }

                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: pinFontSize))
                            .foregroundStyle(.secondary)
                    }

                    if let attention = worktreeMergeAttention {
                        mergeAttentionBadge(for: attention)
                    }

                    if let delegatedQuestionAttention, !delegatedQuestionAttention.isEmpty {
                        delegatedQuestionBadge(for: delegatedQuestionAttention)
                    }

                    if let remoteHostName {
                        remoteHostBadge(hostName: remoteHostName, abbreviation: remoteHostAbbreviation)
                    }

                    if let remoteControlDeviceID {
                        remoteControlledBadge(
                            deviceID: remoteControlDeviceID,
                            displayName: remoteControlDeviceDisplayName
                        )
                    }

                    if isThreadCollapsed, hiddenThreadDescendantCount > 0 {
                        hiddenCountChip
                    }
                }
            }

            Spacer()

            // Trailing indicator (checkmark or delete button)
            if isHovered {
                if attentionRunState != nil, let onDismissAttention {
                    Button(action: onDismissAttention) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 11))
                            .foregroundColor(isDismissAttentionHovered ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isDismissAttentionHovered = $0 }
                    .hoverTooltip(dismissAttentionActionLabel)
                    .accessibilityLabel(dismissAttentionActionLabel)
                }

                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.slash" : "pin")
                        .font(.system(size: 11))
                        .foregroundColor(isPinHovered ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { isPinHovered = $0 }
                .hoverTooltip(pinActionLabel)

                Button(action: beginRename) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundColor(isRenameHovered ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { isRenameHovered = $0 }
                .hoverTooltip(renameActionLabel)

                Button(action: onStash) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 11))
                        .foregroundColor(isStashHovered ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { isStashHovered = $0 }
                .hoverTooltip(stashActionLabel)

                Button(action: requestDeleteConfirmation) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(isDeleteHovered ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { isDeleteHovered = $0 }
                .hoverTooltip(deleteActionLabel)
            }
            // Selected state is already signaled by the accent-tinted background +
            // semibold title weight; a trailing checkmark was redundant.
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, rowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
        .background(
            Group {
                if isActive {
                    RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                } else if isHovered {
                    RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                        .stroke(Color(NSColor.systemGray).opacity(0.5), lineWidth: 1)
                }
            }
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button(pinActionLabel, action: onTogglePin)

            Button(renameActionLabel, action: beginRename)

            Button(stashActionLabel, action: onStash)

            if attentionRunState != nil, let onDismissAttention {
                Button(dismissAttentionActionLabel, action: onDismissAttention)
            }

            Divider()

            Button(deleteActionLabel, role: .destructive, action: requestDeleteConfirmation)
        }
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
        .accessibilityLabel(scheduledSendStatus.map { "\(title), \($0.tooltipText)" } ?? title)
        .popover(isPresented: $showDeleteConfirmation, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Delete chat?")
                    .font(.headline)
                Text("This permanently deletes this chat.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        showDeleteConfirmation = false
                    }
                    Button("Delete") {
                        showDeleteConfirmation = false
                        onDelete()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 280)
        }
        .sheet(isPresented: $showRenameAlert) {
            AgentSessionRenameSheet(
                renameText: $renameText,
                onConfirm: { newName in
                    showRenameAlert = false
                    onRename(newName)
                },
                onCancel: {
                    showRenameAlert = false
                }
            )
        }
    }

    /// True when this row should advertise that it was opened by an
    /// external MCP client. Only root rows wear this cue — sub-agent
    /// rows are always MCP-driven by their parent, so the indent + arrow
    /// glyph already convey the same meaning.
    private var isMCPControlledRoot: Bool {
        isMCPControlled && threadDepth == 0
    }

    /// Compact merge-attention marker shown after the title for sessions with
    /// an active worktree merge operation in `awaiting_approval`,
    /// `conflicted`, or `awaiting_commit` state. Sized to match the existing
    /// pin glyph so layout does not jitter when attention attaches/detaches.
    private func remoteHostBadge(hostName: String, abbreviation: String?) -> some View {
        let displayLabel: String = if let abbreviation, !abbreviation.isEmpty {
            abbreviation
        } else {
            hostName
        }
        return HStack(spacing: 3) {
            Image(systemName: "network")
                .font(.system(size: pinFontSize - 1, weight: .semibold))
            Text(displayLabel)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, chipHorizontalPadding)
        .padding(.vertical, chipVerticalPadding)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.75))
        .hoverTooltip("Running on \(hostName)")
        .accessibilityLabel("Running on \(hostName)")
    }

    private func remoteControlledBadge(deviceID: String, displayName: String?) -> some View {
        let text = Self.remoteControlDeviceBadgeText(deviceID: deviceID, displayName: displayName)
        return HStack(spacing: 3) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: pinFontSize - 1, weight: .semibold))
            Text(text.label)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Self.mcpAccentColor)
        .padding(.horizontal, chipHorizontalPadding)
        .padding(.vertical, chipVerticalPadding)
        .background(Capsule().fill(Self.mcpAccentColor.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Self.mcpAccentColor.opacity(0.35), lineWidth: 0.75))
        .hoverTooltip(text.badgeTooltip)
        .accessibilityLabel(text.badgeTooltip)
    }

    static func remoteControlDeviceBadgeText(
        deviceID: String,
        displayName: String?
    ) -> AgentRemoteControlDeviceBadgeText {
        let label = remoteControlDeviceLabel(for: deviceID)
        if let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty
        {
            let tooltip = "Remote controlled by \(displayName) (\(label))"
            return AgentRemoteControlDeviceBadgeText(
                label: remoteControlDeviceBadgeAbbreviation(for: displayName),
                badgeTooltip: tooltip,
                statusPlateTooltip: tooltip
            )
        }
        return AgentRemoteControlDeviceBadgeText(
            label: label,
            badgeTooltip: "Remote-controlled by device \(deviceID)",
            statusPlateTooltip: "Remote controlled (device \(label))"
        )
    }

    /// Compact badge label for a paired-device display name: initials of the first
    /// three tokens ("Tuan's MacBook Pro" → "TMP"); single-token names use their
    /// first three characters ("Studio" → "STU"). Collisions are acceptable — the
    /// badge is per-row provenance and the tooltip always carries the full name + hex.
    static func remoteControlDeviceBadgeAbbreviation(for displayName: String) -> String {
        let stripped = displayName
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        let tokens = stripped.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let initials = tokens.prefix(3).compactMap(\.first)
        if initials.count >= 2 {
            return String(initials).uppercased()
        }
        if let firstToken = tokens.first {
            return String(firstToken.prefix(3)).uppercased()
        }
        return displayName
    }

    static func remoteControlDeviceLabel(for deviceID: String) -> String {
        String(deviceID.split(separator: ":").last.map(String.init) ?? deviceID).suffix(8).description
    }

    private func mergeAttentionBadge(for attention: AgentWorktreeMergeAttention) -> some View {
        let tint: Color = switch attention.kind {
        case .conflicted: .orange
        case .awaitingApproval: .purple
        case .historicalReview: .secondary
        case .awaitingCommit: .yellow
        }
        let glyph = switch attention.kind {
        case .conflicted: "exclamationmark.triangle.fill"
        case .awaitingApproval: "arrow.triangle.merge"
        case .historicalReview: "clock.arrow.circlepath"
        case .awaitingCommit: "checkmark.circle"
        }
        return Image(systemName: glyph)
            .font(.system(size: pinFontSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: pinFontSize + 2, height: pinFontSize + 2)
            .accessibilityLabel(attention.tooltipText)
            .hoverTooltip(attention.tooltipText)
    }

    private func delegatedQuestionBadge(for attention: AgentDelegatedQuestionSidebarAttention) -> some View {
        let tint: Color = switch attention.ownQuestion {
        case .needsUserAnswer:
            .orange
        case .waitingOnParentAgent, nil:
            .blue
        }
        let glyph = switch attention.ownQuestion {
        case .needsUserAnswer:
            "questionmark.circle.fill"
        case .waitingOnParentAgent:
            "arrow.turn.left.up"
        case nil:
            "questionmark.bubble"
        }
        return Image(systemName: glyph)
            .font(.system(size: pinFontSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: pinFontSize + 2, height: pinFontSize + 2)
            .accessibilityLabel(attention.tooltipText)
            .accessibilityIdentifier("agent.sidebar.delegatedQuestionBadge")
            .hoverTooltip(attention.tooltipText)
    }

    private var hiddenCountChip: some View {
        let hasHiddenAttention = hiddenThreadDescendantAttentionCount > 0
        return Text("\(hiddenThreadDescendantCount)")
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: hasHiddenAttention ? .semibold : .medium))
            .foregroundStyle(hasHiddenAttention ? Color.orange : Color.secondary)
            .padding(.horizontal, chipHorizontalPadding)
            .padding(.vertical, chipVerticalPadding)
            .background(
                Capsule()
                    .fill(
                        hasHiddenAttention
                            ? Color.orange.opacity(0.18)
                            : Color(NSColor.systemGray).opacity(0.18)
                    )
            )
            .overlay(
                Capsule()
                    .stroke(Color.orange.opacity(hasHiddenAttention ? 0.6 : 0), lineWidth: 1)
            )
            .hoverTooltip(hiddenCountTooltip)
            .accessibilityLabel(hiddenCountTooltip)
    }

    /// The state the status slot should visually reflect.
    ///
    /// Rules:
    /// - Running always wins (live activity outranks any stale attention).
    /// - Otherwise prefer the unseen attention state (mirrors the MCP status
    ///   "inactive/active/attention" pattern — attention is the "look at me"
    ///   signal and trumps steady-state).
    /// - Fall back to the current run state.
    private var effectiveStatusState: AgentSessionRunState {
        if runState == .running { return .running }
        if let attentionRunState { return attentionRunState }
        return runState
    }

    /// True when the current signal is a background transition the user
    /// hasn't acknowledged yet. Drives the stronger "badge" treatment.
    private var isUnseenAttention: Bool {
        guard let attentionRunState else { return false }
        // If the row is currently running we prefer to show the running arc
        // rather than a stale attention ring — attention will re-raise when
        // this run terminates.
        if runState == .running { return false }
        return AgentSessionSidebarUIStore.isAttentionEligible(attentionRunState)
    }

    /// Shared accent used to flag MCP-controlled root rows in the status
    /// plate. Orange is the same hue used elsewhere for MCP affordances
    /// (file drawer chips, in-progress streaming badge, etc).
    private static let mcpAccentColor = Color.orange

    private func scheduledSendBadge(for status: AgentSidebarScheduledSendStatus) -> some View {
        let isHistorical = if case .sent = status { true } else { false }
        return Image(systemName: status.needsAttention ? "exclamationmark.circle.fill" : "clock")
            .font(.system(size: pinFontSize))
            .foregroundStyle(
                status.needsAttention ? Color.orange : Color.secondary.opacity(isHistorical ? 0.55 : 0.9)
            )
            .hoverTooltip(status.tooltipText)
            .accessibilityLabel(status.tooltipText)
    }

    // MARK: - Unified status plate

    ///
    /// Single 14pt leading slot that carries BOTH row identity (chevron /
    /// arrow / anchor dot / attention glyph) AND run-state status (plate
    /// fill tint + optional halo stroke + optional running arc overlay).
    ///
    /// Status vocabulary:
    ///   - idle / cancelled     → clear plate, leaf rows show a hairline dot
    ///   - running              → accent-tinted plate + rotating arc overlay,
    ///                            identity glyph remains inside
    ///   - waiting (*)          → green-tinted plate; unseen raises to a
    ///                            louder halo stroke ("needs you" cue)
    ///   - completed + unseen   → green-tinted plate + checkmark glyph
    ///   - failed               → red-tinted plate; unseen swaps the glyph
    ///                            for an exclamation mark
    ///
    /// The identity glyph (chevron / arrow / dot) is preserved except when
    /// a strong background-attention cue requires a dedicated state glyph
    /// (checkmark for unseen-completed, exclamationmark for unseen-failed).
    /// This way the plate always reserves 14pt of leading width and the
    /// title's X offset is a pure function of threadDepth.
    private var statusPlate: some View {
        ZStack {
            // Status-encoding fill tint. Stays decorative so the chevron
            // button's hit test isn't blocked.
            Circle()
                .fill(plateFillColor)
                .allowsHitTesting(false)

            // Louder halo for unseen waiting states — preserves the pre-
            // refactor "green halo ring" cue that tells the user a
            // background session is waiting on them.
            if showsWaitingHalo {
                Circle()
                    .stroke(Color.green.opacity(0.55), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }

            // Spinning arc overlay while a run is live. Sits between the
            // plate fill and the identity glyph so the chevron/arrow/dot
            // remains visually centered while the ring conveys motion.
            if runState == .running {
                AgentRowActivityArc(tint: runningAccentColor)
                    .allowsHitTesting(false)
            }

            // Foreground glyph — identity for normal states, attention
            // glyph when an unseen background transition demands it.
            plateGlyph
        }
        .frame(width: 16, height: 16)
        .overlay(alignment: .bottomTrailing) {
            worktreeMarker
        }
        .hoverTooltip(plateTooltip)
        .accessibilityLabel(plateAccessibilityLabel)
    }

    /// Compact bound-worktree marker overlaid on the status plate's
    /// bottom-right corner. Purely decorative for hit-testing so it never
    /// blocks the disclosure chevron, and layout-neutral so the title's
    /// leading X stays a pure function of `threadDepth`. Its identity is
    /// folded into `plateTooltip` / `plateAccessibilityLabel`.
    @ViewBuilder
    private var worktreeMarker: some View {
        if let worktree {
            worktreeMarkerShape(for: worktree)
                .frame(width: 7, height: 7)
                .padding(1.3)
                .background(
                    Circle().fill(Color(NSColor.controlBackgroundColor))
                )
                .offset(x: 2.5, y: 2.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Marker geometry. Available worktrees use the persisted marker style
    /// (filled dot for dot/capsule, hollow ring for ring); missing worktrees
    /// always render a muted dashed ring so a stale binding reads as such.
    @ViewBuilder
    private func worktreeMarkerShape(for worktree: AgentWorktreeIndicator) -> some View {
        if !worktree.isAvailable {
            Circle()
                .strokeBorder(
                    Color.secondary,
                    style: StrokeStyle(lineWidth: 1.3, dash: [1.6, 1.4])
                )
        } else if worktree.markerStyle == .ring {
            Circle()
                .strokeBorder(worktree.color, lineWidth: 1.7)
        } else {
            Circle()
                .fill(worktree.color)
                .overlay(
                    Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                )
        }
    }

    /// Tint used for the running arc and the running plate fill. Orange
    /// for MCP-controlled root rows so the running cue rhymes with the
    /// rest of the MCP indicators; default accent everywhere else.
    private var runningAccentColor: Color {
        isMCPControlledRoot ? Self.mcpAccentColor : Color.accentColor
    }

    /// Background tint that encodes the row's effective run state. Kept
    /// at low alpha so the plate reads as a tint, not a loud chip.
    private var plateFillColor: Color {
        switch effectiveStatusState {
        case .running:
            // No disc behind the running arc — the rotating arc reads cleanly
            // on its own and the faint accent fill clashed with the centered
            // dot. Keep the plate transparent so only the arc + glyph show.
            .clear
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            Color.green.opacity(isUnseenAttention ? 0.22 : 0.15)
        case .completed:
            isUnseenAttention ? Color.green.opacity(0.18) : .clear
        case .failed:
            Color.red.opacity(isUnseenAttention ? 0.18 : 0.12)
        case .cancelled, .idle:
            .clear
        }
    }

    /// True only for unseen-attention waiting states — the one case where
    /// we still want a crisp stroke ring, because the user needs to
    /// notice that a backgrounded session is waiting on them.
    private var showsWaitingHalo: Bool {
        guard isUnseenAttention else { return false }
        switch effectiveStatusState {
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            return true
        default:
            return false
        }
    }

    /// Foreground glyph inside the plate. Attention states (unseen
    /// completed / unseen failed) get a dedicated state glyph; everything
    /// else falls back to the row's identity glyph (chevron / arrow /
    /// anchor dot).
    @ViewBuilder
    private var plateGlyph: some View {
        let state = effectiveStatusState

        if isUnseenAttention, state == .completed {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.green)
                .accessibilityLabel("Completed in background")
        } else if isUnseenAttention, state == .failed {
            Image(systemName: "exclamationmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.red)
                .accessibilityLabel("Failed in background")
        } else if threadDepth > 0 {
            // Sub-agent identity glyph.
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.55))
                .accessibilityHidden(true)
        } else if showsDisclosureChevron, let onToggleThreadCollapse {
            // Expandable root identity glyph — tappable disclosure affordance.
            // MCP-controlled roots tint the chevron orange when idle so the
            // row still signals "opened by an MCP client" without needing a
            // dedicated leading rail.
            let chevronColor: Color = {
                if isDisclosureHovered { return .accentColor }
                return isMCPControlledRoot ? Self.mcpAccentColor : .secondary
            }()
            Button {
                onToggleThreadCollapse()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(chevronColor)
                    .rotationEffect(.degrees(isThreadCollapsed ? 0 : 90))
                    .animation(.easeInOut(duration: 0.15), value: isThreadCollapsed)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isDisclosureHovered = $0 }
            .hoverTooltip(disclosureAccessibilityLabel)
            .accessibilityLabel(disclosureAccessibilityLabel)
        } else if isMCPControlledRoot {
            // MCP-controlled leaf root — keeps the existing anchor-dot
            // design but recolors it orange and bumps the size a hair so
            // it reads as a deliberate "this chat came from an MCP client"
            // marker instead of a generic idle dot.
            Circle()
                .fill(Self.mcpAccentColor.opacity((isHovered || isActive) ? 0.95 : 0.8))
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        } else {
            // Leaf root anchor dot — reacts with hover/active to rhyme
            // with the row's outline highlight. While the row is running the
            // dot also adopts the running accent (blue / MCP-orange) at full
            // opacity so the spinner reads with contrast against the arc.
            let isRunningRow = runState == .running
            let dotColor: Color = isRunningRow
                ? runningAccentColor
                : Color.secondary
            let dotOpacity: Double = {
                if isRunningRow { return 1.0 }
                return (isHovered || isActive) ? 0.55 : 0.22
            }()
            Circle()
                .fill(dotColor.opacity(dotOpacity))
                .frame(width: 3, height: 3)
                .accessibilityHidden(true)
        }
    }

    /// Tooltip for the plate. Combines the run-state / MCP status portion
    /// (`statusPlateTooltip`) with the bound-worktree identity line so a
    /// single hover surfaces both. Either portion may be absent.
    private var plateTooltip: String? {
        var parts: [String] = []
        if let status = statusPlateTooltip {
            parts.append(status)
        }
        if let remoteHostName {
            parts.append("Running on \(remoteHostName)")
        }
        if let worktreeTooltip = worktree?.tooltipText {
            parts.append(worktreeTooltip)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Run-state / MCP portion of the plate tooltip, before worktree identity
    /// is folded in. Expandable roots rely on the chevron button's own
    /// tooltip, so this stays nil there to avoid two competing bubbles.
    private var statusPlateTooltip: String? {
        if showsDisclosureChevron { return nil }

        let state = effectiveStatusState
        let controlTooltip = remoteControlDeviceID.map {
            Self.remoteControlDeviceBadgeText(
                deviceID: $0,
                displayName: remoteControlDeviceDisplayName
            ).statusPlateTooltip
        } ?? "MCP Controlled"
        let stateTooltip: String? = switch state {
        case .running:
            "Running"
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            waitingTooltip(for: state, unseen: isUnseenAttention)
        case .completed:
            isUnseenAttention
                ? "Completed in background — select or dismiss to clear"
                : nil
        case .failed:
            isUnseenAttention
                ? "Failed in background — select or dismiss to clear"
                : "Last run failed"
        case .cancelled, .idle:
            nil
        }

        switch (stateTooltip, isMCPControlledRoot) {
        case (let tip?, true):
            return tip + " — " + controlTooltip
        case (nil, true):
            return controlTooltip
        case (let tip, false):
            return tip
        }
    }

    /// Accessibility companion to `plateTooltip`. Always returns a
    /// non-empty label for MCP-controlled roots so VoiceOver still
    /// announces the affordance after the rail was removed.
    private var plateAccessibilityLabel: String {
        if let tip = plateTooltip { return tip }
        return isMCPControlledRoot ? "MCP controlled" : ""
    }

    private func waitingTooltip(
        for state: AgentSessionRunState,
        unseen: Bool
    ) -> String {
        let base = switch state {
        case .waitingForApproval:
            "Waiting for approval"
        case .waitingForQuestion:
            "Waiting for your answer"
        default:
            "Waiting for your input"
        }
        return unseen ? base + " — select or dismiss to clear" : base
    }
}

struct AgentStashedSessionRow: View {
    let stashed: StashedTab
    let onRestore: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isRestoreHovered = false
    @State private var isDeleteHovered = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var rowMinHeight: CGFloat {
        fontPreset.scaledClamped(30, min: 30, max: 40)
    }

    private var rowHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    private var rowVerticalPadding: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    private var rowCornerRadius: CGFloat {
        fontPreset.scaledClamped(16, max: 20)
    }

    private var rowSpacing: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var titlePinSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    private var titleVStackSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    private var leadingIconSize: CGFloat {
        fontPreset.scaledClamped(12, max: 15)
    }

    private var pinIconSize: CGFloat {
        fontPreset.scaledClamped(10, max: 13)
    }

    private var restoreActionLabel: String {
        "Restore tab"
    }

    private var deleteActionLabel: String {
        "Delete stashed tab"
    }

    var body: some View {
        HStack(spacing: rowSpacing) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: leadingIconSize))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: titleVStackSpacing) {
                HStack(spacing: titlePinSpacing) {
                    Text(stashed.tab.name)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if stashed.tab.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: pinIconSize))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if isHovered {
                Button(action: onRestore) {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: 11))
                        .foregroundColor(isRestoreHovered ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { isRestoreHovered = $0 }
                .hoverTooltip(restoreActionLabel)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(isDeleteHovered ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { isDeleteHovered = $0 }
                .hoverTooltip(deleteActionLabel)
            }
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, rowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
        .background(
            Group {
                if isHovered {
                    RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                        .stroke(Color(NSColor.systemGray).opacity(0.4), lineWidth: 1)
                }
            }
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button(restoreActionLabel, action: onRestore)

            Divider()

            Button(deleteActionLabel, role: .destructive, action: onDelete)
        }
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onRestore)
        .accessibilityLabel("\(stashed.tab.name), archived session")
    }
}

// MARK: - Agent Row Activity Arc

/// A compact, calm rotating arc used in place of the native `ProgressView`
/// inside the Agent Mode sidebar row's status slot.
///
/// Design goals:
/// - Match the 14pt status slot so titles stay aligned whether the row shows
///   a spinner, a waiting dot, a failed dot, or nothing at all.
/// - Rhyme with the circle-based waiting/failed dots (they all share the same
///   geometric vocabulary).
/// - Read as "actively processing" without competing with the green waiting
///   dot — running is informational, waiting is actionable, so running
///   should not out-shout it.
///
/// The rotation runs as a Core Animation animation on the render server, so it
/// keeps turning while the main thread is busy and does not drive per-frame
/// SwiftUI updates for every running row.
private struct AgentRowActivityArc: View {
    var tint: Color = .accentColor

    var body: some View {
        // The layer view is sized to the stroke's outer edge so the centered
        // stroke of the 15pt circle is never clipped; the outer frame keeps the
        // 15pt layout footprint the SwiftUI shape had.
        AgentRowActivityArcLayerRepresentable(tint: tint)
            .frame(
                width: 15 + AgentRowActivityArcLayerView.lineWidth,
                height: 15 + AgentRowActivityArcLayerView.lineWidth
            )
            .frame(width: 15, height: 15)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Running")
    }
}

private struct AgentRowActivityArcLayerRepresentable: NSViewRepresentable {
    let tint: Color

    func makeNSView(context _: Context) -> AgentRowActivityArcLayerView {
        let view = AgentRowActivityArcLayerView()
        view.update(tint: NSColor(tint))
        return view
    }

    func updateNSView(_ nsView: AgentRowActivityArcLayerView, context _: Context) {
        nsView.update(tint: NSColor(tint))
    }

    static func dismantleNSView(_ nsView: AgentRowActivityArcLayerView, coordinator _: ()) {
        nsView.tearDown()
    }
}

/// Layer-hosted rotating arc behind `AgentRowActivityArc`. Owns one
/// `CAShapeLayer` sublayer of AppKit's backing layer and one explicit
/// rotation animation that is installed only when missing, so sidebar
/// re-renders never reset its phase or stack extra animations.
final class AgentRowActivityArcLayerView: NSView {
    static let rotationAnimationKey = "agentRowActivityArc.rotation"
    static let lineWidth: CGFloat = 1.5
    static let strokeEnd: CGFloat = 0.7
    static let strokeOpacity: CGFloat = 0.75

    let arcLayer = CAShapeLayer()
    private var tintColor: NSColor = .controlAccentColor
    private var observesSystemColors = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
        arcLayer.fillColor = nil
        arcLayer.lineWidth = Self.lineWidth
        arcLayer.lineCap = .round
        arcLayer.strokeStart = 0
        arcLayer.strokeEnd = Self.strokeEnd
        arcLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(arcLayer)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemColorsDidChange(_:)),
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )
        observesSystemColors = true
        applyStrokeColor()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Matches SwiftUI's y-down space: angle 0 is 3 o'clock, increasing angles
    /// and positive rotation read clockwise on screen.
    override var isFlipped: Bool {
        true
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func update(tint: NSColor) {
        tintColor = tint
        applyStrokeColor()
        installRotationIfNeeded()
    }

    func tearDown() {
        arcLayer.removeAnimation(forKey: Self.rotationAnimationKey)
        if observesSystemColors {
            NotificationCenter.default.removeObserver(
                self,
                name: NSColor.systemColorsDidChangeNotification,
                object: nil
            )
            observesSystemColors = false
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arcLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        arcLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Inset by half the stroke so the full stroke stays inside bounds.
        let diameter = max(0, min(bounds.width, bounds.height) - Self.lineWidth)
        let path = CGMutablePath()
        if diameter > 0 {
            path.addArc(
                center: CGPoint(x: bounds.midX, y: bounds.midY),
                radius: diameter / 2,
                startAngle: 0,
                endAngle: 2 * .pi,
                clockwise: false
            )
        }
        arcLayer.path = path
        CATransaction.commit()
        installRotationIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            arcLayer.removeAnimation(forKey: Self.rotationAnimationKey)
        } else {
            applyContentsScale()
            applyStrokeColor()
            installRotationIfNeeded()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentsScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStrokeColor()
    }

    @objc private func systemColorsDidChange(_: Notification) {
        applyStrokeColor()
    }

    private func applyContentsScale() {
        guard let scale = window?.backingScaleFactor else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arcLayer.contentsScale = scale
        CATransaction.commit()
    }

    private func applyStrokeColor() {
        var resolved: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = tintColor.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arcLayer.strokeColor = resolved.map { $0.copy(alpha: $0.alpha * Self.strokeOpacity) ?? $0 }
        CATransaction.commit()
    }

    private func installRotationIfNeeded() {
        guard window != nil, arcLayer.animation(forKey: Self.rotationAnimationKey) == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = 2 * Double.pi
        rotation.duration = 1.0
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        // Phase follows whole wall-clock seconds, so running rows turn in sync and
        // re-entering a window continues the turn instead of restarting at 0.
        rotation.beginTime = arcLayer.convertTime(floor(CACurrentMediaTime()), from: nil)
        // A 15pt indicator needs no ProMotion rate; cap render-server work at 60 fps.
        rotation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        arcLayer.add(rotation, forKey: Self.rotationAnimationKey)
    }
}

// MARK: - Agent Kind Extensions

extension AgentProviderKind {
    // displayName is defined in AgentRuntimeProviderService.swift

    var iconName: String {
        switch self {
        case .codexExec: "terminal"
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible: "cpu"
        case .openCode: "curlybraces.square"
        case .cursor: "cursorarrow"
        case .ohMyPi: "circle.grid.cross"
        }
    }
}
