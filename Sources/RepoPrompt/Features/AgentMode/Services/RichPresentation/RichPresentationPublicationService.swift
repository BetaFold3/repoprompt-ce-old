import Foundation
import RepoPromptAgentCore

/// App-wide admission and root revisions. Not a tool: `RichPresentationMCPToolService` calls it.
@MainActor
final class RichPresentationPublicationService: ObservableObject {
    static let shared = RichPresentationPublicationService()
    struct Storage: Equatable {
        let workspaceID: UUID
        let root: URL
        let revision: UInt64
    }

    struct Mutation {
        let id: UUID
        let workspaceIDs: Set<UUID>
    }

    private var revisions: [UUID: UInt64] = [:]
    private var mutations: [UUID: Set<UUID>] = [:]
    /// Advances when any root mutation begins or ends, so mounted history views re-evaluate their
    /// load identity (a capture is refused while the mutation runs and has a new revision after).
    @Published private(set) var storageGeneration: UInt64 = 0
    private var operations: [UUID: (workspaceID: UUID, sessionIDs: Set<UUID>, cancel: () -> Void)] = [:]
    private var deletionObserver: NSObjectProtocol?
    private let fetcher: RichPresentationImageFetcher

    init(fetcher: RichPresentationImageFetcher = .shared) {
        self.fetcher = fetcher
        deletionObserver = NotificationCenter.default.addObserver(
            forName: .agentSessionDeletionDidCommit, object: nil, queue: .main
        ) { [weak self] notification in
            guard let sessionID = notification.userInfo?["sessionID"] as? UUID else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for operation in operations.values where operation.sessionIDs.contains(sessionID) {
                    operation.cancel()
                }
            }
        }
    }

    deinit {
        if let deletionObserver { NotificationCenter.default.removeObserver(deletionObserver) }
    }

    func capture(workspaceID: UUID, root: URL) throws -> Storage {
        guard !mutations.values.contains(where: { $0.contains(workspaceID) }) else {
            throw AgentRichArtifactError.storageMoved
        }
        return Storage(workspaceID: workspaceID, root: root.standardizedFileURL.resolvingSymlinksInPath(), revision: revisions[workspaceID] ?? 0)
    }

    /// D2 storage agreement gate. Rich creation and artifact-bearing handoffs are supported only
    /// when the workspace's actual resolved directory (this window's workspace manager, and the
    /// process-wide persisted global location another window may have changed) is the directory
    /// session persistence uses for it. Otherwise they are refused with a non-retryable error;
    /// session persistence itself is unchanged. Computes only: creates nothing.
    static func agreedStorageRoot(
        for workspace: WorkspaceModel,
        dataService: AgentSessionDataService,
        workspaceManager: WorkspaceManagerViewModel
    ) throws -> URL {
        func canonical(_ url: URL) -> URL {
            url.standardizedFileURL.resolvingSymlinksInPath()
        }
        let sessionRoot = canonical(dataService.workspaceStorageRoot(for: workspace))
        let windowRoot = canonical(workspaceManager.workspaceDirectory(for: workspace))
        let persistedRoot = canonical(workspaceManager.workspaceDirectory(
            for: workspace, baseRoot: WorkspaceManagerViewModel.recoveryInventoryBaseRoot()
        ))
        guard sessionRoot == windowRoot, sessionRoot == persistedRoot else {
            throw AgentRichArtifactError.storageLocationUnsupported
        }
        return sessionRoot
    }

    /// The D2-agreed root of the current model of this exact workspace (looked up by ID in the
    /// window's workspace list, never the selected tab or active workspace).
    static func currentAgreedStorageRoot(
        workspaceID: UUID, dataService: AgentSessionDataService, workspaceManager: WorkspaceManagerViewModel
    ) throws -> URL {
        guard let current = workspaceManager.workspaces.first(where: { $0.id == workspaceID }) else {
            throw AgentRichArtifactError.storageMoved
        }
        return try agreedStorageRoot(for: current, dataService: dataService, workspaceManager: workspaceManager)
    }

    /// Creation's final check (run with the install on the main actor): the captured revision and
    /// root still hold AND the workspace and session roots still agree.
    func validateAgreedStorage(
        _ storage: Storage, dataService: AgentSessionDataService, workspaceManager: WorkspaceManagerViewModel
    ) throws {
        try validate(storage, currentRoot: Self.currentAgreedStorageRoot(
            workspaceID: storage.workspaceID, dataService: dataService, workspaceManager: workspaceManager
        ))
    }

    func validate(_ storage: Storage, currentRoot: URL) throws {
        guard try capture(workspaceID: storage.workspaceID, root: currentRoot) == storage else {
            throw AgentRichArtifactError.storageMoved
        }
    }

    /// Called synchronously BEFORE the first suspension, including when a physical move fails.
    func beginMutation(workspaceIDs: Set<UUID>) -> Mutation {
        let token = Mutation(id: UUID(), workspaceIDs: workspaceIDs)
        mutations[token.id] = workspaceIDs
        for id in workspaceIDs {
            revisions[id, default: 0] &+= 1
        }
        storageGeneration &+= 1
        for operation in operations.values where workspaceIDs.contains(operation.workspaceID) {
            operation.cancel()
        }
        return token
    }

    func endMutation(_ mutation: Mutation) {
        mutations.removeValue(forKey: mutation.id)
        storageGeneration &+= 1
    }

    /// Nonqueued two-slot bound, shared by publications and whole handoff transactions.
    /// The task remains owned and awaited through cancellation and local cleanup.
    /// It covers publication work, including image acquisition, but not the owner save that
    /// `RichPresentationMCPToolService` performs before calling `publish`. `present_rich` runs on
    /// the control lane without a window-wide lease, so this bound (with the session gate, fence
    /// and final install check) is what limits concurrent publication work.
    func withPublication<T>(
        workspaceID: UUID, sessionIDs: Set<UUID> = [], operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        guard operations.count < 2 else { throw AgentRichArtifactError.busy }
        let id = UUID()
        let task = Task { @MainActor in try await operation() }
        operations[id] = (workspaceID, sessionIDs, { task.cancel() })
        defer { operations.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func publish(
        data: Data, metadata: MCPServerViewModel.RequestMetadata,
        resolver suppliedResolver: RichPresentationMCPAuthorityResolver? = nil,
        dataService: AgentSessionDataService,
        workspace: WorkspaceModel,
        state: AgentSessionPersistenceState,
        workspaceManager: WorkspaceManagerViewModel
    ) async throws -> RichPresentationReference {
        // The root is the D2-agreed root of the CURRENT model of this exact workspace, so a
        // completed rename is picked up by the next capture without relaunch, a capture taken
        // before it fails by revision or root, and a workspace/session root disagreement refuses
        // here (before authority resolution, admission, download or any write), at capture, and
        // at the final install check. `RichPresentationMCPToolService` checks the same agreement
        // before the owner save, so a refused tool call saves nothing either.
        let currentRoot: @MainActor () throws -> URL = {
            try Self.currentAgreedStorageRoot(
                workspaceID: workspace.id, dataService: dataService, workspaceManager: workspaceManager
            )
        }
        _ = try currentRoot()
        let resolver = suppliedResolver ?? .live
        let authority = try await resolver.resolve(metadata: metadata).get()
        guard let invocationID = authority.toolInvocationID, authority.workspaceID == workspace.id,
              authority.sessionID == state.stamp.sessionID
        else { throw RichPresentationMCPAuthorityResolver.Denial.invalidContext(RichPresentationMCPAuthorityResolver.noAttemptAuthorityMessage) }
        return try await withPublication(workspaceID: workspace.id, sessionIDs: [authority.sessionID]) {
            let input = try RichPresentationValidator.validateInput(data: data)
            let storage = try self.capture(workspaceID: workspace.id, root: currentRoot())
            guard let captureWorkspace = workspaceManager.workspaces.first(where: { $0.id == workspace.id }) else {
                throw AgentRichArtifactError.storageMoved
            }
            let root = try await dataService.captureRichArtifactRoot(
                state: state, workspace: captureWorkspace, resolvedRoot: storage.root
            )
            let images = try await self.fetcher.fetchImages(for: input, approvedHosts: authority.policy?.approvedImageHosts ?? [])
            let artifactID = UUID()
            let manifest = try AgentRichArtifactManifest(
                artifactID: artifactID, input: input, outcomes: images.map(\.outcome),
                provenance: AgentRichArtifactProvenance(
                    runID: authority.runID, attemptID: authority.ownership.attemptID,
                    sessionID: authority.sessionID, toolInvocationID: invocationID
                )
            )
            var assets: [UUID: Data] = [:]
            for image in images {
                if case let .asset(asset) = image.outcome.outcome, let bytes = image.jpegData {
                    assets[asset.assetID] = bytes
                }
            }
            try await dataService.publishRichArtifact(state: state, root: root, manifest: manifest, assets: assets) {
                try Task.checkCancellation()
                _ = try resolver.revalidate(authority).get()
                try self.validateAgreedStorage(storage, dataService: dataService, workspaceManager: workspaceManager)
            }
            return RichPresentationReference(
                artifactID: artifactID, kind: input.kind, title: input.title,
                fallbackText: "Rich presentation summary: " + input.title,
                warnings: images.compactMap(\.outcome.warning)
            )
        }
    }
}
