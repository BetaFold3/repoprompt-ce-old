import RepoPromptUI
import SwiftUI

/// Lists, adds and removes workspace→workspace steering grants. Embedded in the Settings
/// "Manage Workspaces" page and reuses its workspace list (non-system workspaces).
struct WorkspaceSteeringGrantsSettingsView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManagerViewModel
    @ObservedObject var settings: GlobalSettingsStore
    @State private var sourceID: UUID?
    @State private var targetID: UUID?
    @State private var errorMessage: String?
    @Environment(\.repoPromptFontScalePreset) private var fontPreset

    private var store: WorkspaceSteeringGrantStore {
        WorkspaceSteeringGrantStore(settings: settings)
    }

    private var pickableWorkspaces: [WorkspaceModel] {
        workspaceManager.workspaces
            .filter { !$0.isSystemWorkspace }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var canAdd: Bool {
        guard let sourceID, let targetID, sourceID != targetID else { return false }
        // In-memory check for enabling only; `add` rechecks the file under the settings lock.
        return !store.grants.contains { $0.sourceWorkspaceID == sourceID && $0.targetWorkspaceID == targetID }
    }

    var body: some View {
        SettingSection(
            title: "Workspace Steering",
            description: "Each grant lets every Agent Mode session in the source workspace list and steer top-level sessions in the target workspace. Grants are one-way and stay until you remove them."
        ) {
            VStack(alignment: .leading, spacing: fontPreset.scaledClamped(8, max: 12)) {
                let rows = store.rows(workspaces: workspaceManager.workspaces)
                if rows.isEmpty {
                    Text("No grants.")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(rows) { row in
                        HStack(spacing: fontPreset.scaledClamped(8, max: 12)) {
                            Text("\(Self.displayName(row.sourceName)) → \(Self.displayName(row.targetName))")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 13))
                            Spacer()
                            Button("Remove") {
                                let result = store.remove(
                                    source: row.grant.sourceWorkspaceID,
                                    target: row.grant.targetWorkspaceID
                                )
                                errorMessage = result == .saveFailed
                                    ? "Couldn't save settings; the grant is still in effect." : nil
                            }
                        }
                    }
                }

                HStack(spacing: fontPreset.scaledClamped(8, max: 12)) {
                    workspacePicker("Source", selection: $sourceID)
                    Text("→")
                    workspacePicker("Target", selection: $targetID)
                    Button("Add") {
                        guard let sourceID, let targetID else { return }
                        switch store.add(source: sourceID, target: targetID) {
                        case .added, .alreadyGranted:
                            errorMessage = nil
                            self.sourceID = nil
                            self.targetID = nil
                        case .rejectedSelfGrant:
                            errorMessage = "A workspace can't be granted to itself."
                        case .saveFailed:
                            errorMessage = "Couldn't save settings; no grant was added."
                        }
                    }
                    .disabled(!canAdd)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundColor(.red)
                }
            }
        }
        .onAppear { settings.refreshWorkspaceSteeringGrantsFromDisk() }
    }

    private func workspacePicker(_ title: String, selection: Binding<UUID?>) -> some View {
        let workspaces = pickableWorkspaces
        let names = WorkspaceSteeringGrantStore.displayNames(for: workspaces)
        return Picker(title, selection: selection) {
            Text("Choose…").tag(UUID?.none)
            ForEach(workspaces) { workspace in
                Text(names[workspace.id] ?? workspace.name).tag(UUID?.some(workspace.id))
            }
        }
        .fixedSize()
    }

    private static func displayName(_ name: String?) -> String {
        name.map { "'\($0)'" } ?? "unknown workspace"
    }
}
