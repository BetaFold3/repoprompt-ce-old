import Foundation
import RepoPromptAgentCore
import SwiftUI

struct AgentScheduledSendBanner: View {
    private enum EditorMode: String, Identifiable {
        case edit
        case reschedule

        var id: String {
            rawValue
        }
    }

    let props: AgentScheduledSendProps
    let actions: AgentScheduledSendActions

    @State private var editorMode: EditorMode?
    @State private var editorText: String
    @State private var editorNotBefore: Date
    @State private var editorDateRange: ClosedRange<Date>
    @State private var editorRunAlongside: Bool
    @State private var editorRemovedImageIDs: Set<UUID> = []
    @State private var editorRemovedTaggedFileIDs: Set<UUID> = []
    @State private var actionError: String?
    @State private var isActionInFlight = false

    init(props: AgentScheduledSendProps, actions: AgentScheduledSendActions) {
        self.props = props
        self.actions = actions
        let now = Date()
        _editorText = State(initialValue: props.rawText)
        _editorNotBefore = State(initialValue: props.notBefore)
        _editorDateRange = State(
            initialValue: AgentScheduledSendTiming.editorRange(
                originalNotBefore: props.notBefore,
                now: now
            )
        )
        _editorRunAlongside = State(initialValue: props.runAlongsideOtherSessions)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if let recoveryMessage = props.recoveryMessage, !recoveryMessage.isEmpty {
                    Text(recoveryMessage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .accessibilityIdentifier("agent.scheduledSend.recoveryMessage")
                }
                if let recoveryBlockedMessage = props.recoveryBlockedMessage {
                    Text(recoveryBlockedMessage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .hoverTooltip(recoveryBlockedMessage)
                        .accessibilityIdentifier("agent.scheduledSend.recoveryBlockedMessage")
                }
                if let actionError {
                    Text(actionError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .hoverTooltip(actionError)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if props.isUnreadable {
                Button("Discard", role: .destructive) {
                    performDiscardUnreadable()
                }
            } else if isSavingFailed {
                // Persistence-only retry: the message was already delivered; never a re-send.
                Button("Retry saving") {
                    performRetrySaving()
                }
                .accessibilityIdentifier("agent.scheduledSend.retrySaving")
            } else if !isDispatching {
                if case .needsAttention = props.pendingConfirmationSaving {
                    // Persistence-only retry of the pending confirmation; never a send.
                    Button("Retry saving") {
                        performRetrySaving()
                    }
                    .accessibilityIdentifier("agent.scheduledSend.retryConfirmationSaving")
                }
                Button("Edit") {
                    presentEditor(.edit)
                }
                Button("Reschedule") {
                    presentEditor(.reschedule)
                }
                sendNowControl
                Button("Cancel", role: .destructive) {
                    performCancel()
                }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(isActionInFlight)
        .padding(.horizontal, 10)
        .frame(height: bannerHeight)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 0.5)
        )
        .popover(item: $editorMode) { mode in
            editor(mode: mode)
        }
        .onChange(of: props) { _, newProps in
            guard editorMode == nil else { return }
            let now = Date()
            editorText = newProps.rawText
            editorNotBefore = newProps.notBefore
            editorDateRange = AgentScheduledSendTiming.editorRange(
                originalNotBefore: newProps.notBefore,
                now: now
            )
            editorRunAlongside = newProps.runAlongsideOtherSessions
            editorRemovedImageIDs = []
            editorRemovedTaggedFileIDs = []
        }
    }

    @ViewBuilder
    private var sendNowControl: some View {
        if props.isNewSessionStart {
            Menu {
                Button("Send when the workspace is available") {
                    performSendNow(runAlongsideOtherSessions: false)
                }
                Button("Run alongside other sessions") {
                    performSendNow(runAlongsideOtherSessions: true)
                }
            } label: {
                Text("Send now")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        } else {
            Button("Send now") {
                performSendNow(runAlongsideOtherSessions: false)
            }
        }
    }

    private func editor(mode: EditorMode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .edit ? "Edit scheduled message" : "Reschedule message")
                .font(.headline)

            TextEditor(text: $editorText)
                .font(.body)
                .frame(width: 360, height: 90)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )

            if editorAttachments.hasAny {
                AgentAttachmentsStrip(
                    snapshot: editorAttachments,
                    allowsRemoval: true,
                    onRemoveImage: { editorRemovedImageIDs.insert($0) },
                    onRemoveTaggedFile: { editorRemovedTaggedFileIDs.insert($0) }
                )
                .equatable()
            }

            DatePicker(
                "Send after",
                selection: $editorNotBefore,
                in: editorDateRange,
                displayedComponents: [.date, .hourAndMinute]
            )

            if props.isNewSessionStart {
                Toggle("Run alongside other sessions", isOn: $editorRunAlongside)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    editorMode = nil
                }
                Button("Save") {
                    performUpdate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSaveEditor)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private var editorAttachments: AgentAttachmentStripSnapshot {
        AgentAttachmentStripSnapshot(
            scopeTabID: props.attachments.scopeTabID,
            imageAttachments: props.attachments.imageAttachments.filter {
                !editorRemovedImageIDs.contains($0.id)
            },
            taggedFileAttachments: props.attachments.taggedFileAttachments.filter {
                !editorRemovedTaggedFileIDs.contains($0.id)
            }
        )
    }

    private var canSaveEditor: Bool {
        !editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || editorAttachments.hasAny
    }

    private func presentEditor(_ mode: EditorMode) {
        let now = Date()
        actionError = nil
        editorText = props.rawText
        editorNotBefore = props.notBefore
        editorDateRange = AgentScheduledSendTiming.editorRange(
            originalNotBefore: props.notBefore,
            now: now
        )
        editorRunAlongside = props.runAlongsideOtherSessions
        editorRemovedImageIDs = []
        editorRemovedTaggedFileIDs = []
        editorMode = mode
    }

    private func performUpdate() {
        isActionInFlight = true
        actionError = nil
        Task { @MainActor in
            let error = await actions.update(
                props.tabID,
                props.id,
                editorText,
                editorNotBefore,
                editorRunAlongside,
                editorRemovedImageIDs,
                editorRemovedTaggedFileIDs
            )
            isActionInFlight = false
            actionError = error
            if error == nil {
                editorMode = nil
            }
        }
    }

    private func performCancel() {
        isActionInFlight = true
        actionError = nil
        Task { @MainActor in
            let error = await actions.cancel(props.tabID, props.id)
            isActionInFlight = false
            actionError = error
        }
    }

    private func performDiscardUnreadable() {
        isActionInFlight = true
        actionError = nil
        Task { @MainActor in
            let error = await actions.discardUnreadable(props.tabID)
            isActionInFlight = false
            actionError = error
        }
    }

    private func performRetrySaving() {
        isActionInFlight = true
        actionError = nil
        Task { @MainActor in
            let error = await actions.retrySaving(props.tabID)
            isActionInFlight = false
            actionError = error
        }
    }

    private func performSendNow(runAlongsideOtherSessions: Bool) {
        isActionInFlight = true
        actionError = nil
        Task { @MainActor in
            let error = await actions.sendNow(
                props.tabID,
                props.id,
                runAlongsideOtherSessions
            )
            isActionInFlight = false
            actionError = error
        }
    }

    private var bannerHeight: CGFloat {
        // Every optional line under the status grows the fixed height so none is clipped.
        48 + (props.recoveryMessage == nil ? 0 : 16)
            + (props.recoveryBlockedMessage == nil ? 0 : 26)
            + (actionError == nil ? 0 : 14)
    }

    private var isDispatching: Bool {
        switch props.status {
        case .dispatching, .finalizing, .savingFailed:
            true
        case .scheduled, .waitingForCurrentRun, .waitingForWorkspace, .needsConfirmation, .failed, .unreadable:
            false
        }
    }

    private var isSavingFailed: Bool {
        if case .savingFailed = props.status { return true }
        return false
    }

    private var statusIcon: String {
        switch props.status {
        case .scheduled, .waitingForCurrentRun, .waitingForWorkspace:
            "clock"
        case .needsConfirmation, .failed, .unreadable, .savingFailed:
            "exclamationmark.clock"
        case .dispatching, .finalizing:
            "paperplane"
        }
    }

    private var statusColor: Color {
        switch props.status {
        case .needsConfirmation, .failed, .unreadable, .savingFailed:
            .orange
        case .dispatching, .finalizing:
            .accentColor
        case .scheduled, .waitingForCurrentRun, .waitingForWorkspace:
            .secondary
        }
    }

    private var statusText: String {
        let scheduledTime = AgentScheduledSendDateFormatting.dateAndTime(props.notBefore)
        switch props.status {
        case .scheduled:
            return "Scheduled for \(scheduledTime)"
        case let .waitingForCurrentRun(blockingSessionName):
            return waitingText(
                scheduledTime: scheduledTime,
                fallback: "waiting for this run to finish",
                blockingSessionName: blockingSessionName
            )
        case let .waitingForWorkspace(blockingSessionName):
            return waitingText(
                scheduledTime: scheduledTime,
                fallback: "waiting for the workspace to become available",
                blockingSessionName: blockingSessionName
            )
        case let .needsConfirmation(reason):
            if props.pendingConfirmationSaving == .saving {
                return "Scheduled for \(scheduledTime) · \(confirmationText(reason)) · saving…"
            }
            return "Scheduled for \(scheduledTime) · \(confirmationText(reason))"
        case .dispatching:
            return "Sending scheduled message…"
        case .finalizing:
            return "Delivered · saving…"
        case let .savingFailed(message):
            if let message, !message.isEmpty {
                return "Delivered · not saved yet · \(message)"
            }
            return "Delivered · not saved yet"
        case let .failed(message):
            if let message, !message.isEmpty {
                return "Delivery unconfirmed · \(message)"
            }
            return "Delivery unconfirmed"
        case .unreadable:
            return "Unreadable scheduled message"
        }
    }

    private func waitingText(
        scheduledTime: String,
        fallback: String,
        blockingSessionName: String?
    ) -> String {
        let prefix = if let firstEligibleAt = props.firstEligibleAt {
            "Waiting since \(AgentScheduledSendDateFormatting.time(firstEligibleAt))"
        } else {
            "Scheduled for \(scheduledTime)"
        }
        if let blockingSessionName, !blockingSessionName.isEmpty {
            return "\(prefix) · waiting for \(blockingSessionName)"
        }
        return "\(prefix) · \(fallback)"
    }

    private func confirmationText(
        _ reason: AgentScheduledSendPersist.ConfirmationReason?
    ) -> String {
        reason?.displayText ?? "confirmation required"
    }
}
