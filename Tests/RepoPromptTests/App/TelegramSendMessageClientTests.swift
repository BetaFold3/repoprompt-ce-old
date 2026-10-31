import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Stubbed Telegram transport tests. No real network: every request goes to `StubHTTPClient`.
final class TelegramSendMessageClientTests: XCTestCase {
    /// Synthetic, test-only sentinel shaped like a bot token. Not a real credential.
    private static let syntheticToken = "424242:SYNTHETIC_TELEGRAM_TOKEN_SENTINEL-not-real"
    private static let syntheticSecret = "SYNTHETIC_TELEGRAM_TOKEN_SENTINEL"
    private static let syntheticURL = "https://api.telegram.org/bot\(syntheticToken)/sendMessage"

    private var token: TelegramBotToken {
        TelegramBotToken(Self.syntheticToken)!
    }

    // MARK: - Leak: failing requests never surface the token or URL

    func testTransportErrorCarryingTokenizedURLIsDroppedFromResult() async {
        let stub = StubHTTPClient(behavior: .fail(Self.leakyURLError()))
        let result = await TelegramSendMessageClient(httpClient: stub)
            .send(text: "hello", to: .numeric(7), token: token)

        XCTAssertEqual(result, .unknown(.requestInterrupted))
        XCTAssertEqual(result.deliveryOutcome, .unknown)
        XCTAssertEqual(stub.requestCount, 1)
        assertNoLeak(in: result)
    }

    /// Pre-send network failures are definite (`notConnected`); ambiguous ones stay unknown. Only the
    /// error code is read, so the tokenized URL in `userInfo` never reaches the result (OracleB S3-3).
    func testTransportErrorsMapByCodeOnlyWithoutLeaking() async {
        let definite: [URLError.Code] = [
            .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
            .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid
        ]
        let ambiguous: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .secureConnectionFailed, .cancelled, .badServerResponse,
            .cannotParseResponse, .unknown, .notConnectedToInternet
        ]
        for (codes, expected) in [
            (definite, TelegramSendResult.failed(.notConnected)),
            (ambiguous, .unknown(.requestInterrupted))
        ] {
            for code in codes {
                let stub = StubHTTPClient(behavior: .fail(Self.leakyURLError(code)))
                let result = await TelegramSendMessageClient(httpClient: stub)
                    .send(text: "hello", to: .numeric(7), token: token)
                XCTAssertEqual(result, expected, "code \(code.rawValue)")
                XCTAssertEqual(stub.requestCount, 1, "code \(code.rawValue)")
                assertNoLeak(in: result)
            }
        }
    }

    func testTransportErrorWithLeakyDescriptionIsDroppedFromResult() async {
        let stub = StubHTTPClient(behavior: .fail(LeakyError()))
        let result = await TelegramSendMessageClient(httpClient: stub)
            .send(text: "hello", to: .numeric(7), token: token)

        XCTAssertEqual(result, .unknown(.requestInterrupted))
        assertNoLeak(in: result)
    }

    func testAPIRejectionEchoingTokenAndURLIsSanitized() async {
        let body = Data("""
        {"ok":false,"error_code":401,"description":"Unauthorized \(Self.syntheticURL) token=\(Self.syntheticToken)"}
        """.utf8)
        let stub = StubHTTPClient(behavior: .respond(status: 401, body: body))
        let result = await TelegramSendMessageClient(httpClient: stub)
            .send(text: "hello", to: .numeric(7), token: token)

        XCTAssertEqual(result, .failed(.unauthorized))
        XCTAssertEqual(result.deliveryOutcome, .failed)
        assertNoLeak(in: result)
    }

    func testEveryResultDiagnosticIsFixedTextWithoutRequestDetails() {
        var results: [TelegramSendResult] = [.sent]
        results += TelegramSendFailure.allCases.map { .failed($0) }
        results += TelegramSendUncertainty.allCases.map { .unknown($0) }
        for result in results {
            XCTAssertFalse(result.diagnosticMessage.isEmpty)
            assertNoLeak(in: result)
        }
    }

    func testTokenTextualDebugAndReflectedFormsAreRedacted() {
        let token = token
        var dumped = ""
        dump(token, to: &dumped)
        for surface in [
            String(describing: token),
            String(reflecting: token),
            "\(token)",
            dumped,
            String(describing: Mirror(reflecting: token).children.map(\.value))
        ] {
            XCTAssertFalse(surface.contains(Self.syntheticSecret), surface)
        }
    }

    func testNewNotificationSourcesNeverLogPersistOrRecordBreadcrumbs() throws {
        let root = try RepoRoot.url()
        let forbidden = [
            "print(", "NSLog", "os_log", "Logger", "logger", "SentrySDK", "Breadcrumb",
            "UserDefaults", "FileManager", ".write(to", "localizedDescription"
        ]
        for path in Self.telegramSourcePaths {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for needle in forbidden {
                XCTAssertFalse(text.contains(needle), "\(path) contains \(needle)")
            }
        }
    }

    /// Evidence pin: the app's crash reporter already records no network breadcrumbs or failed requests.
    func testSentryBootstrapKeepsNetworkCaptureDisabled() throws {
        let root = try RepoRoot.url()
        let text = try String(
            contentsOf: root.appendingPathComponent("Sources/RepoPrompt/Infrastructure/Telemetry/SentryTelemetryBootstrap.swift"),
            encoding: .utf8
        )
        for line in [
            "options.enableAutoBreadcrumbTracking = false",
            "options.enableNetworkBreadcrumbs = false",
            "options.enableNetworkTracking = false",
            "options.enableCaptureFailedRequests = false",
            "options.enableLogs = false"
        ] {
            XCTAssertTrue(text.contains(line), line)
        }
    }

    // MARK: - Request shape

    func testRequestIsSinglePlainJSONPostToFixedEndpoint() async throws {
        let stub = StubHTTPClient(behavior: .respond(status: 200, body: Data(#"{"ok":true,"result":{}}"#.utf8)))
        let result = await TelegramSendMessageClient(httpClient: stub)
            .send(text: "line 1\n*not markdown* <b>x</b> 🧑‍💻", to: .numeric(-1_001_234), token: token)

        XCTAssertEqual(result, .sent)
        XCTAssertEqual(stub.requestCount, 1)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, Self.syntheticURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertTrue(request.timeoutInterval.isFinite)
        XCTAssertGreaterThan(request.timeoutInterval, 0)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), ["chat_id", "text"])
        XCTAssertEqual(json["chat_id"] as? Int64, -1_001_234)
        XCTAssertEqual(json["text"] as? String, "line 1\n*not markdown* <b>x</b> 🧑‍💻")
    }

    func testUsernameChatIDIsSentAsString() async throws {
        let stub = StubHTTPClient(behavior: .respond(status: 200, body: Data(#"{"ok":true}"#.utf8)))
        let chat = try XCTUnwrap(TelegramChatID("@my_channel"))
        _ = await TelegramSendMessageClient(httpClient: stub).send(text: "x", to: chat, token: token)

        let request = try XCTUnwrap(stub.requests.first)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(json["chat_id"] as? String, "@my_channel")
    }

    func testOptionalOpenSessionButtonIsOneInlineURLButtonAndKeepsPlainText() async throws {
        let stub = StubHTTPClient(behavior: .respond(status: 200, body: Data(#"{"ok":true}"#.utf8)))
        let link = try XCTUnwrap(URL(string: "https://mac.example.ts.net:8443/?session_id=ABC"))
        let result = await TelegramSendMessageClient(httpClient: stub)
            .send(text: "*plain*", to: .numeric(7), token: token, openSessionURL: link)

        XCTAssertEqual(result, .sent)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, Self.syntheticURL)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), ["chat_id", "text", "reply_markup"], "No parse_mode: the text stays plain")
        XCTAssertEqual(json["text"] as? String, "*plain*")
        let markup = try XCTUnwrap(json["reply_markup"] as? [String: Any])
        XCTAssertEqual(Set(markup.keys), ["inline_keyboard"])
        let rows = try XCTUnwrap(markup["inline_keyboard"] as? [[[String: String]]])
        XCTAssertEqual(rows, [[["text": "Open session", "url": "https://mac.example.ts.net:8443/?session_id=ABC"]]])
    }

    func testInvalidTextIsRejectedWithoutAnyRequest() async {
        let stub = StubHTTPClient(behavior: .respond(status: 200, body: Data(#"{"ok":true}"#.utf8)))
        let client = TelegramSendMessageClient(httpClient: stub)

        let empty = await client.send(text: "", to: .numeric(1), token: token)
        let tooLong = await client.send(
            text: String(repeating: "😀", count: 2049),
            to: .numeric(1),
            token: token
        )
        let atLimit = await client.send(text: String(repeating: "😀", count: 2048), to: .numeric(1), token: token)

        XCTAssertEqual(empty, .failed(.invalidMessage))
        XCTAssertEqual(tooLong, .failed(.invalidMessage))
        XCTAssertEqual(atLimit, .sent)
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testTokenValidationRejectsValuesThatCouldEscapeTheFixedPath() {
        XCTAssertNotNil(TelegramBotToken("  \(Self.syntheticToken)\n"))
        for invalid in [
            "", ":", "123:", ":abc", "abc:def", "123:abc/def", "123:abc?x=1", "123:abc#f",
            "123:abc@evil.example", "123:abc def", "123:abc%2F", "123:ａｂｃ", "１２３:abc"
        ] {
            XCTAssertNil(TelegramBotToken(invalid), invalid)
        }
    }

    func testChatIDValidation() {
        XCTAssertEqual(TelegramChatID(" 12345 "), .numeric(12345))
        XCTAssertEqual(TelegramChatID("-100987"), .numeric(-100_987))
        XCTAssertEqual(TelegramChatID("@chan_1"), .username("@chan_1"))
        for invalid in ["", "@", "@abc", "abc", "12 34", "@chan/../x", "@chän_1"] {
            XCTAssertNil(TelegramChatID(invalid), invalid)
        }
    }

    // MARK: - Outcome classification (one attempt, never retried)

    func testOutcomeClassification() async {
        let cases: [(Int, String, TelegramSendResult)] = [
            (200, #"{"ok":true,"result":{"message_id":1}}"#, .sent),
            (200, #"{"ok":false,"error_code":400,"description":"x"}"#, .failed(.badRequest)),
            (200, "not json", .unknown(.unreadableResponse)),
            (200, "", .unknown(.unreadableResponse)),
            (200, #"{"result":{}}"#, .unknown(.unreadableResponse)),
            (400, #"{"ok":false,"error_code":400,"description":"chat not found"}"#, .failed(.badRequest)),
            (401, "", .failed(.unauthorized)),
            (403, #"{"ok":false,"error_code":403}"#, .failed(.forbidden)),
            (429, #"{"ok":false,"error_code":429,"parameters":{"retry_after":5}}"#, .failed(.rateLimited)),
            // Non-boolean `ok` is not a confirmation.
            (200, #"{"ok":1}"#, .unknown(.unreadableResponse)),
            (200, #"{"ok":"true"}"#, .unknown(.unreadableResponse)),
            // Server failures are uncertain; ordinary explicit API rejections stay failed.
            (502, "<html>bad gateway</html>", .unknown(.serverUnconfirmed)),
            (504, "", .unknown(.serverUnconfirmed)),
            (500, #"{"ok":true}"#, .unknown(.serverUnconfirmed)),
            (500, #"{"ok":false,"error_code":500,"description":"x"}"#, .unknown(.serverUnconfirmed)),
            (200, #"{"ok":false,"error_code":500}"#, .unknown(.serverUnconfirmed)),
            (502, #"{"ok":false,"error_code":429}"#, .failed(.rateLimited)),
            (307, "", .failed(.redirectRefused)),
            (404, "", .failed(.rejected))
        ]
        for (status, body, expected) in cases {
            let stub = StubHTTPClient(behavior: .respond(status: status, body: Data(body.utf8)))
            let result = await TelegramSendMessageClient(httpClient: stub)
                .send(text: "x", to: .numeric(1), token: token)
            XCTAssertEqual(result, expected, "status \(status) body \(body)")
            XCTAssertEqual(stub.requestCount, 1, "exactly one attempt for status \(status)")
        }
    }

    func testCancelledTransportIsUnknownAndNotRetried() async {
        let stub = StubHTTPClient(behavior: .fail(CancellationError()))
        let result = await TelegramSendMessageClient(httpClient: stub)
            .send(text: "x", to: .numeric(1), token: token)
        XCTAssertEqual(result, .unknown(.requestInterrupted))
        XCTAssertEqual(stub.requestCount, 1)
    }

    // MARK: - Dedicated session

    func testDedicatedSessionConfigurationIsEphemeralWithoutCookiesCacheOrCredentials() {
        let config = TelegramHTTPClient.makeConfiguration()
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.httpCookieAcceptPolicy, .never)
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertFalse(config.waitsForConnectivity)
        XCTAssertTrue(config.timeoutIntervalForRequest.isFinite)
        XCTAssertTrue(config.timeoutIntervalForResource.isFinite)
        XCTAssertLessThanOrEqual(config.timeoutIntervalForResource, 60)
    }

    func testRedirectDelegateRefusesEveryRedirect() throws {
        let delegate = TelegramHTTPClient.RedirectRefusingDelegate()
        // URLSession only consults the delegate if the method still satisfies the SDK requirement.
        XCTAssertTrue(delegate.responds(to: #selector(
            URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)
        )))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = try XCTUnwrap(URL(string: Self.syntheticURL))
        // Created but never resumed: no network activity.
        let task = session.dataTask(with: original)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: original,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://evil.example/collect"]
        ))
        let redirectTarget = try URLRequest(url: XCTUnwrap(URL(string: "https://evil.example/collect")))
        var forwarded: URLRequest? = URLRequest(url: original)
        var called = false
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirectTarget,
            completionHandler: { request in
                called = true
                forwarded = request
            }
        )
        XCTAssertTrue(called)
        XCTAssertNil(forwarded)
    }

    // MARK: - Helpers

    static let telegramSourcePaths = [
        "Sources/RepoPrompt/App/Notifications/TelegramSendMessageClient.swift",
        "Sources/RepoPrompt/App/Notifications/TelegramAttentionMessageRenderer.swift",
        "Sources/RepoPrompt/App/Notifications/TelegramBotTokenStore.swift"
    ]

    private func assertNoLeak(in result: TelegramSendResult, file: StaticString = #filePath, line: UInt = #line) {
        var dumped = ""
        dump(result, to: &dumped)
        for surface in [
            String(describing: result),
            String(reflecting: result),
            dumped,
            result.diagnosticMessage
        ] {
            XCTAssertFalse(surface.contains(Self.syntheticSecret), surface, file: file, line: line)
            XCTAssertFalse(surface.contains("api.telegram.org"), surface, file: file, line: line)
            XCTAssertFalse(surface.contains("sendMessage"), surface, file: file, line: line)
        }
    }

    private static func leakyURLError(_ code: URLError.Code = .timedOut) -> URLError {
        URLError(code, userInfo: [
            NSURLErrorFailingURLStringErrorKey: syntheticURL,
            NSURLErrorFailingURLErrorKey: URL(string: syntheticURL)!,
            NSLocalizedDescriptionKey: "The request to \(syntheticURL) timed out"
        ])
    }

    private struct LeakyError: LocalizedError, CustomStringConvertible {
        var errorDescription: String? {
            "POST \(TelegramSendMessageClientTests.syntheticURL) failed"
        }

        var description: String {
            "token \(TelegramSendMessageClientTests.syntheticToken)"
        }
    }
}

private final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    enum Behavior {
        case respond(status: Int, body: Data)
        case fail(any Error)
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    var requestCount: Int {
        requests.count
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        switch behavior {
        case let .respond(status, body):
            // The stub response deliberately carries the tokenized URL, as a real one would.
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return HTTPResponse(data: body, http: http)
        case let .fail(error):
            throw error
        }
    }

    func bytes(for _: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) {
        XCTFail("Telegram transport must not stream")
        throw URLError(.unsupportedURL)
    }
}
