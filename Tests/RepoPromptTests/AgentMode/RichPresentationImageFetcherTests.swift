import CoreGraphics
import Foundation
import ImageIO
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import UniformTypeIdentifiers
import XCTest

/// Step 2 of docs/context/specs/2026-11-04-rich-presentation-spec.md.
///
/// Evidence classes, kept distinct:
/// - **URLSession fixture**: the production `RichPresentationImageFetcher` and its real ephemeral
///   `URLSession` configuration and delegates, with only `protocolClasses` replaced by
///   `RichPresentationImageFixtureTransport` (a `URLProtocol`). This exercises actual URLSession
///   request construction, cookie/credential/cache isolation, redirect and challenge delegation,
///   streaming and cancellation. It does not exercise TLS, DNS, proxies, HTTP framing or
///   Content-Encoding, and nothing leaves the process (no public external fetch).
/// - **Mock decoder**: an injected gated decoder, used only to control native-decode timing.
/// - **Real ImageIO**: real JPEG/PNG/APNG/GIF/TIFF bytes produced and parsed by ImageIO.
final class RichPresentationImageFetcherTests: XCTestCase {
    private static let host = "images.example.com"

    override func setUp() {
        super.setUp()
        RichPresentationImageFixtureTransport.state.reset()
    }

    override func tearDown() {
        RichPresentationImageFixtureTransport.state.reset()
        super.tearDown()
    }

    // MARK: - Hosts, URL bytes and stored values (URLSession fixture)

    func testApprovedRequestKeepsExactURLBytesOnlyInTheRequestAndStoresSanitizedOrigin() async throws {
        let jpeg = Self.encode(Self.solidImage(width: 40, height: 20), type: .jpeg)
        let state = RichPresentationImageFixtureTransport.state
        state.setBehavior { _ in .respond(status: 200, headers: ["Content-Type": "image/jpeg"], chunks: [jpeg]) }
        let signedURL = "https://images.example.com:443/news/photo.jpg?X-Amz-Signature=ab%2Fcd%3D&expires=17&x=%E2%9C%93"
        let input = Self.briefing(imageURLs: [signedURL], credit: "Wire photo")

        let results = try await makeFetcher().fetchImages(for: input, approvedHosts: [Self.host])

        let request = try XCTUnwrap(state.requests.first)
        XCTAssertEqual(state.requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, signedURL, "the request must carry the supplied bytes, signed query included")
        XCTAssertEqual(request.httpMethod, "GET")
        for header in ["Cookie", "Authorization", "Referer", "Proxy-Authorization"] {
            XCTAssertNil(request.value(forHTTPHeaderField: header), header)
        }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "image/jpeg, image/png")

        let result = try XCTUnwrap(results.first)
        guard case let .asset(asset) = result.outcome.outcome else {
            return XCTFail("expected an asset, got \(result.outcome.outcome)")
        }
        XCTAssertEqual(asset.origin, "https://images.example.com")
        XCTAssertEqual([asset.width, asset.height], [40, 20])
        XCTAssertEqual(asset.alt, "Alt 0")
        XCTAssertEqual(asset.credit, "Wire photo")
        XCTAssertEqual(try RichPresentationImageNormalizer.completeFormat(of: XCTUnwrap(result.jpegData)), .jpeg)
        XCTAssertNil(result.outcome.warning)

        let stored = try String(decoding: JSONEncoder().encode(result.outcome), as: UTF8.self)
        for leaked in ["X-Amz", "Signature", "expires", "/news", "photo.jpg", ":443", "?"] {
            XCTAssertFalse(stored.contains(leaked), "stored outcome leaked \(leaked): \(stored)")
        }
    }

    func testURLAndHostRejectionsAreTerminalWithoutAnyRequest() async throws {
        let cases: [(url: String, approved: [String], code: RichPresentationImageFailureCode)] = [
            ("https://cdn.example.com/a.jpg", [Self.host], .hostNotApproved),
            ("https://sub.images.example.com/a.jpg", [Self.host], .hostNotApproved),
            ("https://images.example.com/a.jpg", [], .hostNotApproved),
            ("http://images.example.com/a.jpg", [Self.host], .invalidURL),
            ("https://images.example.com:8443/a.jpg", [Self.host], .invalidURL),
            ("https://user:pw@images.example.com/a.jpg", [Self.host], .invalidURL),
            ("https://93.184.216.34/a.jpg", ["93.184.216.34"], .invalidURL),
            ("https://[::1]/a.jpg", [Self.host], .invalidURL),
            ("https://localhost/a.jpg", ["localhost"], .invalidURL),
            ("https://images.example.com\\@evil.example/a.jpg", [Self.host], .invalidURL),
            // Characters URL(string:) would silently percent-encode: the request bytes would differ.
            ("https://images.example.com/a|b.jpg?sig=x", [Self.host], .invalidURL),
            ("https://images.example.com/a.jpg?sig={x}", [Self.host], .invalidURL),
            ("https://images.example.com/a.jpg?q=\"x\"", [Self.host], .invalidURL),
            ("", [Self.host], .invalidURL)
        ]
        let fetcher = makeFetcher()
        for testCase in cases {
            let results = try await fetcher.fetchImages(for: Self.briefing(imageURLs: [testCase.url]), approvedHosts: testCase.approved)
            XCTAssertEqual(results.map(\.outcome.outcome), [.failed(testCase.code)], testCase.url)
            XCTAssertEqual(results.first?.outcome.warning, RichPresentationWarning(sectionIndex: 0, articleIndex: 0, code: testCase.code))
            XCTAssertNil(results.first?.jpegData)
        }
        XCTAssertTrue(RichPresentationImageFixtureTransport.state.requests.isEmpty)
    }

    func testMixedFailuresStayPerArticleInDocumentOrderAndChartsFetchNothing() async throws {
        let jpeg = Self.encode(Self.solidImage(width: 8, height: 8), type: .jpeg)
        RichPresentationImageFixtureTransport.state.setBehavior { request in
            request.url?.path == "/ok.jpg"
                ? .respond(status: 200, headers: ["Content-Type": "image/jpeg"], chunks: [jpeg])
                : .respond(status: 404, headers: ["Content-Type": "text/html"], chunks: [Data("missing".utf8)])
        }
        let article = { (index: Int, url: String?) in
            RichPresentationArticle(
                headline: "Headline \(index)",
                body: "Body \(index)",
                sources: [RichPresentationSource(label: "Desk")],
                image: url.map { RichPresentationImageRequest(url: $0, alt: "Alt \(index)") }
            )
        }
        let input = RichPresentationInput(title: "Morning", content: .briefing(RichPresentationBriefing(date: "2026-11-05", sections: [
            RichPresentationSection(heading: "One", articles: [article(0, "https://images.example.com/ok.jpg"), article(1, nil)]),
            RichPresentationSection(heading: "Two", articles: [
                article(2, "https://images.example.com/gone.jpg"),
                article(3, "https://other.example.com/x.jpg")
            ])
        ])))
        let fetcher = makeFetcher()

        let results = try await fetcher.fetchImages(for: input, approvedHosts: [Self.host])

        XCTAssertEqual(results.map(\.outcome.sectionIndex), [0, 1, 1])
        XCTAssertEqual(results.map(\.outcome.articleIndex), [0, 0, 1])
        guard case .asset = results[0].outcome.outcome else { return XCTFail("first image should succeed") }
        XCTAssertEqual(results.compactMap(\.outcome.warning), [
            RichPresentationWarning(sectionIndex: 1, articleIndex: 0, code: .fetchFailed),
            RichPresentationWarning(sectionIndex: 1, articleIndex: 1, code: .hostNotApproved)
        ])

        let chart = RichPresentationInput(title: "Chart", content: .chart(RichPresentationChart(
            chartType: .bar,
            xLabel: "Team",
            unit: "count",
            x: ["A"],
            series: [RichPresentationSeries(name: "S", y: [1])],
            sources: [RichPresentationSource(label: "Local")]
        )))
        let chartResults = try await fetcher.fetchImages(for: chart, approvedHosts: [Self.host])
        XCTAssertEqual(chartResults, [])
        XCTAssertEqual(RichPresentationImageFixtureTransport.state.requests.count, 2)
    }

    func testAlreadyCancelledPublicationThrowsEvenWithoutImages() async throws {
        let fetcher = makeFetcher()
        let chart = RichPresentationInput(title: "Chart", content: .chart(RichPresentationChart(
            chartType: .line,
            xLabel: "Time",
            unit: "ms",
            x: ["2026-11-05T10:00:00Z"],
            series: [RichPresentationSeries(name: "S", y: [1])],
            sources: [RichPresentationSource(label: "Local")]
        )))
        let textOnly = RichPresentationInput(title: "Text", content: .briefing(RichPresentationBriefing(
            date: "2026-11-05",
            sections: [RichPresentationSection(heading: "News", articles: [
                RichPresentationArticle(headline: "H", body: "B", sources: [RichPresentationSource(label: "Desk")])
            ])]
        )))
        for input in [chart, textOnly] {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await fetcher.fetchImages(for: input, approvedHosts: [Self.host])
            }
            do {
                _ = try await task.value
                XCTFail("a cancelled publication returned outcomes for \(input.title)")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
        }
        XCTAssertTrue(RichPresentationImageFixtureTransport.state.requests.isEmpty)
    }

    // MARK: - Isolation (URLSession fixture + configuration)

    func testIsolatedSessionConfigurationAndChallengePolicy() {
        let config = RichPresentationImageFetcher.makeConfiguration()
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.httpCookieAcceptPolicy, .never)
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertTrue(config.httpAdditionalHeaders?.isEmpty ?? true)
        XCTAssertFalse(config.waitsForConnectivity)
        XCTAssertLessThanOrEqual(config.timeoutIntervalForResource, 20)

        XCTAssertEqual(RichPresentationImageRequestPolicy.disposition(for: NSURLAuthenticationMethodServerTrust), .performDefaultHandling)
        for method in [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodNTLM,
            NSURLAuthenticationMethodNegotiate,
            NSURLAuthenticationMethodClientCertificate,
            NSURLAuthenticationMethodDefault
        ] {
            XCTAssertEqual(RichPresentationImageRequestPolicy.disposition(for: method), .cancelAuthenticationChallenge, method)
        }
    }

    /// Scope (mutation-checked 2026-11-05): a `URLProtocol` fixture sits above CFNetwork's cookie layer, so the
    /// missing `Cookie` header passes even with session cookie isolation removed. Session isolation is proven by
    /// `testIsolatedSessionConfigurationAndChallengePolicy`; this test pins the request-level opt-out and is an
    /// end-to-end smoke check only, not proof that a real HTTP stack drops the cookie.
    func testCookiesSetByAnImageHostAreNeverSentBack() async throws {
        let jpeg = Self.encode(Self.solidImage(width: 4, height: 4), type: .jpeg)
        let state = RichPresentationImageFixtureTransport.state
        state.setBehavior { _ in
            .respond(status: 200, headers: ["Content-Type": "image/jpeg", "Set-Cookie": "track=1; Path=/; Secure"], chunks: [jpeg])
        }
        let fetcher = makeFetcher()
        _ = try await fetcher.fetchImages(for: Self.briefing(imageURLs: ["https://images.example.com/1.jpg"]), approvedHosts: [Self.host])
        _ = try await fetcher.fetchImages(for: Self.briefing(imageURLs: ["https://images.example.com/2.jpg"]), approvedHosts: [Self.host])

        XCTAssertEqual(state.requests.count, 2)
        XCTAssertEqual(state.requests.map(\.httpShouldHandleCookies), [false, false])
        XCTAssertNil(state.requests.last?.value(forHTTPHeaderField: "Cookie"))
    }

    func testAuthenticationChallengeIsCancelledWithoutOfferingCredentials() async throws {
        let state = RichPresentationImageFixtureTransport.state
        state.setBehavior { _ in .challenge }
        var limits = RichPresentationImageLimits()
        limits.imagePhaseDeadline = .seconds(5)

        let results = try await makeFetcher(limits: limits)
            .fetchImages(for: Self.briefing(imageURLs: ["https://images.example.com/private.jpg"]), approvedHosts: [Self.host])

        XCTAssertEqual(results.map(\.outcome.outcome), [.failed(.fetchFailed)])
        // URLSession applies the cancel disposition itself by stopping the load; any credential
        // use, default handling or continuation would reach the challenge sender instead.
        XCTAssertEqual(state.challengeEvents, [])
        XCTAssertEqual(state.stoppedCount, 1)
        XCTAssertEqual(state.requests.count, 1)
    }

    func testRedirectsAreRefusedAndNeverFollowed() async throws {
        let state = RichPresentationImageFixtureTransport.state
        let target = try XCTUnwrap(URL(string: "https://images.example.com/elsewhere.jpg"))
        state.setBehavior { request in
            switch request.url?.path {
            case "/delegated.jpg": .redirect(to: target, status: 302)
            case "/plain.jpg": .respond(status: 301, headers: ["Location": target.absoluteString], chunks: [])
            default: .respond(status: 200, headers: ["Content-Type": "image/jpeg"], chunks: [Data([0xFF])])
            }
        }
        let fetcher = makeFetcher()
        for path in ["delegated", "plain"] {
            let results = try await fetcher.fetchImages(
                for: Self.briefing(imageURLs: ["https://images.example.com/\(path).jpg"]),
                approvedHosts: [Self.host]
            )
            XCTAssertEqual(results.map(\.outcome.outcome), [.failed(.redirectRejected)], path)
        }
        XCTAssertFalse(state.requests.contains { $0.url == target }, "a refused redirect must never be requested")
    }

    // MARK: - Status, MIME and byte bounds (URLSession fixture)

    func testOnlyHTTP200WithACompatibleMIMEProducesAnAsset() async throws {
        let jpeg = Self.encode(Self.solidImage(width: 4, height: 4), type: .jpeg)
        let cases: [(status: Int, contentType: String?, code: RichPresentationImageFailureCode?)] = [
            (200, "image/jpeg", nil),
            (200, "IMAGE/JPEG; charset=binary", nil),
            (203, "image/jpeg", .fetchFailed),
            (204, "image/jpeg", .fetchFailed),
            (404, "image/jpeg", .fetchFailed),
            (500, "image/jpeg", .fetchFailed),
            (200, "image/png", .invalidImage),
            (200, "text/html", .invalidImage),
            (200, "application/octet-stream", .invalidImage),
            (200, nil, .invalidImage)
        ]
        let fetcher = makeFetcher()
        for (index, testCase) in cases.enumerated() {
            RichPresentationImageFixtureTransport.state.setBehavior { _ in
                .respond(status: testCase.status, headers: testCase.contentType.map { ["Content-Type": $0] } ?? [:], chunks: [jpeg])
            }
            let results = try await fetcher.fetchImages(
                for: Self.briefing(imageURLs: ["https://images.example.com/\(index).jpg"]),
                approvedHosts: [Self.host]
            )
            let label = "\(testCase.status) \(testCase.contentType ?? "nil")"
            if let code = testCase.code {
                XCTAssertEqual(results.map(\.outcome.outcome), [.failed(code)], label)
            } else {
                guard case .asset = results.first?.outcome.outcome else { return XCTFail("expected asset for \(label)") }
            }
        }
    }

    func testStreamedByteBoundsIgnoreLyingLengthsAndDetectTruncation() async throws {
        let jpeg = Self.encode(Self.solidImage(width: 32, height: 32), type: .jpeg)
        let over = RichPresentationImageLimits.standard.maxImageBytes + 1
        let cases: [(label: String, limit: Int?, headers: [String: String], chunks: [Data], code: RichPresentationImageFailureCode?)] = [
            ("exact per-image limit", jpeg.count, ["Content-Length": "\(jpeg.count)"], [jpeg], nil),
            ("one byte over the limit", jpeg.count - 1, [:], [jpeg], .tooLarge),
            ("declared length above the limit", nil, ["Content-Length": "\(over)"], [Data([0xFF, 0xD8])], .tooLarge),
            ("understated length, streamed past the limit", nil, ["Content-Length": "100"], Array(repeating: Data(count: 1024 * 1024), count: 4) + [Data([0])], .tooLarge),
            ("overstated length, body cut short", nil, ["Content-Length": "\(jpeg.count)"], [jpeg.prefix(jpeg.count / 2)], .invalidImage)
        ]
        for testCase in cases {
            var limits = RichPresentationImageLimits()
            if let limit = testCase.limit { limits.maxImageBytes = limit }
            var headers = testCase.headers
            headers["Content-Type"] = "image/jpeg"
            RichPresentationImageFixtureTransport.state.setBehavior { _ in .respond(status: 200, headers: headers, chunks: testCase.chunks) }
            let results = try await makeFetcher(limits: limits)
                .fetchImages(for: Self.briefing(imageURLs: ["https://images.example.com/a.jpg"]), approvedHosts: [Self.host])
            if let code = testCase.code {
                XCTAssertEqual(results.map(\.outcome.outcome), [.failed(code)], testCase.label)
            } else {
                guard case .asset = results.first?.outcome.outcome else { return XCTFail("expected asset: \(testCase.label)") }
            }
        }
    }

    func testArtifactAggregateBoundRejectsTheImageThatWouldExceedIt() async throws {
        let jpeg = Self.encode(Self.solidImage(width: 16, height: 16), type: .jpeg)
        RichPresentationImageFixtureTransport.state.setBehavior { _ in
            .respond(status: 200, headers: ["Content-Type": "image/jpeg"], chunks: [jpeg])
        }
        var limits = RichPresentationImageLimits()
        limits.maxArtifactBytes = jpeg.count * 3 / 2

        let results = try await makeFetcher(limits: limits).fetchImages(
            for: Self.briefing(imageURLs: ["https://images.example.com/1.jpg", "https://images.example.com/2.jpg"]),
            approvedHosts: [Self.host]
        )

        let assets = results.filter { if case .asset = $0.outcome.outcome { true } else { false } }
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(results.compactMap(\.outcome.warning).map(\.code), [.tooLarge])
    }

    // MARK: - Deadline, cancellation and concurrency (URLSession fixture)

    func testImagePhaseDeadlineEndsStalledTransfersButKeepsFinishedImages() async throws {
        let jpeg = Self.encode(Self.solidImage(width: 4, height: 4), type: .jpeg)
        let state = RichPresentationImageFixtureTransport.state
        state.setBehavior { request in
            request.url?.path == "/fast.jpg" ? .respond(status: 200, headers: ["Content-Type": "image/jpeg"], chunks: [jpeg]) : .stall
        }
        var limits = RichPresentationImageLimits()
        limits.imagePhaseDeadline = .milliseconds(400)
        let start = ContinuousClock.now

        let results = try await makeFetcher(limits: limits).fetchImages(
            for: Self.briefing(imageURLs: ["https://images.example.com/fast.jpg", "https://images.example.com/stall.jpg"]),
            approvedHosts: [Self.host]
        )

        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        guard case .asset = results[0].outcome.outcome else { return XCTFail("finished image must survive the deadline") }
        XCTAssertEqual(results[1].outcome.outcome, .failed(.deadline))
        try await waitUntil("stalled transfer stopped") { state.stoppedCount == 1 }
    }

    func testPublicationCancellationThrowsAndStopsTheTransfer() async throws {
        let state = RichPresentationImageFixtureTransport.state
        state.setBehavior { _ in .stall }
        let fetcher = makeFetcher()
        let task = Task {
            try await fetcher.fetchImages(for: Self.briefing(imageURLs: ["https://images.example.com/a.jpg"]), approvedHosts: [Self.host])
        }
        try await waitUntil("transfer started") { state.requests.count == 1 }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled publication must not return outcomes")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try await waitUntil("transfer stopped") { state.stoppedCount == 1 }
    }

    func testAtMostTwoDownloadsRunAcrossConcurrentPublications() async throws {
        let jpeg = Self.encode(Self.solidImage(width: 4, height: 4), type: .jpeg)
        let gate = DispatchSemaphore(value: 0)
        let state = RichPresentationImageFixtureTransport.state
        state.setBehavior { _ in .gated(gate, then: .respond(status: 200, headers: ["Content-Type": "image/jpeg"], chunks: [jpeg])) }
        let fetcher = makeFetcher()
        let urls = (0 ..< 3).map { "https://images.example.com/\($0).jpg" }
        let first = Task { try await fetcher.fetchImages(for: Self.briefing(imageURLs: urls), approvedHosts: [Self.host]) }
        let second = Task { try await fetcher.fetchImages(for: Self.briefing(imageURLs: urls), approvedHosts: [Self.host]) }

        try await waitUntil("two transfers started") { state.requests.count == 2 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(state.requests.count, 2, "a third transfer started while two were in flight")
        for _ in 0 ..< 6 {
            gate.signal()
        }

        let outcomes = try await (first.value + second.value).map(\.outcome.outcome)
        XCTAssertEqual(outcomes.count, 6)
        XCTAssertTrue(outcomes.allSatisfy { if case .asset = $0 { true } else { false } }, "\(outcomes)")
        XCTAssertEqual(state.maxActive, 2)
        XCTAssertEqual(state.requests.count, 6)
    }

    func testDownloadPermitStaysHeldUntilURLSessionReportsTheCancelledTransferEnded() async throws {
        let jpeg = Self.encode(Self.solidImage(width: 4, height: 4), type: .jpeg)
        let state = RichPresentationImageFixtureTransport.state
        state.setBehavior { request in
            request.url?.path == "/replacement.jpg"
                ? .respond(status: 200, headers: ["Content-Type": "image/jpeg"], chunks: [jpeg])
                : .stall
        }
        // URLSession delivers every delegate callback, including each task's terminal
        // didCompleteWithError, on this queue; suspending it delays the transfers' actual end.
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let fetcher = makeFetcher(delegateQueue: delegateQueue)
        let occupying = Task {
            try await fetcher.fetchImages(
                for: Self.briefing(imageURLs: ["https://images.example.com/stall-0.jpg", "https://images.example.com/stall-1.jpg"]),
                approvedHosts: [Self.host]
            )
        }
        try await waitUntil("both permits in use") { state.requests.count == 2 }
        let replacement = Task {
            try await fetcher.fetchImages(
                for: Self.briefing(imageURLs: ["https://images.example.com/replacement.jpg"]),
                approvedHosts: [Self.host]
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.requests.count, 2)

        delegateQueue.isSuspended = true
        let cancelledAt = ContinuousClock.now
        occupying.cancel()
        do {
            _ = try await occupying.value
            XCTFail("a cancelled publication returned outcomes")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(2), "cancellation must not wait for transport teardown")
        try await waitUntil("cancelled transfers stopped") { state.stoppedCount == 2 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(state.requests.count, 2, "a replacement transfer started before URLSession reported the cancelled ones ended")

        delegateQueue.isSuspended = false
        let outcomes = try await replacement.value.map(\.outcome.outcome)
        guard case .asset = outcomes.first else { return XCTFail("replacement should succeed: \(outcomes)") }
        XCTAssertEqual(state.requests.count, 3)
    }

    // MARK: - Decode permit (mock decoder)

    func testExecutingDecodeKeepsItsPermitAfterCancellationAndItsLateResultIsDiscarded() async throws {
        let jpeg = Self.encode(Self.solidImage(width: 4, height: 4), type: .jpeg)
        RichPresentationImageFixtureTransport.state.setBehavior { _ in
            .respond(status: 200, headers: ["Content-Type": "image/jpeg"], chunks: [jpeg])
        }
        let decoder = GatedDecoder()
        var limits = RichPresentationImageLimits()
        limits.imagePhaseDeadline = .seconds(2)
        let fetcher = makeFetcher(limits: limits, decode: decoder.decode)
        let input = Self.briefing(imageURLs: ["https://images.example.com/a.jpg"])

        let first = Task { try await fetcher.fetchImages(for: input, approvedHosts: [Self.host]) }
        try await waitUntil("first decode executing") { decoder.calls == 1 }
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("cancelled publication returned a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(decoder.firstFinished, "the native decode is still executing after its caller left")

        // The executing decode still holds the only permit: another publication cannot decode.
        let blocked = try await fetcher.fetchImages(for: input, approvedHosts: [Self.host])
        XCTAssertEqual(blocked.map(\.outcome.outcome), [.failed(.deadline)])
        XCTAssertEqual(decoder.calls, 1)

        decoder.releaseFirst()
        try await waitUntil("first decode finished") { decoder.firstFinished }
        let afterRelease = try await fetcher.fetchImages(for: input, approvedHosts: [Self.host])
        guard case let .asset(asset) = afterRelease.first?.outcome.outcome else {
            return XCTFail("permit was not returned after the native decode ended")
        }
        XCTAssertEqual([asset.width, asset.height], [2, 3])
        XCTAssertEqual(decoder.calls, 2)
    }

    // MARK: - Real ImageIO normalization

    func testNormalizerDownsamplesRealJPEGAndPNGToSRGBJPEGWithoutUpscaling() throws {
        let cases: [(type: UTType, mime: String, width: Int, height: Int, expected: [Int])] = [
            (.jpeg, "image/jpeg", 2000, 1000, [1600, 800]),
            (.png, "image/png", 900, 1800, [800, 1600]),
            (.png, "image/png", 300, 200, [300, 200])
        ]
        for testCase in cases {
            let data = Self.encode(Self.solidImage(width: testCase.width, height: testCase.height), type: testCase.type)
            let image = try Self.normalized(data, mime: testCase.mime)
            XCTAssertEqual([image.width, image.height], testCase.expected, testCase.mime)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(image.jpegData as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual([decoded.width, decoded.height], testCase.expected)
            XCTAssertEqual(decoded.colorSpace?.name, CGColorSpace.sRGB)
        }
    }

    func testNormalizerFlattensTransparencyOnWhiteAndDropsSourceMetadata() throws {
        let transparent = Self.encode(Self.solidImage(width: 20, height: 20, alpha: 0), type: .png)
        let flattened = try Self.normalized(transparent, mime: "image/png")
        let pixel = try Self.centerPixel(of: flattened.jpegData)
        XCTAssertTrue(pixel.allSatisfy { $0 >= 250 }, "transparent pixels must become white, got \(pixel)")

        let marker = "RPCE-PRIVATE-MARKER"
        let tagged = Self.encode(Self.solidImage(width: 30, height: 30), type: .jpeg, properties: [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: marker],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: marker, kCGImagePropertyTIFFMake: marker],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: marker]
        ])
        XCTAssertNotNil(tagged.range(of: Data(marker.utf8)), "fixture must actually carry the marker")
        let stripped = try Self.normalized(tagged, mime: "image/jpeg")
        XCTAssertNil(stripped.jpegData.range(of: Data(marker.utf8)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(stripped.jpegData as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties[kCGImagePropertyIPTCDictionary])
    }

    func testNormalizerRejectsAnimationTruncationAndOtherFormats() {
        let jpeg = Self.encode(Self.solidImage(width: 24, height: 24), type: .jpeg)
        let png = Self.encode(Self.solidImage(width: 24, height: 24), type: .png)
        let apng = Self.animatedPNG()
        XCTAssertNotNil(apng.range(of: Data("acTL".utf8)), "fixture must be an actual APNG")
        let gif = Self.encode(Self.solidImage(width: 24, height: 24), type: .gif)
        let tiff = Self.encode(Self.solidImage(width: 24, height: 24), type: .tiff)
        var trailingGarbagePNG = png
        trailingGarbagePNG.append(contentsOf: [0, 1, 2, 3])

        let cases: [(label: String, data: Data, mime: String)] = [
            ("animated PNG", apng, "image/png"),
            ("truncated JPEG", jpeg.prefix(jpeg.count - 8), "image/jpeg"),
            ("JPEG cut after header", jpeg.prefix(64), "image/jpeg"),
            ("truncated PNG", png.prefix(png.count - 12), "image/png"),
            ("PNG with bytes after IEND", trailingGarbagePNG, "image/png"),
            ("GIF declared as GIF", gif, "image/gif"),
            ("GIF declared as PNG", gif, "image/png"),
            ("TIFF declared as JPEG", tiff, "image/jpeg"),
            ("PNG declared as JPEG", png, "image/jpeg"),
            ("SVG", Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8), "image/svg+xml"),
            ("empty", Data(), "image/png")
        ]
        for testCase in cases {
            let result = RichPresentationImageNormalizer.normalize(data: testCase.data, mimeType: testCase.mime, limits: .standard)
            XCTAssertEqual(result.failureCode, .invalidImage, testCase.label)
        }
        XCTAssertNotNil(try? Self.normalized(png, mime: "image/png"), "control: the untouched PNG is accepted")
    }

    func testJPEGFramingRejectsTrailingPayloadAndDamagedScansThatKeepTheirEOI() throws {
        let jpeg = Self.encode(Self.solidImage(width: 64, height: 48), type: .jpeg)
        let sos = try XCTUnwrap(Self.firstSOSOffset(in: jpeg))
        let scan = try XCTUnwrap(Self.firstScanDataRange(in: jpeg))
        XCTAssertGreaterThan(scan.count, 8, "fixture needs real entropy-coded data")
        let middle = scan.lowerBound + scan.count / 2
        func splice(_ inserted: [UInt8]) -> Data {
            jpeg.prefix(middle) + Data(inserted) + jpeg.suffix(from: middle)
        }
        var trailingPayload = jpeg
        trailingPayload.append(contentsOf: [0x12, 0x34, 0x56, 0xFF, 0xD9])

        // ImageIO alone accepts these: rejection comes from the framing walk, not decode status.
        for (label, data) in [("trailing payload ending in a second EOI", trailingPayload), ("second JPEG stream appended", jpeg + jpeg)] {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil), "precondition: ImageIO decodes \(label)")
        }
        let cases: [(label: String, data: Data)] = [
            ("trailing payload ending in a second EOI", trailingPayload),
            ("second JPEG stream appended", jpeg + jpeg),
            // Known, accepted false rejection: nothing may follow the first EOI. That also rejects
            // trailing zero padding and MPF / gain-map (Ultra HDR, adaptive HDR) secondary images.
            ("trailing zero padding after EOI", jpeg + Data([0, 0])),
            ("reserved marker inside the scan, EOI kept", splice([0xFF, 0x4A, 0x00, 0x04, 0x01, 0x02])),
            ("segment inside the scan overruns the data, EOI kept", splice([0xFF, 0xC4, 0xFF, 0xF0])),
            ("second SOI inside the scan, EOI kept", splice([0xFF, 0xD8])),
            ("EOI before any scan", jpeg.prefix(2) + Data([0xFF, 0xD9])),
            // Between header segments the next bytes are `FF DA`, so this fails only if reserved
            // markers are rejected outright rather than skipped as length-prefixed segments.
            ("reserved marker between header segments", jpeg.prefix(sos) + Data([0xFF, 0x4A, 0x00, 0x02]) + jpeg.suffix(from: sos)),
            ("restart marker outside a scan", Data([0xFF, 0xD8, 0xFF, 0xD0]) + jpeg.suffix(from: 2))
        ]
        for testCase in cases {
            XCTAssertNil(RichPresentationImageNormalizer.completeFormat(of: testCase.data), testCase.label)
            let result = RichPresentationImageNormalizer.normalize(data: testCase.data, mimeType: "image/jpeg", limits: .standard)
            XCTAssertEqual(result.failureCode, .invalidImage, testCase.label)
        }

        // Controls: stuffed bytes, restart markers, fill bytes and multiple scans are legitimate framing.
        // A real noisy photo-like JPEG; solid fills almost never produce a stuffed `FF 00`.
        let noisy = Self.encode(Self.noiseImage(width: 96, height: 64), type: .jpeg)
        let noisyScan = try XCTUnwrap(Self.firstScanDataRange(in: noisy))
        XCTAssertNotNil(noisy[noisyScan].range(of: Data([0xFF, 0x00])), "precondition: fixture scan contains stuffed FF 00")
        XCTAssertEqual(RichPresentationImageNormalizer.completeFormat(of: noisy), .jpeg, "noisy JPEG with stuffed bytes")
        XCTAssertNotNil(try? Self.normalized(noisy, mime: "image/jpeg"), "noisy JPEG with stuffed bytes")
        // Encoder output need not contain restart markers or fill bytes, so this framing-only control
        // is hand-built: SOI, DRI, SOS header, entropy with `FF 00`, `FF D0` and fill `FF FF D1`, then EOI.
        let restartFramed = Data([
            0xFF, 0xD8,
            0xFF, 0xDD, 0x00, 0x04, 0x00, 0x01,
            0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
            0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56, 0xFF, 0xFF, 0xD1, 0x78,
            0xFF, 0xD9
        ])
        XCTAssertEqual(RichPresentationImageNormalizer.completeFormat(of: restartFramed), .jpeg, "restart markers and fill bytes inside a scan")
        let progressive = Self.encode(Self.solidImage(width: 64, height: 48), type: .jpeg, properties: [
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]
        ])
        XCTAssertGreaterThan(progressive.ranges(of: Data([0xFF, 0xDA])).count, 1, "fixture must be multi-scan")
        XCTAssertNotNil(try? Self.normalized(progressive, mime: "image/jpeg"), "progressive JPEG")
        XCTAssertNotNil(try? Self.normalized(jpeg, mime: "image/jpeg"), "baseline JPEG")
    }

    func testNormalizerPixelAndOutputCeilings() throws {
        // Real PNGs at the production 24-million-pixel ceiling (solid fills keep them small).
        let atLimit = Self.encode(Self.solidImage(width: 6000, height: 4000), type: .png)
        let accepted = try Self.normalized(atLimit, mime: "image/png")
        XCTAssertEqual(accepted.width, 1600)
        XCTAssertTrue((1066 ... 1067).contains(accepted.height), "\(accepted.height)")
        for (width, height) in [(6001, 4000), (4000, 6001)] {
            let over = Self.encode(Self.solidImage(width: width, height: height), type: .png)
            XCTAssertEqual(
                RichPresentationImageNormalizer.normalize(data: over, mimeType: "image/png", limits: .standard).failureCode,
                .tooLarge,
                "\(width)x\(height)"
            )
        }

        var tinyOutput = RichPresentationImageLimits()
        tinyOutput.maxOutputBytes = 64
        let small = Self.encode(Self.solidImage(width: 100, height: 100), type: .png)
        XCTAssertEqual(RichPresentationImageNormalizer.normalize(data: small, mimeType: "image/png", limits: tinyOutput).failureCode, .tooLarge)
    }

    // MARK: - Stored outcome values (Core)

    func testStoredOutcomeRoundTripsAndDecodesStrictly() throws {
        let assetID = try XCTUnwrap(UUID(uuidString: "6C1B3E52-8A51-4C0B-9A0E-2D6F3C1A7B10"))
        let values = [
            RichPresentationArticleImageOutcome(sectionIndex: 1, articleIndex: 2, outcome: .asset(RichPresentationImageAsset(
                assetID: assetID, width: 1600, height: 900, alt: "Harbor", credit: "Desk", origin: "https://images.example.com"
            ))),
            RichPresentationArticleImageOutcome(sectionIndex: 0, articleIndex: 0, outcome: .asset(RichPresentationImageAsset(
                assetID: assetID, width: 1, height: 1, alt: "", credit: nil, origin: "https://images.example.com"
            ))),
            RichPresentationArticleImageOutcome(sectionIndex: 5, articleIndex: 11, outcome: .failed(.deadline))
        ]
        for value in values {
            let decoded = try JSONDecoder().decode(RichPresentationArticleImageOutcome.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(decoded, value)
        }

        let asset = #""section_index":0,"article_index":0,"status":"asset","asset_id":"6C1B3E52-8A51-4C0B-9A0E-2D6F3C1A7B10","alt":"a""#
        let rejected = [
            "{\(asset),\"width\":10,\"height\":10,\"origin\":\"https://images.example.com/x.jpg?sig=1\"}",
            "{\(asset),\"width\":10,\"height\":10,\"origin\":\"http://images.example.com\"}",
            "{\(asset),\"width\":10,\"height\":10,\"origin\":\"https://images.example.com:443\"}",
            "{\(asset),\"width\":1601,\"height\":10,\"origin\":\"https://images.example.com\"}",
            "{\(asset),\"width\":0,\"height\":10,\"origin\":\"https://images.example.com\"}",
            "{\(asset),\"width\":10,\"height\":10,\"origin\":\"https://images.example.com\",\"credit\":null}",
            "{\(asset),\"width\":10,\"height\":10,\"origin\":\"https://images.example.com\",\"url\":\"https://images.example.com/x\"}",
            #"{"section_index":0,"article_index":0,"status":"failed","code":"deadline","origin":"https://images.example.com"}"#,
            #"{"section_index":0,"article_index":0,"status":"failed","code":"pending"}"#,
            #"{"section_index":6,"article_index":0,"status":"failed","code":"deadline"}"#,
            #"{"section_index":0,"article_index":0,"status":"pending"}"#
        ]
        for json in rejected {
            XCTAssertThrowsError(try JSONDecoder().decode(RichPresentationArticleImageOutcome.self, from: Data(json.utf8)), json)
        }
    }

    // MARK: - Helpers

    private func makeFetcher(
        limits: RichPresentationImageLimits = .standard,
        delegateQueue: OperationQueue? = nil,
        decode: RichPresentationImageFetcher.Decoder? = nil
    ) -> RichPresentationImageFetcher {
        let configuration = RichPresentationImageFetcher.makeConfiguration()
        configuration.protocolClasses = [RichPresentationImageFixtureTransport.self]
        guard let decode else {
            return RichPresentationImageFetcher(configuration: configuration, limits: limits, delegateQueue: delegateQueue)
        }
        return RichPresentationImageFetcher(configuration: configuration, limits: limits, delegateQueue: delegateQueue, decode: decode)
    }

    private func waitUntil(_ label: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting: \(label)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func briefing(imageURLs: [String], credit: String? = nil) -> RichPresentationInput {
        let articles = imageURLs.enumerated().map { index, url in
            RichPresentationArticle(
                headline: "Headline \(index)",
                body: "Body \(index)",
                sources: [RichPresentationSource(label: "Desk")],
                image: RichPresentationImageRequest(url: url, alt: "Alt \(index)", credit: credit)
            )
        }
        return RichPresentationInput(
            title: "Briefing",
            content: .briefing(RichPresentationBriefing(date: "2026-11-05", sections: [RichPresentationSection(heading: "News", articles: articles)]))
        )
    }

    /// Offset of the first SOS marker (`FF DA`).
    private static func firstSOSOffset(in jpeg: Data) -> Int? {
        let bytes = [UInt8](jpeg)
        return (2 ..< bytes.count - 3).first(where: { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xDA })
    }

    /// Byte range of the first scan's entropy-coded data (after the SOS header, before EOI).
    private static func firstScanDataRange(in jpeg: Data) -> Range<Int>? {
        let bytes = [UInt8](jpeg)
        guard let sos = firstSOSOffset(in: jpeg) else { return nil }
        let start = sos + 2 + (Int(bytes[sos + 2]) << 8 | Int(bytes[sos + 3]))
        let end = bytes.count - 2
        return start < end ? start ..< end : nil
    }

    private static func normalized(_ data: Data, mime: String) throws -> RichPresentationNormalizedImage {
        try RichPresentationImageNormalizer.normalize(data: data, mimeType: mime, limits: .standard).get()
    }

    static func solidImage(width: Int, height: Int, alpha: CGFloat = 1) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.4, blue: 0.7, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Deterministic opaque noise (fixed-seed LCG): photo-like entropy data for JPEG framing controls.
    static func noiseImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var state: UInt32 = 0x2545_F491
        for offset in 0 ..< width * height * 4 {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[offset] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return context.makeImage()!
    }

    static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]? = nil) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func animatedPNG() -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 2, nil)!
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]
        ] as CFDictionary)
        let frame = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]] as CFDictionary
        CGImageDestinationAddImage(destination, solidImage(width: 12, height: 12), frame)
        CGImageDestinationAddImage(destination, solidImage(width: 12, height: 12, alpha: 0.5), frame)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func centerPixel(of jpeg: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return Array(pixel.prefix(3))
    }
}

private extension Result {
    var failureCode: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}

/// Mock decoder for permit timing only: the first call blocks on a gate; later calls return at once.
private final class GatedDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var callCount = 0
    private var finishedFirst = false

    var calls: Int {
        lock.withLock { callCount }
    }

    var firstFinished: Bool {
        lock.withLock { finishedFirst }
    }

    func releaseFirst() {
        gate.signal()
    }

    var decode: RichPresentationImageFetcher.Decoder {
        { [self] _, _, _ in
            let call = lock.withLock { () -> Int in
                callCount += 1
                return callCount
            }
            if call == 1 {
                gate.wait()
                lock.withLock { finishedFirst = true }
            }
            return .success(RichPresentationNormalizedImage(jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]), width: 2, height: 3))
        }
    }
}

/// Controlled transport for the real URLSession: installed only through `protocolClasses`, so
/// requests are answered in-process and never reach a network. Client callbacks run off the
/// loading thread so a gated or stalled reply never blocks other transfers.
final class RichPresentationImageFixtureTransport: URLProtocol, URLAuthenticationChallengeSender {
    indirect enum Behavior {
        case respond(status: Int, headers: [String: String], chunks: [Data])
        case redirect(to: URL, status: Int)
        case challenge
        case stall
        case gated(DispatchSemaphore, then: Behavior)
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var behavior: (URLRequest) -> Behavior = { _ in .stall }
        private var recordedRequests: [URLRequest] = []
        private var events: [String] = []
        private var active = 0
        private var peak = 0
        private var stopped = 0

        var requests: [URLRequest] {
            lock.withLock { recordedRequests }
        }

        var challengeEvents: [String] {
            lock.withLock { events }
        }

        var maxActive: Int {
            lock.withLock { peak }
        }

        var stoppedCount: Int {
            lock.withLock { stopped }
        }

        func reset() {
            lock.withLock {
                behavior = { _ in .stall }
                recordedRequests = []
                events = []
                active = 0
                peak = 0
                stopped = 0
            }
        }

        func setBehavior(_ behavior: @escaping (URLRequest) -> Behavior) {
            lock.withLock { self.behavior = behavior }
        }

        fileprivate func begin(_ request: URLRequest) -> Behavior {
            lock.withLock {
                recordedRequests.append(request)
                active += 1
                peak = max(peak, active)
                return behavior(request)
            }
        }

        fileprivate func end() {
            lock.withLock { active -= 1 }
        }

        fileprivate func noteStopped() {
            lock.withLock { stopped += 1 }
        }

        fileprivate func record(_ event: String) {
            lock.withLock { events.append(event) }
        }
    }

    static let state = State()
    private let endLock = NSLock()
    private var ended = false

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let behavior = Self.state.begin(request)
        DispatchQueue.global().async { self.perform(behavior) }
    }

    override func stopLoading() {
        if markEnded() {
            Self.state.noteStopped()
        }
    }

    private func markEnded() -> Bool {
        let first = endLock.withLock { () -> Bool in
            defer { ended = true }
            return !ended
        }
        if first {
            Self.state.end()
        }
        return first
    }

    private func perform(_ behavior: Behavior) {
        let url = request.url!
        switch behavior {
        case let .gated(gate, next):
            gate.wait()
            perform(next)
        case let .respond(status, headers, chunks):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            guard markEnded() else { return }
            client?.urlProtocolDidFinishLoading(self)
        case let .redirect(target, status):
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // When the redirect is refused, the redirect response is the final response.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            guard markEnded() else { return }
            client?.urlProtocolDidFinishLoading(self)
        case .challenge:
            let space = URLProtectionSpace(
                host: url.host!,
                port: 443,
                protocol: NSURLProtectionSpaceHTTPS,
                realm: "fixture",
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic
            )
            let challenge = URLAuthenticationChallenge(
                protectionSpace: space,
                proposedCredential: URLCredential(user: "u", password: "p", persistence: .none),
                previousFailureCount: 0,
                failureResponse: nil,
                error: nil,
                sender: self
            )
            client?.urlProtocol(self, didReceive: challenge)
        case .stall:
            break
        }
    }

    private func failChallenge(_ event: String) {
        Self.state.record(event)
        guard markEnded() else { return }
        client?.urlProtocol(self, didFailWithError: URLError(.userCancelledAuthentication))
    }

    func use(_: URLCredential, for _: URLAuthenticationChallenge) {
        failChallenge("use")
    }

    func continueWithoutCredential(for _: URLAuthenticationChallenge) {
        failChallenge("continue")
    }

    func cancel(_: URLAuthenticationChallenge) {
        failChallenge("cancel")
    }

    func performDefaultHandling(for _: URLAuthenticationChallenge) {
        failChallenge("default")
    }

    func rejectProtectionSpaceAndContinue(with _: URLAuthenticationChallenge) {
        failChallenge("reject")
    }
}
