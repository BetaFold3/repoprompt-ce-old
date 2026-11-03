import Darwin
import Foundation

// MARK: - Worktree merge review artifact retention (Step 5c)

/// Retains the SAME published worktree-merge preview bundle for a pending review, so the review
/// can still be read after the original snapshot (often a temporary directory or a tab-scoped
/// `_git_data` snapshot) is deleted. Merge-specific and deliberately small: one copy per review
/// under a caller-validated session storage folder, assembled in a unique hidden sibling and
/// published with a no-replace rename. There is no catalog, collector, or retention policy.
///
/// Every entry of the source bundle is opened without following symlinks; symlinks, special
/// files, references outside the bundle, and a sidecar that does not describe the expected
/// operation are refused, never repaired or regenerated. The bundle bytes are copied unchanged:
/// MAP.txt keeps naming its original snapshot directory as provenance only.
public enum GitWorktreeMergeReviewArtifactRetention {
    /// Hidden subdirectory of an AgentSessions folder holding retained bundles. Session scanners
    /// skip hidden entries and only match session filenames.
    public static let directoryName = ".worktree-merge-reviews"

    static let maximumEntryCount = 20000
    static let maximumTotalBytes: Int64 = 512 * 1024 * 1024
    static let maximumDepth = 32
    private static let sidecarByteLimit = 16 * 1024 * 1024
    private static let copyChunkSize = 64 * 1024

    public enum Failure: Error, Equatable, LocalizedError {
        case missing(String)
        case escaping(String)
        case unsupportedEntry(String)
        case identityMismatch(String)
        case limitExceeded(String)
        case notRetained
        case ioFailure(operation: String, code: Int32)

        public var errorDescription: String? {
            switch self {
            case let .missing(path):
                "The merge preview file \(path) is missing."
            case let .escaping(path):
                "The merge preview reference \(path) is outside its preview bundle."
            case let .unsupportedEntry(path):
                "The merge preview bundle contains an unsupported entry (\(path)); symlinks and special files are not retained."
            case let .identityMismatch(field):
                "The merge preview bundle does not describe this merge operation (\(field) differs)."
            case let .limitExceeded(detail):
                "The merge preview bundle is too large to retain (\(detail))."
            case .notRetained:
                "This merge review's preview files were not retained."
            case let .ioFailure(operation, code):
                "Retaining the merge preview failed (\(operation): \(String(cString: strerror(code))))."
            }
        }
    }

    /// The operation the bundle's sidecar must describe.
    public struct ExpectedIdentity: Sendable, Equatable {
        public let operationID: String
        public let snapshotID: String
        public let mergeBase: String
        public let sourceHead: String
        public let targetHead: String
        public let sourceFingerprint: GitDiffFingerprint
        public let targetFingerprint: GitDiffFingerprint

        public init(
            operationID: String,
            snapshotID: String,
            mergeBase: String,
            sourceHead: String,
            targetHead: String,
            sourceFingerprint: GitDiffFingerprint,
            targetFingerprint: GitDiffFingerprint
        ) {
            self.operationID = operationID
            self.snapshotID = snapshotID
            self.mergeBase = mergeBase
            self.sourceHead = sourceHead
            self.targetHead = targetHead
            self.sourceFingerprint = sourceFingerprint
            self.targetFingerprint = targetFingerprint
        }

        public init?(preview: GitWorktreeMergePreview) {
            guard let artifacts = preview.artifacts else { return nil }
            let inspection = preview.inspection
            self.init(
                operationID: preview.operationID,
                snapshotID: artifacts.snapshotID,
                mergeBase: inspection.mergeBase,
                sourceHead: inspection.sourceHead,
                targetHead: inspection.targetHead,
                sourceFingerprint: inspection.sourceFingerprint,
                targetFingerprint: inspection.targetFingerprint
            )
        }
    }

    /// Validated subset of the publisher's `merge_preview.json`.
    private struct SidecarIdentity: Decodable {
        let operationID: String
        let snapshotID: String
        let mergeBase: String
        let sourceHead: String
        let targetHead: String
        let sourceFingerprint: GitDiffFingerprint
        let targetFingerprint: GitDiffFingerprint
        let conflictPrediction: GitWorktreeMergeConflictPrediction
    }

    // MARK: Retain

    /// Copies the bundle at `artifacts.snapshotDirectory` to
    /// `<agentSessionsFolder>/.worktree-merge-reviews/<sessionID>/<operation>-<unique>` and returns the
    /// relocated references (same relative layout, same snapshot ID).
    public static func retain(
        _ artifacts: GitWorktreeMergePreviewArtifacts,
        expected: ExpectedIdentity,
        agentSessionsFolder: URL,
        sessionID: UUID
    ) throws -> GitWorktreeMergePreviewArtifacts {
        guard artifacts.snapshotID == expected.snapshotID else { throw Failure.identityMismatch("snapshot") }
        let sourceRoot = standardized(artifacts.snapshotDirectory)
        let manifest = try relativeComponents(artifacts.manifestPath, under: sourceRoot)
        let map = try relativeComponents(artifacts.mapPath, under: sourceRoot)
        let sidecar = try relativeComponents(artifacts.sidecarPath, under: sourceRoot)
        let allPatch = try artifacts.allPatchPath.map { try relativeComponents($0, under: sourceRoot) }

        let source = try openDirectory(atPath: sourceRoot, displayPath: artifacts.snapshotDirectory)
        defer { Darwin.close(source) }

        let sessions = try openDirectory(atPath: standardized(agentSessionsFolder.path), displayPath: agentSessionsFolder.path)
        defer { Darwin.close(sessions) }
        let retention = try openOrCreateDirectory(directoryName, in: sessions)
        defer { Darwin.close(retention) }
        let owner = try openOrCreateDirectory(sessionID.uuidString, in: retention)
        defer { Darwin.close(owner) }

        let finalName = "\(safeName(expected.operationID))-\(UUID().uuidString)"
        let assemblyName = ".\(finalName).assembling"
        guard mkdirat(owner, assemblyName, 0o700) == 0 else { throw ioError("assembly-create") }
        var published = false
        defer {
            if !published { removeTree(named: assemblyName, in: owner) }
        }
        let assembly = openat(owner, assemblyName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard assembly >= 0 else { throw ioError("assembly-open") }
        do {
            var budget = Budget()
            try copyDirectory(from: source, to: assembly, relativePath: "", depth: 0, budget: &budget)
            // The copy (not the mutable source) is what gets published: validate it.
            for components in [manifest, map] + [allPatch].compactMap(\.self) {
                try requireRegularFile(components, in: assembly, displayRoot: sourceRoot)
            }
            let sidecarData = try readFile(sidecar, in: assembly, maximumBytes: sidecarByteLimit, displayRoot: sourceRoot)
            try validate(sidecarData, expected: expected)
            Darwin.close(assembly)
        } catch {
            Darwin.close(assembly)
            throw error
        }
        guard renameatx_np(owner, assemblyName, owner, finalName, UInt32(RENAME_EXCL)) == 0 else {
            throw ioError("publish")
        }
        published = true

        let destination = agentSessionsFolder
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(finalName, isDirectory: true)
        func relocated(_ components: [String]) -> String {
            components.reduce(destination) { $0.appendingPathComponent($1) }.path
        }
        return GitWorktreeMergePreviewArtifacts(
            snapshotID: artifacts.snapshotID,
            snapshotDirectory: destination.path,
            manifestPath: relocated(manifest),
            mapPath: relocated(map),
            allPatchPath: allPatch.map(relocated),
            sidecarPath: relocated(sidecar)
        )
    }

    // MARK: Historical reads

    /// Reads one file of a retained bundle (never a non-retained snapshot), without following
    /// symlinks. Throws `limitExceeded` when the file is larger than `maximumBytes`.
    public static func readRetainedFile(
        _ path: String,
        in artifacts: GitWorktreeMergePreviewArtifacts,
        maximumBytes: Int
    ) throws -> Data {
        let root = standardized(artifacts.snapshotDirectory)
        try requireRetained(root)
        let components = try relativeComponents(path, under: root)
        let directory = try openDirectory(atPath: root, displayPath: artifacts.snapshotDirectory)
        defer { Darwin.close(directory) }
        return try readFile(components, in: directory, maximumBytes: maximumBytes, displayRoot: root)
    }

    /// The conflict prediction recorded when the proposal was made (past metadata, never current
    /// validation), after checking the retained sidecar still describes `operationID`.
    public static func retainedConflictPrediction(
        in artifacts: GitWorktreeMergePreviewArtifacts,
        operationID: String
    ) throws -> GitWorktreeMergeConflictPrediction {
        let data = try readRetainedFile(artifacts.sidecarPath, in: artifacts, maximumBytes: sidecarByteLimit)
        let sidecar = try decodeSidecar(data)
        guard sidecar.operationID == operationID else { throw Failure.identityMismatch("operation") }
        guard sidecar.snapshotID == artifacts.snapshotID else { throw Failure.identityMismatch("snapshot") }
        return sidecar.conflictPrediction
    }

    /// Whether `snapshotDirectory` is a bundle this type published (`…/.worktree-merge-reviews/<session>/<name>`).
    public static func isRetained(_ artifacts: GitWorktreeMergePreviewArtifacts) -> Bool {
        (try? requireRetained(standardized(artifacts.snapshotDirectory))) != nil
    }

    // MARK: Validation

    private static func validate(_ data: Data, expected: ExpectedIdentity) throws {
        let sidecar = try decodeSidecar(data)
        guard sidecar.operationID == expected.operationID else { throw Failure.identityMismatch("operation") }
        guard sidecar.snapshotID == expected.snapshotID else { throw Failure.identityMismatch("snapshot") }
        guard sidecar.mergeBase == expected.mergeBase else { throw Failure.identityMismatch("merge base") }
        guard sidecar.sourceHead == expected.sourceHead else { throw Failure.identityMismatch("source HEAD") }
        guard sidecar.targetHead == expected.targetHead else { throw Failure.identityMismatch("target HEAD") }
        guard sidecar.sourceFingerprint == expected.sourceFingerprint else {
            throw Failure.identityMismatch("source fingerprint")
        }
        guard sidecar.targetFingerprint == expected.targetFingerprint else {
            throw Failure.identityMismatch("target fingerprint")
        }
    }

    private static func decodeSidecar(_ data: Data) throws -> SidecarIdentity {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SidecarIdentity.self, from: data)
        } catch {
            throw Failure.identityMismatch("sidecar")
        }
    }

    private static func requireRetained(_ root: String) throws {
        let url = URL(fileURLWithPath: root, isDirectory: true)
        guard url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == directoryName,
              UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) != nil
        else { throw Failure.notRetained }
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Components of `path` below `root`; refuses anything that is not strictly inside it.
    private static func relativeComponents(_ path: String, under root: String) throws -> [String] {
        guard path.hasPrefix("/"), root.hasPrefix("/") else { throw Failure.escaping(path) }
        let candidate = standardized(path)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard candidate.hasPrefix(prefix) else { throw Failure.escaping(path) }
        let components = candidate.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw Failure.escaping(path)
        }
        return components
    }

    private static func safeName(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let filtered = String(raw.filter { allowed.contains($0) }.prefix(64))
        return filtered.isEmpty ? "merge" : filtered
    }

    // MARK: Descriptors

    private static func openDirectory(atPath path: String, displayPath: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            switch code {
            case ENOENT: throw Failure.missing(displayPath)
            case ELOOP, ENOTDIR: throw Failure.unsupportedEntry(displayPath)
            default: throw Failure.ioFailure(operation: "directory-open", code: code)
            }
        }
        return descriptor
    }

    private static func openOrCreateDirectory(_ name: String, in parent: Int32) throws -> Int32 {
        if mkdirat(parent, name, 0o700) != 0, errno != EEXIST {
            throw ioError("directory-create")
        }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR { throw Failure.unsupportedEntry(name) }
            throw Failure.ioFailure(operation: "directory-open", code: code)
        }
        return descriptor
    }

    /// Opens a regular file by components below `directory`, no symlink followed at any level.
    private static func readFile(
        _ components: [String],
        in directory: Int32,
        maximumBytes: Int,
        displayRoot: String,
        sizeOnly: Bool = false
    ) throws -> Data {
        let display = ([displayRoot] + components).joined(separator: "/")
        var current = directory
        var owned: [Int32] = []
        defer { owned.forEach { Darwin.close($0) } }
        for component in components.dropLast() {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw openFailure(errno, display: display) }
            owned.append(next)
            current = next
        }
        guard let leaf = components.last else { throw Failure.escaping(display) }
        let descriptor = openat(current, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw openFailure(errno, display: display) }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ioError("file-stat") }
        guard status.st_mode & S_IFMT == S_IFREG else { throw Failure.unsupportedEntry(display) }
        if sizeOnly { return Data() }
        guard status.st_size <= off_t(maximumBytes) else {
            throw Failure.limitExceeded("\(display) is \(status.st_size) bytes")
        }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: copyChunkSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, copyChunkSize) }
            if count < 0 {
                if errno == EINTR { continue }
                throw ioError("file-read")
            }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else { throw Failure.limitExceeded("\(display) grew while reading") }
            data.append(contentsOf: buffer[0 ..< count])
        }
        return data
    }

    private static func requireRegularFile(_ components: [String], in directory: Int32, displayRoot: String) throws {
        _ = try readFile(components, in: directory, maximumBytes: 0, displayRoot: displayRoot, sizeOnly: true)
    }

    private static func openFailure(_ code: Int32, display: String) -> Failure {
        switch code {
        case ENOENT: .missing(display)
        case ELOOP, ENOTDIR: .unsupportedEntry(display)
        default: .ioFailure(operation: "file-open", code: code)
        }
    }

    // MARK: Copy

    private struct Budget {
        var entries = 0
        var bytes: Int64 = 0
    }

    private static func copyDirectory(
        from source: Int32,
        to destination: Int32,
        relativePath: String,
        depth: Int,
        budget: inout Budget
    ) throws {
        guard depth <= maximumDepth else { throw Failure.limitExceeded("nesting deeper than \(maximumDepth)") }
        for name in try entryNames(source) {
            budget.entries += 1
            guard budget.entries <= maximumEntryCount else {
                throw Failure.limitExceeded("more than \(maximumEntryCount) entries")
            }
            let display = relativePath.isEmpty ? name : relativePath + "/" + name
            let entry = openat(source, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard entry >= 0 else { throw openFailure(errno, display: display) }
            defer { Darwin.close(entry) }
            var status = stat()
            guard fstat(entry, &status) == 0 else { throw ioError("entry-stat") }
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                guard mkdirat(destination, name, 0o700) == 0 else { throw ioError("directory-copy") }
                let child = openat(destination, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw ioError("directory-copy-open") }
                defer { Darwin.close(child) }
                try copyDirectory(from: entry, to: child, relativePath: display, depth: depth + 1, budget: &budget)
            case S_IFREG:
                try copyFile(entry, named: name, into: destination, budget: &budget)
            default:
                throw Failure.unsupportedEntry(display)
            }
        }
    }

    private static func copyFile(_ source: Int32, named name: String, into destination: Int32, budget: inout Budget) throws {
        let output = openat(destination, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw ioError("file-create") }
        defer { Darwin.close(output) }
        var buffer = [UInt8](repeating: 0, count: copyChunkSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, copyChunkSize) }
            if count < 0 {
                if errno == EINTR { continue }
                throw ioError("file-copy-read")
            }
            if count == 0 { return }
            budget.bytes += Int64(count)
            guard budget.bytes <= maximumTotalBytes else {
                throw Failure.limitExceeded("more than \(maximumTotalBytes) bytes")
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress! + offset, count - offset) }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ioError("file-copy-write")
                }
                offset += written
            }
        }
    }

    private static func entryNames(_ directory: Int32) throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw ioError("directory-duplicate") }
        guard let stream = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw ioError("directory-stream")
        }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
            guard names.count <= maximumEntryCount else {
                throw Failure.limitExceeded("more than \(maximumEntryCount) entries")
            }
            errno = 0
        }
        guard errno == 0 else { throw ioError("directory-read") }
        return names.sorted()
    }

    /// Best-effort removal of an unpublished assembly directory (never follows symlinks).
    private static func removeTree(named name: String, in parent: Int32) {
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory >= 0 {
            for child in (try? entryNames(directory)) ?? [] {
                var status = stat()
                guard fstatat(directory, child, &status, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if status.st_mode & S_IFMT == S_IFDIR {
                    removeTree(named: child, in: directory)
                } else {
                    unlinkat(directory, child, 0)
                }
            }
            Darwin.close(directory)
        }
        unlinkat(parent, name, AT_REMOVEDIR)
    }

    private static func ioError(_ operation: String) -> Failure {
        .ioFailure(operation: operation, code: errno)
    }
}
