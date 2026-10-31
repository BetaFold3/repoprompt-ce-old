import Combine
import Foundation
import RepoPromptRemoteWire

@MainActor
final class RemoteGatewayStatusStore: ObservableObject {
    static let shared = RemoteGatewayStatusStore()

    enum Status: Equatable {
        case disabled
        case resolvingTailscale
        case starting(RemoteGatewayOrigin)
        case discoverable(RemoteGatewayOrigin)
        case unavailable(String)
        case failed(String)

        var origin: RemoteGatewayOrigin? {
            switch self {
            case let .starting(origin), let .discoverable(origin):
                origin
            case .disabled, .resolvingTailscale, .unavailable, .failed:
                nil
            }
        }

        var summary: String {
            switch self {
            case .disabled:
                "Disabled"
            case .resolvingTailscale:
                "Resolving Tailscale binding…"
            case let .starting(origin):
                "Starting on \(origin.string)…"
            case let .discoverable(origin):
                "Discoverable on \(origin.string)"
            case let .unavailable(reason):
                "Unavailable: \(reason)"
            case let .failed(message):
                "Failed: \(message)"
            }
        }
    }

    @Published private(set) var status: Status = .disabled
    /// The browser HTTPS origin passed to the current launch (shown while starting, too).
    @Published private(set) var browserOrigin: RemoteGatewayOrigin?
    /// The browser HTTPS origin only while the gateway is discoverable; nil when the port is
    /// unset or the gateway is not active. Telegram session links use this value.
    @Published private(set) var activeBrowserOrigin: RemoteGatewayOrigin?

    /// How a stop withdraws the gateway.
    enum Stop: Equatable {
        /// Remote Control was turned off.
        case disabled
        /// The gateway stops while Remote Control stays on (for example with the MCP server).
        case stopped(reason: String)
    }

    /// Publishes the start of a stop for `generation`, before termination is awaited, so the
    /// browser link stops being active at once. A store that was never enabled stays disabled.
    @discardableResult
    func publishStop(_ stop: Stop, generation: UInt64) -> Bool {
        switch stop {
        case .disabled:
            publish(.disabled, generation: generation)
        case let .stopped(reason):
            publish(status == .disabled ? .disabled : .unavailable(reason), generation: generation)
        }
    }

    /// The newest activation-gate generation published so far.
    private var publishedGeneration: UInt64 = 0

    /// Publishes `status` for an activation-gate `generation`. A publication from an older
    /// generation than one already published is stale (it lost a race with a newer apply,
    /// stop, or exit) and is ignored, so it cannot re-advertise a stopped gateway's link.
    @discardableResult
    func publish(_ status: Status, browserOrigin: RemoteGatewayOrigin? = nil, generation: UInt64) -> Bool {
        guard generation >= publishedGeneration else { return false }
        publishedGeneration = generation
        let launchOrigin = status.origin == nil ? nil : browserOrigin
        let active: RemoteGatewayOrigin? = if case .discoverable = status { launchOrigin } else { nil }
        self.status = status
        if self.browserOrigin != launchOrigin {
            self.browserOrigin = launchOrigin
        }
        if activeBrowserOrigin != active {
            activeBrowserOrigin = active
        }
        return true
    }
}
