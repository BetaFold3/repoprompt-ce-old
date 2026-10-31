import Foundation
@testable import RepoPromptGateway
import XCTest

final class PWAResourceTests: XCTestCase {
    func testPackagedResourceLookupResolvesAllRequiredAssets() {
        XCTAssertNotNil(
            GatewayPWAResources.resourceBundle(),
            "The gateway PWA resource bundle must resolve wherever the gateway runs."
        )
        for asset in GatewayPWAResources.requiredAssets {
            let data = GatewayPWAResources.data(forAsset: asset)
            XCTAssertNotNil(data, "Missing packaged PWA asset: \(asset)")
            XCTAssertGreaterThan(data?.count ?? 0, 0, "Packaged PWA asset is empty: \(asset)")
        }
    }

    func testRequiredAssetSetMatchesPlanFileTable() {
        XCTAssertEqual(
            Set(GatewayPWAResources.requiredAssets),
            ["index.html", "app.js", "sw.js", "manifest.webmanifest"]
        )
    }

    func testUnknownAssetDoesNotResolve() {
        XCTAssertNil(GatewayPWAResources.url(forAsset: "secrets.json"))
        XCTAssertNil(GatewayPWAResources.url(forAsset: "../pwa/index.html"))
        XCTAssertNil(GatewayPWAResources.data(forAsset: "evil/../../index.html"))
    }

    func testContentTypesForAssets() {
        XCTAssertEqual(GatewayPWAResources.contentType(forAsset: "index.html"), "text/html; charset=utf-8")
        XCTAssertEqual(GatewayPWAResources.contentType(forAsset: "app.js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(GatewayPWAResources.contentType(forAsset: "sw.js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(
            GatewayPWAResources.contentType(forAsset: "manifest.webmanifest"),
            "application/manifest+json; charset=utf-8"
        )
    }

    func testServerPathMappingServesShellAndAssetsOnly() {
        XCTAssertEqual(GatewayHTTPHandler.pwaAsset(forPath: "/"), "index.html")
        XCTAssertEqual(GatewayHTTPHandler.pwaAsset(forPath: "/index.html"), "index.html")
        XCTAssertEqual(GatewayHTTPHandler.pwaAsset(forPath: "/app.js"), "app.js")
        XCTAssertEqual(GatewayHTTPHandler.pwaAsset(forPath: "/sw.js"), "sw.js")
        XCTAssertEqual(GatewayHTTPHandler.pwaAsset(forPath: "/manifest.webmanifest"), "manifest.webmanifest")
        XCTAssertNil(GatewayHTTPHandler.pwaAsset(forPath: "/healthz"))
        XCTAssertNil(GatewayHTTPHandler.pwaAsset(forPath: "/ws"))
        XCTAssertNil(GatewayHTTPHandler.pwaAsset(forPath: "/../Package.swift"))
        XCTAssertNil(GatewayHTTPHandler.pwaAsset(forPath: "/pwa/index.html"))
    }

    func testServedAssetsNeverUseMarkupOrCodeEvaluatingAPIs() throws {
        let unsafe = try NSRegularExpression(
            pattern: #"innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|new Function|DOMParser|createContextualFragment|setHTMLUnsafe|parseHTMLUnsafe|srcdoc"#
        )
        for asset in GatewayPWAResources.requiredAssets {
            let data = try XCTUnwrap(GatewayPWAResources.data(forAsset: asset), asset)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8), asset)
            let matches = unsafe.matches(in: text, range: NSRange(text.startIndex..., in: text))
            let found = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            XCTAssertEqual(found, [], "PWA asset \(asset) must render agent text through DOM text APIs only")
        }
    }

    func testShellWiresModuleServiceWorkerAndManifest() throws {
        let html = try XCTUnwrap(GatewayPWAResources.data(forAsset: "index.html"))
        let text = try XCTUnwrap(String(data: html, encoding: .utf8))
        XCTAssertTrue(text.contains("./app.js"), "index.html must load the ES module client")
        XCTAssertTrue(text.contains("manifest.webmanifest"), "index.html must link the manifest")
        XCTAssertTrue(
            text.contains("bound window"),
            "The UI must surface that sessions are scoped to the bound window's active workspace"
        )
        XCTAssertTrue(text.contains("<details id=\"activity-panel\" class=\"panel\">"), "Activity starts collapsed")
        XCTAssertTrue(text.contains("<details id=\"transcript-raw\" class=\"disclosure\">"), "Raw transcript starts collapsed")
        XCTAssertFalse(text.contains("aria-live"), "the refreshed transcript is not a live region")
        XCTAssertFalse(text.contains("user-scalable"), "browser zoom stays available")
        let order = try ["id=\"transcript-view\"", "id=\"transcript-nav\"", "id=\"jump-top\"", "id=\"jump-latest\"", "id=\"transcript-raw\""]
            .map { try XCTUnwrap(text.range(of: $0)?.lowerBound, $0) }
        XCTAssertEqual(order, order.sorted(), "Top and Latest follow the transcript, before Raw transcript")
        let composer = try ["<textarea id=\"composer-input\"", "<button id=\"composer-send\">"]
            .map { try XCTUnwrap(text.range(of: $0)?.lowerBound, $0) }
        XCTAssertLessThan(composer[0], composer[1], "Send follows the text box in its row")
        /// The body of the stylesheet rule that starts a line with `selector`.
        func rule(_ selector: String) throws -> String {
            let start = try XCTUnwrap(text.range(of: "\n\(selector) {"), selector)
            let end = try XCTUnwrap(text.range(of: "}", range: start.upperBound ..< text.endIndex), selector)
            return String(text[start.upperBound ..< end.lowerBound])
        }
        // The row never wraps, the text box may shrink below its intrinsic width, and Send keeps its size.
        let row = try rule(".composer-row")
        XCTAssertTrue(row.contains("display: flex") && !row.contains("wrap"), row)
        let input = try rule("#composer-input")
        XCTAssertTrue(input.contains("flex: 1; min-width: 0;"), input)
        let send = try rule("#composer-send")
        XCTAssertTrue(send.contains("flex: none"), send)

        let appJS = try XCTUnwrap(GatewayPWAResources.data(forAsset: "app.js"))
        let appText = try XCTUnwrap(String(data: appJS, encoding: .utf8))
        XCTAssertTrue(appText.contains("./sw.js"), "app.js must register the service worker")
        XCTAssertTrue(appText.contains("push_subscribe"), "app.js must register push subscriptions")
        XCTAssertTrue(appText.contains("binding_required"), "app.js must surface binding_required")
        XCTAssertTrue(
            appText.contains("case 'interaction_resolved'") && appText.contains("detectSeqGap(frame)"),
            "app.js must include interaction_resolved frames in per-session seq tracking"
        )
    }
}
