@testable import RepoPromptWorkspace
import XCTest

#if DEBUG
    /// `WorkspaceAppliedIndexBatchEvent.isCodemapProjectionNeutral` is true exactly for batches with no
    /// file-level change: folder-only payloads (and an empty payload) are neutral; any file payload,
    /// file source snapshot, full resync, or root unload is not.
    extension WorkspaceCatalogShardTests {
        func testCodemapProjectionNeutralityIsFileLevelOnly() {
            let rootID = UUID()
            let rootPath = "/tmp/projection-neutrality-root"
            let folder = WorkspaceFolderRecord(
                rootID: rootID,
                name: "Sources",
                relativePath: "Sources",
                fullPath: rootPath + "/Sources",
                parentFolderID: rootID
            )
            let file = WorkspaceFileRecord(
                rootID: rootID,
                name: "Source.swift",
                relativePath: "Sources/Source.swift",
                fullPath: rootPath + "/Sources/Source.swift",
                parentFolderID: folder.id
            )
            let snapshot = WorkspaceSliceRebaseSourceSnapshot(
                rootID: rootID,
                rootLifetimeID: UUID(),
                fileID: file.id,
                relativePath: file.relativePath,
                fullPath: file.fullPath,
                text: "struct Source {}\n",
                modificationTime: 1
            )
            func event(
                modifiedFileSourceSnapshotsByID: [UUID: WorkspaceSliceRebaseSourceSnapshot] = [:],
                upsertedFiles: [WorkspaceFileRecord] = [],
                upsertedFolders: [WorkspaceFolderRecord] = [],
                removedFileIDs: [UUID] = [],
                removedFolderIDs: [UUID] = [],
                removedFilePaths: [String] = [],
                removedFolderPaths: [String] = [],
                modifiedFileIDs: [UUID] = [],
                modifiedFolderIDs: [UUID] = [],
                requiresFullResync: Bool = false,
                isRootUnload: Bool = false
            ) -> WorkspaceAppliedIndexBatchEvent {
                WorkspaceAppliedIndexBatchEvent(
                    rootID: rootID,
                    rootPath: rootPath,
                    generation: 1,
                    modifiedFileSourceSnapshotsByID: modifiedFileSourceSnapshotsByID,
                    upsertedFiles: upsertedFiles,
                    upsertedFolders: upsertedFolders,
                    removedFileIDs: removedFileIDs,
                    removedFolderIDs: removedFolderIDs,
                    removedFilePaths: removedFilePaths,
                    removedFolderPaths: removedFolderPaths,
                    modifiedFileIDs: modifiedFileIDs,
                    modifiedFolderIDs: modifiedFolderIDs,
                    requiresFullResync: requiresFullResync,
                    isRootUnload: isRootUnload
                )
            }

            let rows: [(name: String, event: WorkspaceAppliedIndexBatchEvent, neutral: Bool)] = [
                ("empty payload", event(), true),
                ("modifiedFolderIDs only", event(modifiedFolderIDs: [folder.id]), true),
                ("upsertedFolders only", event(upsertedFolders: [folder]), true),
                ("removedFolderIDs only", event(removedFolderIDs: [folder.id]), true),
                ("removedFolderPaths only", event(removedFolderPaths: [folder.relativePath]), true),
                ("upsertedFiles", event(upsertedFiles: [file]), false),
                ("removedFileIDs", event(removedFileIDs: [file.id]), false),
                ("removedFilePaths only", event(removedFilePaths: [file.relativePath]), false),
                ("modifiedFileIDs", event(modifiedFileIDs: [file.id]), false),
                (
                    "modifiedFileSourceSnapshotsByID only",
                    event(modifiedFileSourceSnapshotsByID: [file.id: snapshot]),
                    false
                ),
                ("requiresFullResync", event(requiresFullResync: true), false),
                ("isRootUnload", event(isRootUnload: true), false)
            ]
            for row in rows {
                XCTAssertEqual(
                    row.event.isCodemapProjectionNeutral,
                    row.neutral,
                    "Projection neutrality for \(row.name) must be \(row.neutral)."
                )
            }
        }
    }
#endif
