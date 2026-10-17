import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class GitDiffEngineWorktreePathFilterTests: XCTestCase {
    func testAbsolutePathFilterInLinkedWorktreeMatchesUnfilteredDiff() async throws {
        let fixture = try LinkedWorktreeDiffFixture()
        defer { fixture.cleanup() }
        let engine = GitDiffEngine(vcsService: VCSService(), gitService: GitService())

        let unfiltered = try await engine.buildSnapshotInputs(
            compare: .uncommitted(base: "HEAD"),
            pathspecs: nil,
            repoURL: fixture.worktree,
            contextLines: 3,
            detectRenames: false,
            generateDiffText: true
        )
        let filtered = try await engine.buildSnapshotInputs(
            compare: .uncommitted(base: "HEAD"),
            pathspecs: [fixture.changedFile.path],
            repoURL: fixture.worktree,
            contextLines: 3,
            detectRenames: false,
            generateDiffText: true
        )

        XCTAssertEqual(unfiltered.changedFiles.map(\.path), [fixture.relativePath])
        XCTAssertEqual(filtered.changedFiles, unfiltered.changedFiles)
        XCTAssertEqual(filtered.summary.files, unfiltered.summary.files)
        XCTAssertEqual(filtered.summary.insertions, unfiltered.summary.insertions)
        XCTAssertEqual(filtered.summary.deletions, unfiltered.summary.deletions)
        XCTAssertEqual(filtered.requestedPaths, [fixture.relativePath])
        XCTAssertEqual(filtered.perFile, unfiltered.perFile)
    }

    /// Artifact publication honors caller `path`/`paths` filters (D2 review D2-01): they restrict
    /// `.all`, intersect `.selected`, and a filter for another repository publishes nothing here.
    func testPublicationPathspecsRestrictAllScopeAndIntersectSelectedScope() async throws {
        let fixture = try LinkedWorktreeDiffFixture(extraChangedPath: "Sources/Other.swift")
        defer { fixture.cleanup() }
        let engine = GitDiffEngine(vcsService: VCSService(), gitService: GitService())
        let kept = fixture.changedFile.path
        let excluded = fixture.worktree.appendingPathComponent("Sources/Other.swift").path
        let sourcesDirectory = fixture.worktree.appendingPathComponent("Sources").path

        func build(
            scope: GitDiffScope,
            selected: [String] = [],
            pathspecs: [String]?
        ) async throws -> GitDiffEngine.GitDiffSnapshotBuildResult {
            try await engine.buildSnapshotInputs(
                compare: .uncommitted(base: "HEAD"),
                scope: scope,
                selectedAbsolutePaths: selected,
                pathspecs: pathspecs,
                repoURL: fixture.worktree,
                contextLines: 3,
                detectRenames: false,
                generateDiffText: true
            )
        }

        let unfiltered = try await build(scope: .all, pathspecs: nil)
        XCTAssertEqual(unfiltered.changedFiles.map(\.path).sorted(), ["Sources/Feature.swift", "Sources/Other.swift"])

        for result in try await [
            build(scope: .all, pathspecs: [kept]),
            build(scope: .all, pathspecs: [fixture.relativePath]),
            build(scope: .selected, selected: [kept, excluded], pathspecs: [kept]),
            // Directory selection with a file filter, and file selection with a directory filter.
            build(scope: .selected, selected: [sourcesDirectory], pathspecs: [kept]),
            build(scope: .selected, selected: [kept], pathspecs: [sourcesDirectory])
        ] {
            XCTAssertEqual(result.changedFiles.map(\.path), [fixture.relativePath])
            XCTAssertEqual(result.requestedPaths, [fixture.relativePath])
            XCTAssertEqual(result.summary.files, 1)
            let perFileKeys = try XCTUnwrap(result.perFile?.keys)
            XCTAssertEqual(perFileKeys.count, 1, "\(perFileKeys)")
            XCTAssertTrue(result.diffText?.contains("let value = 2") ?? false, result.diffText ?? "nil")
            XCTAssertFalse(result.diffText?.contains("Other.swift") ?? true, result.diffText ?? "nil")
        }

        // A directory filter and a repository-root (".") filter keep every matching change.
        for result in try await [
            build(scope: .all, pathspecs: [sourcesDirectory]),
            build(scope: .all, pathspecs: [fixture.worktree.path]),
            build(scope: .selected, selected: [kept, excluded], pathspecs: [fixture.worktree.path])
        ] {
            XCTAssertEqual(result.changedFiles.map(\.path).sorted(), ["Sources/Feature.swift", "Sources/Other.swift"])
            XCTAssertEqual(result.perFile?.count, 2)
        }

        let disjoint = try await build(scope: .selected, selected: [excluded], pathspecs: [kept])
        let otherRepository = try await build(
            scope: .all,
            pathspecs: [fixture.repo.appendingPathComponent(fixture.relativePath).path]
        )
        // Pathspecs are literal (GIT_LITERAL_PATHSPECS): a glob matches neither the file list nor the diff.
        let wildcard = try await build(scope: .all, pathspecs: ["Sources/*.swift"])
        for result in [disjoint, otherRepository, wildcard] {
            XCTAssertEqual(result.changedFiles, [])
            XCTAssertNil(result.diffText)
        }
    }
}

private struct LinkedWorktreeDiffFixture {
    let sandbox: URL
    let repo: URL
    let worktree: URL
    let relativePath = "Sources/Feature.swift"

    var changedFile: URL {
        worktree.appendingPathComponent(relativePath)
    }

    init(extraChangedPath: String? = nil) throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitDiffEngineWorktreePathFilterTests-\(UUID().uuidString)", isDirectory: true)
        repo = sandbox.appendingPathComponent("repo", isDirectory: true).standardizedFileURL
        worktree = sandbox.appendingPathComponent("linked", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init"], cwd: repo)
        try runGit(["config", "user.name", "RepoPrompt Test"], cwd: repo)
        try runGit(["config", "user.email", "repoprompt@example.test"], cwd: repo)
        try runGit(["config", "commit.gpgSign", "false"], cwd: repo)
        try runGit(["checkout", "-b", "main"], cwd: repo)

        let initialFile = repo.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: initialFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let value = 1\n".write(to: initialFile, atomically: true, encoding: .utf8)
        if let extraChangedPath {
            try "let other = 1\n".write(
                to: repo.appendingPathComponent(extraChangedPath),
                atomically: true,
                encoding: .utf8
            )
        }
        try runGit(["add", "."], cwd: repo)
        try runGit(["commit", "-m", "Initial commit"], cwd: repo)
        try runGit(["worktree", "add", "-b", "feature/linked", worktree.path, "HEAD"], cwd: repo)
        try "let value = 2\n".write(to: changedFile, atomically: true, encoding: .utf8)
        if let extraChangedPath {
            try "let other = 2\n".write(
                to: worktree.appendingPathComponent(extraChangedPath),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        let environment = TestGitCommandRunner.processEnvironment()
        let result = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: cwd,
            environment: environment
        )
        guard result.terminationStatus == 0 else {
            throw NSError(
                domain: "GitDiffEngineWorktreePathFilterTests.git",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: result.outputText]
            )
        }
    }
}
