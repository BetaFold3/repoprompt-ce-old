import AppKit
import CoreFoundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentImageInputAdapterTests: XCTestCase {
    func testDocumentAndUnresolvedFilePayloadsDoNotBecomePreviewImages() throws {
        try withFixture { fixture in
            let pdf = try fixture.file("document.pdf")
            let html = try fixture.file("document.html")
            let references = [
                pdf.absoluteString,
                html.absoluteString,
                fixture.root.appendingPathComponent("missing.pdf").absoluteString,
                fixture.root.appendingPathComponent("missing.png").absoluteString,
                "not-a-file-url",
                "https://example.invalid/document.pdf"
            ]
            for reference in references {
                for previewType in [Self.iconType, .png, .tiff] {
                    let item = fileItem(reference, previewType: previewType)
                    item.setString("document", forType: .string)
                    fixture.write([item])
                    XCTAssertFalse(fixture.adapter.shouldConsumePasteAsImageAttachment(from: fixture.pasteboard), reference)
                    XCTAssertEqual(fixture.adapter.preparedImages(from: fixture.pasteboard), [], reference)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path), reference)
                }
            }
        }
    }

    func testMixedFileSelectionIsNotPartiallyConsumedInEitherOrder() throws {
        try withFixture { fixture in
            let image = try fixture.file("image.png")
            let pdf = try fixture.file("document.pdf")
            for urls in [[image, pdf], [pdf, image]] {
                fixture.write(urls.map { fileItem($0.absoluteString) })
                XCTAssertFalse(fixture.adapter.shouldConsumePasteAsImageAttachment(from: fixture.pasteboard))
                XCTAssertEqual(fixture.adapter.preparedImages(from: fixture.pasteboard), [])
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
            }
        }
    }

    func testImageFileSelectionUsesOriginalFilesAndNeverTheirIcons() throws {
        try withFixture { fixture in
            let urls = try ["image.png", "image.jpg", "actual.icns"].map { try fixture.file($0) }
            fixture.write(urls.map { fileItem($0.absoluteString) })
            XCTAssertTrue(fixture.adapter.shouldConsumePasteAsImageAttachment(from: fixture.pasteboard))
            XCTAssertEqual(
                fixture.adapter.preparedImages(from: fixture.pasteboard),
                urls.map { AgentImageInputAdapter.PreparedImage(url: $0.standardizedFileURL, isTemporary: false) }
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))

            // A file disappearing after admission must not enable preview fallback.
            try FileManager.default.removeItem(at: urls[0])
            XCTAssertEqual(fixture.adapter.preparedImages(from: fixture.pasteboard), [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
            for url in urls.dropFirst() {
                try FileManager.default.removeItem(at: url)
            }
            XCTAssertEqual(fixture.adapter.preparedImages(from: fixture.pasteboard), [])
        }
    }

    func testFinderFileReferenceURLsResolveToOriginalImages() throws {
        try withFixture { fixture in
            let image = try fixture.file("image.png")
            let pdf = try fixture.file("document.pdf")
            // Keep the wire string in CFURL: bridging a reference to Swift URL can resolve it early.
            let imageReference = try fileReferenceString(image)
            let pdfReference = try fileReferenceString(pdf)

            fixture.write([fileItem(imageReference)])
            XCTAssertTrue(fixture.adapter.shouldConsumePasteAsImageAttachment(from: fixture.pasteboard))
            let prepared = fixture.adapter.preparedImages(from: fixture.pasteboard)
            XCTAssertEqual(prepared.map { $0.url.resolvingSymlinksInPath() }, [image.resolvingSymlinksInPath()])
            XCTAssertEqual(prepared.map(\.isTemporary), [false])
            XCTAssertEqual(prepared.first?.url.lastPathComponent, image.lastPathComponent)

            fixture.write([fileItem(pdfReference)])
            XCTAssertFalse(fixture.adapter.shouldConsumePasteAsImageAttachment(from: fixture.pasteboard))
            XCTAssertEqual(fixture.adapter.preparedImages(from: fixture.pasteboard), [])
            fixture.write([imageReference, pdfReference].map { fileItem($0) })
            XCTAssertFalse(fixture.adapter.shouldConsumePasteAsImageAttachment(from: fixture.pasteboard))
            XCTAssertEqual(fixture.adapter.preparedImages(from: fixture.pasteboard), [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        }
    }

    func testRawImagesWithoutFileURLsStillPrepareAndCleanUp() throws {
        try withFixture { fixture in
            for type in [NSPasteboard.PasteboardType.png, .tiff, Self.iconType] {
                let item = NSPasteboardItem()
                item.setData(Self.imageData, forType: type)
                // A browser source URL is not a Finder file payload.
                item.setString("https://example.invalid/image", forType: .URL)
                fixture.write([item])
                XCTAssertTrue(fixture.adapter.shouldConsumePasteAsImageAttachment(from: fixture.pasteboard), type.rawValue)
                let prepared = fixture.adapter.preparedImages(from: fixture.pasteboard)
                XCTAssertEqual(prepared.count, 1, type.rawValue)
                let entry = try XCTUnwrap(prepared.first)
                XCTAssertTrue(entry.isTemporary)
                XCTAssertEqual(try Data(contentsOf: entry.url), Self.imageData)
                fixture.adapter.cleanupTemporaryFiles(prepared)
                XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path))
            }
        }
    }

    func testPlainTextPathsKeepExistingImageAndTextBehavior() throws {
        try withFixture { fixture in
            let image = try fixture.file("image.png")
            let document = try fixture.file("document.pdf")
            for (text, consumed) in [(image.path, true), ("Please inspect \(image.path)", false)] {
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                fixture.write([item])
                XCTAssertEqual(fixture.adapter.shouldConsumePasteAsImageAttachment(from: fixture.pasteboard), consumed, text)
                if consumed {
                    XCTAssertEqual(
                        fixture.adapter.preparedImages(from: fixture.pasteboard),
                        [AgentImageInputAdapter.PreparedImage(url: image.standardizedFileURL, isTemporary: false)]
                    )
                }
            }
            let documentItem = NSPasteboardItem()
            documentItem.setString(document.path, forType: .string)
            fixture.write([documentItem])
            // Admission may accept path-shaped text; preparation must not attach a document.
            XCTAssertEqual(fixture.adapter.preparedImages(from: fixture.pasteboard), [])
        }
    }

    func testNativeTextSelectionDoesNotAttachDocumentIcon() throws {
        try withFixture { fixture in
            let pdf = try fixture.file("document.pdf")
            let item = fileItem(pdf.absoluteString)
            item.setString("document.pdf", forType: .string)
            fixture.write([item])
            let view = ImageAwareTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
            view.isRichText = false
            view.enablesImagePasteHandling = true
            var attachments: [AgentImageInputAdapter.PreparedImage] = []
            view.imagePasteHandler = { pasteboard in
                guard fixture.adapter.shouldConsumePasteAsImageAttachment(from: pasteboard) else { return false }
                attachments += fixture.adapter.preparedImages(from: pasteboard)
                return !attachments.isEmpty
            }

            // Use a private board: paste(_:) would let AppKit read the user's general clipboard.
            _ = view.readSelection(from: fixture.pasteboard)
            XCTAssertEqual(attachments, [])
            XCTAssertEqual(view.string, "document.pdf")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        }
    }

    func testFilePayloadWithoutPreviewAndBoardLevelDataCannotUseNSImageFallback() throws {
        try withFixture { fixture in
            let pdf = try fixture.file("document.pdf")
            fixture.pasteboard.declareTypes([.fileURL], owner: nil)
            XCTAssertTrue(fixture.pasteboard.setData(pdf.dataRepresentation, forType: .fileURL))
            XCTAssertFalse(fixture.adapter.shouldConsumePasteAsImageAttachment(from: fixture.pasteboard))
            XCTAssertEqual(fixture.adapter.preparedImages(from: fixture.pasteboard), [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        }
    }

    func testStructuredFilesOutrankTextImageReferencesAndRejectImageNamedDirectories() throws {
        try withFixture { fixture in
            let image = try fixture.file("image.png")
            let pdf = try fixture.file("document.pdf")
            let folder = fixture.root.appendingPathComponent("folder.png")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for url in [pdf, folder] {
                let item = fileItem(url.absoluteString)
                item.setString(image.path, forType: .string)
                fixture.write([item])
                XCTAssertFalse(fixture.adapter.shouldConsumePasteAsImageAttachment(from: fixture.pasteboard))
                XCTAssertEqual(fixture.adapter.preparedImages(from: fixture.pasteboard), [])
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        }
    }

    func testTextViewRejectsFilePreviewsOnReadSelectionAndDropAdmission() throws {
        try withFixture { fixture in
            let pdf = try fixture.file("document.pdf")
            let image = try fixture.file("image.png")
            let view = ImageAwareTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
            view.isRichText = false
            view.enablesImagePasteHandling = true
            var callbackCount = 0
            view.imagePasteHandler = { _ in
                callbackCount += 1
                return true
            }
            for urls in [[pdf], [image, pdf], [pdf, image]] {
                fixture.write(urls.map { fileItem($0.absoluteString, previewType: .png) })
                XCTAssertFalse(view.canHandleImageDrop(from: fixture.pasteboard))
                _ = view.readSelection(from: fixture.pasteboard, type: .png)
                XCTAssertEqual(callbackCount, 0)
            }
            fixture.write([fileItem(image.absoluteString, previewType: .png)])
            XCTAssertTrue(view.canHandleImageDrop(from: fixture.pasteboard))
            XCTAssertTrue(view.readSelection(from: fixture.pasteboard, type: .png))
            XCTAssertEqual(callbackCount, 1)
        }
    }

    func testUnreadableImageDefersEntireSelectionWithoutPreviewFallback() throws {
        try withFixture { fixture in
            let unreadable = try fixture.file("unreadable.png")
            let readable = try fixture.file("readable.png")
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
            XCTAssertFalse(FileManager.default.isReadableFile(atPath: unreadable.path))
            fixture.write([readable, unreadable].map { fileItem($0.absoluteString) })
            XCTAssertFalse(fixture.adapter.shouldConsumePasteAsImageAttachment(from: fixture.pasteboard))
            XCTAssertEqual(fixture.adapter.preparedImages(from: fixture.pasteboard), [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        }
    }

    func testDropCompletionOnlyConsumesAnAcceptedImageCallback() throws {
        try withFixture { fixture in
            let item = NSPasteboardItem()
            item.setData(Self.imageData, forType: .png)
            fixture.write([item])
            let drag = PasteboardDraggingInfo(pasteboard: fixture.pasteboard)
            let native = NSTextView(frame: .zero)
            native.isRichText = false
            // A plain text view cannot insert this raw-image-only payload.
            XCTAssertFalse(native.performDragOperation(drag))

            let view = ImageAwareTextView(frame: .zero)
            view.isRichText = false
            view.enablesImagePasteHandling = true
            var callbackCount = 0
            view.imagePasteHandler = { _ in
                callbackCount += 1
                return false
            }
            XCTAssertFalse(view.performDragOperation(drag))
            // Native fallback may reenter readSelection; AppKit owns the retry count.
            XCTAssertGreaterThan(callbackCount, 0)

            callbackCount = 0
            view.imagePasteHandler = { _ in
                callbackCount += 1
                return true
            }
            XCTAssertTrue(view.performDragOperation(drag))
            XCTAssertEqual(callbackCount, 1)

            callbackCount = 0
            view.imagePasteHandler = nil
            XCTAssertFalse(view.performDragOperation(drag))
            XCTAssertEqual(callbackCount, 0)
        }
    }

    private func fileReferenceString(_ url: URL) throws -> String {
        let reference = try XCTUnwrap(CFURLCreateFileReferenceURL(nil, url as CFURL, nil)).takeRetainedValue()
        XCTAssertTrue(CFURLIsFileReferenceURL(reference))
        let string = CFURLGetString(reference) as String
        XCTAssertTrue(string.hasPrefix("file:///.file/id="), string)
        return string
    }

    private static let iconType = NSPasteboard.PasteboardType("com.apple.icns")
    private static let imageData = Data([0x01, 0x02, 0x03])

    private func fileItem(
        _ reference: String,
        previewType: NSPasteboard.PasteboardType? = nil
    ) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(reference, forType: .fileURL)
        item.setData(Self.imageData, forType: previewType ?? Self.iconType)
        return item
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderPasteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
        try body(Fixture(root: root, pasteboard: pasteboard))
    }

    private final class PasteboardDraggingInfo: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingDestinationWindow: NSWindow? = nil
        let draggingSourceOperationMask: NSDragOperation = .copy
        let draggingLocation: NSPoint = .zero
        let draggedImageLocation: NSPoint = .zero
        let draggingSource: Any? = nil
        let draggingSequenceNumber = 1
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        let springLoadingHighlight: NSSpringLoadingHighlight = .none

        nonisolated var draggedImage: NSImage? {
            nil
        }

        @MainActor
        init(pasteboard: NSPasteboard) {
            draggingPasteboard = pasteboard
        }

        func slideDraggedImage(to _: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination _: URL) -> [String]? {
            nil
        }

        func resetSpringLoading() {}
        func enumerateDraggingItems(
            options _: NSDraggingItemEnumerationOptions,
            for _: NSView?,
            classes _: [AnyClass],
            searchOptions _: [NSPasteboard.ReadingOptionKey: Any],
            using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
    }

    private struct Fixture {
        let root: URL
        let pasteboard: NSPasteboard
        var output: URL {
            root.appendingPathComponent("prepared")
        }

        var adapter: AgentImageInputAdapter {
            AgentImageInputAdapter(temporaryRoot: output)
        }

        func file(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data([0x01]).write(to: url)
            return url
        }

        func write(_ items: [NSPasteboardItem]) {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects(items))
        }
    }
}
