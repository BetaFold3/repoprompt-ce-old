import RepoPromptAgentCore
import RepoPromptUI
import SwiftUI

/// An editor draft of one workspace's rich presentation permissions and the committed entry it
/// started from. A clean draft follows the committed entry when it changes elsewhere (another
/// settings view, or the on-disk entry another build saved); a dirty draft keeps the owner's edit
/// and saves only as a compare-and-set against `base`, so it never overwrites a newer choice.
struct RichPresentationSettingsDraft: Equatable {
    private(set) var base: WorkspaceRichPresentationSettings
    var enabled: Bool
    var approvedImageHosts: [String]

    init(committed: WorkspaceRichPresentationSettings) {
        base = committed
        enabled = committed.enabled
        approvedImageHosts = committed.approvedImageHosts
    }

    /// The owner changed the toggle or the host list since the draft started.
    var isDirty: Bool {
        enabled != base.enabled || approvedImageHosts != base.approvedImageHosts
    }

    /// The complete entry Save writes.
    var candidate: WorkspaceRichPresentationSettings {
        WorkspaceRichPresentationSettings(enabled: enabled, approvedImageHosts: approvedImageHosts)
    }

    /// The committed entry changed after this dirty draft started.
    func hasConflict(with committed: WorkspaceRichPresentationSettings) -> Bool {
        isDirty && committed != base
    }

    /// Rebases onto the current committed entry whenever that loses no unsaved edit: the draft is
    /// clean (including an edit undone after the committed entry changed elsewhere), or its
    /// candidate already equals the committed entry. A dirty, different draft keeps its base.
    /// Called when the committed entry or the draft changes.
    mutating func reconcile(withCommitted committed: WorkspaceRichPresentationSettings) {
        guard base != committed, !isDirty || candidate == committed else { return }
        self = RichPresentationSettingsDraft(committed: committed)
    }
}

/// Workspace-specific rich presentation permissions (rich presentation spec, A3). Edits a local
/// draft and commits the toggle and host list together through
/// `GlobalSettingsStore.saveRichPresentationSettings` as a compare-and-set against the entry the
/// draft started from; a failed or conflicting save leaves the committed value in effect and keeps
/// the draft. With no workspace, every control is disabled.
struct RichPresentationSettingsSection: View {
    @ObservedObject var settings: GlobalSettingsStore
    let workspaceID: UUID?
    let workspaceName: String?

    @State private var draft = RichPresentationSettingsDraft(committed: .disabled)
    @State private var hostInput = ""
    @State private var hostError: String?
    @State private var saveError: String?
    @Environment(\.repoPromptFontScalePreset) private var fontPreset

    private var committed: WorkspaceRichPresentationSettings {
        guard let workspaceID else { return .disabled }
        return settings.richPresentationSettings(for: workspaceID)
    }

    private var hasChanges: Bool {
        workspaceID != nil && (committed.storedEntryWasInvalid || draft.isDirty)
    }

    var body: some View {
        SettingSection(
            title: "Rich Presentations",
            description: "Not yet available: no agent tool uses these settings yet. When available, Agent Mode runs in this workspace will be able to publish inline charts and newspaper briefings."
        ) {
            VStack(alignment: .leading, spacing: fontPreset.scaledClamped(10, max: 15)) {
                workspaceLabel

                Toggle("Allow rich presentations in this workspace", isOn: $draft.enabled)
                    .disabled(workspaceID == nil)

                if committed.storedEntryWasInvalid {
                    caption("The stored settings for this workspace were invalid and grant nothing. Save to replace them.")
                        .foregroundColor(.orange)
                }

                if draft.hasConflict(with: committed) {
                    caption("These settings changed elsewhere after you started editing. Revert to load the current settings.")
                        .foregroundColor(.orange)
                }

                approvedHostsEditor

                VStack(alignment: .leading, spacing: fontPreset.scaledClamped(4, max: 7)) {
                    caption("Changes apply to the next agent run. Runs already in progress keep the settings they started with.")
                    caption("Only exact hosts are approved. Approving a site doesn't approve its CDN; add the host that serves the image. With no approved hosts, article images show placeholders.")
                    caption("Image publishers see your Mac's IP address and the full image URL, including its path and query. Fetches also trust your Mac's DNS, TLS and proxy configuration for each approved host.")
                }

                HStack(spacing: fontPreset.scaledClamped(8, max: 12)) {
                    Button("Save") { save() }
                        .disabled(!hasChanges)
                    Button("Revert") { resetDraft() }
                        .disabled(!hasChanges)
                }

                if let saveError {
                    caption(saveError)
                        .foregroundColor(.red)
                }
            }
        }
        .onAppear {
            // Another build may have changed the saved entry that new runs admit from.
            settings.refreshRichPresentationSettingsFromDisk()
            resetDraft()
        }
        .onChange(of: workspaceID) { _, _ in resetDraft() }
        .onChange(of: committed) { _, newValue in draft.reconcile(withCommitted: newValue) }
        .onChange(of: draft) { _, _ in draft.reconcile(withCommitted: committed) }
    }

    @ViewBuilder
    private var workspaceLabel: some View {
        if workspaceID == nil {
            caption("Open a workspace to configure rich presentations.")
        } else {
            caption("Workspace: \(workspaceName ?? "Untitled")")
        }
    }

    private var approvedHostsEditor: some View {
        VStack(alignment: .leading, spacing: fontPreset.scaledClamped(6, max: 10)) {
            Text("Approved image hosts")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .medium))
            if draft.approvedImageHosts.isEmpty {
                caption("No approved hosts.")
            } else {
                ForEach(draft.approvedImageHosts, id: \.self) { host in
                    HStack(spacing: fontPreset.scaledClamped(8, max: 12)) {
                        Text(host)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 13))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Remove") {
                            draft.approvedImageHosts.removeAll { $0 == host }
                        }
                        .disabled(workspaceID == nil)
                    }
                }
            }
            HStack(spacing: fontPreset.scaledClamped(8, max: 12)) {
                TextField("images.example.com", text: $hostInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onSubmit { addHost() }
                Button("Add") { addHost() }
                    .disabled(hostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(workspaceID == nil)
            if let hostError {
                caption(hostError)
                    .foregroundColor(.red)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func addHost() {
        switch RichPresentationURLPolicy.normalizeApprovedHostInput(hostInput) {
        case let .success(host):
            // Canonical (deduplicated, sorted), as the committed entry stores it.
            draft.approvedImageHosts = WorkspaceRichPresentationSettings(
                enabled: draft.enabled,
                approvedImageHosts: draft.approvedImageHosts + [host]
            ).approvedImageHosts
            hostInput = ""
            hostError = nil
        case let .failure(rejection):
            hostError = rejection.message
        }
    }

    private func save() {
        guard let workspaceID else { return }
        switch settings.saveRichPresentationSettings(draft.candidate, for: workspaceID, replacing: draft.base) {
        case .saved:
            saveError = nil
            resetDraft()
        case .conflict:
            saveError = "Nothing was saved: these settings changed elsewhere after you started editing. Revert to load the current settings, then make your change again."
        case .failed:
            saveError = "Couldn't save settings; the previous rich presentation settings are still in effect."
        }
    }

    private func resetDraft() {
        draft = RichPresentationSettingsDraft(committed: committed)
        hostInput = ""
        hostError = nil
        saveError = nil
    }
}
