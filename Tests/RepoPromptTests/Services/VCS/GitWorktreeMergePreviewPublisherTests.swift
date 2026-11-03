@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class GitWorktreeMergePreviewPublisherTests: XCTestCase {
    func testPreviewPublishesDiffSnapshotAndMergeSidecar() async throws {
        let fixture = try GitMergePreviewFixture()
        defer { fixture.cleanup() }
        try fixture.commitFile("Source.txt", contents: "source\n", message: "Source change", cwd: fixture.source)

        let git = GitService()
        let source = try await fixture.endpoint(for: fixture.source, using: git)
        let target = try await fixture.endpoint(for: fixture.repo, using: git)
        let preview = try await VCSService().previewGitWorktreeMerge(.init(
            source: source,
            target: target,
            workspaceDirectory: fixture.workspace,
            contextLines: 2,
            publishArtifacts: true
        ))

        XCTAssertFalse(preview.operationID.isEmpty)
        let artifacts = try XCTUnwrap(preview.artifacts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.manifestPath), artifacts.manifestPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.mapPath), artifacts.mapPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.sidecarPath), artifacts.sidecarPath)
        let allPatch = try XCTUnwrap(artifacts.allPatchPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: allPatch), allPatch)

        let sidecarData = try Data(contentsOf: URL(fileURLWithPath: artifacts.sidecarPath))
        let sidecarObject = try XCTUnwrap(JSONSerialization.jsonObject(with: sidecarData) as? [String: Any])
        XCTAssertEqual(sidecarObject["operationID"] as? String, preview.operationID)
        XCTAssertEqual(sidecarObject["sourceHead"] as? String, source.head)
        XCTAssertEqual(sidecarObject["targetHead"] as? String, target.head)
        XCTAssertEqual((sidecarObject["summary"] as? [String: Any])?["files"] as? Int, 1)
        XCTAssertTrue((sidecarObject["visualization"] as? String)?.contains("merge preview") ?? false)
    }

    // MARK: - Step 5c review retention

    func testRetainedReviewBundleSurvivesOriginalDeletionAndKeepsItsIdentity() async throws {
        let fixture = try GitMergePreviewFixture()
        defer { fixture.cleanup() }
        let (preview, artifacts) = try await publishPreview(fixture)
        let identity = try XCTUnwrap(GitWorktreeMergeReviewArtifactRetention.ExpectedIdentity(preview: preview))
        let sessionsFolder = try fixture.makeSessionsFolder()
        let sessionID = UUID()
        let originalPatchPath = try XCTUnwrap(artifacts.allPatchPath)
        let originalPatch = try Data(contentsOf: URL(fileURLWithPath: originalPatchPath))
        XCTAssertFalse(originalPatch.isEmpty)

        let retained = try GitWorktreeMergeReviewArtifactRetention.retain(
            artifacts,
            expected: identity,
            agentSessionsFolder: sessionsFolder,
            sessionID: sessionID
        )

        let ownerFolder = sessionsFolder
            .appendingPathComponent(GitWorktreeMergeReviewArtifactRetention.directoryName, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        XCTAssertTrue(GitWorktreeMergeReviewArtifactRetention.directoryName.hasPrefix("."), "Hidden from session scanners")
        XCTAssertEqual(retained.snapshotID, artifacts.snapshotID, "The SAME bundle identity is kept")
        XCTAssertTrue(retained.snapshotDirectory.hasPrefix(ownerFolder.path + "/"), retained.snapshotDirectory)
        XCTAssertTrue(GitWorktreeMergeReviewArtifactRetention.isRetained(retained))
        XCTAssertFalse(GitWorktreeMergeReviewArtifactRetention.isRetained(artifacts))
        XCTAssertThrowsError(try GitWorktreeMergeReviewArtifactRetention.readRetainedFile(
            originalPatchPath,
            in: artifacts,
            maximumBytes: 1 << 20
        )) { error in
            XCTAssertEqual(error as? GitWorktreeMergeReviewArtifactRetention.Failure, .notRetained)
        }
        for path in [retained.manifestPath, retained.mapPath, retained.sidecarPath] {
            XCTAssertTrue(path.hasPrefix(retained.snapshotDirectory + "/"), path)
        }
        XCTAssertEqual(
            try fixture.visibleEntries(of: ownerFolder),
            [URL(fileURLWithPath: retained.snapshotDirectory).lastPathComponent],
            "Exactly one published copy and no assembly leftovers"
        )

        // The original (temporary, tab-scoped) snapshot disappears; the retained copy still reads.
        try FileManager.default.removeItem(atPath: artifacts.snapshotDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalPatchPath))
        let retainedPatchPath = try XCTUnwrap(retained.allPatchPath)
        let retainedPatch = try GitWorktreeMergeReviewArtifactRetention.readRetainedFile(
            retainedPatchPath,
            in: retained,
            maximumBytes: 1 << 20
        )
        XCTAssertEqual(retainedPatch, originalPatch, "Bytes are copied unchanged")
        XCTAssertEqual(
            try GitWorktreeMergeReviewArtifactRetention.retainedConflictPrediction(in: retained, operationID: preview.operationID),
            preview.inspection.conflictPrediction,
            "The recorded prediction is read back as past metadata"
        )
        XCTAssertThrowsError(try GitWorktreeMergeReviewArtifactRetention.retainedConflictPrediction(in: retained, operationID: "other")) { error in
            XCTAssertEqual(error as? GitWorktreeMergeReviewArtifactRetention.Failure, .identityMismatch("operation"))
        }
        XCTAssertThrowsError(try GitWorktreeMergeReviewArtifactRetention.readRetainedFile(
            retainedPatchPath,
            in: retained,
            maximumBytes: originalPatch.count - 1
        )) { error in
            guard case .limitExceeded = error as? GitWorktreeMergeReviewArtifactRetention.Failure else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertThrowsError(try GitWorktreeMergeReviewArtifactRetention.readRetainedFile(
            retained.snapshotDirectory + "/../escape.txt",
            in: retained,
            maximumBytes: 1 << 20
        )) { error in
            guard case .escaping = error as? GitWorktreeMergeReviewArtifactRetention.Failure else {
                return XCTFail("\(error)")
            }
        }
    }

    func testRetentionRefusesMissingEscapingSymlinkAndMismatchedBundlesWithoutPublishing() async throws {
        typealias Retention = GitWorktreeMergeReviewArtifactRetention
        let fixture = try GitMergePreviewFixture()
        defer { fixture.cleanup() }
        let (preview, artifacts) = try await publishPreview(fixture)
        let identity = try XCTUnwrap(Retention.ExpectedIdentity(preview: preview))
        let sessionsFolder = try fixture.makeSessionsFolder()
        let sessionID = UUID()
        let ownerFolder = sessionsFolder
            .appendingPathComponent(Retention.directoryName, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        let root = artifacts.snapshotDirectory

        func assertRefused(
            _ label: String,
            _ candidate: GitWorktreeMergePreviewArtifacts,
            expected: Retention.ExpectedIdentity = identity,
            matches: (Retention.Failure) -> Bool
        ) throws {
            XCTAssertThrowsError(try Retention.retain(candidate, expected: expected, agentSessionsFolder: sessionsFolder, sessionID: sessionID), label) { error in
                guard let failure = error as? Retention.Failure else { return XCTFail("\(label): \(error)") }
                XCTAssertTrue(matches(failure), "\(label): \(failure)")
            }
            XCTAssertEqual(try fixture.visibleEntries(of: ownerFolder), [], "\(label): nothing is published")
            XCTAssertEqual(try fixture.allEntries(of: ownerFolder), [], "\(label): no assembly is left behind")
        }
        func relocated(_ newRoot: String) -> GitWorktreeMergePreviewArtifacts {
            func move(_ path: String) -> String {
                newRoot + path.dropFirst(root.count)
            }
            return GitWorktreeMergePreviewArtifacts(
                snapshotID: artifacts.snapshotID,
                snapshotDirectory: newRoot,
                manifestPath: move(artifacts.manifestPath),
                mapPath: move(artifacts.mapPath),
                allPatchPath: artifacts.allPatchPath.map(move),
                sidecarPath: move(artifacts.sidecarPath)
            )
        }

        try assertRefused("missing bundle", relocated(root + "-missing")) { if case .missing = $0 { true } else { false } }
        let outside = GitWorktreeMergePreviewArtifacts(
            snapshotID: artifacts.snapshotID,
            snapshotDirectory: root,
            manifestPath: fixture.sandbox.appendingPathComponent("outside.json").path,
            mapPath: artifacts.mapPath,
            allPatchPath: artifacts.allPatchPath,
            sidecarPath: artifacts.sidecarPath
        )
        try assertRefused("reference outside the bundle", outside) { if case .escaping = $0 { true } else { false } }
        let dotDot = GitWorktreeMergePreviewArtifacts(
            snapshotID: artifacts.snapshotID,
            snapshotDirectory: root,
            manifestPath: artifacts.manifestPath,
            mapPath: root + "/../MAP.txt",
            allPatchPath: artifacts.allPatchPath,
            sidecarPath: artifacts.sidecarPath
        )
        try assertRefused("dot-dot escape", dotDot) { if case .escaping = $0 { true } else { false } }

        let otherOperation = Retention.ExpectedIdentity(
            operationID: "merge_other",
            snapshotID: identity.snapshotID,
            mergeBase: identity.mergeBase,
            sourceHead: identity.sourceHead,
            targetHead: identity.targetHead,
            sourceFingerprint: identity.sourceFingerprint,
            targetFingerprint: identity.targetFingerprint
        )
        try assertRefused("sidecar describes another operation", artifacts, expected: otherOperation) { $0 == .identityMismatch("operation") }
        let movedTarget = Retention.ExpectedIdentity(
            operationID: identity.operationID,
            snapshotID: identity.snapshotID,
            mergeBase: identity.mergeBase,
            sourceHead: identity.sourceHead,
            targetHead: String(repeating: "e", count: 40),
            sourceFingerprint: identity.sourceFingerprint,
            targetFingerprint: identity.targetFingerprint
        )
        try assertRefused("target HEAD differs", artifacts, expected: movedTarget) { $0 == .identityMismatch("target HEAD") }
        let otherSnapshot = Retention.ExpectedIdentity(
            operationID: identity.operationID,
            snapshotID: "snapshot_other",
            mergeBase: identity.mergeBase,
            sourceHead: identity.sourceHead,
            targetHead: identity.targetHead,
            sourceFingerprint: identity.sourceFingerprint,
            targetFingerprint: identity.targetFingerprint
        )
        try assertRefused("snapshot differs", artifacts, expected: otherSnapshot) { $0 == .identityMismatch("snapshot") }

        // The bundle directory itself reached through a symlink is refused (never followed).
        let linkedRoot = fixture.sandbox.appendingPathComponent("linked-snapshot").path
        try FileManager.default.createSymbolicLink(atPath: linkedRoot, withDestinationPath: root)
        try assertRefused("symlinked bundle directory", relocated(linkedRoot)) { if case .unsupportedEntry = $0 { true } else { false } }

        // A symlink inside the bundle is refused, and the partial assembly is removed.
        let secret = fixture.sandbox.appendingPathComponent("secret.txt")
        try "secret\n".write(to: secret, atomically: true, encoding: .utf8)
        let innerLink = URL(fileURLWithPath: root).appendingPathComponent("zz-link.txt").path
        try FileManager.default.createSymbolicLink(atPath: innerLink, withDestinationPath: secret.path)
        try assertRefused("symlink entry", artifacts) { if case .unsupportedEntry = $0 { true } else { false } }
        try FileManager.default.removeItem(atPath: innerLink)

        // A required file missing from the copy is refused.
        try FileManager.default.removeItem(atPath: artifacts.mapPath)
        try assertRefused("missing MAP.txt", artifacts) { if case .missing = $0 { true } else { false } }
    }

    private func publishPreview(_ fixture: GitMergePreviewFixture) async throws -> (GitWorktreeMergePreview, GitWorktreeMergePreviewArtifacts) {
        try fixture.commitFile("Source.txt", contents: "source\n", message: "Source change", cwd: fixture.source)
        let git = GitService()
        let source = try await fixture.endpoint(for: fixture.source, using: git)
        let target = try await fixture.endpoint(for: fixture.repo, using: git)
        let preview = try await VCSService().previewGitWorktreeMerge(.init(
            source: source,
            target: target,
            workspaceDirectory: fixture.workspace,
            contextLines: 2,
            publishArtifacts: true
        ))
        return try (preview, XCTUnwrap(preview.artifacts))
    }
}

private struct GitMergePreviewFixture {
    let sandbox: URL
    let repo: URL
    let source: URL
    let workspace: URL

    init() throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorktreeMergePreviewPublisherTests-\(suffix)", isDirectory: true)
        repo = sandbox.appendingPathComponent("repo", isDirectory: true).standardizedFileURL
        source = sandbox.appendingPathComponent("source", isDirectory: true).standardizedFileURL
        workspace = sandbox.appendingPathComponent("workspace", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Self.runGit(["init"], cwd: repo)
        try Self.runGit(["config", "user.name", "RepoPrompt Test"], cwd: repo)
        try Self.runGit(["config", "user.email", "repoprompt@example.test"], cwd: repo)
        try Self.runGit(["config", "commit.gpgSign", "false"], cwd: repo)
        try Self.runGit(["checkout", "-b", "main"], cwd: repo)
        try "base\n".write(to: repo.appendingPathComponent("Common.txt"), atomically: true, encoding: .utf8)
        try Self.runGit(["add", "Common.txt"], cwd: repo)
        try Self.runGit(["commit", "-m", "Initial commit"], cwd: repo)
        try Self.runGit(["worktree", "add", "-b", "feature/source", source.path, "HEAD"], cwd: repo)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func makeSessionsFolder() throws -> URL {
        let folder = sandbox.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Non-hidden entries of `folder` (empty when it doesn't exist).
    func visibleEntries(of folder: URL) throws -> [String] {
        try allEntries(of: folder).filter { !$0.hasPrefix(".") }
    }

    func allEntries(of folder: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func endpoint(for path: URL, using git: GitService) async throws -> GitWorktreeMergeEndpoint {
        let worktrees = try await git.listWorktrees(at: repo)
        let standardized = path.standardizedFileURL.path
        let descriptor = try XCTUnwrap(worktrees.first { $0.path == standardized })
        return try GitWorktreeMergeEndpoint(descriptor: descriptor)
    }

    func commitFile(_ relativePath: String, contents: String, message: String, cwd: URL) throws {
        let url = cwd.appendingPathComponent(relativePath)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try Self.runGit(["add", relativePath], cwd: cwd)
        try Self.runGit(["commit", "-m", message], cwd: cwd)
    }

    private static func runGit(_ arguments: [String], cwd: URL) throws {
        let environment = TestGitCommandRunner.processEnvironment()
        let result = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: cwd,
            environment: environment
        )
        guard result.terminationStatus == 0 else {
            throw NSError(
                domain: "GitWorktreeMergePreviewPublisherTests.git",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(result.outputText)"]
            )
        }
    }
}
