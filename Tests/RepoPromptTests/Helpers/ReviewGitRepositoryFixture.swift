import Darwin
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class ReviewGitRepositoryFixture {
    let sandbox: URL
    /// Calls to `rewriteIndexWithoutContentChange`, so each call backdates to a distinct mtime.
    private var indexRewriteCount = 0

    init(name: String = "ReviewGitRepositoryFixture") throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    deinit {
        cleanup()
    }

    func cleanup() {
        guard FileManager.default.fileExists(atPath: sandbox.path) else { return }
        try? FileManager.default.removeItem(at: sandbox)
    }

    func makeRepository(
        named name: String,
        files: [String: String] = ["Sources/Feature.swift": "let value = 1\n"],
        objectFormat: GitObjectFormat? = nil
    ) throws -> URL {
        let root = sandbox.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        if let objectFormat {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try initializeRepository(at: root, objectFormat: objectFormat)
        } else {
            try ImmutableGitRepositoryTemplate.copy(.configuredMain, to: root)
            try configureHermeticAttributesFile(at: root)
        }

        for (path, contents) in files {
            try write(contents, to: path, at: root)
        }
        _ = try runGit(["add", "-A"], at: root)
        _ = try runGit(["commit", "-m", "Initial commit"], at: root)
        return root
    }

    private func initializeRepository(at root: URL, objectFormat: GitObjectFormat) throws {
        _ = try runGit(["init", "--object-format=\(objectFormat.rawValue)"], at: root)
        _ = try runGit(["config", "user.name", "RepoPrompt Test"], at: root)
        _ = try runGit(["config", "user.email", "repoprompt@example.test"], at: root)
        _ = try runGit(["config", "commit.gpgSign", "false"], at: root)
        _ = try runGit(["config", "core.autocrlf", "false"], at: root)
        _ = try runGit(["config", "core.eol", "native"], at: root)
        try configureHermeticAttributesFile(at: root)
        _ = try runGit(["checkout", "-b", "main"], at: root)
    }

    private func configureHermeticAttributesFile(at root: URL) throws {
        let attributesFile = root
            .appendingPathComponent(".git", isDirectory: true)
            .appendingPathComponent("info", isDirectory: true)
            .appendingPathComponent("repoprompt-empty-global-attributes")
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: attributesFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: attributesFile.path) {
            try Data().write(to: attributesFile, options: .atomic)
        }
        _ = try runGit(["config", "core.attributesFile", attributesFile.path], at: root)
    }

    func makeLinkedWorktree(
        from repository: URL,
        named name: String,
        branch: String
    ) throws -> URL {
        let worktree = sandbox.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        _ = try runGit(["worktree", "add", "-b", branch, worktree.path, "HEAD"], at: repository)
        return worktree
    }

    func write(_ contents: String, to relativePath: String, at root: URL) throws {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func write(_ data: Data, to relativePath: String, at root: URL) throws {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: file, options: .atomic)
    }

    func stage(_ relativePath: String, at root: URL) throws {
        _ = try runGit(["add", "--", relativePath], at: root)
    }

    func commit(_ message: String, at root: URL) throws {
        _ = try runGit(["commit", "-m", message], at: root)
    }

    func head(at root: URL) throws -> String {
        try runGit(["rev-parse", "HEAD"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func headBlobOID(for relativePath: String, at root: URL) throws -> String {
        let oid = try runGit(["rev-parse", "--verify", "HEAD:\(relativePath)"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard [40, 64].contains(oid.count), oid.allSatisfy(\.isHexDigit) else {
            throw NSError(
                domain: "ReviewGitRepositoryFixture.git",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected blob OID for \(relativePath): \(oid)"]
            )
        }
        return oid
    }

    func isTracked(_ relativePath: String, at root: URL) throws -> Bool {
        let output = try runGit(["ls-files", "--", relativePath], at: root)
        return output.split(whereSeparator: \.isNewline).contains(Substring(relativePath))
    }

    func porcelainStatus(for relativePath: String, at root: URL) throws -> String {
        try runGit(
            ["status", "--porcelain=v1", "--untracked-files=all", "--", relativePath],
            at: root
        ).trimmingCharacters(in: .newlines)
    }

    /// Backdates tracked worktree files and refreshes the index so later `git status` calls find
    /// stat-clean entries and cannot rewrite racily-clean index entries. Throws when a probe
    /// `git status` still rewrites the index, because tests that depend on a stable index would be invalid.
    func settleIndex(at root: URL) throws {
        let indexURL = try gitPath("index", at: root)
        // Unstaged edits keep their original index stat, which can stay racily clean until the
        // index is rewritten in a later second; a bounded retry lets that rewrite settle.
        for attempt in 0 ..< 4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1.1) }
            let backdated = Date(timeIntervalSinceNow: -120)
            let tracked = try runGit(["ls-files", "-z"], at: root)
                .split(separator: "\0")
                .map(String.init)
            for path in tracked {
                try FileManager.default.setAttributes(
                    [.modificationDate: backdated],
                    ofItemAtPath: root.appendingPathComponent(path).path
                )
            }
            _ = try runGit(["update-index", "-q", "--refresh"], at: root)
            let before = try Self.indexStat(at: indexURL)
            _ = try runGit(["status", "--porcelain"], at: root)
            let after = try Self.indexStat(at: indexURL)
            if before == after { return }
        }
        throw NSError(
            domain: "ReviewGitRepositoryFixture.git",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "git status kept rewriting a settled index"]
        )
    }

    /// Rewrites the index without changing any entry: backdates the tracked file's mtime (to a value
    /// distinct per call, and from `settleIndex`'s) so `update-index --refresh` re-verifies its
    /// unchanged content and records new stat data, then settles the index. Fails the test when the
    /// index file was not rewritten.
    func rewriteIndexWithoutContentChange(
        path relativePath: String,
        at root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let indexURL = try gitPath("index", at: root)
        let before = try Self.indexStat(at: indexURL)
        indexRewriteCount += 1
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -10 - Double(indexRewriteCount))],
            ofItemAtPath: root.appendingPathComponent(relativePath).path
        )
        _ = try runGit(["update-index", "-q", "--refresh"], at: root)
        let after = try Self.indexStat(at: indexURL)
        if before == after {
            XCTFail("index not rewritten by a stat-only refresh of \(relativePath)", file: file, line: line)
        }
        try settleIndex(at: root)
    }

    /// Changes directory timestamps inside the Git directory, and optionally the worktree root,
    /// without changing any authority file. Mirrors lock-file churn from read-only Git commands.
    func churnRepositoryDirectoryTimestamps(at root: URL, includeWorktreeRoot: Bool) throws {
        var directories = try [gitPath("", at: root)]
        if includeWorktreeRoot { directories.append(root) }
        for directory in directories {
            let probe = directory.appendingPathComponent("rp-directory-churn-\(UUID().uuidString)")
            try Data("churn\n".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
        }
    }

    func gitPath(_ name: String, at root: URL) throws -> URL {
        let arguments = name.isEmpty
            ? ["rev-parse", "--absolute-git-dir"]
            : ["rev-parse", "--path-format=absolute", "--git-path", name]
        let path = try runGit(arguments, at: root).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func indexStat(at url: URL) throws -> [Int64] {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return [
            Int64(value.st_ino),
            Int64(value.st_size),
            Int64(value.st_mtimespec.tv_sec),
            Int64(value.st_mtimespec.tv_nsec),
            Int64(value.st_ctimespec.tv_sec),
            Int64(value.st_ctimespec.tv_nsec)
        ]
    }

    @discardableResult
    func createUntrackedFile(_ contents: String, at relativePath: String, root: URL) throws -> URL {
        guard try !isTracked(relativePath, at: root) else {
            throw NSError(
                domain: "ReviewGitRepositoryFixture.git",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Expected untracked path: \(relativePath)"]
            )
        }
        try write(contents, to: relativePath, at: root)
        return root.appendingPathComponent(relativePath).standardizedFileURL
    }

    @discardableResult
    func runGit(_ arguments: [String], at root: URL) throws -> String {
        try TestGitCommandRunner.run(
            arguments,
            cwd: root,
            failureDomain: "ReviewGitRepositoryFixture.git"
        )
    }

    func runGitResult(_ arguments: [String], at root: URL) throws -> TestProcessResult {
        try TestGitCommandRunner.runResult(arguments, cwd: root)
    }
}
