import CoreGraphics
@testable import RepoPromptAgentCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Rich presentation spec Step 4 rendering bounds: the decoded-image cache is cost-bounded LRU,
/// invalid bytes never decode, and the briefing switches to two columns only at 760 pt.
@MainActor
final class RichPresentationRenderingTests: XCTestCase {
    func testDecodedImageCacheEvictsLeastRecentlyUsedByCostAndRejectsOversizedImages() throws {
        let unit = try decodedImage(width: 8, height: 8)
        var cache = RichPresentationDecodedImageCache<Int>(maxCost: unit.cost * 2)
        cache.insert(unit, for: 1)
        try cache.insert(decodedImage(width: 8, height: 8), for: 2)
        XCTAssertNotNil(cache.value(for: 1), "Touching 1 makes 2 the least recently used")
        try cache.insert(decodedImage(width: 8, height: 8), for: 3)
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(for: 2))
        XCTAssertNotNil(cache.value(for: 1))
        XCTAssertNotNil(cache.value(for: 3))
        XCTAssertLessThanOrEqual(cache.totalCost, cache.maxCost)

        let oversized = try decodedImage(width: 64, height: 64)
        XCTAssertGreaterThan(oversized.cost, cache.maxCost)
        cache.insert(oversized, for: 4)
        XCTAssertNil(cache.value(for: 4), "An image costlier than the whole budget is not cached")
        XCTAssertEqual(cache.count, 2)

        // Replacing a key adjusts the total instead of double counting.
        try cache.insert(decodedImage(width: 8, height: 8), for: 1)
        XCTAssertEqual(cache.totalCost, unit.cost * 2)
        XCTAssertEqual(RichPresentationHistoryLoader.maxDecodedImageBytes, 32 * 1024 * 1024)
        XCTAssertEqual(RichPresentationHistoryLoader.maxConcurrentDecodes, 1)
        XCTAssertEqual(RichPresentationHistoryLoader.maxConcurrentLocalReads, 2)
    }

    func testDecodeRejectsNonImageBytes() {
        XCTAssertNil(RichPresentationHistoryLoader.decode(Data("not an image".utf8)))
        XCTAssertNil(RichPresentationHistoryLoader.decode(Data()))
    }

    func testBriefingUsesTwoColumnsOnlyFromSevenHundredSixtyPoints() {
        XCTAssertEqual(RichPresentationBriefingView.columnCount(forWidth: 0), 1)
        XCTAssertEqual(RichPresentationBriefingView.columnCount(forWidth: 759.9), 1)
        XCTAssertEqual(RichPresentationBriefingView.columnCount(forWidth: 760), 2)
        XCTAssertEqual(RichPresentationBriefingView.columnCount(forWidth: 1100), 2)
    }

    func testMissingOwnerYieldsUnavailableWithoutReading() async {
        let loader = RichPresentationHistoryLoader()
        let reference = RichPresentationReference(
            artifactID: UUID(), kind: .chart, title: "Rates", fallbackText: "Rich presentation summary: Rates"
        )
        let state = await loader.manifest(for: reference, owner: nil)
        XCTAssertEqual(state, .unavailable)
        let image = await loader.image(assetID: UUID(), reference: reference, owner: nil)
        XCTAssertNil(image)
        XCTAssertEqual(loader.test_manifestReadCount, 0)
        XCTAssertEqual(loader.test_assetReadCount, 0)
    }

    private func decodedImage(width: Int, height: Int) throws -> RichPresentationHistoryLoader.DecodedImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        return try RichPresentationHistoryLoader.DecodedImage(image: XCTUnwrap(context.makeImage()))
    }
}
