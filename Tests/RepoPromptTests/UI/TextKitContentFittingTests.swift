import AppKit
@testable import RepoPromptUI
import SwiftUI
import XCTest

@MainActor
final class TextKitContentFittingTests: XCTestCase {
    private typealias Measurer = TextKitContentHeightMeasurer
    private let cap: CGFloat = 200
    private let overlayChrome = TextKitContentHeightMeasurer.ScrollChrome()

    private func fittingView(
        _ text: String,
        fontSize: Double = 11,
        transcriptCodeFont: Bool = true,
        wrapLines: Bool = true,
        maxHeight: CGFloat? = 200
    ) -> TextKitView {
        TextKitView(
            text: .constant(text),
            isEditable: false,
            fontSize: fontSize,
            useMonospacedFont: transcriptCodeFont,
            useTranscriptCodeFont: transcriptCodeFont,
            wrapLines: wrapLines,
            autohidesScrollers: true,
            scrollerStyle: .overlay,
            contentFittingMaxHeight: maxHeight
        )
    }

    private func measure(_ view: TextKitView, width: CGFloat?) throws -> Measurer.Result {
        try XCTUnwrap(view.contentFittingMeasurement(proposedWidth: width, chrome: overlayChrome))
    }

    private func lineHeight(pointSize: CGFloat = 11) -> CGFloat {
        TranscriptCodeFontResolver.resolve(preferredPostScriptName: nil, pointSize: pointSize).minimumLineHeight
    }

    private var verticalInsets: CGFloat {
        2 * TextKitView.textContainerInset.height
    }

    func testDefaultTextKitViewDoesNotOptIntoFitting() {
        let view = TextKitView(text: .constant("docs/report.md"))

        XCTAssertNil(view.contentFittingMaxHeight)
        XCTAssertNil(view.contentFittingMeasurement(proposedWidth: 300, chrome: overlayChrome))
        XCTAssertNil(fittingView("x", maxHeight: nil).contentFittingMeasurement(proposedWidth: 300, chrome: overlayChrome))
    }

    func testShortContentFitsBelowCapUsingResolvedLineMetrics() throws {
        let result = try measure(fittingView("{ \"id\": \"short\" }"), width: 400)

        XCTAssertEqual(result.reason, .fitted)
        XCTAssertEqual(result.height, lineHeight() + verticalInsets)
        XCTAssertLessThan(result.height, cap)
    }

    func testTallContentCapsAtExistingMaximum() throws {
        let manyLines = (1 ... 80).map { "line \($0)" }.joined(separator: "\n")
        let byLines = try measure(fittingView(manyLines), width: 400)
        XCTAssertEqual(byLines, .init(height: cap, reason: .capped))

        let longWrappedLine = String(repeating: "token ", count: 600)
        let byWrapping = try measure(fittingView(longWrappedLine), width: 240)
        XCTAssertEqual(byWrapping, .init(height: cap, reason: .capped))
    }

    func testWrapSettingAndNarrowWidthsDriveHeight() throws {
        let line = String(repeating: "abcdefgh ", count: 10)
        let wide = try measure(fittingView(line), width: 900)
        let narrow = try measure(fittingView(line), width: 220)
        let unwrapped = try measure(fittingView(line, wrapLines: false), width: 220)

        XCTAssertEqual(wide.height, lineHeight() + verticalInsets)
        XCTAssertGreaterThan(narrow.height, wide.height)
        XCTAssertEqual(narrow.reason, .fitted)
        XCTAssertEqual(unwrapped.height, lineHeight() + verticalInsets, "No-wrap keeps one line and scrolls horizontally")
    }

    func testCustomFontSizeAndDefaultParagraphStyleAreMeasured() throws {
        let text = "alpha\nbeta"
        let small = try measure(fittingView(text, fontSize: 11), width: 400)
        let large = try measure(fittingView(text, fontSize: 18), width: 400)
        XCTAssertEqual(small.height, 2 * lineHeight(pointSize: 11) + verticalInsets)
        XCTAssertEqual(large.height, 2 * lineHeight(pointSize: 18) + verticalInsets)

        let systemFont = fittingView(text, fontSize: 13, transcriptCodeFont: false)
        XCTAssertNil(systemFont.resolvedParagraphStyle(font: NSFont.systemFont(ofSize: 13)))
        let native = try nativeLayoutHeight(for: systemFont, frameWidth: 400)
        XCTAssertEqual(try measure(systemFont, width: 400).height, native)
    }

    func testNewlinesAndUnicodeCountEveryLine() throws {
        let trailingNewlines = try measure(fittingView("a\n\nb\n"), width: 400)
        XCTAssertEqual(trailingNewlines.height, 4 * lineHeight() + verticalInsets)

        let empty = try measure(fittingView(""), width: 400)
        XCTAssertEqual(empty.height, lineHeight() + verticalInsets)

        let unicode = fittingView("😀 前置 資料/報告.html\n{\n  \"id\": \"規格-\(String(repeating: "é", count: 40))\"\n}")
        XCTAssertEqual(try measure(unicode, width: 180).height, try nativeLayoutHeight(for: unicode, frameWidth: 180))
    }

    func testLargeInputFallsBackToCapWithoutLayout() throws {
        let large = String(repeating: "x", count: Measurer.measurementUTF16Limit + 1)
        XCTAssertEqual(
            try measure(fittingView(large, wrapLines: false), width: 400),
            .init(height: cap, reason: .fallbackLargeInput)
        )
    }

    func testInvalidWidthsFallBackToCap() throws {
        let view = fittingView("short")
        let widths: [CGFloat?] = [nil, 0, -5, CGFloat.infinity, CGFloat.nan, 20]
        for width in widths {
            XCTAssertEqual(
                try measure(view, width: width),
                .init(height: cap, reason: .fallbackInvalidWidth),
                "width \(String(describing: width))"
            )
        }
    }

    func testReservedLegacyScrollerNeverUnderestimatesHeight() throws {
        let view = fittingView(String(repeating: "wrap me ", count: 30), maxHeight: 400)
        let overlay = try measure(view, width: 260)
        let legacy = try XCTUnwrap(view.contentFittingMeasurement(
            proposedWidth: 260,
            chrome: .init(scrollerStyle: .legacy, reservesVerticalScroller: true, reservesHorizontalScroller: true)
        ))

        XCTAssertGreaterThanOrEqual(legacy.height, overlay.height)
    }

    func testMeasurementMatchesNativeTextViewLayout() throws {
        let samples = [
            "short",
            "a\nb\nc\n",
            String(repeating: "lorem ipsum dolor ", count: 12),
            "tab\there\n\n\nend",
            "{\n  \"id\": \"evt_\(String(repeating: "0123456789abcdef", count: 4))\"\n}"
        ]
        for wrap in [true, false] {
            for width in [160, 320, 640] as [CGFloat] {
                for sample in samples {
                    let view = fittingView(sample, wrapLines: wrap, maxHeight: 2000)
                    XCTAssertEqual(
                        try measure(view, width: width).height,
                        try nativeLayoutHeight(for: view, frameWidth: width),
                        "wrap=\(wrap) width=\(width) sample=\(sample.prefix(16))"
                    )
                }
            }
        }
    }

    func testFittedSizeReportsFiniteSizesOnlyForConcreteWidths() {
        let view = fittingView("short")
        let fitted = lineHeight() + verticalInsets

        XCTAssertNil(view.fittedSize(for: .unspecified, chrome: overlayChrome))
        XCTAssertNil(view.fittedSize(for: .infinity, chrome: overlayChrome))
        XCTAssertNil(view.fittedSize(for: ProposedViewSize(width: CGFloat.infinity, height: nil), chrome: overlayChrome))
        XCTAssertNil(view.fittedSize(for: ProposedViewSize(width: CGFloat.nan, height: 50), chrome: overlayChrome))
        XCTAssertEqual(view.fittedSize(for: .zero, chrome: overlayChrome), CGSize(width: 0, height: cap))
        XCTAssertEqual(
            view.fittedSize(for: ProposedViewSize(width: -4, height: nil), chrome: overlayChrome),
            CGSize(width: 0, height: cap)
        )
        XCTAssertEqual(
            view.fittedSize(for: ProposedViewSize(width: 400, height: nil), chrome: overlayChrome),
            CGSize(width: 400, height: fitted)
        )
        XCTAssertEqual(
            view.fittedSize(for: ProposedViewSize(width: 400, height: 5), chrome: overlayChrome),
            CGSize(width: 400, height: fitted),
            "Proposed height does not change the fitted content height"
        )
        for proposal in [ProposedViewSize.unspecified, .infinity, .zero, ProposedViewSize(width: 400, height: nil)] {
            XCTAssertNil(
                TextKitView(text: .constant("short")).fittedSize(for: proposal, chrome: overlayChrome),
                "Default-off views keep SwiftUI's default sizing"
            )
        }
    }

    func testHostedFittingTracksWidthAndContentWithoutWindow() throws {
        let line = String(repeating: "abcdefgh ", count: 10)
        let manyLines = (1 ... 80).map { "line \($0)" }.joined(separator: "\n")
        func hosted(_ view: TextKitView, width: CGFloat) -> AnyView {
            AnyView(view.fixedSize(horizontal: false, vertical: true).frame(width: width))
        }
        let wide = try measure(fittingView(line), width: 900).height
        let host = NSHostingView(rootView: hosted(fittingView(line), width: 900))
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window, "Measured offscreen; no window is shown")
        XCTAssertEqual(host.fittingSize.height, wide, accuracy: 0.5)

        host.rootView = hosted(fittingView(line), width: 220)
        host.layoutSubtreeIfNeeded()
        let narrow = try measure(fittingView(line), width: 220).height
        XCTAssertGreaterThan(narrow, lineHeight() + verticalInsets)
        XCTAssertEqual(host.fittingSize.height, narrow, accuracy: 0.5)

        host.rootView = hosted(fittingView(manyLines), width: 220)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, cap, accuracy: 0.5)
    }

    func testHardLineCountStopsEarly() {
        XCTAssertEqual(Measurer.hardLineCount(in: "", stoppingAfter: 10), 1)
        XCTAssertEqual(Measurer.hardLineCount(in: "a\nb\n", stoppingAfter: 10), 3)
        XCTAssertEqual(Measurer.hardLineCount(in: String(repeating: "\n", count: 1000), stoppingAfter: 4), 5)
    }

    /// Lays `view`'s text out in a real `TextKitView`-configured NSTextView and returns the
    /// height (used rect plus insets) the scroll view needs to show it without scrolling.
    private func nativeLayoutHeight(for view: TextKitView, frameWidth: CGFloat) throws -> CGFloat {
        let coordinator = TextKitView.Coordinator(view)
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.frame = NSRect(x: 0, y: 0, width: frameWidth, height: 2000)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        view.setupTextView(textView, coordinator: coordinator)
        scrollView.tile()
        textView.frame.size.width = scrollView.contentSize.width
        let container = try XCTUnwrap(textView.textContainer)
        if view.wrapLines {
            // Mirror `widthTracksTextView`, which AppKit applies during a live layout pass.
            container.containerSize = NSSize(
                width: textView.frame.width - 2 * TextKitView.textContainerInset.width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height.rounded(.up) + verticalInsets
    }
}
