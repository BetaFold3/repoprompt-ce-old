import Foundation
import RepoPromptWorkspace

struct WorkspaceFileEditHost: FileEditHost {
    let mutationService: WorkspaceFileMutationService
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let lookupRootScope: WorkspaceLookupRootScope
    let createPathResolutionPolicy: WorkspaceFileCreatePathResolutionPolicy
    let selectCreatedFiles: Bool

    init(
        store: WorkspaceFileContextStore,
        selectionCoordinator: WorkspaceSelectionCoordinator? = nil,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        createPathResolutionPolicy: WorkspaceFileCreatePathResolutionPolicy = .literalPreferredIfStronger,
        selectCreatedFiles: Bool = true
    ) {
        mutationService = WorkspaceFileMutationService(store: store)
        self.selectionCoordinator = selectionCoordinator
        self.lookupRootScope = lookupRootScope
        self.createPathResolutionPolicy = createPathResolutionPolicy
        self.selectCreatedFiles = selectCreatedFiles
    }

    func fileExists(path: String) async -> Bool {
        await (mutationService.exactExistingFile(path, rootScope: lookupRootScope)) != nil
    }

    /// Step 5a: the canonical absolute path of the existing file `path` names now (the same exact
    /// lookup `readText`/`writeText` use), or nil when no existing file matches. Passing it back to
    /// this host reaches the same file whatever the later selection.
    func canonicalExistingFilePath(path: String) async -> String? {
        await mutationService.exactExistingFile(path, rootScope: lookupRootScope)?.standardizedFullPath
    }

    /// Step 5a: resolves a canonical absolute create destination using this host's root scope,
    /// current selection bias, and create policy, without creating it. Actual creation still runs
    /// its final scope, folder, and already-exists checks.
    func canonicalCreateDestinationPath(path: String) async throws -> String {
        try await mutationService.resolveCreateDestination(
            userPath: path,
            rootScope: lookupRootScope,
            selectedFileFullPaths: selectedFileFullPaths(),
            pathResolutionPolicy: createPathResolutionPolicy
        )
    }

    func readText(path: String) async throws -> String {
        let resolved = try await mutationService.resolveExactExistingFileForMutation(path, rootScope: lookupRootScope)
        return try await mutationService.readText(file: resolved) ?? ""
    }

    func writeText(path: String, content: String, overwrite: Bool) async throws {
        if overwrite,
           let resolved = await mutationService.exactExistingFile(path, rootScope: lookupRootScope)
        {
            try await mutationService.overwrite(file: resolved, content: content)
            return
        }

        let writeResult = try await mutationService.createFileWithPostcondition(
            userPath: path,
            content: content,
            rootScope: lookupRootScope,
            selectedFileFullPaths: selectedFileFullPaths(),
            pathResolutionPolicy: createPathResolutionPolicy
        )
        if selectCreatedFiles, let selectionCoordinator, let created = writeResult.materializedFile {
            _ = await selectionCoordinator.addPathsToActiveSelection(
                paths: [created.standardizedFullPath],
                mode: "full",
                rootScope: lookupRootScope
            )
        }
    }

    @MainActor
    private func selectedFileFullPaths() -> Set<String> {
        guard let selectionCoordinator else { return [] }
        let snapshot = selectionCoordinator.activeSelectionSnapshot(flushPendingUI: true)
        return Set(StoredSelectionPathNormalization.standardizedPaths(snapshot.selection.selectedPaths))
    }
}
