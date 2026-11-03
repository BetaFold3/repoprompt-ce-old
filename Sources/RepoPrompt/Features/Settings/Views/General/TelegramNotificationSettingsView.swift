import SwiftUI

/// Settings for Telegram attention notifications on this (executing) Mac. The bot token is
/// entered into a blank secure field, never shown or preloaded, and cleared after a successful
/// save and when the view disappears.
struct TelegramNotificationSettingsView: View {
    let service: TelegramAttentionNotificationService
    @State private var chatIDDraft = ""
    @State private var idleMinutesDraft = ""
    @State private var tokenDraft = ""
    @Environment(\.repoPromptFontScalePreset) private var fontPreset

    /// Shows the automatic-notification preference in effect for this launch, not delivery readiness; a fixed notice
    /// explains when it is on but nothing can be delivered.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { service.isEnabled },
            set: { _ = service.setEnabled($0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: fontPreset.scaledClamped(18, max: 26)) {
                SettingSection(
                    title: "Telegram",
                    description: "Message your phone when a root Agent Mode turn finishes or an ask_user question is waiting. Configure on the Mac executing the session."
                ) {
                    VStack(alignment: .leading, spacing: fontPreset.scaledClamped(10, max: 14)) {
                        if !service.isStarted {
                            note(TelegramAttentionNotificationService.TokenStatus.notLoaded.message)
                        }

                        SettingToggle(
                            title: "Send Telegram notifications",
                            description: "Off by default. Automatic notifications use the idle setting below. Zero means always notify; otherwise enter whole minutes. If idle time is unavailable, notifications are sent. Events skipped while you are active are not sent later.",
                            isOn: enabledBinding
                        )
                        .disabled(!service.isStarted)

                        ForEach(service.notices, id: \.self) { notice in
                            note(notice.message)
                        }
                        if let hint = service.sessionLinkHint {
                            note(hint)
                        }
                        if service.offIsUnsaved {
                            Button("Retry Saving Off") { _ = service.setEnabled(false) }
                        }

                        idleRow
                        chatIDRow
                        tokenRow

                        HStack(spacing: fontPreset.scaledClamped(8, max: 12)) {
                            Button("Send Test") { _ = service.sendTest() }
                                .disabled(!service.isStarted || !service.isDeliveryConfigured || service.isTestPending)
                            if let record = service.lastTestRecord {
                                label("Test: \(TelegramAttentionNotificationService.message(for: record))")
                            }
                        }
                        label("Send Test ignores the idle setting and queues a test message, even while automatic notifications are off.")

                        if let action = service.lastAction {
                            label(action.message)
                        }
                    }
                }

                SettingSection(
                    title: "Last Results",
                    description: "Automatic notifications in this launch only; Send test results appear above. No message content or credentials are shown."
                ) {
                    VStack(alignment: .leading, spacing: fontPreset.scaledClamped(6, max: 9)) {
                        label("Last delivery: \(service.admission.lastDeliveryOutcome.map { TelegramAttentionNotificationService.message(for: $0) } ?? "None")")
                        label("Last skipped: \(service.admission.lastSuppression.map { TelegramAttentionNotificationService.message(for: $0) } ?? "None")")
                    }
                }
            }
            .padding(fontPreset.scaledClamped(20, max: 28))
        }
        .onAppear {
            chatIDDraft = service.chatID ?? ""
            idleMinutesDraft = String(service.idleThresholdMinutes)
        }
        .onDisappear { tokenDraft = "" }
    }

    private var idleRow: some View {
        VStack(alignment: .leading, spacing: fontPreset.scaledClamped(4, max: 6)) {
            HStack(spacing: fontPreset.scaledClamped(8, max: 12)) {
                TextField("Idle minutes", text: $idleMinutesDraft)
                    .onSubmit { saveIdleMinutes(idleMinutesDraft) }
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                Button("Save Idle Setting") { saveIdleMinutes(idleMinutesDraft) }
                    .disabled(!service.isStarted)
                Button("Always Notify (0 minutes)") { saveIdleMinutes("0") }
                    .disabled(!service.isStarted)
            }
            if service.isStarted {
                label(savedIdleDescription)
            }
        }
    }

    private var savedIdleDescription: String {
        let minutes = service.idleThresholdMinutes
        if minutes == 0 {
            return "Saved idle setting: always notify."
        }
        return "Saved idle setting: at least \(minutes) minute\(minutes == 1 ? "" : "s") idle."
    }

    /// Keeps an invalid or unsaved draft for correction; normalizes it after a successful save.
    private func saveIdleMinutes(_ draft: String) {
        if service.saveIdleThresholdMinutes(draft) {
            idleMinutesDraft = String(service.idleThresholdMinutes)
        }
    }

    private var chatIDRow: some View {
        HStack(spacing: fontPreset.scaledClamped(8, max: 12)) {
            TextField("Chat ID", text: $chatIDDraft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Button("Save Chat ID") {
                if service.saveChatID(chatIDDraft) {
                    chatIDDraft = service.chatID ?? ""
                }
            }
            .disabled(!service.isStarted)
        }
    }

    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: fontPreset.scaledClamped(4, max: 6)) {
            HStack(spacing: fontPreset.scaledClamped(8, max: 12)) {
                SecureField("Bot token", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()
                    .frame(maxWidth: 260)
                Button("Save Token") {
                    if service.saveToken(tokenDraft) {
                        tokenDraft = ""
                    }
                }
                .disabled(!service.isStarted || tokenDraft.isEmpty)
                Button("Remove Token") { _ = service.removeToken() }
                    .disabled(!service.isStarted || service.tokenStatus == .missing)
            }
            if service.isStarted {
                label(service.tokenStatus.message)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
            .foregroundColor(.secondary)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
            .foregroundColor(.secondary)
            .padding(fontPreset.scaledClamped(10, max: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
