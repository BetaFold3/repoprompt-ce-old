import RepoPromptAgentCore
import RepoPromptUI
import SwiftUI

/// App-wide Needs Attention sheet (lossless restart Phase 2): renders the recovery coordinator's
/// catalog snapshot itself in two sections (O34-2), "Needs action" then "Information" (collapsed by
/// default), each in snapshot order, with the same rows and actions as the composer banner.
/// Dismissed and automatically cleared items are hidden unless "Show dismissed and cleared" is on.
/// Each section offers a bulk Dismiss of its displayed rows (O34-2; confirmed for Needs action).
/// "Check and resolve" (Step 9-check) checks the displayed rows and reports each one; it is
/// observational (no confirmation: its report header names what it may clear).
/// Presented by each window's root host (`AgentRecoveryNeedsAttentionHost`) from the View menu,
/// the banner, or the sidebar, independent of the sidebar and of any tab. Opening a row never
/// starts a provider.
struct AgentRecoveryNeedsAttentionSheet: View {
    let agentModeVM: AgentModeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDismissed = false
    @State private var showInformation = false
    @State private var revision = 0
    /// The needs-action bulk Dismiss frozen when "Dismiss eligible…" was clicked, awaiting
    /// confirmation (its eligible items are the confirmed count).
    @State private var pendingNeedsActionBulk: AgentRecoveryBulkDismissRequest?

    var body: some View {
        let _ = revision
        let rows = agentModeVM.recoveryNeedsAttentionRows(
            includeDismissed: showDismissed,
            activeSession: agentModeVM.activeSession
        )
        let needsActionRows = rows.filter { $0.attention == .needsAction }
        let informationalRows = rows.filter { $0.attention == .informational }
        let actions = AgentRecoveryListActions(
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
            inspect: { rowID in await agentModeVM.inspectRecoveryEditProposal(rowID: rowID) }
        )
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Needs Attention")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Check and resolve") {
                    agentModeVM.startRecoveryCheck(rows: rows)
                }
                .disabled(agentModeVM.isRecoveryCheckRunning || AgentModeViewModel.recoveryCheckItems(rows).isEmpty)
                .hoverTooltip(agentModeVM.recoveryCheckHelpText)
                .accessibilityIdentifier("agent.recoveryNeedsAttention.check")
                Toggle("Show dismissed and cleared", isOn: $showDismissed)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("agent.recoveryNeedsAttention.showDismissed")
                Button("Done") { dismiss() }
            }
            bulkStatusLine
            checkReport
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Needs action (\(Self.headerCount(needsActionRows)))")
                            .font(.headline)
                            .accessibilityIdentifier("agent.recoveryNeedsAttention.section.needsAction")
                        Spacer()
                        Button("Dismiss eligible…") {
                            pendingNeedsActionBulk = agentModeVM.recoveryBulkDismissRequest(section: .needsAction, rows: needsActionRows)
                        }
                        .controlSize(.small)
                        .disabled(isBulkRunning || agentModeVM.recoveryBulkDismissEligibleCount(needsActionRows) == 0)
                        .accessibilityIdentifier("agent.recoveryNeedsAttention.dismissAll.needsAction")
                    }
                    if needsActionRows.isEmpty {
                        Text("Nothing needs your attention.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    ForEach(needsActionRows) { entry in
                        entryView(entry, actions: actions)
                    }
                    HStack {
                        Button {
                            showInformation.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showInformation ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold))
                                Text("Information (\(Self.headerCount(informationalRows)))")
                                    .font(.headline)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent.recoveryNeedsAttention.section.informational")
                        .accessibilityValue(showInformation ? "expanded" : "collapsed")
                        Spacer()
                        // Informational notes: no confirmation (nothing is paused or lost).
                        Button("Dismiss all") {
                            agentModeVM.startRecoveryBulkDismiss(section: .informational, rows: informationalRows)
                        }
                        .controlSize(.small)
                        .disabled(isBulkRunning || agentModeVM.recoveryBulkDismissEligibleCount(informationalRows) == 0)
                        .accessibilityIdentifier("agent.recoveryNeedsAttention.dismissAll.informational")
                    }
                    .padding(.top, 6)
                    if showInformation {
                        ForEach(informationalRows) { entry in
                            entryView(entry, actions: actions)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 400)
        // A row's View opens beside the sheet, over the inert window behind, never over another row.
        .agentRecoveryNativePopoverRegion(edge: .trailing)
        // A container element, so the sheet's identifier names the sheet itself instead of being
        // applied to the elements inside it (the check report kept only `…sheet`).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.recoveryNeedsAttention.sheet")
        .confirmationDialog(
            Self.needsActionConfirmationTitle(
                eligible: pendingNeedsActionBulk?.eligibleCount ?? 0,
                otherWorkspaces: pendingNeedsActionBulk?.otherWorkspaceCount ?? 0
            ),
            isPresented: Binding(
                get: { pendingNeedsActionBulk != nil },
                set: { if !$0 { pendingNeedsActionBulk = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Dismiss") {
                if let captured = pendingNeedsActionBulk {
                    agentModeVM.startRecoveryBulkDismiss(captured)
                }
                pendingNeedsActionBulk = nil
            }
            .accessibilityIdentifier("agent.recoveryNeedsAttention.dismissAll.needsAction.confirm")
            Button("Cancel", role: .cancel) { pendingNeedsActionBulk = nil }
        } message: {
            Text(AgentModeViewModel.recoveryBulkDismissNeedsActionWarning)
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentRecoveryCatalogDidChange).receive(on: RunLoop.main)) { _ in
            revision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentRecoveryCoordinatorDidChange).receive(on: RunLoop.main)) { _ in
            revision &+= 1
        }
        // A finished bulk's summary is not shown again on the next opening (a running one stays).
        .onDisappear {
            agentModeVM.clearRecoveryBulkDismissSummary()
            agentModeVM.clearRecoveryCheckReport()
        }
    }

    private var isBulkRunning: Bool {
        agentModeVM.isRecoveryBulkDismissRunning
    }

    /// The app-wide bulk Dismiss's one-line progress or summary, with Stop while it runs.
    @ViewBuilder
    private var bulkStatusLine: some View {
        if let status = agentModeVM.recoveryBulkDismissStatus {
            HStack(spacing: 8) {
                Text(status.summaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agent.recoveryNeedsAttention.bulkSummary")
                if status.isRunning {
                    Button("Stop") { agentModeVM.cancelRecoveryBulkDismiss() }
                        .controlSize(.small)
                        .disabled(status.cancelRequested)
                        .accessibilityIdentifier("agent.recoveryNeedsAttention.bulkCancel")
                }
            }
        }
    }

    /// The app-wide Check and resolve's header, progress or summary and per-item results, with Stop
    /// while it runs; before it runs (checks active), the sentence its header will show.
    @ViewBuilder
    private var checkReport: some View {
        if let status = agentModeVM.recoveryCheckStatus {
            VStack(alignment: .leading, spacing: 4) {
                Text(status.headerText)
                    .font(.callout.weight(.medium))
                HStack(spacing: 8) {
                    Text(status.summaryText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if status.isRunning {
                        Button("Stop") { agentModeVM.cancelRecoveryCheck() }
                            .controlSize(.small)
                            .disabled(status.cancelRequested)
                            .accessibilityIdentifier("agent.recoveryNeedsAttention.checkCancel")
                    }
                }
                if !status.entries.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(status.entries.enumerated()), id: \.offset) { _, entry in
                                Text("\(entry.label) — \(entry.outcome.text)")
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.08)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent.recoveryNeedsAttention.checkReport")
        } else if let notice = agentModeVM.recoveryCheckNoticeText {
            // Before Check runs, the same sentence its header shows (Step 9-activation-b).
            Text(notice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agent.recoveryNeedsAttention.checkNotice")
        }
    }
}

extension AgentRecoveryNeedsAttentionSheet {
    private func entryView(_ entry: AgentRecoveryNeedsAttentionRow, actions: AgentRecoveryListActions) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label = Self.label(for: entry) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            AgentRecoveryListRow(row: entry.row, actions: actions, detailLineLimit: 4)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(entry.isHidden ? 0.04 : 0.10))
        )
        .opacity(entry.isHidden ? 0.7 : 1)
    }

    /// A section header's count: its rows that are neither dismissed nor cleared (those are listed
    /// only while "Show dismissed and cleared" is on and are never counted).
    static func headerCount(_ rows: [AgentRecoveryNeedsAttentionRow]) -> Int {
        rows.count { !$0.isHidden }
    }

    /// Names how many of the confirmed cards are in other workspaces (the bulk covers every
    /// workspace's cards).
    static func needsActionConfirmationTitle(eligible: Int, otherWorkspaces: Int = 0) -> String {
        let cards = eligible == 1 ? "1 card that needs action" : "\(eligible) cards that need action"
        let scope = switch otherWorkspaces {
        case 0: ""
        case 1: " (1 in another workspace)"
        default: " (\(otherWorkspaces) in other workspaces)"
        }
        return "Dismiss \(cards)\(scope)?"
    }

    static func label(for entry: AgentRecoveryNeedsAttentionRow) -> String? {
        var parts: [String] = []
        if entry.isDismissed { parts.append("Dismissed") }
        if let clear = entry.automaticClear { parts.append(clearedLabel(clear)) }
        if entry.isOtherWorkspace { parts.append("Another workspace") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func clearedLabel(_ clear: AgentRecoveryCatalogAutomaticClear) -> String {
        switch clear {
        case .sessionContinued: "Cleared: session continued"
        case .conversationCleared: "Cleared: conversation cleared"
        case .resolved: "Cleared: resolved"
        }
    }
}

/// Window-root host of the Needs Attention sheet: presents it once per pending request of this
/// window's view model (View menu, banner, or sidebar), including a request made while the window
/// was still appearing. Independent of the session sidebar and of any tab.
struct AgentRecoveryNeedsAttentionHost: ViewModifier {
    let agentModeVM: AgentModeViewModel
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                AgentRecoveryNeedsAttentionSheet(agentModeVM: agentModeVM)
            }
            .onAppear(perform: consumeRequest)
            .onReceive(NotificationCenter.default.publisher(for: .agentRecoveryNeedsAttentionRequested)) { notification in
                guard (notification.object as AnyObject?) === agentModeVM else { return }
                consumeRequest()
            }
    }

    private func consumeRequest() {
        if agentModeVM.consumeRecoveryNeedsAttentionRequest() {
            isPresented = true
        }
    }
}

/// Sidebar shortcut to the Needs Attention sheet; shown while any needs-action recovery item is
/// undismissed (the View menu's command is always available).
struct AgentRecoveryNeedsAttentionSidebarButton: View {
    let agentModeVM: AgentModeViewModel
    let hitSize: CGFloat
    let open: () -> Void
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let count = agentModeVM.recoveryNeedsAttentionCount
        Group {
            if count > 0 {
                Button(action: open) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                            .frame(width: hitSize, height: hitSize)
                        Text(count > 99 ? "99+" : String(count))
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3)
                            .background(Color.orange, in: Capsule())
                            .foregroundStyle(.white)
                            .offset(x: 8, y: -4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTooltip("Needs Attention")
                .accessibilityLabel("Needs Attention, \(count)")
                .accessibilityIdentifier("agent.recoveryNeedsAttention.sidebarButton")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentRecoveryCatalogDidChange).receive(on: RunLoop.main)) { _ in
            revision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentRecoveryCoordinatorDidChange).receive(on: RunLoop.main)) { _ in
            revision &+= 1
        }
    }
}
