import Darwin
import Foundation
import RepoPromptPlatform

/// O42 fallback: finds which Claude configuration directory holds a conversation's native history
/// when the process registry recorded none for it. Bounded and exact: the regular file
/// `<home>/projects/<project>/<sessionID>.jsonl`, where `projects` and `<project>` are real
/// directories (a symlink at either level, or a symlinked file, never counts; one level, no
/// recursion, no other names), under a fixed candidate list. A candidate home may itself be an
/// alias (deduplicated by canonical path). Exactly one home holding it, with every other candidate
/// inspected, is the answer; none is unknown; more than one, or a candidate that couldn't be
/// inspected, is refused, never guessed.
package enum ClaudeHistoryLocator {
    package enum Location: Equatable {
        /// The one home (the directory containing `projects`) that holds the conversation's file.
        case unique(URL)
        /// More than one distinct home holds it (for example a duplicated profile).
        case ambiguous([URL])
        /// At most one hit, but these candidates couldn't be inspected, so uniqueness is unproven.
        case uninspectable([URL])
    }

    /// What one path is, without following a symlink in its last component.
    package enum EntryKind: Equatable {
        case absent
        case directory
        case regularFile
        /// A symlink or any other type.
        case other
        /// Exists or may exist, but couldn't be inspected.
        case unreadable
    }

    /// The filesystem reads the search performs (injected by tests).
    package struct FileSystem {
        /// `lstat`-style kind of a path.
        package var kind: @Sendable (URL) -> EntryKind
        /// Entry names of a directory (`nil` when it couldn't be listed).
        package var entryNames: @Sendable (URL) -> [String]?
        /// Path used to deduplicate candidate homes.
        package var canonicalPath: @Sendable (URL) -> String

        package init(
            kind: @escaping @Sendable (URL) -> EntryKind,
            entryNames: @escaping @Sendable (URL) -> [String]?,
            canonicalPath: @escaping @Sendable (URL) -> String
        ) {
            self.kind = kind
            self.entryNames = entryNames
            self.canonicalPath = canonicalPath
        }

        package static let live = FileSystem(
            kind: { url in
                var status = stat()
                guard lstat(url.path, &status) == 0 else {
                    return errno == ENOENT || errno == ENOTDIR ? .absent : .unreadable
                }
                switch status.st_mode & S_IFMT {
                case S_IFDIR: return .directory
                case S_IFREG: return .regularFile
                default: return .other
                }
            },
            entryNames: { url in try? FileManager.default.contentsOfDirectory(atPath: url.path) },
            canonicalPath: { url in url.standardizedFileURL.resolvingSymlinksInPath().path }
        )
    }

    /// Candidate homes in order: every home the registry recorded on any Claude runtime, the app's
    /// own `CLAUDE_CONFIG_DIR` when set, then `~/.claude`. Empty entries are dropped.
    package static func candidateHomes(recorded: [String], environment: [String: String], userHome: URL) -> [URL] {
        var paths = recorded.filter { !$0.isEmpty }
        if let configured = environment[ProcessEnvironmentIdentity.claudeConfigDirectoryKey], !configured.isEmpty {
            paths.append((configured as NSString).expandingTildeInPath)
        }
        paths.append(userHome.appendingPathComponent(".claude", isDirectory: true).path)
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The home holding `<sessionID>.jsonl`. A session ID that is not a UUID returns `nil` without
    /// any filesystem access; so do no homes and no hit (with every candidate inspected).
    package static func locate(sessionID: String, homes: [URL], fileSystem: FileSystem = .live) -> Location? {
        guard UUID(uuidString: sessionID) != nil, !homes.isEmpty else { return nil }
        var seen: Set<String> = []
        var hits: [URL] = []
        var uninspectable: [URL] = []
        for home in homes {
            guard seen.insert(fileSystem.canonicalPath(home)).inserted else { continue }
            switch inspect(home, fileName: "\(sessionID).jsonl", fileSystem: fileSystem) {
            case .hit: hits.append(home)
            case .noHit: continue
            case .uninspectable: uninspectable.append(home)
            }
        }
        if hits.count > 1 { return .ambiguous(hits) }
        if !uninspectable.isEmpty { return .uninspectable(uninspectable) }
        return hits.first.map(Location.unique)
    }

    private enum HomeResult {
        case hit
        case noHit
        case uninspectable
    }

    private static func inspect(_ home: URL, fileName: String, fileSystem: FileSystem) -> HomeResult {
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        switch fileSystem.kind(projects) {
        case .directory: break
        // Absent, a file, or a symlink (never followed): not a history directory.
        case .absent, .regularFile, .other: return .noHit
        case .unreadable: return .uninspectable
        }
        guard let names = fileSystem.entryNames(projects) else { return .uninspectable }
        var undetermined = false
        for name in names.sorted() {
            let project = projects.appendingPathComponent(name, isDirectory: true)
            switch fileSystem.kind(project) {
            case .directory: break
            case .unreadable:
                undetermined = true
                continue
            case .absent, .regularFile, .other: continue
            }
            switch fileSystem.kind(project.appendingPathComponent(fileName, isDirectory: false)) {
            case .regularFile: return .hit
            case .unreadable: undetermined = true
            case .absent, .directory, .other: continue
            }
        }
        return undetermined ? .uninspectable : .noHit
    }
}
