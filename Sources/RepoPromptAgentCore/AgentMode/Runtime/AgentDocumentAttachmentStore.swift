import Darwin
import Foundation
import RepoPromptWorkspace

/// Why a document could not be imported. Every case names the user-visible source filename so the
/// composer can report an explicit failure while preserving the user's input.
package enum AgentDocumentImportError: LocalizedError, Equatable {
    case notLocalFile(filename: String)
    case unsupportedType(filename: String)
    case notRegularFile(filename: String)
    case finderAlias(filename: String)
    case unreadable(filename: String, code: Int32)
    case sourceChangedDuringImport(filename: String)
    case copyFailed(filename: String, code: Int32)
    case storageUnavailable(code: Int32)

    package var errorDescription: String? {
        switch self {
        case let .notLocalFile(filename):
            "“\(filename)” is not a local file and cannot be attached."
        case let .unsupportedType(filename):
            "“\(filename)” is not a PDF or HTML document."
        case let .notRegularFile(filename):
            "“\(filename)” is not a regular file and cannot be attached."
        case let .finderAlias(filename):
            "“\(filename)” is a Finder alias. Attach the original file instead."
        case let .unreadable(filename, code):
            "“\(filename)” could not be read (\(Self.describe(code)))."
        case let .sourceChangedDuringImport(filename):
            "“\(filename)” changed while it was being attached. Try again."
        case let .copyFailed(filename, code):
            "“\(filename)” could not be copied into RepoPrompt storage (\(Self.describe(code)))."
        case let .storageUnavailable(code):
            "RepoPrompt document storage is unavailable (\(Self.describe(code)))."
        }
    }

    private static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// Why a managed document reference could not be resolved to a readable original.
package enum AgentDocumentResolutionError: LocalizedError, Equatable {
    case missing(filename: String)
    case notRegularFile(filename: String)
    case unreadable(filename: String, code: Int32)
    case sizeMismatch(filename: String, expected: Int64, actual: Int64)

    package var errorDescription: String? {
        switch self {
        case let .missing(filename):
            "The attached document “\(filename)” is no longer available in RepoPrompt storage."
        case let .notRegularFile(filename):
            "The stored copy of “\(filename)” is not a regular file."
        case let .unreadable(filename, code):
            "The stored copy of “\(filename)” could not be read (\(String(cString: strerror(code))))."
        case let .sizeMismatch(filename, expected, actual):
            "The stored copy of “\(filename)” changed size (expected \(expected) bytes, found \(actual))."
        }
    }
}

/// Durable, app-owned storage for the original bytes of attached PDF/HTML documents.
///
/// - Originals live under `<Application Support>/RepoPrompt CE/AgentDocuments/v1/originals` (never a
///   temporary directory), named only by attachment ID and canonical kind extension. A record never
///   persists a path; `managedFileURL(for:)` derives it, so decoded data cannot point elsewhere.
/// - Imports copy bytes from an `O_RDONLY` descriptor (the source is never modified, symlinks are
///   followed to their regular-file target and the link itself is never copied, Finder aliases,
///   directories and other non-regular files are rejected) without decoding or rewriting the
///   document. A source whose size or nanosecond modification time changes during the copy is
///   rejected.
/// - A batch import is all-or-nothing for thrown errors (including task cancellation, checked once
///   per copied chunk and before publication): originals are staged in a per-batch directory and
///   published only after every copy succeeds, and a thrown failure removes everything this batch
///   wrote. A process crash or forced quit mid-import can leave a partial `staging/<batch>`
///   directory behind; nothing is ever published from it, and it is not swept automatically
///   (multi-process ownership and bounded cleanup are deferred).
/// - Published originals are retained. Nothing here deletes them on send or provider acceptance.
///
/// The actor keeps filesystem work off the main actor; callers `await` imports so UI can show a
/// pending state.
package actor AgentDocumentAttachmentStore {
    private static let copyBufferSize = 1 << 20

    package nonisolated let rootURL: URL
    private let now: @Sendable () -> Date

    package init(rootURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.rootURL = rootURL.standardizedFileURL
        self.now = now
    }

    /// `<Application Support>/RepoPrompt CE/AgentDocuments/v1`. XCTest processes get a temporary
    /// root (the `AgentRecoveryStore` precedent), so tests never touch live data.
    package static func defaultRootURL() -> URL {
        #if DEBUG
            if NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil {
                return FileManager.default.temporaryDirectory
                    .appendingPathComponent("RepoPromptCE-XCTest", isDirectory: true)
                    .appendingPathComponent("AgentDocuments-\(UUID().uuidString)", isDirectory: true)
                    .appendingPathComponent("v1", isDirectory: true)
            }
        #endif
        return MCPFilesystemConstants.identity.applicationSupportRootURL()
            .appendingPathComponent("AgentDocuments", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    /// The app's single production store. Construction performs no filesystem work.
    package static let production = AgentDocumentAttachmentStore(rootURL: defaultRootURL())

    // MARK: Paths

    package nonisolated var originalsDirectoryURL: URL {
        rootURL.appendingPathComponent("originals", isDirectory: true)
    }

    nonisolated var stagingDirectoryURL: URL {
        rootURL.appendingPathComponent("staging", isDirectory: true)
    }

    /// The only location a managed original can have: derived from the immutable ID and kind.
    package nonisolated func managedFileURL(for attachment: AgentDocumentAttachment) -> URL {
        managedFileURL(id: attachment.id, kind: attachment.kind)
    }

    package nonisolated func managedFileURL(id: UUID, kind: AgentDocumentKind) -> URL {
        originalsDirectoryURL
            .appendingPathComponent(id.uuidString, isDirectory: false)
            .appendingPathExtension(kind.managedFileExtension)
    }

    /// Classifies a candidate source by filename extension; `nil` means not a supported document.
    package nonisolated static func documentKind(for sourceURL: URL) -> AgentDocumentKind? {
        AgentDocumentKind(pathExtension: sourceURL.pathExtension)
    }

    // MARK: Resolution

    /// Resolves a managed reference to its stored original, validating that it exists as a regular
    /// file (not a symlink), is readable, and still has the recorded size.
    package nonisolated func resolveManagedFile(
        for attachment: AgentDocumentAttachment
    ) -> Result<URL, AgentDocumentResolutionError> {
        let url = managedFileURL(for: attachment)
        let filename = attachment.originalFilename
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let code = errno
            return .failure(
                code == ENOENT || code == ENOTDIR
                    ? .missing(filename: filename)
                    : .unreadable(filename: filename, code: code)
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            return .failure(.notRegularFile(filename: filename))
        }
        guard access(url.path, R_OK) == 0 else {
            return .failure(.unreadable(filename: filename, code: errno))
        }
        let actual = Int64(info.st_size)
        guard actual == attachment.byteCount else {
            return .failure(.sizeMismatch(filename: filename, expected: attachment.byteCount, actual: actual))
        }
        return .success(url)
    }

    // MARK: Import

    /// Imports every source atomically, returning attachments in source order. An empty input
    /// returns an empty result without touching storage. On any thrown failure nothing from this
    /// batch remains published and the first error is thrown; cancellation of the calling task
    /// throws `CancellationError`.
    package func importDocuments(from sourceURLs: [URL]) throws -> [AgentDocumentAttachment] {
        guard !sourceURLs.isEmpty else { return [] }

        // Classify the whole batch before any filesystem work.
        let plans: [(source: URL, filename: String, kind: AgentDocumentKind)] = try sourceURLs.map { source in
            let filename = source.lastPathComponent
            guard source.isFileURL else { throw AgentDocumentImportError.notLocalFile(filename: filename) }
            guard let kind = Self.documentKind(for: source) else {
                throw AgentDocumentImportError.unsupportedType(filename: filename)
            }
            return (source, filename, kind)
        }

        try ensurePrivateDirectory(originalsDirectoryURL)
        try ensurePrivateDirectory(stagingDirectoryURL)
        let batchDirectory = stagingDirectoryURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ensurePrivateDirectory(batchDirectory)
        defer { try? FileManager.default.removeItem(at: batchDirectory) }

        var staged: [(attachment: AgentDocumentAttachment, stagedURL: URL)] = []
        staged.reserveCapacity(plans.count)
        for plan in plans {
            let id = UUID()
            let stagedURL = batchDirectory
                .appendingPathComponent(id.uuidString, isDirectory: false)
                .appendingPathExtension(plan.kind.managedFileExtension)
            let byteCount = try copyOriginalBytes(from: plan.source, to: stagedURL, filename: plan.filename)
            let attachment = AgentDocumentAttachment(
                id: id,
                kind: plan.kind,
                originalFilename: plan.filename,
                byteCount: byteCount,
                createdAt: now()
            )
            staged.append((attachment, stagedURL))
        }

        try Task.checkCancellation()
        var published: [URL] = []
        do {
            for item in staged {
                let destination = managedFileURL(for: item.attachment)
                guard renamex_np(item.stagedURL.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw AgentDocumentImportError.copyFailed(filename: item.attachment.originalFilename, code: errno)
                }
                published.append(destination)
            }
        } catch {
            for url in published {
                unlink(url.path)
            }
            throw error
        }
        syncDirectory(originalsDirectoryURL)
        return staged.map(\.attachment)
    }

    // MARK: Private

    private func ensurePrivateDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            let nsError = error as NSError
            let posixError = nsError.domain == NSPOSIXErrorDomain
                ? nsError
                : nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            let code = posixError.map { Int32($0.code) } ?? EIO
            throw AgentDocumentImportError.storageUnavailable(code: code)
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw AgentDocumentImportError.storageUnavailable(code: ENOTDIR)
        }
    }

    /// Streams the source's bytes into a new private file and returns the copied byte count.
    private func copyOriginalBytes(from source: URL, to destination: URL, filename: String) throws -> Int64 {
        // Follow symlinks to the final target, then refuse to traverse a link swapped in afterwards.
        guard let resolvedCString = realpath(source.standardizedFileURL.path, nil) else {
            throw AgentDocumentImportError.unreadable(filename: filename, code: errno)
        }
        let resolvedPath = String(cString: resolvedCString)
        free(resolvedCString)
        // The resolved path is never a symlink, so `isAliasFile` here identifies a Finder alias.
        let aliasValues = try? URL(fileURLWithPath: resolvedPath).resourceValues(forKeys: [.isAliasFileKey])
        if aliasValues?.isAliasFile == true {
            throw AgentDocumentImportError.finderAlias(filename: filename)
        }
        let sourceFD = open(resolvedPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard sourceFD >= 0 else {
            let code = errno
            if code == ELOOP { throw AgentDocumentImportError.notRegularFile(filename: filename) }
            throw AgentDocumentImportError.unreadable(filename: filename, code: code)
        }
        defer { close(sourceFD) }

        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0 else {
            throw AgentDocumentImportError.unreadable(filename: filename, code: errno)
        }
        guard (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
            throw AgentDocumentImportError.notRegularFile(filename: filename)
        }

        let destinationFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destinationFD >= 0 else {
            throw AgentDocumentImportError.copyFailed(filename: filename, code: errno)
        }
        defer { close(destinationFD) }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.copyBufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let readCount = read(sourceFD, buffer, Self.copyBufferSize)
            if readCount < 0 {
                let code = errno
                if code == EINTR { continue }
                throw AgentDocumentImportError.unreadable(filename: filename, code: code)
            }
            if readCount == 0 { break }
            var written = 0
            while written < readCount {
                let result = write(destinationFD, buffer.advanced(by: written), readCount - written)
                if result < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw AgentDocumentImportError.copyFailed(filename: filename, code: code)
                }
                written += result
            }
            total += Int64(readCount)
        }

        guard fsync(destinationFD) == 0 else {
            throw AgentDocumentImportError.copyFailed(filename: filename, code: errno)
        }

        var finalSourceInfo = stat()
        guard fstat(sourceFD, &finalSourceInfo) == 0,
              Int64(finalSourceInfo.st_size) == total,
              Int64(sourceInfo.st_size) == total,
              finalSourceInfo.st_mtimespec.tv_sec == sourceInfo.st_mtimespec.tv_sec,
              finalSourceInfo.st_mtimespec.tv_nsec == sourceInfo.st_mtimespec.tv_nsec
        else {
            throw AgentDocumentImportError.sourceChangedDuringImport(filename: filename)
        }
        return total
    }

    private func syncDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }
}
