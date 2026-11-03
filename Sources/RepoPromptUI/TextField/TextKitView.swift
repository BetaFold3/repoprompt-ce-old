import AppKit
import SwiftUI

/**
 A SwiftUI wrapper around an NSTextView for plain text usage.
 Spell‑checking can optionally be enabled.
 */
package struct TextKitView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var isSpellCheckEnabled: Bool = false
    var fontSize: Double?
    var useMonospacedFont: Bool = false // Use monospaced font
    /// When true with `useMonospacedFont`, resolve via `TranscriptCodeFontResolver`
    /// (transcript tool cards). Leave false for composers / editors.
    var useTranscriptCodeFont: Bool = false
    /// Optional PostScript preference when `useTranscriptCodeFont` is true.
    var preferredTranscriptCodeFontPostScriptName: String?
    var wrapLines: Bool = true // New: toggle line-wrapping / horizontal scroll
    var externalUpdateTick: Int = 0
    /// When true, allows non-contiguous layout (incremental layout). Default is false
    /// to fix Intel Mac scroll issues, but can be enabled to avoid expensive full-layout on click.
    var allowNonContiguousLayout: Bool = false
    /// When true, scroll indicators auto-hide when not scrolling. Default is false (always visible).
    var autohidesScrollers: Bool = false
    /// Optional AppKit scroller style override.
    var scrollerStyle: NSScroller.Style?
    /// Default-off lexical file links for plain-text surfaces that preserve verbatim Markdown.
    var detectedMarkdownFileLinks: [MarkdownFilePathLinkDetector.Match] = []
    /// Routes opt-in detected links through the same policy as rendered Markdown links.
    var markdownFileLinkOpener: MarkdownFileLinkOpener?
    /// Default-off content fitting. When set, `sizeThatFits` reports the laid-out content height
    /// for the proposed width, capped at this value; when nil, SwiftUI's default sizing applies.
    var contentFittingMaxHeight: CGFloat?
    /// Notifies parent when the user starts/stops editing so it can gate external writes.
    var onEditingChanged: ((Bool) -> Void)?

    package init(
        text: Binding<String>,
        isEditable: Bool = true,
        isSpellCheckEnabled: Bool = false,
        fontSize: Double? = nil,
        useMonospacedFont: Bool = false,
        useTranscriptCodeFont: Bool = false,
        preferredTranscriptCodeFontPostScriptName: String? = nil,
        wrapLines: Bool = true,
        externalUpdateTick: Int = 0,
        allowNonContiguousLayout: Bool = false,
        autohidesScrollers: Bool = false,
        scrollerStyle: NSScroller.Style? = nil,
        detectedMarkdownFileLinks: [MarkdownFilePathLinkDetector.Match] = [],
        markdownFileLinkOpener: MarkdownFileLinkOpener? = nil,
        contentFittingMaxHeight: CGFloat? = nil,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        _text = text
        self.isEditable = isEditable
        self.isSpellCheckEnabled = isSpellCheckEnabled
        self.fontSize = fontSize
        self.useMonospacedFont = useMonospacedFont
        self.useTranscriptCodeFont = useTranscriptCodeFont
        self.preferredTranscriptCodeFontPostScriptName = preferredTranscriptCodeFontPostScriptName
        self.wrapLines = wrapLines
        self.externalUpdateTick = externalUpdateTick
        self.allowNonContiguousLayout = allowNonContiguousLayout
        self.autohidesScrollers = autohidesScrollers
        self.scrollerStyle = scrollerStyle
        self.detectedMarkdownFileLinks = detectedMarkdownFileLinks
        self.markdownFileLinkOpener = markdownFileLinkOpener
        self.contentFittingMaxHeight = contentFittingMaxHeight
        self.onEditingChanged = onEditingChanged
    }

    static let textContainerInset = NSSize(width: 8, height: 8)

    @ObservedObject private var fontScale = FontScaleManager.shared

    private var resolvedFontSize: CGFloat {
        if let fontSize {
            return CGFloat(fontSize)
        }
        return useMonospacedFont
            ? CGFloat(max(fontScale.preset.rawValue - 2, 9))
            : CGFloat(fontScale.preset.rawValue)
    }

    private var resolvedFont: NSFont {
        if useMonospacedFont, useTranscriptCodeFont {
            return TranscriptCodeFontResolver.resolve(
                preferredPostScriptName: preferredTranscriptCodeFontPostScriptName,
                pointSize: resolvedFontSize
            ).font
        }
        return useMonospacedFont
            ? NSFont.monospacedSystemFont(ofSize: resolvedFontSize, weight: .regular)
            : NSFont.systemFont(ofSize: resolvedFontSize)
    }

    struct ParagraphStyleSignature: Equatable {
        let fontFingerprint: TranscriptCodeFontFingerprint
        let wrapLines: Bool
    }

    static func paragraphStyleSignature(
        font: NSFont,
        wrapLines: Bool
    ) -> ParagraphStyleSignature {
        ParagraphStyleSignature(
            fontFingerprint: .fingerprint(of: font),
            wrapLines: wrapLines
        )
    }

    static func codeParagraphStyle(for signature: ParagraphStyleSignature) -> NSParagraphStyle {
        let metrics = TranscriptCodeFontResolver.resolve(
            preferredPostScriptName: signature.fontFingerprint.faceIdentity,
            pointSize: signature.fontFingerprint.pointSize
        )
        return metrics.makeCodeParagraphStyle(
            lineBreakMode: signature.wrapLines ? .byWordWrapping : .byClipping
        )
    }

    /// The default paragraph style the live text view applies (`nil` = AppKit default).
    func resolvedParagraphStyle(font: NSFont) -> NSParagraphStyle? {
        guard useMonospacedFont, useTranscriptCodeFont else { return nil }
        return Self.codeParagraphStyle(for: Self.paragraphStyleSignature(font: font, wrapLines: wrapLines))
    }

    // MARK: - Opt-in content fitting

    /// Synchronous, width-driven fitting for callers that set `contentFittingMaxHeight`.
    /// Measurement uses a private layout stack and never mutates the displayed view.
    @MainActor
    package func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard contentFittingMaxHeight != nil else { return nil }
        return fittedSize(
            for: proposal,
            chrome: TextKitContentHeightMeasurer.ScrollChrome(scrollView: nsView)
        )
    }

    /// The size reported to SwiftUI for an opted-in view.
    ///
    /// Only a concrete, finite proposed width is measured; its returned width is that proposal.
    /// Unspecified (`nil`) or infinite width probes return nil, which keeps SwiftUI's default
    /// representable sizing for them and never reports an infinite size back. Not opting in
    /// always returns nil.
    func fittedSize(
        for proposal: ProposedViewSize,
        chrome: TextKitContentHeightMeasurer.ScrollChrome
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite,
              let measurement = contentFittingMeasurement(proposedWidth: width, chrome: chrome)
        else { return nil }
        return CGSize(width: max(width, 0), height: measurement.height)
    }

    /// Nil when fitting is not opted in, so default callers keep SwiftUI's default sizing.
    func contentFittingMeasurement(
        proposedWidth: CGFloat?,
        chrome: TextKitContentHeightMeasurer.ScrollChrome
    ) -> TextKitContentHeightMeasurer.Result? {
        guard let maxHeight = contentFittingMaxHeight else { return nil }
        let font = resolvedFont
        return TextKitContentHeightMeasurer.fittedHeight(
            text: text,
            font: font,
            paragraphStyle: resolvedParagraphStyle(font: font),
            wrapLines: wrapLines,
            frameWidth: proposedWidth,
            textContainerInset: Self.textContainerInset,
            chrome: chrome,
            maxHeight: maxHeight
        )
    }

    // MARK: - Coordinator

    @MainActor
    package class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextKitView
        private let textViewUndoManager = UndoManager()
        var internalText: String
        var lastAppliedTick: Int = 0
        // NEW: mark inactive after dismantle
        var isActive: Bool = true
        /// Track previous empty state to detect empty<->non-empty transitions
        var wasEmpty: Bool = true
        var pendingLayoutTask: Task<Void, Never>?
        var layoutGeneration: UInt64 = 0
        var paragraphStyleSignature: ParagraphStyleSignature?
        var appliedDetectedMarkdownFileLinks: [MarkdownFilePathLinkDetector.Match] = []

        fileprivate enum LayoutStabilizationReason {
            case emptyTransition
            case externalWrite
        }

        init(_ parent: TextKitView) {
            self.parent = parent
            internalText = parent.text
            wasEmpty = parent.text.isEmpty
            textViewUndoManager.levelsOfUndo = 100
            textViewUndoManager.groupsByEvent = true
        }

        package func textDidChange(_ notification: Notification) {
            guard isActive, let textView = notification.object as? NSTextView else { return }
            let newText = textView.string
            let isEmpty = newText.isEmpty

            // Force full layout on empty<->non-empty transitions (fixes placeholder/scroll issues)
            if isEmpty != wasEmpty {
                wasEmpty = isEmpty
                scheduleLayoutStabilization(
                    for: textView,
                    expectedIsEmpty: isEmpty,
                    reason: .emptyTransition
                )
            }

            internalText = newText
            parent.text = newText
        }

        package func textDidBeginEditing(_ notification: Notification) {
            parent.onEditingChanged?(true)
        }

        package func textDidEndEditing(_ notification: Notification) {
            parent.onEditingChanged?(false)
        }

        package func undoManager(for view: NSTextView) -> UndoManager? {
            textViewUndoManager
        }

        package func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard charIndex >= 0,
                  let storage = textView.textStorage,
                  charIndex < storage.length,
                  storage.attribute(.markdownDetectedFileLink, at: charIndex, effectiveRange: nil) != nil
            else { return false }

            guard let rawPath = storage.attribute(
                .markdownRawLink,
                at: charIndex,
                effectiveRange: nil
            ) as? String,
                let target = MarkdownFileLinkTarget.detectedFilePath(rawPath)
            else { return true }

            guard let opener = parent.markdownFileLinkOpener else { return true }
            Task { @MainActor in
                _ = await opener.open(target)
            }
            return true
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

        fileprivate func scheduleLayoutStabilization(
            for textView: NSTextView,
            expectedIsEmpty: Bool,
            reason: LayoutStabilizationReason
        ) {
            layoutGeneration &+= 1
            let generation = layoutGeneration

            pendingLayoutTask?.cancel()
            pendingLayoutTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                guard isActive else { return }
                guard generation == layoutGeneration else { return }
                guard textView.window != nil else { return }
                guard expectedIsEmpty == textView.string.isEmpty else { return }
                guard !textView.hasMarkedText() else { return }

                textView.clampSelectionToCurrentString()
                let nsLen = textView.currentStringLength()
                if nsLen == 0 {
                    let emptyRange = NSRange(location: 0, length: 0)
                    if let lm = textView.layoutManager {
                        lm.invalidateLayout(forCharacterRange: emptyRange, actualCharacterRange: nil)
                        lm.invalidateDisplay(forCharacterRange: emptyRange)
                    }
                    if reason == .emptyTransition {
                        textView.scrollRangeToVisible(emptyRange)
                    }
                    return
                }

                let fullRange = NSRange(location: 0, length: nsLen)
                if let lm = textView.layoutManager {
                    lm.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
                    lm.invalidateDisplay(forCharacterRange: fullRange)
                }

                let isActiveEditor = (textView.window?.firstResponder as? NSTextView) == textView
                guard !isActiveEditor,
                      let lm = textView.layoutManager,
                      let container = textView.textContainer,
                      container.layoutManager === lm,
                      lm.textContainers.contains(where: { $0 === container })
                else { return }
                lm.ensureLayout(for: container)
            }
        }
    }

    package func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    package func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        setupTextView(textView, coordinator: context.coordinator)

        // Scroll-view configuration
        scrollView.scrollsDynamically = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.contentView.postsBoundsChangedNotifications = true
        // Enable horizontal scroller when wrapping is disabled
        scrollView.hasHorizontalScroller = !wrapLines
        if let scrollerStyle {
            scrollView.scrollerStyle = scrollerStyle
        }
        return scrollView
    }

    func setupTextView(_ textView: NSTextView, coordinator: Coordinator) {
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        // Conditionally set font
        textView.font = resolvedFont
        refreshDefaultParagraphStyle(
            in: textView,
            coordinator: coordinator,
            font: resolvedFont
        )

        textView.textContainerInset = Self.textContainerInset
        textView.delegate = coordinator
        textView.string = coordinator.internalText

        textView.isVerticallyResizable = true
        // Wrapping / horizontal behaviour
        if wrapLines {
            textView.isHorizontallyResizable = false
            if let container = textView.textContainer {
                container.containerSize = NSSize(
                    width: 0,
                    height: CGFloat.greatestFiniteMagnitude
                )
                container.widthTracksTextView = true
            }
        } else {
            textView.isHorizontallyResizable = true
            if let container = textView.textContainer {
                container.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
                container.widthTracksTextView = false
            }
        }

        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        if let layoutManager = textView.layoutManager {
            // Non-contiguous layout can cause scroll bar and display issues on Intel Macs
            layoutManager.allowsNonContiguousLayout = false
            layoutManager.usesFontLeading = true
        }

        if let scrollView = textView.enclosingScrollView {
            scrollView.hasVerticalScroller = true
            // Keep this aligned with wrap mode (was hardcoded to false)
            scrollView.hasHorizontalScroller = !wrapLines
            scrollView.autohidesScrollers = autohidesScrollers
            if let scrollerStyle {
                scrollView.scrollerStyle = scrollerStyle
            }
        }

        textView.isRichText = false
        textView.smartInsertDeleteEnabled = false
        textView.displaysLinkToolTips = false

        // Disable costly automatic transforms by default (opt back in if needed)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        if #available(macOS 13.0, *) {
            textView.isAutomaticDataDetectionEnabled = false
        }

        // Configure spell-check and autocorrection (kept user-configurable)
        textView.isContinuousSpellCheckingEnabled = isSpellCheckEnabled
        textView.isAutomaticSpellingCorrectionEnabled = isSpellCheckEnabled

        refreshDetectedMarkdownFileLinks(
            in: textView,
            coordinator: coordinator,
            force: true
        )
    }

    @MainActor
    package func updateNSView(_ nsView: NSScrollView, context: Context) {
        updateNSView(nsView, coordinator: context.coordinator)
    }

    @MainActor
    func updateNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.parent = self
        guard let textView = nsView.documentView as? NSTextView else { return }

        // Non-contiguous layout: disabled by default (fixes Intel Mac scroll issues),
        // but can be enabled to avoid expensive full-layout on click.
        if let layoutManager = textView.layoutManager {
            if layoutManager.allowsNonContiguousLayout != allowNonContiguousLayout {
                layoutManager.allowsNonContiguousLayout = allowNonContiguousLayout
            }
        }

        // Mirror wrapping → horizontal scroller only when wrapping is disabled
        if let scrollView = textView.enclosingScrollView {
            let shouldHaveHScroller = !wrapLines
            if scrollView.hasHorizontalScroller != shouldHaveHScroller {
                scrollView.hasHorizontalScroller = shouldHaveHScroller
            }
            if scrollView.autohidesScrollers != autohidesScrollers {
                scrollView.autohidesScrollers = autohidesScrollers
            }
            if let scrollerStyle, scrollView.scrollerStyle != scrollerStyle {
                scrollView.scrollerStyle = scrollerStyle
            }
        }

        // Compute whether we should force a programmatic update even if focused
        let shouldForce = coordinator.lastAppliedTick != externalUpdateTick

        // Only touch the font when size/mono actually changed to avoid reflow on every update
        let requiredFont = resolvedFont
        if let currentFont = textView.font {
            let faceChanged = currentFont.fontName != requiredFont.fontName
            let sizeChanged = abs(currentFont.pointSize - requiredFont.pointSize) > 0.01
            if faceChanged || sizeChanged {
                textView.font = requiredFont
            }
        } else {
            textView.font = requiredFont
        }
        refreshDefaultParagraphStyle(
            in: textView,
            coordinator: coordinator,
            font: requiredFont
        )

        // Determine if user is actively editing in this text view
        let wasFirstResponder = (textView.window?.firstResponder as? NSTextView) == textView

        var replacedText = false
        if textView.string != text {
            if textView.hasMarkedText() { return }
            if isEditable, wasFirstResponder, !shouldForce {
                // Do not overwrite in-flight user edits; let delegate drive the binding.
            } else {
                // Preserve selection but clamp it to the new text length
                let previousSelection = textView.clampedSelectedRange()
                if let storage = textView.textStorage {
                    storage.beginEditing()
                    Self.restorePlainTextStyling(
                        for: coordinator.appliedDetectedMarkdownFileLinks,
                        in: storage
                    )
                    storage.endEditing()
                }
                coordinator.appliedDetectedMarkdownFileLinks = []
                coordinator.performExternalReplacement(in: textView) {
                    textView.string = text
                }
                replacedText = true
                textView.setSelectedRange(previousSelection.clamped(to: textView.currentStringLength()))

                // Preserve editor scrolling behavior, but a focused read-only payload update
                // must not jump to the end.
                let shouldAutoScroll = (!wasFirstResponder || !shouldForce) &&
                    (isEditable || !wasFirstResponder)
                if shouldAutoScroll {
                    let nsLen = textView.currentStringLength()
                    textView.scrollRangeToVisible(NSRange(location: nsLen, length: 0))
                }

                // Record that we applied this external tick
                if shouldForce {
                    coordinator.lastAppliedTick = externalUpdateTick
                    // Sync empty state tracker
                    coordinator.wasEmpty = text.isEmpty
                    coordinator.scheduleLayoutStabilization(
                        for: textView,
                        expectedIsEmpty: text.isEmpty,
                        reason: .externalWrite
                    )
                }
            }
        }

        refreshDetectedMarkdownFileLinks(
            in: textView,
            coordinator: coordinator,
            force: replacedText
        )

        // Ensure wrapping mode is still respected with minimal churn
        let shouldBeHorizontallyResizable = !wrapLines
        if textView.isHorizontallyResizable != shouldBeHorizontallyResizable {
            textView.isHorizontallyResizable = shouldBeHorizontallyResizable
        }
        if let container = textView.textContainer {
            if wrapLines {
                if container.widthTracksTextView == false {
                    container.widthTracksTextView = true
                    container.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
                }
            } else {
                if container.widthTracksTextView == true {
                    container.widthTracksTextView = false
                }
                container.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
        }
    }

    private func refreshDetectedMarkdownFileLinks(
        in textView: NSTextView,
        coordinator: Coordinator,
        force: Bool
    ) {
        guard textView.string == text,
              let storage = textView.textStorage
        else { return }

        let desiredMatches = markdownFileLinkOpener == nil ? [] : detectedMarkdownFileLinks
        guard force || coordinator.appliedDetectedMarkdownFileLinks != desiredMatches else { return }

        storage.beginEditing()
        defer { storage.endEditing() }
        Self.restorePlainTextStyling(
            for: coordinator.appliedDetectedMarkdownFileLinks,
            in: storage
        )
        Self.decorateDetectedMarkdownFileLinks(desiredMatches, in: storage)
        coordinator.appliedDetectedMarkdownFileLinks = desiredMatches
    }

    static func restorePlainTextStyling(
        for matches: [MarkdownFilePathLinkDetector.Match],
        in storage: NSMutableAttributedString
    ) {
        for match in matches where NSMaxRange(match.range) <= storage.length {
            storage.removeAttribute(.link, range: match.range)
            storage.removeAttribute(.markdownRawLink, range: match.range)
            storage.removeAttribute(.markdownDetectedFileLink, range: match.range)
            storage.addAttributes([
                .foregroundColor: NSColor.textColor,
                .underlineStyle: 0
            ], range: match.range)
        }
    }

    static func decorateDetectedMarkdownFileLinks(
        _ matches: [MarkdownFilePathLinkDetector.Match],
        in storage: NSMutableAttributedString
    ) {
        for match in matches where NSMaxRange(match.range) <= storage.length {
            storage.addAttributes([
                .link: match.path,
                .markdownRawLink: match.path,
                .markdownDetectedFileLink: true,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)
        }
    }

    private func refreshDefaultParagraphStyle(
        in textView: NSTextView,
        coordinator: Coordinator,
        font: NSFont
    ) {
        guard useMonospacedFont, useTranscriptCodeFont else {
            if coordinator.paragraphStyleSignature != nil {
                textView.defaultParagraphStyle = nil
                coordinator.paragraphStyleSignature = nil
            }
            return
        }

        let signature = Self.paragraphStyleSignature(
            font: font,
            wrapLines: wrapLines
        )
        guard coordinator.paragraphStyleSignature != signature else { return }

        textView.defaultParagraphStyle = Self.codeParagraphStyle(for: signature)
        coordinator.paragraphStyleSignature = signature
    }

    /// Ensure AppKit resources are released when SwiftUI detaches the view
    package static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.delegate = nil
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        coordinator.clearUndoHistory()
        textView.string = ""
        coordinator.internalText = ""
        coordinator.wasEmpty = true
        coordinator.appliedDetectedMarkdownFileLinks = []
        coordinator.pendingLayoutTask?.cancel()
        coordinator.pendingLayoutTask = nil
        // NEW: mark inactive
        coordinator.isActive = false
    }
}
