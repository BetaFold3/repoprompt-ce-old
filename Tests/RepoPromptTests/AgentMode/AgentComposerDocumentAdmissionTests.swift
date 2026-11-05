import AppKit
import CoreFoundation
@_spi(TestSupport) @testable import RepoPromptAgentCore
@_spi(TestSupport) @testable import RepoPromptApp
import UniformTypeIdentifiers
import XCTest

/// Step 3 composer admission of Finder PDF/HTML files: explicit-file classification on private
/// pasteboards (genuine CFURL file-reference wire strings, Finder icons and filename text alongside),
/// the opt-in text-view hook before image/native handling, the surrounding SwiftUI drop's provider
/// loading, the asynchronous managed-store import with its destination fences, and the composer
/// projection (chips, removal, scheduled props). Fixture tests only: they never prove installed-app
/// Finder acceptance.
@MainActor
final class AgentComposerDocumentAdmissionTests: XCTestCase {
    private var root: URL!
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentComposerDocumentAdmissionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDownWithError() throws {
        pasteboard?.releaseGlobally()
        if let root {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Classification

    func testFinderReferencePDFAndHTMLWithIconsClassifyAsTheirOriginals() throws {
        let pdf = try file("Résumé 📄 final.pdf", "%PDF-1.4 body")
        let html = try file("Notes page.HTM", "<html><body>notes</body></html>")
        let pdfReference = try fileReferenceString(pdf)
        let htmlReference = try fileReferenceString(html)
        // Finder-shaped items: file reference, ICNS icon and filename text; plus a duplicate.
        write([
            finderItem(pdfReference, name: pdf.lastPathComponent),
            finderItem(htmlReference, name: html.lastPathComponent),
            finderItem(pdf.absoluteString, name: pdf.lastPathComponent)
        ])

        let admission = ComposerDocumentFileAdmission.classify(pasteboard: pasteboard)
        guard case let .documents(urls) = admission else {
            return XCTFail("Expected documents, got \(admission)")
        }
        XCTAssertEqual(urls.map { $0.resolvingSymlinksInPath() }, [pdf, html].map { $0.resolvingSymlinksInPath() })
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Résumé 📄 final.pdf", "Notes page.HTM"])
        // The image path still defers these to native handling (it never attaches the icon).
        XCTAssertEqual(ImagePasteboardTypes.filePayload(in: pasteboard), .deferToNative)
    }

    func testMissingOrDirectoryNamedDocumentIsStillClaimed() throws {
        let missing = root.appendingPathComponent("missing.pdf")
        let folder = root.appendingPathComponent("folder.html", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        write([finderItem(missing.absoluteString, name: "missing.pdf"), finderItem(folder.absoluteString, name: "folder.html")])
        // Claimed so the import reports it; never a fallback to filename or icon insertion.
        XCTAssertEqual(
            ComposerDocumentFileAdmission.classify(pasteboard: pasteboard),
            .documents([missing.standardizedFileURL, folder.standardizedFileURL])
        )
    }

    func testMixedDocumentSelectionsAreRefusedWholeInEitherOrder() throws {
        let pdf = try file("document.pdf", "%PDF")
        let png = try file("image.png", "png")
        let text = try file("notes.txt", "text")
        let selections: [[String]] = [
            [pdf.absoluteString, png.absoluteString],
            [png.absoluteString, pdf.absoluteString],
            [pdf.absoluteString, text.absoluteString]
        ]
        for selection in selections {
            write(selection.map { finderItem($0, name: "x") })
            XCTAssertEqual(
                ComposerDocumentFileAdmission.classify(pasteboard: pasteboard),
                .rejected(ComposerDocumentFileAdmission.mixedSelectionMessage),
                "\(selection)"
            )
        }
        // An advertised file payload that cannot be read refuses the whole gesture with its own
        // message, beside a document or an image alike (never an icon, preview or filename).
        let unreadable: [[String]] = [
            [pdf.absoluteString, "not-a-file-url"],
            ["https://example.invalid/other.pdf", pdf.absoluteString],
            [png.absoluteString, "not-a-file-url"],
            ["not-a-file-url"]
        ]
        for selection in unreadable {
            write(selection.map { finderItem($0, name: "other.pdf", preview: .png) })
            XCTAssertEqual(
                ComposerDocumentFileAdmission.classify(pasteboard: pasteboard),
                .rejected(ComposerDocumentFileAdmission.unreadableReferenceMessage),
                "\(selection)"
            )
        }
    }

    func testUnresolvedFinderReferenceIsRefusedWholeWithoutAnyFallback() throws {
        let pdf = try file("Gone report.pdf", "%PDF")
        let png = try file("Gone picture.png", "png")
        let pdfReference = try fileReferenceString(pdf)
        let pngReference = try fileReferenceString(png)
        try FileManager.default.removeItem(at: pdf)
        try FileManager.default.removeItem(at: png)
        let deadPDF = try XCTUnwrap(URL(string: pdfReference))
        XCTAssertNil((deadPDF as NSURL).filePathURL, "Precondition: the Finder reference no longer resolves")

        let view = ImageAwareTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        view.isRichText = false
        view.string = "kept"
        view.enablesImagePasteHandling = true
        var imageCallbacks = 0
        view.imagePasteHandler = { _ in
            imageCallbacks += 1
            return true
        }
        var admissions: [ComposerDocumentFileAdmission] = []
        view.documentFileHandler = { admission in
            admissions.append(admission)
            return false
        }
        // A dead document reference, and a dead image reference (with a PNG preview), each beside
        // Finder's icon and filename text.
        for (reference, name) in [(pdfReference, "Gone report.pdf"), (pngReference, "Gone picture.png")] {
            write([finderItem(reference, name: name, preview: .png)])
            XCTAssertEqual(
                ComposerDocumentFileAdmission.classify(pasteboard: pasteboard),
                .rejected(ComposerDocumentFileAdmission.unreadableReferenceMessage)
            )
            view.paste(pasteboard)
            XCTAssertTrue(view.readSelection(from: pasteboard, type: .png))
            XCTAssertFalse(view.performDragOperation(PasteboardDraggingInfo(pasteboard: pasteboard)))
        }
        XCTAssertEqual(admissions.count, 6)
        XCTAssertTrue(admissions.allSatisfy { $0 == .rejected(ComposerDocumentFileAdmission.unreadableReferenceMessage) })
        XCTAssertEqual(imageCallbacks, 0, "No preview or icon substitute")
        XCTAssertEqual(view.string, "kept", "No filename inserted")
    }

    func testImagesTextAndCopiedHTMLAreNotDocuments() throws {
        let png = try file("image.png", "png")
        write([finderItem(png.absoluteString, name: "image.png")])
        XCTAssertEqual(ComposerDocumentFileAdmission.classify(pasteboard: pasteboard), .notDocuments)

        // Ordinary copied HTML (no explicit file) and a path-shaped string stay text.
        let item = NSPasteboardItem()
        item.setString("<p>Hello</p>", forType: .html)
        item.setString("/Users/someone/report.pdf", forType: .string)
        write([item])
        XCTAssertEqual(ComposerDocumentFileAdmission.classify(pasteboard: pasteboard), .notDocuments)

        pasteboard.clearContents()
        XCTAssertEqual(ComposerDocumentFileAdmission.classify(pasteboard: pasteboard), .notDocuments)
    }

    // MARK: Text view (paste, readSelection, drop)

    func testTextViewRoutesDocumentsBeforeImageAndNativeHandlingAndKeepsTypedText() throws {
        let pdf = try file("Quarterly.pdf", "%PDF")
        let reference = try fileReferenceString(pdf)
        write([finderItem(reference, name: "Quarterly.pdf", preview: .png)])
        let view = ImageAwareTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        view.isRichText = false
        view.string = "typed first"
        view.enablesImagePasteHandling = true
        var imageCallbacks = 0
        view.imagePasteHandler = { _ in
            imageCallbacks += 1
            return true
        }
        var admissions: [ComposerDocumentFileAdmission] = []
        var accepts = true
        view.documentFileHandler = { admission in
            admissions.append(admission)
            return accepts
        }
        let drag = PasteboardDraggingInfo(pasteboard: pasteboard)

        // Paste from a private board (never the general clipboard).
        view.paste(pasteboard)
        XCTAssertTrue(view.readSelection(from: pasteboard, type: .fileURL))
        XCTAssertTrue(view.readSelection(from: pasteboard, type: .png))
        XCTAssertEqual(view.draggingEntered(drag), .copy)
        XCTAssertEqual(view.draggingUpdated(drag), .copy)
        XCTAssertTrue(view.prepareForDragOperation(drag))
        XCTAssertTrue(view.performDragOperation(drag))
        XCTAssertEqual(admissions.count, 4)
        XCTAssertTrue(admissions.allSatisfy { $0 == .documents([pdf.standardizedFileURL]) || $0.isDocumentAt(pdf) })
        XCTAssertEqual(imageCallbacks, 0, "Never handed to the image path")
        XCTAssertEqual(view.string, "typed first", "No filename, path or icon inserted; typing kept")

        // A refused claim still suppresses native insertion and reports a failed drop.
        accepts = false
        XCTAssertFalse(view.performDragOperation(drag))
        view.paste(pasteboard)
        XCTAssertEqual(view.string, "typed first")
        XCTAssertEqual(imageCallbacks, 0)
    }

    func testTextViewWithoutDocumentHandlerKeepsExistingBehaviorAndImagesStillAttach() throws {
        let pdf = try file("document.pdf", "%PDF")
        let png = try file("image.png", "png")
        let view = ImageAwareTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        view.isRichText = false
        view.enablesImagePasteHandling = true
        write([finderItem(pdf.absoluteString, name: "document.pdf")])
        XCTAssertEqual(view.handleDocumentFiles(from: pasteboard), .unclaimed, "Opt-in only")
        XCTAssertFalse(view.canClaimDocumentFiles(from: pasteboard))

        // With the handler installed, image-only selections still take the image path.
        var imageCallbacks = 0
        view.imagePasteHandler = { _ in
            imageCallbacks += 1
            return true
        }
        view.documentFileHandler = { _ in
            XCTFail("Images are not documents")
            return true
        }
        write([finderItem(png.absoluteString, name: "image.png", preview: .png)])
        XCTAssertEqual(view.handleDocumentFiles(from: pasteboard), .unclaimed)
        XCTAssertTrue(view.readSelection(from: pasteboard, type: .png))
        XCTAssertEqual(imageCallbacks, 1)
    }

    // MARK: Surrounding SwiftUI drop

    func testDroppedProvidersLoadExplicitOriginalsInOrderAndMixedDropsAreRefused() async throws {
        let pdf = try file("Ünïcode report.pdf", "%PDF")
        let html = try file("page.html", "<html></html>")
        let adapter = AgentImageInputAdapter(temporaryRoot: root.appendingPathComponent("prepared"))
        let documentProviders = [pdf, html].map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }

        let references = await loadReferences(adapter, documentProviders)
        XCTAssertEqual(
            ComposerDocumentFileAdmission.classify(references: references),
            .documents([pdf.standardizedFileURL, html.standardizedFileURL])
        )

        // A raw image provider beside a document makes the whole drop a refusal.
        let imageProvider = NSItemProvider(item: Data([0x89, 0x50]) as NSData, typeIdentifier: UTType.png.identifier)
        let mixed = await loadReferences(adapter, documentProviders + [imageProvider])
        XCTAssertEqual(mixed.count, 3)
        XCTAssertEqual(mixed[2], .notFile)
        XCTAssertEqual(
            ComposerDocumentFileAdmission.classify(references: mixed),
            .rejected(ComposerDocumentFileAdmission.mixedSelectionMessage)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("prepared").path))
    }

    // MARK: Surrounding SwiftUI drop: reservation spans provider loading (production entry point)

    func testDelayedDroppedDocumentReservesItsComposerBeforeURLsLoad() async throws {
        let harness = try await makeHarness()
        let otherTabID = UUID()
        let otherSession = try await harness.viewModel.ensureSessionReady(tabID: otherTabID)
        let pdf = try file("Dropped ✨.pdf", "%PDF")
        harness.viewModel.storeDraftText(for: harness.tabID, "typed while dropping")
        harness.viewModel.syncComposerUIState(tabID: harness.tabID)
        let target = try XCTUnwrap(harness.viewModel.ui.composer.props.submitTarget)
        let held = HeldFileProvider()
        var fallbacks = 0

        let task = try XCTUnwrap(drop(harness, [held.provider]) { fallbacks += 1 })
        // Reserved synchronously at gesture start, before any URL has loaded.
        XCTAssertTrue(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
        XCTAssertEqual(
            harness.viewModel.ui.composer.props.documentImport,
            AgentComposerDocumentImportProps(importingFilenames: [], isImporting: true, failureMessage: nil)
        )
        guard case let .rejected(rejection) = harness.viewModel.claimComposerSubmitAttempt(attempt(target)) else {
            return XCTFail("Sent while the drop was resolving")
        }
        XCTAssertEqual(rejection, .documentImportInProgress)

        await fulfillment(of: [held.requested], timeout: 10)
        harness.viewModel.test_setCurrentTabIDOverride(otherTabID)
        harness.viewModel.syncComposerUIState()
        held.release(pdf)
        let outcome = await task.value

        guard case let .attached(attachments) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(attachments.map(\.originalFilename), ["Dropped ✨.pdf"])
        XCTAssertEqual(harness.session.pendingDocumentAttachments, attachments, "Lands on the tab it was dropped on")
        XCTAssertTrue(otherSession.pendingDocumentAttachments.isEmpty, "Never redirected to the current tab")
        XCTAssertEqual(fallbacks, 0)
        XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
        XCTAssertEqual(harness.viewModel.retrieveDraftText(for: harness.tabID), "typed while dropping")
    }

    func testChangesWhileDroppedURLsLoadDiscardTheDropWithoutCopyingOrRecreating() async throws {
        typealias Change = @MainActor (Harness) async throws -> Void
        let gone = AgentModeViewModel.documentImportDestinationGoneReason
        let changed = AgentModeViewModel.documentImportDestinationChangedMessage
        let scenarios: [(String, String, Change)] = [
            ("reset", gone, { $0.viewModel.cancelComposerDocumentImports(tabID: $0.tabID) }),
            // Closing a tab moves the window to another tab first (production order).
            ("closed", gone, { harness in
                harness.viewModel.test_setCurrentTabIDOverride(UUID())
                harness.viewModel.test_removeLiveSession(tabID: harness.tabID)
            }),
            ("replaced", changed, { harness in
                harness.viewModel.test_removeLiveSession(tabID: harness.tabID)
                _ = try await harness.viewModel.ensureSessionReady(tabID: harness.tabID)
            }),
            ("rebound", changed, { $0.session.beginPersistentBindingTransition() }),
            ("frozen", AgentModeViewModel.documentImportShutdownReason, {
                $0.viewModel.beginShutdownFreeze(requestID: UUID(), ownsRecoveryFreeze: false)
            })
        ]
        for (name, reason, change) in scenarios {
            let harness = try await makeHarness()
            let pdf = try file("\(name).pdf", "%PDF")
            let held = HeldFileProvider()
            var fallbacks = 0
            let task = try XCTUnwrap(drop(harness, [held.provider]) { fallbacks += 1 }, name)
            await fulfillment(of: [held.requested], timeout: 10)
            try await change(harness)
            held.release(pdf)
            let outcome = await task.value

            XCTAssertEqual(outcome, .discarded(reason: reason), name)
            XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty, name)
            // Read without materializing (`session(for:createIfNeeded:)` would re-create a bound tab).
            if let live = harness.viewModel.sessions[harness.tabID] {
                XCTAssertTrue(live.pendingDocumentAttachments.isEmpty, name)
            }
            if name == "closed" {
                XCTAssertNil(harness.viewModel.sessions[harness.tabID], "Closed tab not re-created")
            }
            XCTAssertEqual(fallbacks, 0, name)
            XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID), "No leaked reservation (\(name))")
            let originals = (try? FileManager.default.contentsOfDirectory(atPath: harness.store.originalsDirectoryURL.path)) ?? []
            XCTAssertEqual(originals, [], "No copy started for a stale drop (\(name))")
        }
    }

    func testDelayedNonDocumentDropsReleaseTheReservationAndKeepTheImagePath() async throws {
        let harness = try await makeHarness()
        let png = try file("picture.png", "png")
        let pdf = try file("paper.pdf", "%PDF")

        // Image-only file drop: released, then exactly the previous image path runs.
        let image = HeldFileProvider()
        var fallbacks = 0
        var task = try XCTUnwrap(drop(harness, [image.provider]) { fallbacks += 1 })
        await fulfillment(of: [image.requested], timeout: 10)
        image.release(png)
        var outcome = await task.value
        XCTAssertEqual(outcome, .notDocuments)
        XCTAssertEqual(fallbacks, 1)
        XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
        XCTAssertNil(harness.viewModel.ui.composer.props.documentImport)

        // A provider whose advertised file URL fails to load, though it also offers a PNG preview:
        // refused visibly, never the preview or an icon.
        let failing = HeldFileProvider(previewPNG: true)
        task = try XCTUnwrap(drop(harness, [failing.provider]) { fallbacks += 1 })
        await fulfillment(of: [failing.requested], timeout: 10)
        failing.release(nil)
        outcome = await task.value
        XCTAssertEqual(outcome, .failed(message: ComposerDocumentFileAdmission.unreadableReferenceMessage))
        XCTAssertEqual(fallbacks, 1, "The image path never sees an unreadable file")
        XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
        XCTAssertEqual(
            harness.viewModel.ui.composer.props.documentImport?.failureMessage,
            ComposerDocumentFileAdmission.unreadableReferenceMessage
        )

        // A document mixed with an image: refused whole and visibly, nothing attached, no fallback.
        let document = HeldFileProvider()
        let picture = HeldFileProvider()
        task = try XCTUnwrap(drop(harness, [document.provider, picture.provider]) { fallbacks += 1 })
        await fulfillment(of: [document.requested, picture.requested], timeout: 10)
        document.release(pdf)
        picture.release(png)
        outcome = await task.value
        XCTAssertEqual(outcome, .failed(message: ComposerDocumentFileAdmission.mixedSelectionMessage))
        XCTAssertEqual(fallbacks, 1)
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty)
        XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
        XCTAssertEqual(
            harness.viewModel.ui.composer.props.documentImport?.failureMessage,
            ComposerDocumentFileAdmission.mixedSelectionMessage
        )

        // Frozen at gesture start: nothing is reserved and the drop is refused.
        harness.viewModel.beginShutdownFreeze(requestID: UUID(), ownsRecoveryFreeze: false)
        XCTAssertNil(drop(harness, [HeldFileProvider().provider]) { fallbacks += 1 })
        XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
    }

    func testStaleImageDropIsDiscardedBeforeTheImagePath() async throws {
        typealias Change = @MainActor (Harness) async throws -> Void
        let gone = AgentModeViewModel.documentImportDestinationGoneReason
        let scenarios: [(String, String, Change)] = [
            ("reset", gone, { $0.viewModel.cancelComposerDocumentImports(tabID: $0.tabID) }),
            ("closed", gone, { harness in
                harness.viewModel.test_setCurrentTabIDOverride(UUID())
                harness.viewModel.test_removeLiveSession(tabID: harness.tabID)
            }),
            ("rebound", AgentModeViewModel.documentImportDestinationChangedMessage, {
                $0.session.beginPersistentBindingTransition()
            }),
            ("frozen", AgentModeViewModel.documentImportShutdownReason, {
                $0.viewModel.beginShutdownFreeze(requestID: UUID(), ownsRecoveryFreeze: false)
            })
        ]
        for (name, reason, change) in scenarios {
            let harness = try await makeHarness()
            let png = try file("\(name).png", "png")
            let held = HeldFileProvider()
            var fallbacks = 0
            let task = try XCTUnwrap(drop(harness, [held.provider]) { fallbacks += 1 }, name)
            await fulfillment(of: [held.requested], timeout: 10)
            try await change(harness)
            held.release(png)
            let outcome = await task.value

            XCTAssertEqual(outcome, .discarded(reason: reason), name)
            XCTAssertEqual(fallbacks, 0, "A changed composer never receives the late image (\(name))")
            XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID), name)
            // A changed session explains why the dropped files vanished; a reset, close or freeze
            // is the user's own action and stays quiet.
            XCTAssertEqual(
                harness.viewModel.composerDocumentImportProps(tabID: harness.tabID)?.failureMessage,
                name == "rebound" ? AgentModeViewModel.documentImportDestinationChangedMessage : nil,
                name
            )
            if name == "closed" {
                XCTAssertNil(harness.viewModel.sessions[harness.tabID], "Closed tab not re-created")
            }
        }
    }

    func testResolvedImageDropStillReachesTheRealImageAdapter() async throws {
        let harness = try await makeHarness()
        let png = try file("Real picture.png", "png")
        let adapter = AgentImageInputAdapter(temporaryRoot: root.appendingPathComponent("prepared"))
        let provider = NSItemProvider(item: png as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let prepared = expectation(description: "image path prepared the original")
        var images: [AgentImageInputAdapter.PreparedImage] = []
        let task = try XCTUnwrap(harness.viewModel.admitDroppedComposerFiles(
            tabID: harness.tabID,
            providers: [provider],
            adapter: adapter,
            onNotDocuments: {
                XCTAssertTrue(adapter.loadPreparedImages(from: [provider]) { result in
                    images = result
                    prepared.fulfill()
                })
            }
        ))
        let outcome = await task.value
        XCTAssertEqual(outcome, .notDocuments)
        await fulfillment(of: [prepared], timeout: 10)
        XCTAssertEqual(images, [AgentImageInputAdapter.PreparedImage(url: png.standardizedFileURL, isTemporary: false)])
        XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
        XCTAssertNil(harness.viewModel.ui.composer.props.documentImport)
    }

    func testCancelReleasesTheReservationAndKeepsTheDraft() async throws {
        let harness = try await makeHarness()
        let pdf = try file("cancelled.pdf", "%PDF")
        harness.viewModel.storeDraftText(for: harness.tabID, "keep me")
        harness.viewModel.syncComposerUIState(tabID: harness.tabID)
        let target = try XCTUnwrap(harness.viewModel.ui.composer.props.submitTarget)

        // Cancelled while copying.
        var task = try XCTUnwrap(harness.viewModel.attachDocumentFiles(tabID: harness.tabID, urls: [pdf]))
        harness.viewModel.cancelComposerDocumentImports(tabID: harness.tabID)
        XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
        XCTAssertNil(harness.viewModel.ui.composer.props.documentImport)
        var outcome = await task.value
        XCTAssertEqual(outcome, .discarded(reason: AgentModeViewModel.documentImportDestinationGoneReason))

        // Cancelled while a drop's URLs are still resolving.
        let held = HeldFileProvider()
        var fallbacks = 0
        task = try XCTUnwrap(drop(harness, [held.provider]) { fallbacks += 1 })
        await fulfillment(of: [held.requested], timeout: 10)
        harness.viewModel.cancelComposerDocumentImports(tabID: harness.tabID)
        XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
        held.release(pdf)
        outcome = await task.value
        XCTAssertEqual(outcome, .discarded(reason: AgentModeViewModel.documentImportDestinationGoneReason))
        XCTAssertEqual(fallbacks, 0)

        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty)
        XCTAssertEqual(harness.viewModel.retrieveDraftText(for: harness.tabID), "keep me")
        XCTAssertNil(harness.viewModel.ui.composer.props.documentImport?.failureMessage)
        let originals = (try? FileManager.default.contentsOfDirectory(atPath: harness.store.originalsDirectoryURL.path)) ?? []
        XCTAssertEqual(originals.count, 0, "A copy cancelled before it published leaves no managed original")
        guard case .claimed = harness.viewModel.claimComposerSubmitAttempt(attempt(target)) else {
            return XCTFail("Cancel must release the send gate")
        }
    }

    func testDocumentGesturesAreRefusedVisiblyWhileASendClaimIsActive() async throws {
        let harness = try await makeHarness()
        let pdf = try file("during send.pdf", "%PDF")
        harness.viewModel.storeDraftText(for: harness.tabID, "sending")
        harness.viewModel.syncComposerUIState(tabID: harness.tabID)
        let target = try XCTUnwrap(harness.viewModel.ui.composer.props.submitTarget)
        guard case let .claimed(claim) = harness.viewModel.claimComposerSubmitAttempt(attempt(target)) else {
            return XCTFail("Precondition: claim")
        }
        let inFlight = AgentModeViewModel.composerSubmitInFlightDocumentMessage

        // Paste or text-view drop: nothing reserved or copied.
        XCTAssertNil(harness.viewModel.attachDocumentFiles(tabID: harness.tabID, urls: [pdf]))
        XCTAssertFalse(harness.viewModel.admitComposerDocumentFiles(tabID: harness.tabID, admission: .documents([pdf])))
        XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
        XCTAssertEqual(harness.viewModel.ui.composer.props.documentImport?.failureMessage, inFlight)

        // A drop that began during the claim and resolved to a document: refused, no copy.
        let held = HeldFileProvider()
        let task = try XCTUnwrap(drop(harness, [held.provider]) {})
        await fulfillment(of: [held.requested], timeout: 10)
        held.release(pdf)
        let outcome = await task.value
        XCTAssertEqual(outcome, .failed(message: inFlight))
        XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty)
        let originals = (try? FileManager.default.contentsOfDirectory(atPath: harness.store.originalsDirectoryURL.path)) ?? []
        XCTAssertEqual(originals, [])

        // Once the send settles, the same gesture imports.
        _ = harness.viewModel.releaseComposerSubmitClaim(claim)
        let after = try XCTUnwrap(harness.viewModel.attachDocumentFiles(tabID: harness.tabID, urls: [pdf]))
        guard case let .attached(attachments) = await after.value else { return XCTFail("Import after the send") }
        XCTAssertEqual(harness.session.pendingDocumentAttachments, attachments)
    }

    func testComposerTextViewRegistersFileURLDrags() throws {
        let scroll = ImageAwareTextView.scrollableTextView()
        let view = try XCTUnwrap(scroll.documentView as? ImageAwareTextView)
        // The production composer's configuration (`ResizableTextField.makeNSView`).
        view.isEditable = true
        view.isRichText = false
        view.enablesImagePasteHandling = true
        // NSTextView alone offers only the legacy filenames and `public.url` drag types.
        XCTAssertFalse(view.acceptableDragTypes.contains(.fileURL))
        view.documentFileHandler = { _ in true }
        XCTAssertTrue(view.acceptableDragTypes.contains(.fileURL), "\(view.acceptableDragTypes)")
        // Hosted in a window like the composer, the registered types include it.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.contentView = nil }
        view.updateDragTypeRegistration()
        XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL), "\(view.registeredDraggedTypes)")
        view.documentFileHandler = nil
        XCTAssertFalse(view.acceptableDragTypes.contains(.fileURL), "Other text views keep the native set")
    }

    // MARK: Managed import

    func testImportCopiesOutsideOriginalsIntoManagedStoreAndAttachesRemovableReferences() async throws {
        let harness = try await makeHarness()
        let outside = root.appendingPathComponent("Outside Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let pdfBytes = Data([0x25, 0x50, 0x44, 0x46, 0x00, 0xFF, 0x80])
        let pdf = outside.appendingPathComponent("Résumé 📄.pdf")
        try pdfBytes.write(to: pdf)
        let html = try file("Outside Workspace/page.htm", "<html>é</html>")
        harness.viewModel.storeDraftText(for: harness.tabID, "keep my typing")

        let task = try XCTUnwrap(harness.viewModel.attachDocumentFiles(tabID: harness.tabID, urls: [pdf, html]))
        XCTAssertTrue(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
        let pending = try XCTUnwrap(harness.viewModel.ui.composer.props.documentImport)
        XCTAssertEqual(pending.importingFilenames, ["Résumé 📄.pdf", "page.htm"])
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty, "No chip before the managed copy exists")

        let outcome = await task.value
        guard case let .attached(attachments) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(attachments.map(\.originalFilename), ["Résumé 📄.pdf", "page.htm"])
        XCTAssertEqual(attachments.map(\.kind), [.pdf, .html])
        XCTAssertEqual(harness.session.pendingDocumentAttachments, attachments)
        XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
        XCTAssertEqual(harness.viewModel.retrieveDraftText(for: harness.tabID), "keep my typing")

        let props = harness.viewModel.ui.composer.props
        XCTAssertNil(props.documentImport)
        XCTAssertEqual(props.attachments.documentAttachments, attachments)
        XCTAssertTrue(props.attachments.hasAny)

        // The managed originals are byte-identical and survive the source moving away.
        let managedPDF = harness.store.managedFileURL(for: attachments[0])
        XCTAssertEqual(try Data(contentsOf: managedPDF), pdfBytes)
        try FileManager.default.removeItem(at: outside)
        XCTAssertEqual(harness.store.resolveManagedFile(for: attachments[0]), .success(managedPDF))

        // Removing a chip drops only the reference; the managed original stays.
        harness.viewModel.removePendingDocument(tabID: harness.tabID, attachmentID: attachments[0].id)
        XCTAssertEqual(harness.session.pendingDocumentAttachments.map(\.id), [attachments[1].id])
        XCTAssertEqual(harness.viewModel.ui.composer.props.attachments.documentAttachments.map(\.id), [attachments[1].id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedPDF.path))
    }

    func testImportFailuresAreVisibleAndAttachNothing() async throws {
        let harness = try await makeHarness()
        let good = try file("good.pdf", "%PDF")
        let unreadable = try file("locked.pdf", "%PDF")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        let folder = root.appendingPathComponent("folder.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let cases: [(URL, String)] = [
            (root.appendingPathComponent("missing.pdf"), "missing.pdf"),
            (unreadable, "locked.pdf"),
            (folder, "folder.pdf")
        ]
        for (bad, name) in cases {
            let task = try XCTUnwrap(harness.viewModel.attachDocumentFiles(tabID: harness.tabID, urls: [good, bad]))
            let outcome = await task.value
            guard case let .failed(message) = outcome else { return XCTFail("\(name): \(outcome)") }
            XCTAssertTrue(message.contains(name), message)
            XCTAssertTrue(message.hasSuffix("Nothing was attached."), message)
            XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty, "No misleading chip (\(name))")
            XCTAssertEqual(harness.viewModel.ui.composer.props.documentImport?.failureMessage, message)
            XCTAssertEqual(harness.viewModel.ui.composer.props.documentImport?.isImporting, false)
        }
        let originals = (try? FileManager.default.contentsOfDirectory(atPath: harness.store.originalsDirectoryURL.path)) ?? []
        XCTAssertEqual(originals, [], "An atomic batch publishes nothing on failure")

        harness.viewModel.dismissComposerDocumentImportFailure(tabID: harness.tabID)
        XCTAssertNil(harness.viewModel.ui.composer.props.documentImport)
    }

    func testRejectedMixedAdmissionShowsMessageAndStartsNothing() async throws {
        let harness = try await makeHarness()
        let started = harness.viewModel.admitComposerDocumentFiles(
            tabID: harness.tabID,
            admission: .rejected(ComposerDocumentFileAdmission.mixedSelectionMessage)
        )
        XCTAssertFalse(started)
        XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
        XCTAssertEqual(
            harness.viewModel.ui.composer.props.documentImport?.failureMessage,
            ComposerDocumentFileAdmission.mixedSelectionMessage
        )
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty)
        XCTAssertFalse(harness.viewModel.admitComposerDocumentFiles(tabID: harness.tabID, admission: .notDocuments))
    }

    func testImportLandsOnItsOwnTabAfterSwitchingTabs() async throws {
        let harness = try await makeHarness()
        let otherTabID = UUID()
        let otherSession = try await harness.viewModel.ensureSessionReady(tabID: otherTabID)
        let pdf = try file("switch.pdf", "%PDF")

        let task = try XCTUnwrap(harness.viewModel.attachDocumentFiles(tabID: harness.tabID, urls: [pdf]))
        harness.viewModel.test_setCurrentTabIDOverride(otherTabID)
        harness.viewModel.syncComposerUIState()
        XCTAssertNil(harness.viewModel.ui.composer.props.documentImport, "Another tab never shows this import")

        let outcome = await task.value
        guard case let .attached(attachments) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(harness.session.pendingDocumentAttachments, attachments)
        XCTAssertTrue(otherSession.pendingDocumentAttachments.isEmpty, "Never attached to the switched-to tab")
        XCTAssertTrue(harness.viewModel.ui.composer.props.attachments.documentAttachments.isEmpty)
    }

    func testImportIsDiscardedWhenItsComposerClosesResetsOrIsReplaced() async throws {
        let harness = try await makeHarness()
        let pdf = try file("fenced.pdf", "%PDF")

        // Reset of the tab's composer.
        var task = try XCTUnwrap(harness.viewModel.attachDocumentFiles(tabID: harness.tabID, urls: [pdf]))
        harness.viewModel.cancelComposerDocumentImports(tabID: harness.tabID)
        var outcome = await task.value
        XCTAssertEqual(outcome, .discarded(reason: AgentModeViewModel.documentImportDestinationGoneReason))
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty)

        // Tab closed (its session removed) while copying.
        task = try XCTUnwrap(harness.viewModel.attachDocumentFiles(tabID: harness.tabID, urls: [pdf]))
        harness.viewModel.test_removeLiveSession(tabID: harness.tabID)
        outcome = await task.value
        XCTAssertEqual(outcome, .discarded(reason: AgentModeViewModel.documentImportDestinationGoneReason))
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty)

        // A different session took over the same tab while copying (swapped synchronously, so the
        // copy cannot settle in between).
        let replacement = try await harness.viewModel.ensureSessionReady(tabID: harness.tabID)
        XCTAssertFalse(replacement === harness.session)
        harness.viewModel.test_installLiveSession(harness.session)
        task = try XCTUnwrap(harness.viewModel.attachDocumentFiles(tabID: harness.tabID, urls: [pdf]))
        harness.viewModel.test_installLiveSession(replacement)
        outcome = await task.value
        XCTAssertEqual(outcome, .discarded(reason: AgentModeViewModel.documentImportDestinationChangedMessage))
        XCTAssertTrue(replacement.pendingDocumentAttachments.isEmpty)
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty)
        XCTAssertEqual(
            harness.viewModel.ui.composer.props.documentImport?.failureMessage,
            AgentModeViewModel.documentImportDestinationChangedMessage
        )

        // The same session object moved to a different persisted binding while copying.
        harness.viewModel.test_installLiveSession(harness.session)
        harness.viewModel.syncComposerUIState(tabID: harness.tabID)
        task = try XCTUnwrap(harness.viewModel.attachDocumentFiles(tabID: harness.tabID, urls: [pdf]))
        harness.session.beginPersistentBindingTransition()
        outcome = await task.value
        XCTAssertEqual(outcome, .discarded(reason: AgentModeViewModel.documentImportDestinationChangedMessage))
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty)
    }

    func testShutdownFreezeRefusesNewImportsAndDiscardsInFlightOnes() async throws {
        let harness = try await makeHarness()
        let pdf = try file("closing.pdf", "%PDF")
        let task = try XCTUnwrap(harness.viewModel.attachDocumentFiles(tabID: harness.tabID, urls: [pdf]))
        harness.viewModel.beginShutdownFreeze(requestID: UUID(), ownsRecoveryFreeze: false)

        let outcome = await task.value
        XCTAssertEqual(outcome, .discarded(reason: AgentModeViewModel.documentImportShutdownReason))
        XCTAssertTrue(harness.session.pendingDocumentAttachments.isEmpty, "A freezing composer is never changed")
        XCTAssertNil(harness.viewModel.attachDocumentFiles(tabID: harness.tabID, urls: [pdf]))
        XCTAssertFalse(harness.viewModel.admitComposerDocumentFiles(tabID: harness.tabID, admission: .documents([pdf])))
        XCTAssertFalse(harness.viewModel.isImportingComposerDocuments(tabID: harness.tabID))
    }

    func testSubmitClaimIsRefusedWhileImportingAndAllowedAfterward() async throws {
        let harness = try await makeHarness()
        let pdf = try file("gate.pdf", "%PDF")
        harness.viewModel.syncComposerUIState(tabID: harness.tabID)
        let target = try XCTUnwrap(harness.viewModel.ui.composer.props.submitTarget)
        let task = try XCTUnwrap(harness.viewModel.attachDocumentFiles(tabID: harness.tabID, urls: [pdf]))

        let refused = harness.viewModel.claimComposerSubmitAttempt(attempt(target))
        guard case let .rejected(rejection) = refused else { return XCTFail("Claimed while importing") }
        XCTAssertEqual(rejection, .documentImportInProgress)
        XCTAssertEqual(harness.viewModel.ui.composer.props.documentImport?.isImporting, true)
        XCTAssertNil(harness.session.activeComposerSubmitAttempt)

        _ = await task.value
        harness.viewModel.syncComposerUIState(tabID: harness.tabID)
        let settledTarget = try XCTUnwrap(harness.viewModel.ui.composer.props.submitTarget)
        guard case .claimed = harness.viewModel.claimComposerSubmitAttempt(attempt(settledTarget)) else {
            return XCTFail("Settled import still blocks the claim")
        }
    }

    // MARK: Projection

    func testStripSnapshotAndScheduledPropsCarryDocuments() {
        let doc = AgentDocumentAttachment(kind: .pdf, originalFilename: "  ", byteCount: 3)
        let html = AgentDocumentAttachment(kind: .html, originalFilename: "Page ✨.html", byteCount: 9)
        let withDocs = AgentAttachmentStripSnapshot(imageAttachments: [], taggedFileAttachments: [], documentAttachments: [doc])
        let without = AgentAttachmentStripSnapshot(imageAttachments: [], taggedFileAttachments: [], documentAttachments: [])
        XCTAssertTrue(withDocs.hasDocuments)
        XCTAssertTrue(withDocs.hasAny)
        XCTAssertFalse(without.hasAny)
        XCTAssertNotEqual(withDocs, without, "Document changes re-render the strip")
        XCTAssertEqual(AgentAttachmentsStrip.documentChipTitle(doc), "PDF document")
        XCTAssertEqual(AgentAttachmentsStrip.documentChipTitle(html), "Page ✨.html")
        XCTAssertEqual(
            AgentAttachmentStripLayout.reservedHeight(hasImages: false, hasTaggedFiles: false, hasDocuments: true),
            AgentAttachmentStripLayout.fileOnlyStripHeight + AgentAttachmentStripLayout.composerVerticalSpacingWhenPresent
        )
        XCTAssertEqual(AgentComposerDocumentImportPresentation.importingText([]), "Checking dropped files…")
        XCTAssertEqual(AgentComposerDocumentImportPresentation.importingText(["a.pdf"]), "Importing a.pdf…")
        XCTAssertEqual(AgentComposerDocumentImportPresentation.importingText(["a.pdf", "b.html"]), "Importing 2 documents…")

        let now = Date()
        let record = AgentScheduledSendPersist(
            id: UUID(),
            createdAt: now,
            updatedAt: now,
            notBefore: now.addingTimeInterval(600),
            state: .scheduled,
            confirmationReason: nil,
            rawText: "",
            attachments: [],
            taggedFileAttachments: [],
            documentAttachments: [doc, html],
            workflow: nil,
            interviewFirst: false,
            isNewSessionStart: false,
            runAlongsideOtherSessions: false,
            firstEligibleAt: nil,
            attempt: nil,
            lastFailureMessage: nil
        )
        let props = AgentScheduledSendProps(tabID: UUID(), scheduledSend: record)
        XCTAssertEqual(props.attachments.documentAttachments, [doc, html])
        XCTAssertTrue(props.attachments.hasAny, "A document-only schedule stays editable and saveable")
    }

    // MARK: Helpers

    private struct Harness {
        let viewModel: AgentModeViewModel
        let tabID: UUID
        let session: AgentTabSession
        let store: AgentDocumentAttachmentStore
    }

    private func makeHarness() async throws -> Harness {
        let tabID = UUID()
        let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let viewModel = AgentModeViewModel(
            testWindowID: 9302,
            testWorkspacePath: workspace.path,
            codexControllerFactory: { _, _, _, _, _, _ in DocumentAdmissionNoopCodexController() }
        )
        let store = AgentDocumentAttachmentStore(rootURL: root.appendingPathComponent("Managed", isDirectory: true))
        viewModel.documentAttachmentStore = store
        viewModel.codexShellToolPreference = { true }
        viewModel.test_setAvailableAgents([.claudeCode, .codexExec])
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        session.selectedAgent = .claudeCode
        viewModel.syncComposerUIState(tabID: tabID)
        return Harness(viewModel: viewModel, tabID: tabID, session: session, store: store)
    }

    private func drop(
        _ harness: Harness,
        _ providers: [NSItemProvider],
        onNotDocuments: @escaping @MainActor () -> Void
    ) -> Task<AgentComposerDocumentImportOutcome, Never>? {
        harness.viewModel.admitDroppedComposerFiles(
            tabID: harness.tabID,
            providers: providers,
            adapter: AgentImageInputAdapter(temporaryRoot: root.appendingPathComponent("prepared")),
            onNotDocuments: onNotDocuments
        )
    }

    private func attempt(_ target: AgentComposerSubmitTarget) -> AgentComposerSubmitAttempt {
        AgentComposerSubmitAttempt(id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: "")
    }

    private func file(_ relativePath: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func fileReferenceString(_ url: URL) throws -> String {
        let reference = try XCTUnwrap(CFURLCreateFileReferenceURL(nil, url as CFURL, nil)).takeRetainedValue()
        XCTAssertTrue(CFURLIsFileReferenceURL(reference))
        let string = CFURLGetString(reference) as String
        XCTAssertTrue(string.hasPrefix("file:///.file/id="), string)
        return string
    }

    private func finderItem(
        _ reference: String,
        name: String,
        preview: NSPasteboard.PasteboardType = documentAdmissionIconType
    ) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(reference, forType: .fileURL)
        item.setData(Data([0x01, 0x02, 0x03]), forType: preview)
        item.setString(name, forType: .string)
        return item
    }

    private func write(_ items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))
    }

    private func loadReferences(
        _ adapter: AgentImageInputAdapter,
        _ providers: [NSItemProvider]
    ) async -> [ComposerFileReference] {
        await withCheckedContinuation { continuation in
            adapter.loadDroppedFileReferences(from: providers) { continuation.resume(returning: $0) }
        }
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
}

private let documentAdmissionIconType = NSPasteboard.PasteboardType("com.apple.icns")

/// A real `NSItemProvider` advertising `public.file-url` whose load is held until the test releases
/// it, so composer changes can happen while the drop's original URLs are still loading.
private final class HeldFileProvider: @unchecked Sendable {
    let provider = NSItemProvider()
    let requested = XCTestExpectation(description: "file URL load requested")
    private let lock = NSLock()
    private var completion: NSItemProvider.CompletionHandler?

    /// `previewPNG` also offers a PNG data representation (an icon or preview a failed file load
    /// must never fall back to).
    init(previewPNG: Bool = false) {
        provider.registerItem(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] completion, _, _ in
            guard let self else { return }
            lock.withLock { self.completion = completion }
            requested.fulfill()
        }
        if previewPNG {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                completion(Data([0x89, 0x50, 0x4E, 0x47]), nil)
                return nil
            }
        }
    }

    /// Delivers `url` (or a load error for `nil`).
    func release(_ url: URL?) {
        let completion = lock.withLock { () -> NSItemProvider.CompletionHandler? in
            defer { self.completion = nil }
            return self.completion
        }
        if let url {
            completion?(url as NSURL, nil)
        } else {
            completion?(nil, NSError(domain: "AgentComposerDocumentAdmissionTests", code: 1))
        }
    }
}

private extension ComposerDocumentFileAdmission {
    /// Reference-resolved comparison (a Finder reference resolves through symlinked temp roots).
    func isDocumentAt(_ url: URL) -> Bool {
        guard case let .documents(urls) = self else { return false }
        return urls.map { $0.resolvingSymlinksInPath() } == [url.resolvingSymlinksInPath()]
    }
}

private final class DocumentAdmissionNoopCodexController: CodexSessionControlling {
    private let eventStream: AsyncStream<CodexNativeSessionController.Event>
    private let eventContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation

    init() {
        var continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation!
        eventContinuation.finish()
    }

    deinit {
        eventContinuation.finish()
    }

    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        eventStream
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "noop",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func startUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        model _: String?,
        reasoningEffort _: String?,
        serviceTier _: String?
    ) async throws -> CodexTurnStartReceipt {
        CodexTurnStartReceipt(provisionalSubmissionID: "noop")
    }

    func steerUserTurn(
        text _: String,
        images _: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
