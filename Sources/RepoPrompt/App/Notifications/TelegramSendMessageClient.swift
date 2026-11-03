import Foundation
import RepoPromptAgentCore
import RepoPromptPlatform

// Telegram transport for outbound attention notifications
// (docs/context/plans/2026-10-10-telegram-attention-notifications-contract.md, Slice 3).
//
// One `sendMessage` POST per call, plain text only, never retried. Results are finite sanitized
// enums: no raw error, response body, URL, request, or token is retained or logged. Pacing and
// pre-send admission belong to the caller (a later slice); nothing here is wired to live events.

/// A validated Telegram bot token. Its textual, debug, and reflected forms are redacted.
struct TelegramBotToken: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    fileprivate let rawValue: String

    /// Accepts `<digits>:<[A-Za-z0-9_-]+>` after trimming surrounding whitespace, so the token can
    /// never change the fixed endpoint's host, path, query, or fragment.
    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: ":") else { return nil }
        let botID = trimmed[..<separator]
        let secret = trimmed[trimmed.index(after: separator)...]
        guard !botID.isEmpty, !secret.isEmpty,
              botID.unicodeScalars.allSatisfy(Self.isASCIIDigit),
              secret.unicodeScalars.allSatisfy({ Self.isASCIIAlphanumeric($0) || $0 == "_" || $0 == "-" })
        else { return nil }
        rawValue = trimmed
    }

    var description: String {
        "TelegramBotToken(redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }

    /// Secure-storage persistence only; never use for display or diagnostics.
    var secureStorageValue: String {
        rawValue
    }

    static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && CharacterSet.decimalDigits.contains(scalar)
    }

    static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
    }
}

/// A validated Telegram chat identifier: a numeric chat ID or an `@channel` username.
enum TelegramChatID: Equatable {
    case numeric(Int64)
    case username(String)

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int64(trimmed) {
            self = .numeric(value)
            return
        }
        let name = trimmed.dropFirst()
        guard trimmed.first == "@", name.count >= 4,
              name.unicodeScalars.allSatisfy({ TelegramBotToken.isASCIIAlphanumeric($0) || $0 == "_" })
        else { return nil }
        self = .username(trimmed)
    }
}

/// The message was definitely not delivered: Telegram explicitly rejected it, it was rejected
/// before any request, or the request could not leave the Mac.
enum TelegramSendFailure: String, Equatable, CaseIterable {
    /// Empty or over-limit text; no request was made.
    case invalidMessage
    /// DNS, connection, or server-certificate failure before any request was sent.
    case notConnected
    /// HTTP 401 or API error 401 (bad token).
    case unauthorized
    /// HTTP 403 or API error 403 (for example, the bot was blocked).
    case forbidden
    /// HTTP 400 or API error 400 (for example, chat not found).
    case badRequest
    /// HTTP 429 or API error 429; not retried.
    case rateLimited
    /// A redirect was refused; the request was not forwarded.
    case redirectRefused
    /// Any other explicit HTTP/API rejection.
    case rejected
}

/// The request may have reached Telegram, but delivery could not be confirmed.
enum TelegramSendUncertainty: String, Equatable, CaseIterable {
    /// The transport failed, timed out, or was cancelled after the request was handed off.
    case requestInterrupted
    /// A success status arrived without a readable `ok: true` confirmation.
    case unreadableResponse
    /// An HTTP or API server error: the message may have been accepted before the failure.
    case serverUnconfirmed
}

/// Sanitized outcome of one `sendMessage` attempt.
enum TelegramSendResult: Equatable {
    case sent
    case failed(TelegramSendFailure)
    case unknown(TelegramSendUncertainty)

    var deliveryOutcome: AttentionNotificationDeliveryOutcome {
        switch self {
        case .sent: .sent
        case .failed: .failed
        case .unknown: .unknown
        }
    }

    /// Fixed, user-facing text for settings and diagnostics. Never contains request details.
    var diagnosticMessage: String {
        switch self {
        case .sent:
            "Sent."
        case let .failed(failure):
            switch failure {
            case .invalidMessage: "Not sent: the message was empty or too long."
            case .notConnected: "Not sent: could not connect to Telegram."
            case .unauthorized: "Telegram rejected the bot token."
            case .forbidden: "Telegram refused delivery to this chat."
            case .badRequest: "Telegram rejected the request (check the chat ID)."
            case .rateLimited: "Telegram rate-limited the message; it was not retried."
            case .redirectRefused: "Telegram redirected the request; it was not followed."
            case .rejected: "Telegram rejected the message."
            }
        case let .unknown(uncertainty):
            switch uncertainty {
            case .requestInterrupted: "Delivery unknown: the request did not complete."
            case .unreadableResponse: "Delivery unknown: Telegram's reply could not be read."
            case .serverUnconfirmed: "Delivery unknown: a server error arrived without Telegram's confirmation."
            }
        }
    }
}

/// Single-message Telegram `sendMessage` client. One POST attempt per call, never retried.
struct TelegramSendMessageClient {
    /// Telegram's documented `sendMessage` text limit. Enforced conservatively in UTF-16 units.
    static let maximumTextUTF16Count = 4096
    static let requestTimeout: TimeInterval = 15
    /// Label of the optional inline URL button that opens the session in the paired browser.
    static let openSessionButtonText = "Open session"

    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = TelegramHTTPClient.shared) {
        self.httpClient = httpClient
    }

    /// `openSessionURL` adds one inline-keyboard URL button; the text stays plain.
    func send(
        text: String,
        to chatID: TelegramChatID,
        token: TelegramBotToken,
        openSessionURL: URL? = nil
    ) async -> TelegramSendResult {
        guard !text.isEmpty, text.utf16.count <= Self.maximumTextUTF16Count,
              let request = Self.makeRequest(text: text, chatID: chatID, token: token, openSessionURL: openSessionURL)
        else {
            return .failed(.invalidMessage)
        }
        let response: HTTPResponse
        do {
            response = try await httpClient.data(for: request)
        } catch let error as URLError {
            // Only the code is read; `userInfo` and descriptions carry the tokenized failing URL.
            return Self.isDefinitelyNotSent(error.code) ? .failed(.notConnected) : .unknown(.requestInterrupted)
        } catch {
            // The error is intentionally dropped unread: it may describe the tokenized URL.
            return .unknown(.requestInterrupted)
        }
        return Self.classify(status: response.http.statusCode, body: response.data)
    }

    /// URL-loading failures that occur before any request byte can reach Telegram: no name
    /// resolution, no connection, or a server certificate refused during the handshake.
    /// The generic `secureConnectionFailed` stays unknown because it is also reported for TLS
    /// failures after the handshake; offline errors, timeouts, lost connections, and cancellation
    /// stay unknown because the connection may have dropped after sending.
    static func isDefinitelyNotSent(_ code: URLError.Code) -> Bool {
        switch code {
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            true
        default:
            false
        }
    }

    static func makeRequest(
        text: String,
        chatID: TelegramChatID,
        token: TelegramBotToken,
        openSessionURL: URL? = nil
    ) -> URLRequest? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.telegram.org"
        components.path = "/bot\(token.rawValue)/sendMessage"
        guard let url = components.url else { return nil }

        let chatValue: Any = switch chatID {
        case let .numeric(value): NSNumber(value: value)
        case let .username(name): name
        }
        var payload: [String: Any] = ["chat_id": chatValue, "text": text]
        if let openSessionURL {
            payload["reply_markup"] = [
                "inline_keyboard": [[["text": openSessionButtonText, "url": openSessionURL.absoluteString]]]
            ]
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// Telegram's reply envelope. `ok` must be a JSON boolean; numbers or strings do not decode.
    private struct Reply: Decodable {
        let ok: Bool
        let errorCode: Int?

        enum CodingKeys: String, CodingKey {
            case ok
            case errorCode = "error_code"
        }
    }

    static func classify(status: Int, body: Data) -> TelegramSendResult {
        let reply = try? JSONDecoder().decode(Reply.self, from: body)
        if (200 ..< 300).contains(status) {
            switch reply?.ok {
            case .some(true): return .sent
            case .some(false): return rejection(code: reply?.errorCode ?? status)
            case nil: return .unknown(.unreadableResponse)
            }
        }
        if (300 ..< 400).contains(status) {
            return .failed(.redirectRefused)
        }
        if let reply, !reply.ok {
            // Ordinary API rejections are definitive; server errors may have followed acceptance.
            return rejection(code: reply.errorCode ?? status)
        }
        if (500 ..< 600).contains(status) {
            // A gateway or server error without Telegram's verdict: the message may have gone out.
            return .unknown(.serverUnconfirmed)
        }
        return rejection(code: status)
    }

    private static func rejection(code: Int) -> TelegramSendResult {
        switch code {
        case 400: .failed(.badRequest)
        case 401: .failed(.unauthorized)
        case 403: .failed(.forbidden)
        case 429: .failed(.rateLimited)
        case 500 ..< 600: .unknown(.serverUnconfirmed)
        default: .failed(.rejected)
        }
    }
}

/// Narrow `HTTPClient` for Telegram: dedicated ephemeral session without cookies, cache, or
/// credential storage, finite timeouts, and every redirect refused so neither the tokenized URL
/// nor the request body is forwarded.
final class TelegramHTTPClient: HTTPClient, @unchecked Sendable {
    static let shared = TelegramHTTPClient()

    private let session: URLSession
    private let redirectDelegate = RedirectRefusingDelegate()

    init(configuration: URLSessionConfiguration = TelegramHTTPClient.makeConfiguration()) {
        session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    deinit {
        // A session retains its delegate until invalidated.
        session.invalidateAndCancel()
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request, delegate: redirectDelegate)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return HTTPResponse(data: data, http: http)
    }

    func bytes(for request: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (bytes: bytes, http: http)
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = TelegramSendMessageClient.requestTimeout
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return config
    }

    final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest _: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
