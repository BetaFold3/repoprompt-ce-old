// ResizableTextField.swift
import AppKit
import RepoPromptAgentCore
import RepoPromptUI
import RepoPromptWorkspace
import SwiftUI
import UniformTypeIdentifiers
#if DEBUG
    import OSLog
#endif

enum ImagePasteboardTypes {
    enum FilePayload: Equatable {
        case none
        case imageFiles([URL])
        case deferToNative
    }

    private static let fallbackImageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jfif", "jpe", "gif", "bmp", "webp", "avif", "heic", "heif", "tif", "tiff", "svg", "ico"
    ]

    /// Every explicit `public.file-url` reference on the board (one per advertised file item, with a
    /// board-level fallback), decoded but not validated: `nil` entries are undecodable references.
    /// Empty when the board has no explicit file payload. Never reads plain text or generic URLs.
    static func explicitFileReferences(in pasteboard: NSPasteboard) -> [URL?] {
        let fileItems = (pasteboard.pasteboardItems ?? []).filter { $0.types.contains(.fileURL) }
        var references = fileItems.map { item in
            fileURL(string: item.string(forType: .fileURL), data: item.data(forType: .fileURL))
        }
        if references.isEmpty, pasteboard.types?.contains(.fileURL) == true {
            references.append(fileURL(
                string: pasteboard.string(forType: .fileURL),
                data: pasteboard.data(forType: .fileURL)
            ))
        }
        return references
    }

    /// Explicit file payloads outrank their icons/previews. Never partially consume a file selection.
    static func filePayload(in pasteboard: NSPasteboard, fileManager: FileManager = .default) -> FilePayload {
        let references = explicitFileReferences(in: pasteboard)
        guard !references.isEmpty else { return .none }

        var urls: [URL] = []
        var seenPaths: Set<String> = []
        for reference in references {
            guard let reference, reference.isFileURL else { return .deferToNative }
            let url = reference.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isReadableFile(atPath: url.path),
                  isImageFileURL(url)
            else {
                return .deferToNative
            }
            if seenPaths.insert(url.path).inserted {
                urls.append(url)
            }
        }
        return .imageFiles(urls)
    }

    private static func fileURL(string: String?, data: Data?) -> URL? {
        if let string, let url = URL(string: string) {
            return url
        }
        return data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
    }

    static func isImageFileURL(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .image)
        {
            return true
        }
        let fileExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !fileExtension.isEmpty else { return false }
        if let type = UTType(filenameExtension: fileExtension), type.conforms(to: .image) {
            return true
        }
        return fallbackImageFileExtensions.contains(fileExtension)
    }

    static let legacyApplePNG = NSPasteboard.PasteboardType("Apple PNG pasteboard type")
    static let legacyNeXTTIFF = NSPasteboard.PasteboardType("NeXT TIFF v4.0 pasteboard type")

    static let explicitImageReadableTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType(UTType.image.identifier),
        NSPasteboard.PasteboardType(UTType.png.identifier),
        NSPasteboard.PasteboardType(UTType.tiff.identifier),
        legacyApplePNG,
        legacyNeXTTIFF
    ]

    static func canonicalImageType(forIdentifier identifier: String) -> UTType? {
        if let type = UTType(identifier), type.conforms(to: .image) {
            return type
        }
        switch identifier {
        case NSPasteboard.PasteboardType.png.rawValue,
             legacyApplePNG.rawValue:
            return .png
        case NSPasteboard.PasteboardType.tiff.rawValue,
             legacyNeXTTIFF.rawValue:
            return .tiff
        default:
            return nil
        }
    }

    static func isImageLike(_ type: NSPasteboard.PasteboardType) -> Bool {
        if let utType = UTType(type.rawValue), utType.conforms(to: .image) {
            return true
        }
        return type == legacyApplePNG || type == legacyNeXTTIFF
    }
}

/// One item of a composer file gesture, as far as its explicit original file reference goes.
enum ComposerFileReference: Equatable {
    /// A decoded explicit `public.file-url` payload (a path or Finder file-reference URL; resolved
    /// during classification).
    case url(URL)
    /// An advertised explicit `public.file-url` payload that could not be decoded or loaded.
    case unreadable
    /// A dropped item with no explicit file URL at all (raw image data, text, …).
    case notFile
}

/// Admission of explicit PDF/HTML document files (Finder copy or drag) for an opt-in composer.
///
/// Classification uses only the explicit original file references (never icons, previews, text,
/// suggested names or generic URLs) and the document kind of each resolved original's filename.
/// - A gesture without any explicit file payload is `.notDocuments` (existing handling).
/// - An advertised explicit file payload that cannot be decoded, loaded or resolved (for example a
///   Finder file reference whose file was deleted or whose volume was ejected) refuses the whole
///   gesture visibly: never an icon, preview, image or filename substitute.
/// - A recognized document is claimed even when it is missing or unreadable, so its import fails
///   visibly. A selection that mixes documents with anything else is refused whole.
/// - Successfully resolved non-document selections (for example PNG/JPEG originals) stay
///   `.notDocuments`, keeping the existing image path.
enum ComposerDocumentFileAdmission: Equatable {
    /// No explicit document file: existing image and native handling continue unchanged.
    case notDocuments
    /// Every explicit file is a PDF/HTML original (deduplicated, in selection order).
    case documents([URL])
    /// A refused gesture (mixed selection or unreadable file reference); nothing is attached.
    case rejected(String)

    static let mixedSelectionMessage =
        "PDF and HTML documents can't be attached together with images or other files. Nothing was attached; attach the documents on their own."
    static let unreadableReferenceMessage =
        "A pasted or dropped file could not be found or read (it may have been moved, deleted or ejected). Nothing was attached."

    var isClaimed: Bool {
        self != .notDocuments
    }

    static func classify(pasteboard: NSPasteboard) -> Self {
        classify(references: ImagePasteboardTypes.explicitFileReferences(in: pasteboard).map { reference in
            reference.map(ComposerFileReference.url) ?? .unreadable
        })
    }

    static func classify(references: [ComposerFileReference]) -> Self {
        // No explicit file payload at all: not this admission's gesture.
        guard references.contains(where: { $0 != .notFile }) else { return .notDocuments }
        var documents: [URL] = []
        var seenPaths: Set<String> = []
        var hasOtherItem = false
        var hasUnreadableReference = false
        for reference in references {
            switch reference {
            case .notFile:
                hasOtherItem = true
            case .unreadable:
                hasUnreadableReference = true
            case let .url(reference):
                // Finder writes file-reference URLs (`file:///.file/id=…`): resolve to the original
                // path. A path URL resolves to itself; an unresolvable reference has no path.
                guard reference.isFileURL, let resolved = (reference as NSURL).filePathURL else {
                    hasUnreadableReference = true
                    continue
                }
                let url = resolved.standardizedFileURL
                guard AgentDocumentKind(pathExtension: url.pathExtension) != nil else {
                    hasOtherItem = true
                    continue
                }
                if seenPaths.insert(url.path).inserted {
                    documents.append(url)
                }
            }
        }
        guard !hasUnreadableReference else { return .rejected(unreadableReferenceMessage) }
        guard !documents.isEmpty else { return .notDocuments }
        guard !hasOtherItem else { return .rejected(mixedSelectionMessage) }
        return .documents(documents)
    }
}

final class ImageAwareTextView: NSTextView {
    var imagePasteHandler: ((NSPasteboard) -> Bool)?
    var enablesImagePasteHandling = false
    /// Opt-in explicit PDF/HTML file handler, consulted before image and native handling. Returns
    /// whether the claimed admission was accepted (an import started); a refusal still suppresses
    /// native filename/icon insertion. `nil` keeps the text view's previous behavior.
    var documentFileHandler: ((ComposerDocumentFileAdmission) -> Bool)? {
        didSet {
            // Re-register only when opting in or out (the representable re-assigns every update).
            if (oldValue == nil) != (documentFileHandler == nil) {
                updateDragTypeRegistration()
            }
        }
    }

    /// NSTextView itself registers only the legacy filenames and `public.url` drag types; an
    /// opted-in composer also registers the explicit `public.file-url` its document admission reads.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        var types = super.acceptableDragTypes
        if documentFileHandler != nil, !types.contains(.fileURL) {
            types.append(.fileURL)
        }
        return types
    }

    enum DocumentFileHandling: Equatable {
        case unclaimed
        case accepted
        case refused
    }

    func canClaimDocumentFiles(from pasteboard: NSPasteboard) -> Bool {
        documentFileHandler != nil && ComposerDocumentFileAdmission.classify(pasteboard: pasteboard).isClaimed
    }

    func handleDocumentFiles(from pasteboard: NSPasteboard) -> DocumentFileHandling {
        guard let documentFileHandler else { return .unclaimed }
        let admission = ComposerDocumentFileAdmission.classify(pasteboard: pasteboard)
        guard admission.isClaimed else { return .unclaimed }
        return documentFileHandler(admission) ? .accepted : .refused
    }

    var onDidMoveToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDidMoveToWindow?()
    }

    #if DEBUG || EDIT_FLOW_PERF
        /// Diagnostics-only notification of an accepted responder change from any route
        /// (token attempt, SwiftUI focus binding, click). It never requests focus.
        var onDidBecomeFirstResponderForInteractionProbe: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted {
                onDidBecomeFirstResponderForInteractionProbe?()
            }
            return accepted
        }
    #endif

    #if DEBUG
        /// Diagnostics-only notification of an accepted resignation. It never changes focus.
        var onDidResignFirstResponderForFocusTrace: (() -> Void)?

        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted {
                onDidResignFirstResponderForFocusTrace?()
            }
            return accepted
        }
    #endif

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        guard enablesImagePasteHandling else {
            return types
        }
        for type in ImagePasteboardTypes.explicitImageReadableTypes where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    override func paste(_ sender: Any?) {
        let pasteboard = sender as? NSPasteboard ?? NSPasteboard.general
        if handleDocumentFiles(from: pasteboard) != .unclaimed {
            return
        }
        if enablesImagePasteHandling,
           ImagePasteboardTypes.filePayload(in: pasteboard) != .deferToNative,
           imagePasteHandler?(pasteboard) == true
        {
            return
        }
        super.paste(sender)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // A claimed document selection (accepted or refused) never falls back to another type.
        if handleDocumentFiles(from: pboard) != .unclaimed {
            return true
        }
        if enablesImagePasteHandling,
           isImageLikePasteboardType(type),
           ImagePasteboardTypes.filePayload(in: pboard) != .deferToNative,
           imagePasteHandler?(pboard) == true
        {
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if canClaimDocumentFiles(from: sender.draggingPasteboard) {
            return .copy
        }
        let superOperation = super.draggingEntered(sender)
        if superOperation != [] {
            return superOperation
        }
        guard enablesImagePasteHandling else {
            return []
        }
        return canHandleImageDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if canClaimDocumentFiles(from: sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if canClaimDocumentFiles(from: sender.draggingPasteboard) {
            return true
        }
        guard enablesImagePasteHandling else {
            return super.prepareForDragOperation(sender)
        }
        if canHandleImageDrop(from: sender.draggingPasteboard) {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Claimed documents never reach native insertion: a refusal reports a failed drop.
        switch handleDocumentFiles(from: sender.draggingPasteboard) {
        case .accepted:
            return true
        case .refused:
            return false
        case .unclaimed:
            break
        }
        guard enablesImagePasteHandling else {
            return super.performDragOperation(sender)
        }
        let pasteboard = sender.draggingPasteboard
        guard canHandleImageDrop(from: pasteboard) else {
            return super.performDragOperation(sender)
        }
        guard imagePasteHandler?(pasteboard) == true else {
            return super.performDragOperation(sender)
        }
        // Only an accepted image drop suppresses native handling.
        return true
    }

    func canHandleImageDrop(from pasteboard: NSPasteboard) -> Bool {
        switch ImagePasteboardTypes.filePayload(in: pasteboard) {
        case .deferToNative:
            return false
        case .imageFiles:
            return true
        case .none:
            break
        }
        if let types = pasteboard.types {
            for type in types where isImageLikePasteboardType(type) {
                return true
            }
        }

        if let urlObjects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urlObjects where url.isFileURL {
                if ImagePasteboardTypes.isImageFileURL(url) {
                    return true
                }
            }
        }

        return false
    }

    private func isImageLikePasteboardType(_ type: NSPasteboard.PasteboardType) -> Bool {
        ImagePasteboardTypes.isImageLike(type)
    }
}

struct SnippetPaletteScope: Equatable {
    let windowID: Int
    let tabID: UUID

    static func matches(
        _ scope: SnippetPaletteScope?,
        requestWindowID: Int?,
        requestTabID: UUID?
    ) -> Bool {
        guard let scope, let requestWindowID, let requestTabID else { return false }
        return scope.windowID == requestWindowID && scope.tabID == requestTabID
    }
}

enum ComposerFocusTokenPolicy {
    enum Action: Equatable {
        case clearPending
        case none
        case waitForWindow
        case drop
        case attempt
    }

    struct State: Equatable {
        var lastAppliedToken: UUID?
        var pendingToken: UUID?
    }

    static func seededState(for token: UUID?) -> State {
        State(lastAppliedToken: token, pendingToken: nil)
    }

    static func action(
        token: UUID?,
        lastAppliedToken: UUID?,
        hasWindow: Bool,
        hasAttachedSheet: Bool
    ) -> Action {
        guard let token else { return .clearPending }
        guard token != lastAppliedToken else { return .none }
        guard hasWindow else { return .waitForWindow }
        guard !hasAttachedSheet else { return .drop }
        return .attempt
    }

    static func state(
        after action: Action,
        token: UUID?,
        currentState: State
    ) -> State {
        switch action {
        case .clearPending:
            State(lastAppliedToken: currentState.lastAppliedToken, pendingToken: nil)
        case .none:
            currentState
        case .waitForWindow:
            State(lastAppliedToken: currentState.lastAppliedToken, pendingToken: token)
        case .drop, .attempt:
            State(lastAppliedToken: token, pendingToken: nil)
        }
    }

    static func shouldSchedule(
        token: UUID?,
        lastAppliedToken: UUID?,
        pendingToken: UUID?
    ) -> Bool {
        guard pendingToken == nil else { return true }
        guard let token else { return false }
        return token != lastAppliedToken
    }

    static func scheduledTokenIsCurrent(_ scheduledToken: UUID?, currentToken: UUID?) -> Bool {
        scheduledToken == currentToken
    }
}

struct ResizableTextFieldFeatures {
    var enableFileTagOverlay: Bool = false
    var fileTagStore: WorkspaceFileContextStore?
    var fileTagSearchService: WorkspaceSearchService?
    var fileTagSelectionCoordinator: WorkspaceSelectionCoordinator?
    var fileTagLookupContextIdentity: AnyHashable?
    var fileTagLookupContextProvider: (() async -> WorkspaceLookupContext)?
    var fileTagPickerConfiguration: FileMentionPickerConfiguration = .compact
    var onFileTagCommitted: ((MentionSuggestion) -> Void)?
    var enableSlashSkillOverlay: Bool = false
    var slashSkillSuggestionsProvider: ((String) async -> [MentionSuggestion])?
    var enableSnippetPalette: Bool = false
    var snippetPaletteItemsProvider: (() -> [SnippetPaletteItem])?
    var snippetPaletteScope: SnippetPaletteScope?
    var composerFocusToken: UUID?
    /// Queried live at the text view's edit entry (typing, paste, drop, snippet insertion): `false`
    /// refuses the change before the text view accepts it (e.g. the shutdown edit freeze).
    var acceptsEdits: (() -> Bool)?

    static let plain = ResizableTextFieldFeatures()

    static func agentInputBar(
        fileTagStore: WorkspaceFileContextStore?,
        fileTagSearchService: WorkspaceSearchService?,
        fileTagSelectionCoordinator: WorkspaceSelectionCoordinator?,
        fileTagLookupContextIdentity: AnyHashable? = nil,
        fileTagLookupContextProvider: (() async -> WorkspaceLookupContext)? = nil,
        fileMentionPickerConfiguration: FileMentionPickerConfiguration = .compact,
        onFileTagCommitted: ((MentionSuggestion) -> Void)?,
        slashSkillSuggestionsProvider: ((String) async -> [MentionSuggestion])?,
        snippetPaletteItemsProvider: (() -> [SnippetPaletteItem])? = nil,
        snippetPaletteScope: SnippetPaletteScope? = nil,
        composerFocusToken: UUID? = nil,
        acceptsEdits: (() -> Bool)? = nil
    ) -> ResizableTextFieldFeatures {
        ResizableTextFieldFeatures(
            enableFileTagOverlay: true,
            fileTagStore: fileTagStore,
            fileTagSearchService: fileTagSearchService,
            fileTagSelectionCoordinator: fileTagSelectionCoordinator,
            fileTagLookupContextIdentity: fileTagLookupContextIdentity,
            fileTagLookupContextProvider: fileTagLookupContextProvider,
            fileTagPickerConfiguration: fileMentionPickerConfiguration,
            onFileTagCommitted: onFileTagCommitted,
            enableSlashSkillOverlay: true,
            slashSkillSuggestionsProvider: slashSkillSuggestionsProvider,
            enableSnippetPalette: snippetPaletteItemsProvider != nil,
            snippetPaletteItemsProvider: snippetPaletteItemsProvider,
            snippetPaletteScope: snippetPaletteScope,
            composerFocusToken: composerFocusToken,
            acceptsEdits: acceptsEdits
        )
    }
}

struct ResizableTextField: View {
    @Binding var text: String
    let placeholder: String
    var onReturn: () -> Void
    @Binding var resetTrigger: Bool
    var onImagePaste: ((NSPasteboard) -> Bool)?
    /// Opt-in explicit PDF/HTML file handling (see `ImageAwareTextView.documentFileHandler`).
    var onDocumentFiles: ((ComposerDocumentFileAdmission) -> Bool)?
    var features: ResizableTextFieldFeatures = .plain

    /// Callback for height changes to coordinate with parent
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// Define height presets at the Normal text-size preset.
    static let heightPresets: [CGFloat] = [36, 52, 68, 84, 100, 116, 132, 148, 164]
    /// Maximum height allowed is the last preset at Normal text size.
    static let maxHeight = heightPresets.last ?? 164

    static func heightPresets(for preset: FontScalePreset) -> [CGFloat] {
        heightPresets.map { preset.scaledMetric($0) }
    }

    static func maxHeight(for preset: FontScalePreset) -> CGFloat {
        heightPresets(for: preset).last ?? preset.scaledMetric(maxHeight)
    }

    static func height(forPresetIndex index: Int, preset: FontScalePreset) -> CGFloat {
        let scaledPresets = heightPresets(for: preset)
        guard !scaledPresets.isEmpty else { return preset.scaledMetric(maxHeight) }
        let clampedIndex = min(max(index, 0), scaledPresets.count - 1)
        return scaledPresets[clampedIndex]
    }

    static func presetIndex(
        forVisibleLineFragmentCount lineFragmentCount: Int,
        preset: FontScalePreset
    ) -> Int {
        let normalizedCount = max(1, lineFragmentCount)
        return min(normalizedCount - 1, heightPresets(for: preset).count - 1)
    }

    static func presetIndex(forVisibleLineFragmentCount lineFragmentCount: Int) -> Int {
        presetIndex(forVisibleLineFragmentCount: lineFragmentCount, preset: .normal)
    }

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    @FocusState private var isFocused: Bool
    @State private var currentHeightPresetIndex: Int = 0

    var body: some View {
        CustomTextField(
            text: $text,
            placeholder: placeholder,
            onReturn: onReturn,
            onImagePaste: onImagePaste,
            onDocumentFiles: onDocumentFiles,
            features: features,
            currentHeightPresetIndex: $currentHeightPresetIndex,
            onHeightChange: onHeightChange
        )
        .focused($isFocused)
        .onChange(of: resetTrigger) { _, newValue in
            if newValue {
                reset()
                resetTrigger = false
            }
        }
        .onChange(of: fontPreset) { _, newPreset in
            onHeightChange(Self.height(forPresetIndex: currentHeightPresetIndex, preset: newPreset))
        }
        .onAppear {
            onHeightChange(Self.height(forPresetIndex: currentHeightPresetIndex, preset: fontPreset))
        }
    }

    private func reset() {
        text = ""
        // Reset to the smallest height preset
        currentHeightPresetIndex = 0
        // Notify parent of height change
        onHeightChange(ResizableTextField.height(forPresetIndex: currentHeightPresetIndex, preset: fontPreset))
    }
}

struct CustomTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onReturn: () -> Void
    var onImagePaste: ((NSPasteboard) -> Bool)?
    var onDocumentFiles: ((ComposerDocumentFileAdmission) -> Bool)?
    var features: ResizableTextFieldFeatures = .plain
    @Binding var currentHeightPresetIndex: Int

    /// Callback for height changes
    var onHeightChange: (CGFloat) -> Void = { _ in }

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ImageAwareTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? ImageAwareTextView else {
            return scrollView
        }

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.font = fontPreset.nsFont
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 0, height: 6)

        // Plain text config
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        if #available(macOS 13.0, *) {
            textView.isAutomaticDataDetectionEnabled = false
        }
        textView.usesFontPanel = false
        textView.usesRuler = false

        // IME/UI perf tweaks
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.layoutManager?.usesFontLeading = true

        textView.delegate = context.coordinator
        textView.imagePasteHandler = onImagePaste
        textView.documentFileHandler = onDocumentFiles
        textView.onDidMoveToWindow = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.composerTextViewDidMoveToWindow(textView)
        }
        let composerFocusState = ComposerFocusTokenPolicy.seededState(for: features.composerFocusToken)
        context.coordinator.lastAppliedComposerFocusToken = composerFocusState.lastAppliedToken
        context.coordinator.pendingComposerFocusToken = composerFocusState.pendingToken
        #if DEBUG || EDIT_FLOW_PERF
            context.coordinator.installInteractionProbeResponderObservation(on: textView)
        #endif
        #if DEBUG
            context.coordinator.traceComposerFocusSeed(features.composerFocusToken)
            context.coordinator.installComposerFocusResignTrace(on: textView)
        #endif
        textView.enablesImagePasteHandling = onImagePaste != nil
        context.coordinator.configureFileTagSupport(
            textView: textView,
            enabled: features.enableFileTagOverlay,
            store: features.fileTagStore,
            searchService: features.fileTagSearchService,
            selectionCoordinator: features.fileTagSelectionCoordinator,
            lookupContextIdentity: features.fileTagLookupContextIdentity,
            lookupContextProvider: features.fileTagLookupContextProvider,
            configuration: features.fileTagPickerConfiguration
        )
        context.coordinator.configureSlashSkillSupport(
            textView: textView,
            enabled: features.enableSlashSkillOverlay,
            suggestionsProvider: features.slashSkillSuggestionsProvider
        )
        context.coordinator.configureSnippetPaletteSupport(
            textView: textView,
            enabled: features.enableSnippetPalette,
            itemsProvider: features.snippetPaletteItemsProvider,
            scope: features.snippetPaletteScope
        )
        textView.string = text
        context.coordinator.clearUndoHistory()

        // Initial height calculation
        Task { @MainActor in
            context.coordinator.updateHeightIfNeeded(textView: textView)
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? ImageAwareTextView else { return }
        // `.disabled` (e.g. the shutdown edit freeze) makes the text read-only; it stays selectable.
        let isEditable = context.environment.isEnabled
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        textView.imagePasteHandler = onImagePaste
        textView.documentFileHandler = onDocumentFiles
        textView.enablesImagePasteHandling = onImagePaste != nil
        if textView.font != fontPreset.nsFont {
            textView.font = fontPreset.nsFont
            Task { @MainActor in
                context.coordinator.updateHeightIfNeeded(textView: textView)
            }
        }
        context.coordinator.configureFileTagSupport(
            textView: textView,
            enabled: features.enableFileTagOverlay,
            store: features.fileTagStore,
            searchService: features.fileTagSearchService,
            selectionCoordinator: features.fileTagSelectionCoordinator,
            lookupContextIdentity: features.fileTagLookupContextIdentity,
            lookupContextProvider: features.fileTagLookupContextProvider,
            configuration: features.fileTagPickerConfiguration
        )
        context.coordinator.configureSlashSkillSupport(
            textView: textView,
            enabled: features.enableSlashSkillOverlay,
            suggestionsProvider: features.slashSkillSuggestionsProvider
        )
        context.coordinator.configureSnippetPaletteSupport(
            textView: textView,
            enabled: features.enableSnippetPalette,
            itemsProvider: features.snippetPaletteItemsProvider,
            scope: features.snippetPaletteScope
        )
        context.coordinator.scheduleComposerFocusToken(features.composerFocusToken, for: textView)
        #if DEBUG || EDIT_FLOW_PERF
            context.coordinator.observeComposerResponderForInteractionProbe(textView, via: "viewUpdate")
        #endif

        var appliedProgrammaticTextChange = false
        // IME FIX: Avoid stomping marked text (composition) with programmatic writes.
        if textView.string != text {
            // If an IME composition is active, DO NOT overwrite.
            if textView.hasMarkedText() { return }

            context.coordinator.internalUpdateInProgress = true

            // Preserve selection when applying programmatic changes.
            let prevSel = textView.selectedRange()
            context.coordinator.performExternalReplacement(in: textView) {
                textView.string = text
            }
            let nsLen = (text as NSString).length
            let clampedLoc = min(max(prevSel.location, 0), nsLen)
            let maxLenFromLoc = max(0, nsLen - clampedLoc)
            let clampedLen = min(max(prevSel.length, 0), maxLenFromLoc)
            textView.setSelectedRange(NSRange(location: clampedLoc, length: clampedLen))

            context.coordinator.internalUpdateInProgress = false
            appliedProgrammaticTextChange = true

            Task { @MainActor in
                context.coordinator.updateHeightIfNeeded(textView: textView)
            }
        }
        if appliedProgrammaticTextChange {
            context.coordinator.scheduleFileTagSuggestionsRefresh(for: textView, immediate: true)
            context.coordinator.scheduleSlashSkillSuggestionsRefresh(for: textView, immediate: true)
            // A programmatic rewrite (draft restore, tab switch) invalidates the
            // palette's caret anchor; the session cannot survive text it never
            // observed.
            context.coordinator.dismissSnippetPaletteSession()
        }
    }

    // NEW: stop callbacks after view is torn down
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let textView = nsView.documentView as? ImageAwareTextView else { return }
        textView.delegate = nil
        textView.imagePasteHandler = nil
        textView.onDidMoveToWindow = nil
        #if DEBUG || EDIT_FLOW_PERF
            textView.onDidBecomeFirstResponderForInteractionProbe = nil
        #endif
        #if DEBUG
            textView.onDidResignFirstResponderForFocusTrace = nil
        #endif
        textView.isAutomaticSpellingCorrectionEnabled = false
        coordinator.clearUndoHistory()
        coordinator.dismissFileTagOverlay()
        coordinator.dismissSlashSkillOverlay()
        coordinator.tearDownSnippetPaletteSupport()
        coordinator.discardPendingComposerFocusTokenForDismantle()
        coordinator.isActive = false
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextField
        var internalUpdateInProgress = false
        var lastReportedHeight: CGFloat?
        var lastAppliedComposerFocusToken: UUID?
        var pendingComposerFocusToken: UUID?

        private let textViewUndoManager = UndoManager()
        private let fileTagHelper = FileTagMentionHelper()
        private let slashSkillHelper = SlashSkillMentionHelper()
        private let snippetPaletteHelper = SnippetPaletteHelper()
        private weak var snippetPaletteTextView: ImageAwareTextView?
        private var snippetPaletteShortcutObserver: (any NSObjectProtocol)?
        private var configuredSnippetPaletteScope: SnippetPaletteScope?
        // NEW: mark inactive after dismantle
        var isActive: Bool = true

        init(_ parent: CustomTextField) {
            self.parent = parent
        }

        /// The edit entry: a refused change never reaches the text (or its binding), so nothing is
        /// accepted on screen and then lost.
        func textView(
            _: NSTextView,
            shouldChangeTextIn _: NSRange,
            replacementString _: String?
        ) -> Bool {
            parent.features.acceptsEdits?() ?? true
        }

        func scheduleComposerFocusToken(_ token: UUID?, for textView: ImageAwareTextView) {
            guard ComposerFocusTokenPolicy.shouldSchedule(
                token: token,
                lastAppliedToken: lastAppliedComposerFocusToken,
                pendingToken: pendingComposerFocusToken
            ) else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                guard isActive, let textView else {
                    #if DEBUG
                        if let token, token != debugActedComposerFocusToken {
                            traceComposerFocusDrop(token: token, cause: .inactive)
                        }
                    #endif
                    return
                }
                let currentToken = parent.features.composerFocusToken
                guard ComposerFocusTokenPolicy.scheduledTokenIsCurrent(
                    token,
                    currentToken: currentToken
                ) else {
                    #if DEBUG
                        if let token, token != debugActedComposerFocusToken {
                            traceComposerFocusDrop(token: token, cause: .superseded)
                        }
                    #endif
                    return
                }
                applyComposerFocusToken(currentToken, to: textView)
            }
        }

        #if DEBUG
            private enum ComposerFocusTraceCause: String {
                case inactive
                case superseded
                case resign
            }

            private static let composerFocusLogger = Logger(
                subsystem: "com.repoprompt.app",
                category: "composer-focus"
            )
            /// Diagnostics only: the token this coordinator last attempted or dropped (never
            /// read by focus policy).
            private var debugActedComposerFocusToken: UUID?
            /// Diagnostics only: the token whose attempt this coordinator saw end with the composer
            /// as first responder; arms the resign trace (never read by focus policy).
            private var debugFocusedComposerFocusToken: UUID?
            /// Diagnostics only: (token, cause) dedupe so repeated view updates trace each pair once.
            /// Bounded; tokens are per-request UUIDs, so clearing only risks a rare re-trace.
            private var debugTracedComposerFocusKeys: Set<String> = []

            private func shouldTraceComposerFocus(token: UUID, cause: ComposerFocusTraceCause) -> Bool {
                if debugTracedComposerFocusKeys.count >= 64 {
                    debugTracedComposerFocusKeys.removeAll(keepingCapacity: true)
                }
                return debugTracedComposerFocusKeys.insert("\(token.uuidString)|\(cause.rawValue)").inserted
            }

            /// Content-free: token UUID and cause only; no text, tab/session IDs, or model names.
            private func traceComposerFocusDrop(token: UUID, cause: ComposerFocusTraceCause) {
                guard shouldTraceComposerFocus(token: token, cause: cause) else { return }
                Self.composerFocusLogger.debug(
                    "drop token=\(token.uuidString, privacy: .public) cause=\(cause.rawValue, privacy: .public)"
                )
            }

            /// A token already present at mount is seeded as applied and intentionally never
            /// focused. It may have been delivered by an earlier text view; if no earlier
            /// `delivery` exists for this UUID, this is where it was lost. Once per mount.
            func traceComposerFocusSeed(_ token: UUID?) {
                guard let token else { return }
                Self.composerFocusLogger.debug(
                    "seed token=\(token.uuidString, privacy: .public)"
                )
            }

            func installComposerFocusResignTrace(on textView: ImageAwareTextView) {
                textView.onDidResignFirstResponderForFocusTrace = { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    traceComposerFocusResign(textView)
                }
            }

            /// Makes a responder theft after `delivery ... firstResponder=true` visible. Traces the
            /// first resignation per token that actually focused the composer; never changes
            /// focus or token state.
            private func traceComposerFocusResign(_ textView: ImageAwareTextView) {
                guard isActive,
                      let token = lastAppliedComposerFocusToken,
                      token == debugFocusedComposerFocusToken,
                      shouldTraceComposerFocus(token: token, cause: .resign)
                else { return }
                Self.composerFocusLogger.debug(
                    "resign token=\(token.uuidString, privacy: .public) window=\(textView.window?.windowNumber ?? -1, privacy: .public)"
                )
            }
        #endif

        func composerTextViewDidMoveToWindow(_ textView: ImageAwareTextView) {
            #if DEBUG || EDIT_FLOW_PERF
                observeComposerResponderForInteractionProbe(textView, via: "moveToWindow")
            #endif
            guard let pendingComposerFocusToken else { return }
            scheduleComposerFocusToken(pendingComposerFocusToken, for: textView)
        }

        func discardPendingComposerFocusTokenForDismantle() {
            #if DEBUG
                let hasUnappliedCurrentToken = parent.features.composerFocusToken.map {
                    $0 != lastAppliedComposerFocusToken
                } ?? false
                if pendingComposerFocusToken != nil || hasUnappliedCurrentToken {
                    AgentModePerfDiagnostics.increment("ui.composer.focusToken.dismantleDrop")
                }
                // The coordinator may be released before a queued attempt runs, so trace the
                // loss here; dedupe keeps a later in-block trace from repeating it.
                var lostTokens: [UUID] = []
                if let pendingComposerFocusToken {
                    lostTokens.append(pendingComposerFocusToken)
                }
                if hasUnappliedCurrentToken,
                   let currentToken = parent.features.composerFocusToken,
                   currentToken != pendingComposerFocusToken
                {
                    lostTokens.append(currentToken)
                }
                for lostToken in lostTokens where lostToken != debugActedComposerFocusToken {
                    traceComposerFocusDrop(token: lostToken, cause: .inactive)
                }
            #endif
            pendingComposerFocusToken = nil
            lastAppliedComposerFocusToken = nil
        }

        #if DEBUG || EDIT_FLOW_PERF
            func installInteractionProbeResponderObservation(on textView: ImageAwareTextView) {
                textView.onDidBecomeFirstResponderForInteractionProbe = { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    observeComposerResponderForInteractionProbe(textView, via: "responderBecame")
                }
            }

            /// Diagnostics only: reads actual AppKit state for the current token. It never
            /// requests focus and does not touch the seeded/applied token policy state.
            func observeComposerResponderForInteractionProbe(_ textView: ImageAwareTextView, via: StaticString) {
                guard AgentInteractionLatencyProbe.isAwaitingComposerFocus,
                      isActive,
                      let token = parent.features.composerFocusToken,
                      let window = textView.window,
                      window.isKeyWindow,
                      window.firstResponder === textView
                else { return }
                AgentInteractionLatencyProbe.composerFocusAcknowledged(token: token, via: via)
            }
        #endif

        private func applyComposerFocusToken(_ token: UUID?, to textView: ImageAwareTextView) {
            #if DEBUG || EDIT_FLOW_PERF
                defer { observeComposerResponderForInteractionProbe(textView, via: "tokenAttempt") }
            #endif
            let action = ComposerFocusTokenPolicy.action(
                token: token,
                lastAppliedToken: lastAppliedComposerFocusToken,
                hasWindow: textView.window != nil,
                hasAttachedSheet: textView.window?.attachedSheet != nil
            )
            let currentState = ComposerFocusTokenPolicy.State(
                lastAppliedToken: lastAppliedComposerFocusToken,
                pendingToken: pendingComposerFocusToken
            )
            #if DEBUG
                // Read actual AppKit state after applying; no text, tab IDs, or model names.
                defer {
                    if let token, action != .none {
                        Logger(subsystem: "com.repoprompt.app", category: "composer-focus").debug(
                            "delivery token=\(token.uuidString, privacy: .public) action=\(String(describing: action), privacy: .public) window=\(textView.window?.windowNumber ?? -1, privacy: .public) key=\(textView.window?.isKeyWindow == true, privacy: .public) firstResponder=\(textView.window?.firstResponder === textView, privacy: .public)"
                        )
                    }
                    if let token, action == .drop || action == .attempt {
                        debugActedComposerFocusToken = token
                    }
                    if let token, action == .attempt, textView.window?.firstResponder === textView {
                        debugFocusedComposerFocusToken = token
                    }
                }
            #endif

            switch action {
            case .clearPending, .none, .waitForWindow:
                applyComposerFocusState(
                    ComposerFocusTokenPolicy.state(
                        after: action,
                        token: token,
                        currentState: currentState
                    )
                )
            case .drop:
                applyComposerFocusState(
                    ComposerFocusTokenPolicy.state(
                        after: action,
                        token: token,
                        currentState: currentState
                    )
                )
                #if DEBUG
                    AgentModePerfDiagnostics.increment("ui.composer.focusToken.sheetDrop")
                #endif
            case .attempt:
                let appliedState = ComposerFocusTokenPolicy.state(
                    after: action,
                    token: token,
                    currentState: currentState
                )
                if textView.window?.firstResponder === textView {
                    applyComposerFocusState(appliedState)
                    return
                }
                guard textView.acceptsFirstResponder,
                      let window = textView.window,
                      window.makeFirstResponder(textView),
                      window.firstResponder === textView
                else {
                    applyComposerFocusState(appliedState)
                    #if DEBUG
                        AgentModePerfDiagnostics.increment("ui.composer.focusToken.attemptFailed")
                    #endif
                    return
                }
                applyComposerFocusState(appliedState)
            }
        }

        private func applyComposerFocusState(_ state: ComposerFocusTokenPolicy.State) {
            lastAppliedComposerFocusToken = state.lastAppliedToken
            pendingComposerFocusToken = state.pendingToken
        }

        func textDidChange(_ notification: Notification) {
            if internalUpdateInProgress { return }
            guard isActive, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string

            updateHeightIfNeeded(textView: textView)
            scheduleFileTagSuggestionsRefresh(for: textView, immediate: false)
            scheduleSlashSkillSuggestionsRefresh(for: textView, immediate: false)
            refreshOrDismissSnippetPalette(for: textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard isActive else { return }
            dismissFileTagOverlay()
            dismissSlashSkillOverlay()
            snippetPaletteHelper.dismiss()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard isActive, let textView = notification.object as? NSTextView else { return }
            // Selection changes fire frequently while typing; debounce to avoid duplicate
            // refreshes alongside textDidChange.
            scheduleFileTagSuggestionsRefresh(for: textView, immediate: false)
            scheduleSlashSkillSuggestionsRefresh(for: textView, immediate: false)
            refreshOrDismissSnippetPalette(for: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // IME FIX: if composing, let IME handle keys (Return/space/numbers etc.)
            if textView.hasMarkedText() { return false }
            guard isActive else { return false }
            if snippetPaletteHelper.handleCommandIfNeeded(
                textView: textView,
                commandSelector: commandSelector,
                enabled: parent.features.enableSnippetPalette
            ) {
                return true
            }
            if slashSkillHelper.handleCommandIfNeeded(
                textView: textView,
                commandSelector: commandSelector,
                enabled: parent.features.enableSlashSkillOverlay
            ) {
                return true
            }
            if fileTagHelper.handleCommandIfNeeded(
                textView: textView,
                commandSelector: commandSelector,
                enabled: parent.features.enableFileTagOverlay,
                onCommit: parent.features.onFileTagCommitted
            ) {
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Use the *current* event to read modifier flags (more reliable)
                let flags = textView.window?.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) {
                    textView.insertNewline(nil) // Shift+Return → newline
                } else {
                    parent.onReturn() // Plain Return → send
                }
                return true
            }
            // Some keyboards/IMEs use insertLineBreak for Shift+Return; let it fall through to newline.
            if commandSelector == #selector(NSResponder.insertLineBreak(_:)) { return false }
            if commandSelector == #selector(NSText.paste(_:)) {
                if let imageAwareTextView = textView as? ImageAwareTextView {
                    if imageAwareTextView.handleDocumentFiles(from: NSPasteboard.general) != .unclaimed {
                        return true
                    }
                    return imageAwareTextView.imagePasteHandler?(NSPasteboard.general) == true
                }
                return parent.onImagePaste?(NSPasteboard.general) == true
            }
            return false
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            textViewUndoManager
        }

        func performExternalReplacement(
            in textView: NSTextView,
            mutation: () -> Void
        ) {
            TextViewUndoSafeReplacement.perform(
                in: textView,
                undoManager: textViewUndoManager,
                mutation: mutation
            )
        }

        func clearUndoHistory() {
            textViewUndoManager.removeAllActions()
        }

        func updateHeightIfNeeded(textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            layoutManager.ensureLayout(for: textContainer)
            let glyphRange = layoutManager.glyphRange(for: textContainer)
            var visibleLineFragmentCount = 0
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
                visibleLineFragmentCount += 1
            }
            if layoutManager.extraLineFragmentTextContainer === textContainer,
               !layoutManager.extraLineFragmentRect.isEmpty
            {
                visibleLineFragmentCount += 1
            }
            let index = ResizableTextField.presetIndex(
                forVisibleLineFragmentCount: visibleLineFragmentCount,
                preset: parent.fontPreset
            )
            let newHeight = ResizableTextField.height(forPresetIndex: index, preset: parent.fontPreset)

            if index != parent.currentHeightPresetIndex || lastReportedHeight.map({ abs($0 - newHeight) >= 0.5 }) != false {
                parent.currentHeightPresetIndex = index
                lastReportedHeight = newHeight
                parent.onHeightChange(newHeight)
            }
        }

        func configureFileTagSupport(
            textView: ImageAwareTextView,
            enabled: Bool,
            store: WorkspaceFileContextStore?,
            searchService: WorkspaceSearchService?,
            selectionCoordinator: WorkspaceSelectionCoordinator?,
            lookupContextIdentity: AnyHashable?,
            lookupContextProvider: (() async -> WorkspaceLookupContext)?,
            configuration: FileMentionPickerConfiguration
        ) {
            fileTagHelper.configure(
                textView: textView,
                enabled: enabled,
                store: store,
                searchService: searchService,
                selectionCoordinator: selectionCoordinator,
                lookupContextIdentity: lookupContextIdentity,
                lookupContextProvider: lookupContextProvider,
                configuration: configuration
            )
        }

        func scheduleFileTagSuggestionsRefresh(for textView: NSTextView, immediate: Bool) {
            fileTagHelper.scheduleRefresh(
                for: textView,
                immediate: immediate,
                enabled: parent.features.enableFileTagOverlay,
                isActive: isActive
            )
        }

        func dismissFileTagOverlay() {
            fileTagHelper.dismiss()
        }

        func configureSlashSkillSupport(
            textView: ImageAwareTextView,
            enabled: Bool,
            suggestionsProvider: ((String) async -> [MentionSuggestion])?
        ) {
            slashSkillHelper.configure(
                textView: textView,
                enabled: enabled,
                suggestionsProvider: suggestionsProvider
            )
        }

        func scheduleSlashSkillSuggestionsRefresh(for textView: NSTextView, immediate: Bool) {
            slashSkillHelper.scheduleRefresh(
                for: textView,
                immediate: immediate,
                enabled: parent.features.enableSlashSkillOverlay,
                isActive: isActive
            )
        }

        func dismissSlashSkillOverlay() {
            slashSkillHelper.dismiss()
        }

        func configureSnippetPaletteSupport(
            textView: ImageAwareTextView,
            enabled: Bool,
            itemsProvider: (() -> [SnippetPaletteItem])?,
            scope: SnippetPaletteScope?
        ) {
            snippetPaletteTextView = textView
            if configuredSnippetPaletteScope != scope {
                snippetPaletteHelper.dismiss()
                configuredSnippetPaletteScope = scope
            }
            snippetPaletteHelper.configure(enabled: enabled, itemsProvider: itemsProvider)
            guard enabled, itemsProvider != nil, scope != nil else {
                removeSnippetPaletteShortcutObserver()
                return
            }
            guard snippetPaletteShortcutObserver == nil else { return }
            snippetPaletteShortcutObserver = NotificationCenter.default.addObserver(
                forName: .performPromptSnippetPaletteActivation,
                object: nil,
                queue: nil
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.handleOpenSnippetPaletteShortcut(note)
                }
            }
        }

        func scheduleSnippetPaletteRefresh(for textView: NSTextView, immediate: Bool) {
            snippetPaletteHelper.scheduleRefresh(
                for: textView,
                immediate: immediate,
                enabled: parent.features.enableSnippetPalette,
                isActive: isActive
            )
        }

        /// Undo/redo arrives via the responder chain (never `doCommandBy`), so
        /// a rewind can leave the palette's integer anchor in-bounds over text
        /// it was never anchored to. Drop the session instead of refreshing.
        func refreshOrDismissSnippetPalette(for textView: NSTextView) {
            if textViewUndoManager.isUndoing || textViewUndoManager.isRedoing {
                snippetPaletteHelper.dismiss()
            } else {
                scheduleSnippetPaletteRefresh(for: textView, immediate: false)
            }
        }

        func dismissSnippetPaletteSession() {
            snippetPaletteHelper.dismiss()
        }

        func tearDownSnippetPaletteSupport() {
            snippetPaletteHelper.dismiss()
            removeSnippetPaletteShortcutObserver()
            snippetPaletteTextView = nil
            configuredSnippetPaletteScope = nil
        }

        private func removeSnippetPaletteShortcutObserver() {
            if let snippetPaletteShortcutObserver {
                NotificationCenter.default.removeObserver(snippetPaletteShortcutObserver)
            }
            snippetPaletteShortcutObserver = nil
        }

        private func handleOpenSnippetPaletteShortcut(_ note: Notification) {
            guard SnippetPaletteScope.matches(
                configuredSnippetPaletteScope,
                requestWindowID: note.userInfo?[SnippetPaletteNotificationUserInfoKey.windowID] as? Int,
                requestTabID: note.userInfo?[SnippetPaletteNotificationUserInfoKey.tabID] as? UUID
            ) else { return }
            guard isActive, parent.features.enableSnippetPalette else { return }
            guard let textView = snippetPaletteTextView,
                  textView.delegate === self,
                  let window = textView.window,
                  window.isKeyWindow,
                  window.attachedSheet == nil,
                  !textView.hasMarkedText()
            else { return }

            if window.firstResponder === textView {
                snippetPaletteHelper.toggleSession(in: textView)
                return
            }

            guard textView.acceptsFirstResponder,
                  window.makeFirstResponder(textView),
                  window.firstResponder === textView
            else { return }
            snippetPaletteHelper.openSession(in: textView)
        }

        #if DEBUG
            var snippetPaletteSessionIsActiveForTesting: Bool {
                snippetPaletteHelper.isSessionActive
            }

            func openSnippetPaletteSessionForTesting(in textView: NSTextView) {
                snippetPaletteHelper.openSession(in: textView)
            }
        #endif
    }
}
