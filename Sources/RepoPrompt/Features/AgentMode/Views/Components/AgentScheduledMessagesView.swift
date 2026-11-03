import SwiftUI

struct AgentScheduledMessagesView: View {
    @StateObject private var model: AgentScheduledMessagesViewModel
    private let agentModeVM: AgentModeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var reloadToken = 0

    init(agentModeVM: AgentModeViewModel) {
        self.agentModeVM = agentModeVM
        _model = StateObject(wrappedValue: AgentScheduledMessagesViewModel(agentModeVM: agentModeVM))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Scheduled Messages")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }

            Picker("Workspaces", selection: $model.scope) {
                ForEach(AgentScheduledMessagesViewModel.Scope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            if let loadError = model.loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.rows.isEmpty {
                        Text("No scheduled messages")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 400)
        .task(id: reloadToken) {
            // A single task coalesces bursts and cancellation stops obsolete index reads.
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            await model.reload()
        }
        .onChange(of: model.scope) { _, _ in reloadToken &+= 1 }
        .onChange(of: model.reloadRequest) { _, _ in reloadToken &+= 1 }
        .onReceive(NotificationCenter.default.publisher(for: .agentScheduledSendDashboardDidChange)) { _ in
            reloadToken &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentScheduledSendDidCommit)) { _ in
            reloadToken &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentScheduledSendRecoveryDidChange)) { _ in
            reloadToken &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentScheduledSendPendingConfirmationDidChange)) { _ in
            reloadToken &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentScheduledSendDispositionDidChange)) { _ in
            reloadToken &+= 1
        }
    }

    private func rowView(_ row: AgentScheduledMessagesViewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.sessionName)
                        .font(.headline)
                    if model.scope == .allWorkspaces {
                        Text(row.workspaceName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.scope == .allWorkspaces || row.isIndexUnavailable {
                    Button("Open workspace") {
                        Task { await model.openWorkspace(row.workspaceID) }
                    }
                } else if !row.isActionable, canOpenCurrentSession(row) {
                    Button("Open session") {
                        Task { await model.openCurrentSession(row) }
                    }
                }
            }

            if !row.previewText.isEmpty {
                Text(row.previewText)
                    .font(.subheadline)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.scope == .currentWorkspace, row.isActionable, let props = row.props {
                AgentScheduledSendBanner(props: props, actions: actions(for: row))
            } else {
                Text(row.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.scope == .currentWorkspace, let recovery = row.recovery,
                   recovery.hasAcceptedPayload,
                   case .needsAttention = recovery.phase
                {
                    Button("Retry saving") {
                        model.retryRecovery(row)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("agent.scheduledMessages.row.\(row.sessionID.uuidString)")
    }

    private func canOpenCurrentSession(_ row: AgentScheduledMessagesViewModel.Row) -> Bool {
        guard let tabID = row.tabID, let promptManager = agentModeVM.promptManager else { return false }
        return promptManager.currentComposeTabs.contains(where: { $0.id == tabID })
            || promptManager.currentStashedTabs.contains(where: { $0.id == tabID })
    }

    private func actions(for row: AgentScheduledMessagesViewModel.Row) -> AgentScheduledSendActions {
        AgentScheduledSendActions(
            executeSchedule: { _, _, _, _ in
                .blocked(message: "Schedule from the composer instead.")
            },
            update: {
                _, _,
                text,
                notBefore,
                runAlongside,
                removingImageAttachmentIDs,
                removingTaggedFileAttachmentIDs in
                await model.update(
                    row,
                    text: text,
                    notBefore: notBefore,
                    runAlongsideOtherSessions: runAlongside,
                    removingImageAttachmentIDs: removingImageAttachmentIDs,
                    removingTaggedFileAttachmentIDs: removingTaggedFileAttachmentIDs
                )
            },
            cancel: { _, _ in await model.cancel(row) },
            sendNow: { _, _, runAlongside in
                await model.sendNow(row, runAlongsideOtherSessions: runAlongside)
            },
            discardUnreadable: { _ in await model.discardUnreadable(row) },
            retrySaving: { _ in await model.retrySaving(row) }
        )
    }
}
