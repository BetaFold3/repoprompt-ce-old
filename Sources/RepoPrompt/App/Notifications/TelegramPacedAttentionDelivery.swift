import Foundation
import RepoPromptAgentCore
import RepoPromptRemoteWire

// Paced Telegram delivery for admitted attention events
// (docs/context/plans/2026-10-10-telegram-attention-notifications-contract.md, Slice 4).
//
// One immutable credential/client snapshot per configuration; replacements share one pacer, so
// reconfiguring never resets the rate limit. The queue head waits for its first message before
// admission (`prepareForAdmission`); later parts wait before their POST. Parts are sent in order,
// one POST attempt each, never retried, and the attempt stops at the first unconfirmed part.
// Nothing here is wired to live events or reads secure storage.

/// Monotonic time source for pacing: elapsed time since an arbitrary origin, and a wait.
struct TelegramAttentionPacingClock {
    let now: @Sendable () -> Duration
    let wait: @Sendable (Duration) async -> Void

    static func continuous() -> TelegramAttentionPacingClock {
        let clock = ContinuousClock()
        let origin = clock.now
        return TelegramAttentionPacingClock(
            now: { origin.duration(to: clock.now) },
            wait: { try? await clock.sleep(for: $0) }
        )
    }
}

/// Service-lifetime spacing between Telegram requests (about one per second per chat, three
/// seconds in groups). Time is marked when a request is initiated, not when it responds.
actor TelegramAttentionPacer {
    static let privateChatSpacing: Duration = .seconds(1)
    static let groupChatSpacing: Duration = .seconds(3)

    private let clock: TelegramAttentionPacingClock
    private var nextEligible: Duration?

    init(clock: TelegramAttentionPacingClock = .continuous()) {
        self.clock = clock
    }

    /// Positive numeric chat IDs are private chats; negative IDs and `@channel` names are groups
    /// or channels and get the slower group spacing.
    static func spacing(for chatID: TelegramChatID) -> Duration {
        if case let .numeric(value) = chatID, value > 0 {
            return privateChatSpacing
        }
        return groupChatSpacing
    }

    func waitUntilEligible() async {
        guard let nextEligible else { return }
        let remaining = nextEligible - clock.now()
        if remaining > .zero {
            await clock.wait(remaining)
        }
    }

    func markRequestInitiated(spacing: Duration) {
        nextEligible = clock.now() + spacing
    }
}

/// Telegram delivery for one immutable bot token and chat ID.
///
/// The optional browser origin is link metadata, not configuration: it is read once at the
/// start of each admitted attempt and kept for all of that attempt's parts. Changing it never
/// replaces this delivery, so it never invalidates queued or pending alerts; with no active
/// origin the attempt is simply text-only.
struct TelegramPacedAttentionDelivery: AttentionNotificationDelivering {
    private let token: TelegramBotToken
    private let chatID: TelegramChatID
    private let client: TelegramSendMessageClient
    private let pacer: TelegramAttentionPacer
    /// The active paired-browser HTTPS origin now, or nil (text-only alerts).
    private let browserOrigin: @Sendable () async -> RemoteGatewayOrigin?

    init(
        token: TelegramBotToken,
        chatID: TelegramChatID,
        client: TelegramSendMessageClient,
        pacer: TelegramAttentionPacer,
        browserOrigin: @escaping @Sendable () async -> RemoteGatewayOrigin? = { nil }
    ) {
        self.token = token
        self.chatID = chatID
        self.client = client
        self.pacer = pacer
        self.browserOrigin = browserOrigin
    }

    /// `<origin>/?session_id=<UUID>` for session events; nil for the Send test or a non-HTTPS
    /// origin. The ID uses `uuidString`, the exact form the gateway reports as `session_id`.
    static func openSessionURL(origin: RemoteGatewayOrigin?, key: AttentionNotificationEventKey) -> URL? {
        guard let origin, origin.scheme == "https" else { return nil }
        let sessionID: UUID
        switch key {
        case let .turnCompleted(id, _), let .question(id, _):
            sessionID = id
        case .test:
            return nil
        }
        var components = URLComponents(url: origin.endpoint(path: "/"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "session_id", value: sessionID.uuidString)]
        return components?.url
    }

    func prepareForAdmission() async {
        await pacer.waitUntilEligible()
    }

    /// All parts confirmed: sent. The first part definitively rejected: failed. Any unconfirmed
    /// part, or a rejection after an earlier part was sent: unknown.
    /// The session link button rides on part 1 only, so it survives a later part's failure.
    func deliver(_ event: AttentionNotificationEvent) async -> AttentionNotificationDeliveryOutcome {
        let spacing = TelegramAttentionPacer.spacing(for: chatID)
        // One origin snapshot per admitted attempt (the Send test never carries a link).
        let origin = event.key.isManualTest ? nil : await browserOrigin()
        let link = Self.openSessionURL(origin: origin, key: event.key)
        for (index, part) in TelegramAttentionMessageRenderer.render(event).enumerated() {
            if index > 0 {
                await pacer.waitUntilEligible()
            }
            await pacer.markRequestInitiated(spacing: spacing)
            switch await client.send(text: part.text, to: chatID, token: token, openSessionURL: index == 0 ? link : nil) {
            case .sent:
                continue
            case .failed:
                return index == 0 ? .failed : .unknown
            case .unknown:
                return .unknown
            }
        }
        return .sent
    }
}
