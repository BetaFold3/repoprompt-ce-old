import Foundation
@testable import RepoPromptAgentCore
import XCTest

/// O42 fallback search for a Claude conversation's history home, over temporary directories only
/// (never the real user's Claude directories).
final class ClaudeHistoryLocatorTests: XCTestCase {
    private let sessionID = "0c6f0f4e-6a0e-4c43-9a56-2f1a9d1b7e10"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeHistoryLocatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A home directory with `projects/<project>/` and, when `holding`, the conversation's file.
    private func makeHome(_ name: String, project: String = "-tmp-project", holding: Bool) throws -> URL {
        let home = root.appendingPathComponent(name, isDirectory: true)
        let projectDirectory = home.appendingPathComponent("projects/\(project)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("projects/-other", isDirectory: true),
            withIntermediateDirectories: true
        )
        if holding {
            try Data("{}\n".utf8).write(to: projectDirectory.appendingPathComponent("\(sessionID).jsonl"))
        }
        return home
    }

    func testNoHomesOrNoHitIsUnknown() throws {
        XCTAssertNil(ClaudeHistoryLocator.locate(sessionID: sessionID, homes: []))
        let empty = try makeHome("empty", holding: false)
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertNil(ClaudeHistoryLocator.locate(sessionID: sessionID, homes: [empty, missing]))
    }

    func testExactlyOneHitIsThatHome() throws {
        let other = try makeHome("other", holding: false)
        let holder = try makeHome("holder", holding: true)
        XCTAssertEqual(ClaudeHistoryLocator.locate(sessionID: sessionID, homes: [other, holder]), .unique(holder))
    }

    func testTheSameFileInTwoHomesIsAmbiguous() throws {
        let first = try makeHome("first", holding: true)
        let second = try makeHome("second", project: "-elsewhere", holding: true)
        XCTAssertEqual(ClaudeHistoryLocator.locate(sessionID: sessionID, homes: [first, second]), .ambiguous([first, second]))
        // The same home listed twice (or through a symlink) is one home, not an ambiguity.
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        XCTAssertEqual(ClaudeHistoryLocator.locate(sessionID: sessionID, homes: [first, first, link]), .unique(first))
    }

    func testOnlyTheExactFileOneLevelDownCounts() throws {
        let home = try makeHome("near-miss", holding: false)
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        // Other names, a directory named like the file, a deeper file and one directly in projects.
        try Data().write(to: projects.appendingPathComponent("-tmp-project/\(sessionID).json"))
        try FileManager.default.createDirectory(
            at: projects.appendingPathComponent("-other/\(sessionID).jsonl", isDirectory: true),
            withIntermediateDirectories: true
        )
        let deeper = projects.appendingPathComponent("-tmp-project/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        try Data().write(to: deeper.appendingPathComponent("\(sessionID).jsonl"))
        try Data().write(to: projects.appendingPathComponent("\(sessionID).jsonl"))
        XCTAssertNil(ClaudeHistoryLocator.locate(sessionID: sessionID, homes: [home]))
    }

    func testANonUUIDSessionIDNeverTouchesTheFilesystem() {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func hit() {
                lock.withLock { count += 1 }
            }
        }
        let counter = Counter()
        let fileSystem = ClaudeHistoryLocator.FileSystem(
            kind: { _ in
                counter.hit()
                return .directory
            },
            entryNames: { _ in
                counter.hit()
                return []
            },
            canonicalPath: { url in
                counter.hit()
                return url.path
            }
        )
        let home = root.appendingPathComponent("any", isDirectory: true)
        for invalid in ["", "not-a-uuid", "../\(sessionID)", "\(sessionID)/x", "*"] {
            XCTAssertNil(ClaudeHistoryLocator.locate(sessionID: invalid, homes: [home], fileSystem: fileSystem))
        }
        XCTAssertEqual(counter.count, 0)
    }

    /// A real-filesystem candidate whose `projects` is a symlink to an external directory holding the
    /// exact file gives no hit; so do a symlinked project directory and a symlinked file.
    func testSymlinksBelowTheHomeAreNeverFollowed() throws {
        let external = try makeHome("external", holding: true)
        let externalProjects = external.appendingPathComponent("projects", isDirectory: true)
        let linkedProjects = root.appendingPathComponent("linked-projects", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedProjects, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedProjects.appendingPathComponent("projects"),
            withDestinationURL: externalProjects
        )
        XCTAssertNil(ClaudeHistoryLocator.locate(sessionID: sessionID, homes: [linkedProjects]), "a symlinked projects directory")

        let linkedProject = root.appendingPathComponent("linked-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: linkedProject.appendingPathComponent("projects", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedProject.appendingPathComponent("projects/-tmp-project"),
            withDestinationURL: externalProjects.appendingPathComponent("-tmp-project", isDirectory: true)
        )
        XCTAssertNil(ClaudeHistoryLocator.locate(sessionID: sessionID, homes: [linkedProject]), "a symlinked project directory")

        let linkedFile = try makeHome("linked-file", holding: false)
        try FileManager.default.createSymbolicLink(
            at: linkedFile.appendingPathComponent("projects/-tmp-project/\(sessionID).jsonl"),
            withDestinationURL: externalProjects.appendingPathComponent("-tmp-project/\(sessionID).jsonl")
        )
        XCTAssertNil(ClaudeHistoryLocator.locate(sessionID: sessionID, homes: [linkedFile]), "a symlinked conversation file")

        // The real holder is still found next to all three.
        XCTAssertEqual(
            ClaudeHistoryLocator.locate(sessionID: sessionID, homes: [linkedProjects, linkedProject, linkedFile, external]),
            .unique(external)
        )
    }

    /// A candidate that couldn't be inspected leaves one readable hit unproven: not unique.
    func testAnUninspectableCandidateMakesASingleHitNotUnique() throws {
        let holder = try makeHome("holder", holding: true)
        let blocked = URL(fileURLWithPath: "/fixture/blocked", isDirectory: true)
        let live = ClaudeHistoryLocator.FileSystem.live
        func isBlocked(_ url: URL) -> Bool {
            url.path.hasPrefix(blocked.path)
        }
        let fileSystem = ClaudeHistoryLocator.FileSystem(
            kind: { url in isBlocked(url) ? .unreadable : live.kind(url) },
            entryNames: { url in isBlocked(url) ? nil : live.entryNames(url) },
            canonicalPath: { url in isBlocked(url) ? url.path : live.canonicalPath(url) }
        )
        XCTAssertEqual(
            ClaudeHistoryLocator.locate(sessionID: sessionID, homes: [blocked, holder], fileSystem: fileSystem),
            .uninspectable([blocked])
        )
        // An unlistable `projects` directory is uninspectable too, never absent.
        let unlistable = ClaudeHistoryLocator.FileSystem(
            kind: { url in isBlocked(url) ? .directory : live.kind(url) },
            entryNames: { url in isBlocked(url) ? nil : live.entryNames(url) },
            canonicalPath: { url in isBlocked(url) ? url.path : live.canonicalPath(url) }
        )
        XCTAssertEqual(
            ClaudeHistoryLocator.locate(sessionID: sessionID, homes: [holder, blocked], fileSystem: unlistable),
            .uninspectable([blocked])
        )
        // Two hits stay ambiguous whatever else couldn't be inspected.
        let second = try makeHome("second", holding: true)
        XCTAssertEqual(
            ClaudeHistoryLocator.locate(sessionID: sessionID, homes: [holder, blocked, second], fileSystem: fileSystem),
            .ambiguous([holder, second])
        )
    }

    func testTheSingleHolderIsFoundWhetherItIsTheDefaultOrARecordedHome() throws {
        let recorded = try makeHome("profile-a", holding: false)
        let userHome = root.appendingPathComponent("user", isDirectory: true)
        let defaultHome = try makeHome("user/.claude", holding: true)
        let homes = ClaudeHistoryLocator.candidateHomes(recorded: [recorded.path], environment: [:], userHome: userHome)
        XCTAssertEqual(homes.map(\.path), [recorded.path, defaultHome.path])
        XCTAssertEqual(ClaudeHistoryLocator.locate(sessionID: sessionID, homes: homes)?.homePath, defaultHome.standardizedFileURL.path)

        // When the recorded home holds it, the default (which does not) is never chosen.
        let recordedHolder = try makeHome("profile-b", holding: true)
        let emptyUser = root.appendingPathComponent("user-empty", isDirectory: true)
        let otherHomes = ClaudeHistoryLocator.candidateHomes(recorded: [recordedHolder.path], environment: [:], userHome: emptyUser)
        XCTAssertEqual(ClaudeHistoryLocator.locate(sessionID: sessionID, homes: otherHomes)?.homePath, recordedHolder.standardizedFileURL.path)
    }

    func testCandidateHomesAddTheAppConfigDirectoryBeforeTheDefault() {
        let homes = ClaudeHistoryLocator.candidateHomes(
            recorded: ["/fixture/recorded", ""],
            environment: ["CLAUDE_CONFIG_DIR": "/fixture/app-config"],
            userHome: URL(fileURLWithPath: "/fixture/user", isDirectory: true)
        )
        XCTAssertEqual(homes.map(\.path), ["/fixture/recorded", "/fixture/app-config", "/fixture/user/.claude"])
        let unset = ClaudeHistoryLocator.candidateHomes(
            recorded: [],
            environment: ["CLAUDE_CONFIG_DIR": ""],
            userHome: URL(fileURLWithPath: "/fixture/user", isDirectory: true)
        )
        XCTAssertEqual(unset.map(\.path), ["/fixture/user/.claude"])
    }
}

private extension ClaudeHistoryLocator.Location {
    var homePath: String? {
        if case let .unique(home) = self { return home.standardizedFileURL.path }
        return nil
    }
}
