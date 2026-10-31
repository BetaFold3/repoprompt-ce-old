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
            pattern: #"innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|new Function"#
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
