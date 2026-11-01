import Foundation

/// Owner-approved, one-way permission for every Agent Mode session in `sourceWorkspaceID` to list
/// and steer top-level sessions in `targetWorkspaceID`. Keyed by workspace UUID, so it survives
/// renames; a grant naming a deleted workspace stays inert until removed.
struct WorkspaceSteeringGrant: Codable, Equatable, Hashable {
    let sourceWorkspaceID: UUID
    let targetWorkspaceID: UUID
    let createdAt: Date
}

/// Validating read/write access to the grants stored in the global settings document. Lookup is
/// one exact directed pair: no chaining, no reciprocity, no self-grants. Checks and writes use
/// the file, not the in-memory copy, because Dev and release builds share it while running.
@MainActor
struct WorkspaceSteeringGrantStore {
    enum AddResult: Equatable {
        case added
        case alreadyGranted
        case rejectedSelfGrant
        case saveFailed
    }

    enum RemoveResult: Equatable {
        case removed
        case notFound
        case saveFailed
    }

    /// A grant with names resolved from the current workspace list; nil means unknown workspace.
    struct Row: Identifiable, Equatable {
        let grant: WorkspaceSteeringGrant
        let sourceName: String?
        let targetName: String?

        var id: String {
            "\(grant.sourceWorkspaceID.uuidString)>\(grant.targetWorkspaceID.uuidString)"
        }
    }

    static var shared: WorkspaceSteeringGrantStore {
        WorkspaceSteeringGrantStore(settings: .shared)
    }

    let settings: GlobalSettingsStore
    private let now: () -> Date

    init(settings: GlobalSettingsStore, now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.now = now
    }

    /// In-memory copy for display; see `GlobalSettingsStore.workspaceSteeringGrants()`.
    var grants: [WorkspaceSteeringGrant] {
        settings.workspaceSteeringGrants()
    }

    /// Reads the file on every call and fails closed when it is unreadable.
    func isGranted(source: UUID, target: UUID) -> Bool {
        guard source != target else { return false }
        return (settings.persistedWorkspaceSteeringGrants() ?? []).contains(where: Self.matching(source, target))
    }

    /// Adds a directed grant. Nothing is written for a self-grant or an existing pair.
    func add(source: UUID, target: UUID) -> AddResult {
        guard source != target else { return .rejectedSelfGrant }
        let grant = WorkspaceSteeringGrant(sourceWorkspaceID: source, targetWorkspaceID: target, createdAt: now())
        let result = settings.updateWorkspaceSteeringGrantsAndSave { grants -> AddResult in
            guard !grants.contains(where: Self.matching(source, target)) else { return .alreadyGranted }
            grants.append(grant)
            return .added
        }
        guard let result else { return .saveFailed }
        return result.saved ? result.outcome : .saveFailed
    }

    /// Removes every stored copy of the directed pair; a failed save leaves it in effect.
    func remove(source: UUID, target: UUID) -> RemoveResult {
        let result = settings.updateWorkspaceSteeringGrantsAndSave { grants -> RemoveResult in
            guard grants.contains(where: Self.matching(source, target)) else { return .notFound }
            grants.removeAll(where: Self.matching(source, target))
            return .removed
        }
        guard let result else { return .saveFailed }
        return result.saved ? result.outcome : .saveFailed
    }

    /// One row per directed pair (a hand-edited duplicate would otherwise repeat a row ID).
    func rows(workspaces: [WorkspaceModel]) -> [Row] {
        let names = Self.displayNames(for: workspaces)
        var seen = Set<String>()
        return grants.compactMap { grant in
            let row = Row(
                grant: grant,
                sourceName: names[grant.sourceWorkspaceID],
                targetName: names[grant.targetWorkspaceID]
            )
            return seen.insert(row.id).inserted ? row : nil
        }
    }

    /// Workspace names, with a short UUID suffix when two workspaces share a name.
    static func displayNames(for workspaces: [WorkspaceModel]) -> [UUID: String] {
        let nameCounts = Dictionary(workspaces.map { ($0.name, 1) }, uniquingKeysWith: +)
        return Dictionary(
            workspaces.map { workspace in
                let name = nameCounts[workspace.name, default: 0] > 1
                    ? "\(workspace.name) (\(workspace.id.uuidString.prefix(8)))"
                    : workspace.name
                return (workspace.id, name)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func matching(_ source: UUID, _ target: UUID) -> (WorkspaceSteeringGrant) -> Bool {
        { $0.sourceWorkspaceID == source && $0.targetWorkspaceID == target }
    }
}
