import AppKit
@testable import RepoPromptApp
import XCTest

/// Lossless restart Step 8: the recovery banner's View popover closes on an outside click without
/// swallowing it, so one click both dismisses the popover and reaches what was clicked.
final class AgentRecoveryNativePopoverEventDecisionTests: XCTestCase {
    private func decide(
        mouseDown: Bool = false,
        escape: Bool = false,
        inPopover: Bool = false,
        inAnchorWindow: Bool = false,
        onAnchor: Bool = false
    ) -> AgentRecoveryNativePopoverEventDecision {
        .decide(
            isMouseDown: mouseDown,
            isEscapeKey: escape,
            isInPopoverWindow: inPopover,
            isInAnchorWindow: inAnchorWindow,
            isOnAnchor: onAnchor
        )
    }

    func testOutsideClickClosesAndIsDelivered() {
        XCTAssertEqual(decide(mouseDown: true), .closeAndDeliver)
        XCTAssertEqual(decide(mouseDown: true, inAnchorWindow: true), .closeAndDeliver)
    }

    func testClickInsidePopoverKeepsItOpen() {
        XCTAssertEqual(decide(mouseDown: true, inPopover: true), .ignore)
    }

    func testClickOnAnchorTogglesClosedWithoutReopening() {
        XCTAssertEqual(decide(mouseDown: true, inAnchorWindow: true, onAnchor: true), .closeAndConsume)
    }

    func testEscapeInPopoverCloses() {
        XCTAssertEqual(decide(escape: true, inPopover: true), .closeAndConsume)
    }

    /// Verifier P5 (9-live R6): the popover never becomes the key window, so Escape arrives in the
    /// anchor's window (the composer's window, or the Needs Attention sheet). It closes the popover
    /// and is swallowed, so neither the composer nor the sheet acts on that press.
    func testEscapeInAnchorWindowClosesAndIsConsumed() {
        XCTAssertEqual(decide(escape: true, inAnchorWindow: true), .closeAndConsume)
    }

    func testEscapeInAnUnrelatedWindowIsIgnored() {
        XCTAssertEqual(decide(escape: true), .ignore)
    }

    func testOtherKeysAreIgnored() {
        XCTAssertEqual(decide(inAnchorWindow: true), .ignore)
        XCTAssertEqual(decide(inPopover: true), .ignore)
        XCTAssertEqual(decide(), .ignore)
    }

    /// Verifier cycle 11: the popover opens outside its rows' region (banner: above it; sheet:
    /// beside it), positioned against the whole region so any edge AppKit picks stays outside.
    private typealias Region = AgentRecoveryNativePopoverRegion
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let popover = NSSize(width: 360, height: 280)

    func testRegionPlacementPrefersTheRequestedEdgeWhenTheScreenHasRoom() {
        let banner = NSRect(x: 300, y: 120, width: 800, height: 180)
        XCTAssertEqual(Region.placement(region: banner, popover: popover, visibleFrame: screen, preferredEdge: .maxY), .region(.maxY))
        let sheet = NSRect(x: 410, y: 300, width: 620, height: 500)
        XCTAssertEqual(Region.placement(region: sheet, popover: popover, visibleFrame: screen, preferredEdge: .maxX), .region(.maxX))
    }

    func testRegionPlacementUsesTheOppositeEdgeWhenOnlyThatHasRoom() {
        // A sheet near the screen's right edge: no room beside it on the right, enough on the left.
        let sheet = NSRect(x: 780, y: 300, width: 620, height: 500)
        XCTAssertEqual(Region.placement(region: sheet, popover: popover, visibleFrame: screen, preferredEdge: .maxX), .region(.minX))
        // A banner near the top of the screen: no room above, enough below.
        let banner = NSRect(x: 300, y: 600, width: 800, height: 180)
        XCTAssertEqual(Region.placement(region: banner, popover: popover, visibleFrame: screen, preferredEdge: .maxY), .region(.minY))
    }

    func testRegionPlacementUsesAnEdgeAtRightAnglesWhenOnlyThatHasRoom() {
        // Re-review VF-R1-1: a 620-pt sheet centred on a 1280-pt display leaves 330 pt on each
        // side, too little for the popover; below it, under the title bar, there is room.
        let laptop = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let sheet = NSRect(x: 330, y: 380, width: 620, height: 400)
        XCTAssertEqual(Region.placement(region: sheet, popover: popover, visibleFrame: laptop, preferredEdge: .maxX), .region(.minY))
        // A banner filling the screen's height, with room only on its leading side.
        let banner = NSRect(x: 400, y: 0, width: 1040, height: 900)
        XCTAssertEqual(Region.placement(region: banner, popover: popover, visibleFrame: screen, preferredEdge: .maxY), .region(.minX))
    }

    func testRegionPlacementFallsBackToTheAnchorWhenNoSideHasRoom() {
        // A minimum-width sheet on a small display: no room on any side.
        let small = NSRect(x: 0, y: 0, width: 1024, height: 700)
        let sheet = NSRect(x: 200, y: 100, width: 620, height: 500)
        XCTAssertEqual(Region.placement(region: sheet, popover: popover, visibleFrame: small, preferredEdge: .maxX), .anchor)
        // A banner filling the screen's height.
        let banner = NSRect(x: 0, y: 0, width: 1024, height: 700)
        XCTAssertEqual(Region.placement(region: banner, popover: popover, visibleFrame: small, preferredEdge: .maxY), .anchor)
    }

    func testRegionPlacementCountsTheArrowAndBorder() {
        let exactFit = NSRect(x: 0, y: 0, width: 1440, height: 900 - popover.height - Region.popoverChrome)
        XCTAssertEqual(Region.placement(region: exactFit, popover: popover, visibleFrame: screen, preferredEdge: .maxY), .region(.maxY))
        let onePointShort = NSRect(x: 0, y: 1, width: 1440, height: exactFit.height)
        XCTAssertEqual(Region.placement(region: onePointShort, popover: popover, visibleFrame: screen, preferredEdge: .maxY), .anchor)
    }
}
