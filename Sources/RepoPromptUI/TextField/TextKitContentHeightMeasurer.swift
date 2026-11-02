import AppKit

/// Synchronous, read-only height measurement for opt-in `TextKitView` content fitting.
///
/// Builds a private TextKit 1 stack with the same font, paragraph style, line-fragment padding,
/// text-container inset, and wrap geometry as the live text view, so measurement never mutates
/// the displayed view's selection, scroll position, or layout. Results are capped at the
/// caller's maximum height; inputs that cannot be measured cheaply return that maximum
/// (the pre-fitting fixed-height behavior) instead of guessing.
package enum TextKitContentHeightMeasurer {
    /// Inputs above this UTF-16 length skip layout and return the cap. Conservative engineering
    /// bound chosen so a single synchronous layout stays small; not derived from a benchmark.
    package static let measurementUTF16Limit = 16384
    /// Upper bound on cached measurements. Conservative engineering bound, not benchmark-derived.
    package static let cacheCountLimit = 128

    package enum Reason: Equatable {
        /// Content was laid out and fits under the cap.
        case fitted
        /// Content was laid out (or counted) and exceeds the cap.
        case capped
        /// Width was missing, non-finite, or too narrow to lay out a glyph.
        case fallbackInvalidWidth
        /// Input exceeded `measurementUTF16Limit`; layout was skipped.
        case fallbackLargeInput
    }

    package struct Result: Equatable {
        /// Final view height, already capped at the requested maximum.
        package let height: CGFloat
        package let reason: Reason
    }

    /// Scroll-view chrome that affects the text container's width and the view's total height.
    package struct ScrollChrome: Equatable {
        package var borderType: NSBorderType
        package var scrollerStyle: NSScroller.Style
        /// True only when a vertical scroller occupies layout width even when content fits.
        package var reservesVerticalScroller: Bool
        /// True when a horizontal scroller may occupy layout height (non-wrapping text).
        package var reservesHorizontalScroller: Bool
        package var lineFragmentPadding: CGFloat

        package init(
            borderType: NSBorderType = .noBorder,
            scrollerStyle: NSScroller.Style = .overlay,
            reservesVerticalScroller: Bool = false,
            reservesHorizontalScroller: Bool = false,
            lineFragmentPadding: CGFloat = 5
        ) {
            self.borderType = borderType
            self.scrollerStyle = scrollerStyle
            self.reservesVerticalScroller = reservesVerticalScroller
            self.reservesHorizontalScroller = reservesHorizontalScroller
            self.lineFragmentPadding = lineFragmentPadding
        }

        /// Reads (never mutates) the live scroll view's current chrome.
        @MainActor
        package init(scrollView: NSScrollView) {
            let textView = scrollView.documentView as? NSTextView
            self.init(
                borderType: scrollView.borderType,
                scrollerStyle: scrollView.scrollerStyle,
                // Auto-hiding scrollers only appear when content overflows, and overflowing
                // content is capped anyway, so they never narrow fitted content.
                reservesVerticalScroller: scrollView.hasVerticalScroller && !scrollView.autohidesScrollers,
                reservesHorizontalScroller: scrollView.hasHorizontalScroller,
                lineFragmentPadding: textView?.textContainer?.lineFragmentPadding ?? 5
            )
        }
    }

    private final class CachedHeight: NSObject {
        let result: Result

        init(_ result: Result) {
            self.result = result
        }
    }

    private static let cache: NSCache<NSString, CachedHeight> = {
        let cache = NSCache<NSString, CachedHeight>()
        cache.countLimit = cacheCountLimit
        return cache
    }()

    /// Height for `text` in a scroll view of `frameWidth`, capped at `maxHeight`.
    ///
    /// - Parameters:
    ///   - paragraphStyle: The paragraph style the live view applies (`nil` = AppKit default).
    ///   - textContainerInset: The live text view's `textContainerInset`.
    package static func fittedHeight(
        text: String,
        font: NSFont,
        paragraphStyle: NSParagraphStyle?,
        wrapLines: Bool,
        frameWidth: CGFloat?,
        textContainerInset: NSSize,
        chrome: ScrollChrome,
        maxHeight: CGFloat
    ) -> Result {
        let cap = max(maxHeight, 0)
        guard let frameWidth, frameWidth.isFinite, frameWidth > 0 else {
            return Result(height: cap, reason: .fallbackInvalidWidth)
        }
        // Flooring makes the measured width never wider than the real one, so wrapped
        // height is never underestimated, and stabilizes the cache key.
        let width = (frameWidth * 2).rounded(.down) / 2
        let probeSize = NSSize(width: width, height: 10000)
        let contentSize = NSScrollView.contentSize(
            forFrameSize: probeSize,
            horizontalScrollerClass: chrome.reservesHorizontalScroller ? NSScroller.self : nil,
            verticalScrollerClass: chrome.reservesVerticalScroller ? NSScroller.self : nil,
            borderType: chrome.borderType,
            controlSize: .regular,
            scrollerStyle: chrome.scrollerStyle
        )
        let chromeHeight = max(probeSize.height - contentSize.height, 0)
        // `widthTracksTextView` sizes the container to the text view width minus both insets;
        // line-fragment padding lives inside the container and is not subtracted again.
        let containerWidth = contentSize.width - 2 * textContainerInset.width
        guard containerWidth - 2 * chrome.lineFragmentPadding >= 1 else {
            return Result(height: cap, reason: .fallbackInvalidWidth)
        }

        let utf16Count = text.utf16.count
        guard utf16Count <= measurementUTF16Limit else {
            return Result(height: cap, reason: .fallbackLargeInput)
        }

        let fixedHeight = 2 * textContainerInset.height + chromeHeight
        if let minimumLineHeight = paragraphStyle?.minimumLineHeight, minimumLineHeight > 0 {
            // Every hard line is at least one pinned line tall; enough of them caps without layout.
            let maxLines = Int(((cap - fixedHeight) / minimumLineHeight).rounded(.down))
            if maxLines >= 0, hardLineCount(in: text, stoppingAfter: maxLines) > maxLines {
                return Result(height: cap, reason: .capped)
            }
        }

        let key = cacheKey(
            text: text,
            font: font,
            paragraphStyle: paragraphStyle,
            wrapLines: wrapLines,
            containerWidth: containerWidth,
            padding: chrome.lineFragmentPadding,
            fixedHeight: fixedHeight,
            cap: cap
        )
        if let cached = cache.object(forKey: key) {
            return cached.result
        }

        let textHeight = layoutHeight(
            text: text,
            font: font,
            paragraphStyle: paragraphStyle,
            wrapLines: wrapLines,
            containerWidth: containerWidth,
            lineFragmentPadding: chrome.lineFragmentPadding
        )
        let total = (textHeight + fixedHeight).rounded(.up)
        let result = total > cap
            ? Result(height: cap, reason: .capped)
            : Result(height: total, reason: .fitted)
        cache.setObject(CachedHeight(result), forKey: key)
        return result
    }

    /// Used-rect height of `text` laid out in a private TextKit 1 stack.
    static func layoutHeight(
        text: String,
        font: NSFont,
        paragraphStyle: NSParagraphStyle?,
        wrapLines: Bool,
        containerWidth: CGFloat,
        lineFragmentPadding: CGFloat
    ) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle ?? NSParagraphStyle.default
        ]
        // An empty storage has no attributes, so its extra line fragment would use AppKit's
        // default font rather than the view's; a single space measures that line faithfully.
        let storage = NSTextStorage(string: text.isEmpty ? " " : text, attributes: attributes)
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = true
        layoutManager.allowsNonContiguousLayout = false
        let container = NSTextContainer(size: NSSize(
            width: wrapLines ? containerWidth : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = lineFragmentPadding
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height.rounded(.up)
    }

    /// Hard (newline-delimited) line count, stopping early once it exceeds `limit`.
    static func hardLineCount(in text: String, stoppingAfter limit: Int) -> Int {
        var count = 1
        for unit in text.utf16 where unit == 0x0A {
            count += 1
            if count > limit {
                return count
            }
        }
        return count
    }

    private static func cacheKey(
        text: String,
        font: NSFont,
        paragraphStyle: NSParagraphStyle?,
        wrapLines: Bool,
        containerWidth: CGFloat,
        padding: CGFloat,
        fixedHeight: CGFloat,
        cap: CGFloat
    ) -> NSString {
        let style = paragraphStyle.map {
            "\($0.minimumLineHeight),\($0.maximumLineHeight),\($0.lineSpacing),\($0.lineBreakMode.rawValue),\($0.defaultTabInterval)"
        } ?? "default"
        let header = [
            font.fontName,
            "\(font.pointSize)",
            style,
            wrapLines ? "w" : "c",
            "\(containerWidth)",
            "\(padding)",
            "\(fixedHeight)",
            "\(cap)"
        ].joined(separator: "|")
        return "\(header)\u{0}\(text)" as NSString
    }
}
