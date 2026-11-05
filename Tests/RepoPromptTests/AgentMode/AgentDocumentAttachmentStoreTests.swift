import Darwin
@testable import RepoPromptAgentCore
import XCTest

/// Durable original-byte import, atomic batch rollback and safe managed-reference resolution for
/// PDF/HTML document attachments.
final class AgentDocumentAttachmentStoreTests: XCTestCase {
    private var sandbox: URL!
    private var sourceDirectory: URL!
    private var store: AgentDocumentAttachmentStore!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDocumentAttachmentStoreTests-\(UUID().uuidString)", isDirectory: true)
        sourceDirectory = sandbox.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        store = AgentDocumentAttachmentStore(
            rootURL: sandbox.appendingPathComponent("store", isDirectory: true),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    override func tearDownWithError() throws {
        // A test may leave `originals` read-only; restore it so the sandbox can be removed.
        chmod(store.originalsDirectoryURL.path, 0o700)
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: Helpers

    /// Bytes that are not valid UTF-8, so any text decoding/re-encoding would be detected.
    private func binaryPDFBytes() -> Data {
        var bytes = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        bytes.append(contentsOf: [0x00, 0xFF, 0xFE, 0x80, 0xC3, 0x28, 0x0D, 0x0A])
        bytes.append(contentsOf: (0 ..< 4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        bytes.append(Data("\n%%EOF\n".utf8))
        return bytes
    }

    private func writeSource(_ name: String, _ data: Data) throws -> URL {
        let url = sourceDirectory.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url)
        return url
    }

    private func permissionBits(_ url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }

    private func directoryEntries(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    private func assertImportFails(
        _ sources: [URL],
        _ expected: AgentDocumentImportError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await store.importDocuments(from: sources)
            XCTFail("Expected import failure \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AgentDocumentImportError, expected, file: file, line: line)
        }
    }

    // MARK: Import

    func testImportPreservesOriginalBytesAfterSourceIsMovedAndDeleted() async throws {
        let pdfBytes = binaryPDFBytes()
        let htmlBytes = Data("<!doctype html><script>alert('x')</script>\r\n\u{00E9}".utf8)
        let pdf = try writeSource("report.pdf", pdfBytes)
        let html = try writeSource("page.html", htmlBytes)
        let pdfModifiedBefore = try FileManager.default.attributesOfItem(atPath: pdf.path)[.modificationDate] as? Date

        let attachments = try await store.importDocuments(from: [pdf, html])

        XCTAssertEqual(attachments.map(\.kind), [.pdf, .html])
        XCTAssertEqual(attachments.map(\.originalFilename), ["report.pdf", "page.html"])
        XCTAssertEqual(attachments.map(\.byteCount), [Int64(pdfBytes.count), Int64(htmlBytes.count)])
        XCTAssertEqual(attachments[0].createdAt, Date(timeIntervalSince1970: 1_700_000_000))

        // The source is never modified by import.
        XCTAssertEqual(try Data(contentsOf: pdf), pdfBytes)
        let pdfModifiedAfter = try FileManager.default.attributesOfItem(atPath: pdf.path)[.modificationDate] as? Date
        XCTAssertEqual(pdfModifiedAfter, pdfModifiedBefore)

        // Move one source away and delete the other: managed originals remain byte-identical.
        try FileManager.default.moveItem(at: pdf, to: sandbox.appendingPathComponent("moved.pdf"))
        try FileManager.default.removeItem(at: html)

        let pdfURL = try store.resolveManagedFile(for: attachments[0]).get()
        let htmlURL = try store.resolveManagedFile(for: attachments[1]).get()
        XCTAssertEqual(try Data(contentsOf: pdfURL), pdfBytes)
        XCTAssertEqual(try Data(contentsOf: htmlURL), htmlBytes)
        XCTAssertEqual(pdfURL, store.managedFileURL(for: attachments[0]))
        XCTAssertEqual(pdfURL.deletingLastPathComponent(), store.originalsDirectoryURL)
        XCTAssertEqual(pdfURL.lastPathComponent, "\(attachments[0].id.uuidString).pdf")
        XCTAssertTrue(directoryEntries(store.stagingDirectoryURL).isEmpty)
    }

    func testUnicodeNamesArePreservedAndHtmIsCanonicalizedToHTML() async throws {
        let pdfName = "Résumé – 日本語 👨‍👩‍👧 (final).pdf"
        let htmName = "Ünïcödé Page.HTM"
        let pdf = try writeSource(pdfName, binaryPDFBytes())
        let htm = try writeSource(htmName, Data("<p>hi</p>".utf8))

        let attachments = try await store.importDocuments(from: [pdf, htm])

        XCTAssertEqual(attachments[0].originalFilename, pdf.lastPathComponent)
        XCTAssertEqual(attachments[1].originalFilename, htm.lastPathComponent)
        XCTAssertEqual(attachments[1].kind, .html)
        XCTAssertEqual(store.managedFileURL(for: attachments[1]).pathExtension, "html")
        XCTAssertNoThrow(try store.resolveManagedFile(for: attachments[1]).get())
    }

    func testEmptyBatchReturnsNothingAndCreatesNoStorage() async throws {
        let attachments = try await store.importDocuments(from: [])
        XCTAssertTrue(attachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.rootURL.path))
    }

    func testUnsupportedOrNonLocalSourceFailsWholeBatchBeforeAnyStorageWork() async throws {
        let pdf = try writeSource("ok.pdf", binaryPDFBytes())
        let text = try writeSource("notes.txt", Data("plain".utf8))
        let image = try writeSource("photo.png", Data([0x89, 0x50, 0x4E, 0x47]))

        await assertImportFails([pdf, text], .unsupportedType(filename: "notes.txt"))
        await assertImportFails([image], .unsupportedType(filename: "photo.png"))
        try await assertImportFails(
            [pdf, XCTUnwrap(URL(string: "https://example.com/remote.pdf"))],
            .notLocalFile(filename: "remote.pdf")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.rootURL.path))
    }

    func testLateStagingFailureRemovesStagedFilesWithoutPublishingOriginals() async throws {
        let first = try writeSource("first.pdf", binaryPDFBytes())
        let second = try writeSource("second.html", Data("<p>2</p>".utf8))
        let missing = sourceDirectory.appendingPathComponent("missing.pdf")

        await assertImportFails([first, second, missing], .unreadable(filename: "missing.pdf", code: ENOENT))

        XCTAssertTrue(directoryEntries(store.originalsDirectoryURL).isEmpty)
        XCTAssertTrue(directoryEntries(store.stagingDirectoryURL).isEmpty)
        // A retry after the failure succeeds and publishes only its own originals.
        let retried = try await store.importDocuments(from: [first, second])
        XCTAssertEqual(directoryEntries(store.originalsDirectoryURL).count, retried.count)
    }

    func testDirectoryNamedLikeADocumentIsRejected() async throws {
        let directory = sourceDirectory.appendingPathComponent("bundle.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pdf = try writeSource("ok.pdf", binaryPDFBytes())

        await assertImportFails([pdf, directory], .notRegularFile(filename: "bundle.pdf"))
        XCTAssertTrue(directoryEntries(store.originalsDirectoryURL).isEmpty)
    }

    func testSymlinkSourceCopiesTargetBytesNotTheLink() async throws {
        let targetBytes = binaryPDFBytes()
        let target = try writeSource("target.pdf", targetBytes)
        let link = sourceDirectory.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let attachments = try await store.importDocuments(from: [link])
        let managed = store.managedFileURL(for: attachments[0])

        var info = stat()
        XCTAssertEqual(lstat(managed.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG, "The managed original must be a regular file, not a link")
        XCTAssertEqual(try Data(contentsOf: managed), targetBytes)
        XCTAssertEqual(attachments[0].originalFilename, "link.pdf")

        // A dangling link is an explicit failure.
        try FileManager.default.removeItem(at: target)
        let dangling = sourceDirectory.appendingPathComponent("dangling.pdf")
        try FileManager.default.createSymbolicLink(
            at: dangling,
            withDestinationURL: sourceDirectory.appendingPathComponent("gone.pdf")
        )
        await assertImportFails([dangling], .unreadable(filename: "dangling.pdf", code: ENOENT))
    }

    func testPublishedOriginalAndStorageDirectoriesArePrivate() async throws {
        let pdf = try writeSource("private.pdf", binaryPDFBytes())
        let attachment = try await store.importDocuments(from: [pdf])[0]

        XCTAssertEqual(permissionBits(store.managedFileURL(for: attachment)), 0o600)
        XCTAssertEqual(permissionBits(store.originalsDirectoryURL), 0o700)
        XCTAssertEqual(permissionBits(store.stagingDirectoryURL), 0o700)
    }

    func testOriginalsLocationThatIsAFileOrSymlinkIsStorageUnavailable() async throws {
        let pdf = try writeSource("doc.pdf", binaryPDFBytes())
        try FileManager.default.createDirectory(at: store.rootURL, withIntermediateDirectories: true)

        try Data("not a directory".utf8).write(to: store.originalsDirectoryURL)
        do {
            _ = try await store.importDocuments(from: [pdf])
            XCTFail("Expected storage failure when originals is a regular file")
        } catch {
            guard case .storageUnavailable = error as? AgentDocumentImportError else {
                return XCTFail("Unexpected error \(error)")
            }
        }

        try FileManager.default.removeItem(at: store.originalsDirectoryURL)
        let elsewhere = sandbox.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.originalsDirectoryURL, withDestinationURL: elsewhere)
        await assertImportFails([pdf], .storageUnavailable(code: ENOTDIR))
        XCTAssertTrue(directoryEntries(elsewhere).isEmpty)
    }

    func testPermissionDeniedPublicationRollsBackWholeBatch() async throws {
        let first = try writeSource("first.pdf", binaryPDFBytes())
        let second = try writeSource("second.html", Data("<p>2</p>".utf8))
        try FileManager.default.createDirectory(at: store.originalsDirectoryURL, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(store.originalsDirectoryURL.path, 0o500), 0)

        await assertImportFails([first, second], .copyFailed(filename: "first.pdf", code: EACCES))

        XCTAssertTrue(directoryEntries(store.originalsDirectoryURL).isEmpty)
        XCTAssertTrue(directoryEntries(store.stagingDirectoryURL).isEmpty)
        XCTAssertEqual(try Data(contentsOf: first), binaryPDFBytes(), "The source must be untouched")
    }

    func testCancelledTaskImportsNothing() async throws {
        let pdf = try writeSource("cancel.pdf", binaryPDFBytes())
        let documentStore = try XCTUnwrap(store)
        let task = Task { () async throws -> [AgentDocumentAttachment] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await documentStore.importDocuments(from: [pdf])
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error \(error)")
        }
        XCTAssertTrue(directoryEntries(documentStore.originalsDirectoryURL).isEmpty)
        XCTAssertTrue(directoryEntries(documentStore.stagingDirectoryURL).isEmpty)
    }

    func testFinderAliasIsRejectedRatherThanImportedAsDocumentBytes() async throws {
        let target = try writeSource("target.pdf", binaryPDFBytes())
        let alias = sourceDirectory.appendingPathComponent("alias.pdf")
        let bookmark = try target.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(bookmark, to: alias)

        await assertImportFails([alias], .finderAlias(filename: "alias.pdf"))
        XCTAssertTrue(directoryEntries(store.originalsDirectoryURL).isEmpty)
    }

    // MARK: Resolution

    func testResolutionRejectsMissingSymlinkedAndResizedOriginals() async throws {
        let pdf = try writeSource("doc.pdf", binaryPDFBytes())
        let attachment = try await store.importDocuments(from: [pdf])[0]
        let managed = store.managedFileURL(for: attachment)

        try Data("short".utf8).write(to: managed)
        XCTAssertEqual(
            store.resolveManagedFile(for: attachment),
            .failure(.sizeMismatch(filename: "doc.pdf", expected: attachment.byteCount, actual: 5))
        )

        try FileManager.default.removeItem(at: managed)
        XCTAssertEqual(store.resolveManagedFile(for: attachment), .failure(.missing(filename: "doc.pdf")))

        try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: pdf)
        XCTAssertEqual(store.resolveManagedFile(for: attachment), .failure(.notRegularFile(filename: "doc.pdf")))

        let unknown = AgentDocumentAttachment(kind: .html, originalFilename: "never.html", byteCount: 1)
        XCTAssertEqual(store.resolveManagedFile(for: unknown), .failure(.missing(filename: "never.html")))
    }

    func testRecordCarriesNoPathAuthorityAndRoundTrips() throws {
        let attachment = AgentDocumentAttachment(
            kind: .pdf,
            originalFilename: "../../etc/passwd.pdf",
            byteCount: 42,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(attachment)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "kind", "originalFilename", "byteCount", "createdAt"])
        XCTAssertEqual(try JSONDecoder().decode(AgentDocumentAttachment.self, from: data), attachment)

        // A hostile name never influences the managed location.
        let managed = store.managedFileURL(for: attachment)
        XCTAssertEqual(managed.deletingLastPathComponent(), store.originalsDirectoryURL)
        XCTAssertEqual(managed.lastPathComponent, "\(attachment.id.uuidString).pdf")
    }

    func testKindClassificationIsExtensionBasedAndExcludesImages() {
        XCTAssertEqual(AgentDocumentKind(pathExtension: "PDF"), .pdf)
        XCTAssertEqual(AgentDocumentKind(pathExtension: "html"), .html)
        XCTAssertEqual(AgentDocumentKind(pathExtension: "Htm"), .html)
        for other in ["png", "jpg", "jpeg", "txt", "xhtml", ""] {
            XCTAssertNil(AgentDocumentKind(pathExtension: other), other)
        }
    }

    func testDefaultRootUnderXCTestIsTemporaryAndVersioned() {
        let root = AgentDocumentAttachmentStore.defaultRootURL()
        XCTAssertTrue(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertEqual(root.lastPathComponent, "v1")
    }
}
